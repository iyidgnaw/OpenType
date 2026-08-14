import XCTest
@testable import OpenType

/// The sidecar's own defaults for every writable path are RELATIVE to its
/// source checkout (`sidecar/.data/...`), which is only correct under a
/// `bun run` dev launch. A packaged launch inherits the app's cwd — often
/// `/`, a read-only volume — so every such path has to be pinned to an
/// absolute, writable location by the spawning side.
///
/// This is the test that would have caught the spill/run-log defect: both
/// features were wired end to end, tested, and shipped, yet neither ever ran
/// in the packaged app because nothing told the sidecar where to write. Both
/// degrade silently by design (a failed audit write must not fail the run
/// that produced it), so nothing surfaced — the failure mode of a
/// best-effort feature is silence, which is exactly why its wiring needs a
/// test rather than a smoke check.
final class SidecarEnvironmentTests: XCTestCase {
    private let socketURL = URL(
        fileURLWithPath: "/Users/someone/Library/Application Support/OpenType/sidecar.sock"
    )

    private var dataDirectory: String {
        socketURL.deletingLastPathComponent().path
    }

    func testEveryWritablePathIsPinnedNextToTheSocket() {
        let env = SidecarClient.dataDirectoryEnvironment(socketURL: socketURL)

        // Naming each key explicitly rather than asserting a count: a new
        // writable path added to the sidecar has to be added here too, and a
        // count assertion would pass while leaving it unpinned.
        for key in [
            "OPENTYPE_SIDECAR_DB_PATH",
            "OPENTYPE_CONTEXT_LOG_PATH",
            "OPENTYPE_WHISPER_SOCKET",
            "OPENTYPE_SPILL_ROOT",
            "OPENTYPE_RUN_LOG_ROOT",
        ] {
            guard let value = env[key] else {
                XCTFail("\(key) is not set: the sidecar would fall back to a relative path")
                continue
            }
            XCTAssertTrue(
                value.hasPrefix("/"),
                "\(key) must be absolute, got \(value)"
            )
            XCTAssertTrue(
                value.hasPrefix(dataDirectory),
                "\(key) must sit in the sidecar's data directory, got \(value)"
            )
        }
    }

    func testPathsAreDistinctFromOneAnother() {
        let env = SidecarClient.dataDirectoryEnvironment(socketURL: socketURL)

        XCTAssertEqual(
            Set(env.values).count,
            env.count,
            "two writable paths collided: \(env)"
        )
    }

    func testItFollowsTheSocketRatherThanHardcodingAHome() {
        // The socket location varies (dev runs put it under /tmp), so these
        // must be derived from it, not from a fixed Application Support path.
        let elsewhere = URL(fileURLWithPath: "/tmp/opentype-dev/sidecar.sock")

        let env = SidecarClient.dataDirectoryEnvironment(socketURL: elsewhere)

        for (key, value) in env {
            XCTAssertTrue(
                value.hasPrefix("/tmp/opentype-dev"),
                "\(key) ignored the socket location: \(value)"
            )
        }
    }

    func testSpillAndRunLogAreDirectoriesNotFiles() {
        let env = SidecarClient.dataDirectoryEnvironment(socketURL: socketURL)

        // Both are roots the sidecar mkdirs into; a path carrying a file
        // extension would be a sign one was pointed at a single file.
        XCTAssertEqual(URL(fileURLWithPath: env["OPENTYPE_SPILL_ROOT"] ?? "").pathExtension, "")
        XCTAssertEqual(URL(fileURLWithPath: env["OPENTYPE_RUN_LOG_ROOT"] ?? "").pathExtension, "")
    }
}
