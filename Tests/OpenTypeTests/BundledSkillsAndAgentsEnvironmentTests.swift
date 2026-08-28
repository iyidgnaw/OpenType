import XCTest
@testable import OpenType

/// Stage-1 TDD test for the packaging bug tracked alongside `8abd25f` (the
/// batch that added `sidecar/skills/` and `sidecar/agents/`): the built-in
/// skill/agent system cannot work in the packaged `.app` for two compounding
/// reasons —
///
///   1. `scripts/build-app.sh` never copies `sidecar/skills/` or
///      `sidecar/agents/` into `Contents/Resources/` (see
///      `test-build-app-bundles-skills-and-agents.sh` in `scripts/tests/` for
///      the packaging half of this fix).
///   2. Even once those directories ARE bundled, nothing tells the sidecar
///      child process where to find them: `sidecar/src/server.ts` resolves
///      the built-in roots as `resolve(import.meta.dir, "..", "skills")` /
///      `"..", "agents"`, which in a `bun build --compile` binary points into
///      the embedded virtual filesystem, not a real directory beside the
///      binary — but `OPENTYPE_SKILLS_DIR` / `OPENTYPE_AGENTS_DIR` already
///      exist as override env vars (`sidecar/src/skills/skillRoots.ts`,
///      `sidecar/src/agent/agentRoots.ts`) precisely for this: they win over
///      the built-in default when set.
///
/// This file covers half 2's Swift side: `SidecarClient` must, when spawning
/// the sidecar child, point `OPENTYPE_SKILLS_DIR`/`OPENTYPE_AGENTS_DIR` at
/// the bundled copies IF this is a packaged launch (the launch already
/// distinguishes "packaged" from "dev/source" via
/// `FileManager.default.isExecutableFile(atPath: bundledBinaryPath)` for the
/// sidecar binary itself, in `start()`), and must NOT set them for a
/// dev/source run — so a source checkout keeps resolving skills/agents via
/// the sidecar's own `import.meta.dir` fallback exactly as it does today.
///
/// TARGET SEAM (does not exist yet — Stage 3 must add it):
///
///     nonisolated static func bundledSkillsAndAgentsEnvironment(
///         resourcePath: String?
///     ) -> [String: String]
///
/// A pure function mirroring the existing `loadBundledEnvironment(resourcePath:)`
/// (same file, same "overridable for testing, defaults to
/// `Bundle.main.resourcePath`" shape) and `dataDirectoryEnvironment(socketURL:)`
/// (same "pure builder function, tested directly rather than by spawning a
/// process and inspecting its real environment" precedent —
/// `SidecarEnvironmentTests.swift`). It should:
///
///   - return `[:]` when `resourcePath` is `nil` (mirrors
///     `loadBundledEnvironment`'s existing nil-resourcePath handling);
///   - check for `<resourcePath>/skills` and `<resourcePath>/agents` as
///     DIRECTORIES on disk (not just any file with that name — a stray file
///     of that name should not count as bundled);
///   - set `OPENTYPE_SKILLS_DIR`/`OPENTYPE_AGENTS_DIR` to the absolute path
///     of whichever of the two actually exist, and leave the corresponding
///     key entirely absent (not merely empty-string) when it does not.
///
/// `start()` must then merge this into the child's environment the same way
/// it already merges `loadBundledEnvironment()` and
/// `dataDirectoryEnvironment(socketURL:)`.
///
/// STAGE-2 REVIEW ADDITION: the gap called out above — a correct pure
/// function that nothing calls — is exactly the shape of two other defects
/// this codebase shipped in one night (an unwired skill-discovery TTL, and
/// Bug 1 itself). The three merges `start()` performs before branching on
/// packaged-vs-dev (`loadBundledEnvironment`, the socket path, and
/// `dataDirectoryEnvironment`) are a small, mechanical extraction away from
/// being one pure function, so this file additionally specifies and tests
/// that seam rather than accepting "untested merge point" as a closed
/// question:
///
///     nonisolated static func childEnvironment(
///         baseEnvironment: [String: String],
///         resourcePath: String?,
///         socketURL: URL
///     ) -> [String: String]
///
/// which composes, in order: `baseEnvironment`, then
/// `loadBundledEnvironment(resourcePath:)`, then `OPENTYPE_SIDECAR_SOCKET`,
/// then `dataDirectoryEnvironment(socketURL:)`, then THIS batch's
/// `bundledSkillsAndAgentsEnvironment(resourcePath:)`. Stage 3 must extract
/// `start()`'s existing inline merges (today around lines 357-366) into this
/// function and change `start()` to call it and assign the result, rather
/// than adding yet another untested inline merge for the new vars. This does
/// NOT reach the packaged-only whisper vars (`OPENTYPE_WHISPER_PYTHON_BIN`/
/// `_SCRIPT_PATH`), which stay entangled with the `bundledIsExecutable`
/// branch's `executableURL`/`arguments` selection — restructuring that too
/// is out of scope for this bug and not attempted here. The residual gap —
/// whether `start()` was actually edited to call `childEnvironment` and
/// assign its result to `process.environment`, rather than merging
/// `bundledSkillsAndAgentsEnvironment` inline as a fourth untested call — is
/// a small, visually-obvious diff; Stage 4 review must still confirm it by
/// reading `start()`, the same residual precedent already accepts for
/// `loadBundledEnvironment`/`dataDirectoryEnvironment`.
final class BundledSkillsAndAgentsEnvironmentTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ot-bsa-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    /// A packaged launch: `Contents/Resources/skills` and
    /// `Contents/Resources/agents` both exist as real directories.
    func testResourcesDirectoryContainingBothSubdirectoriesSetsBothEnvVars() throws {
        let skillsDir = tempDir.appendingPathComponent("skills", isDirectory: true)
        let agentsDir = tempDir.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let env = SidecarClient.bundledSkillsAndAgentsEnvironment(resourcePath: tempDir.path)

        XCTAssertEqual(env["OPENTYPE_SKILLS_DIR"], skillsDir.path)
        XCTAssertEqual(env["OPENTYPE_AGENTS_DIR"], agentsDir.path)
    }

    /// A dev/source run: the resources directory exists (e.g. a build
    /// product directory) but was never populated with bundled `skills/` /
    /// `agents/` copies. Neither var must be set, so the sidecar falls back
    /// to its own `import.meta.dir` resolution exactly as it does today —
    /// this is the regression a naive "always set them" fix would introduce.
    func testResourcesDirectoryWithoutEitherSubdirectorySetsNeitherVar() {
        // tempDir itself is empty — no skills/, no agents/.
        let env = SidecarClient.bundledSkillsAndAgentsEnvironment(resourcePath: tempDir.path)

        XCTAssertNil(env["OPENTYPE_SKILLS_DIR"], "a dev/source run must not set OPENTYPE_SKILLS_DIR")
        XCTAssertNil(env["OPENTYPE_AGENTS_DIR"], "a dev/source run must not set OPENTYPE_AGENTS_DIR")
        XCTAssertTrue(env.isEmpty, "expected no env entries at all for an unbundled resources directory, got \(env)")
    }

    /// A `nil` resourcePath (e.g. `Bundle.main.resourcePath` unavailable, the
    /// same case `loadBundledEnvironment` already handles) must not crash and
    /// must set nothing.
    func testNilResourcePathSetsNeitherVar() {
        let env = SidecarClient.bundledSkillsAndAgentsEnvironment(resourcePath: nil)

        XCTAssertTrue(env.isEmpty, "expected no env entries for a nil resourcePath, got \(env)")
    }

    /// Only one of the two bundled directories present (a partially-built
    /// Resources dir, or a future world where skills/agents ship on
    /// different timelines) — each var is decided independently, not as an
    /// all-or-nothing pair.
    func testOnlySkillsPresentSetsOnlySkillsVar() throws {
        let skillsDir = tempDir.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        let env = SidecarClient.bundledSkillsAndAgentsEnvironment(resourcePath: tempDir.path)

        XCTAssertEqual(env["OPENTYPE_SKILLS_DIR"], skillsDir.path)
        XCTAssertNil(env["OPENTYPE_AGENTS_DIR"])
    }

    /// A same-named FILE (not a directory) must not count as "bundled" — a
    /// stray `skills` file should not be handed to the sidecar as a root
    /// directory to scan.
    func testSameNamedFileIsNotTreatedAsABundledDirectory() throws {
        let skillsFile = tempDir.appendingPathComponent("skills", isDirectory: false)
        FileManager.default.createFile(atPath: skillsFile.path, contents: Data("not a directory".utf8))

        let env = SidecarClient.bundledSkillsAndAgentsEnvironment(resourcePath: tempDir.path)

        XCTAssertNil(env["OPENTYPE_SKILLS_DIR"], "a file named `skills` must not be treated as the bundled skills directory")
    }

    /// Every value this function ever sets must be an absolute path — the
    /// sidecar treats these as filesystem roots to scan, and a relative path
    /// would be resolved against whatever the child process's cwd happens to
    /// be at spawn time rather than the intended bundled location.
    func testValuesAreAlwaysAbsolutePaths() throws {
        let skillsDir = tempDir.appendingPathComponent("skills", isDirectory: true)
        let agentsDir = tempDir.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let env = SidecarClient.bundledSkillsAndAgentsEnvironment(resourcePath: tempDir.path)

        for (key, value) in env {
            XCTAssertTrue(value.hasPrefix("/"), "\(key) must be an absolute path, got \(value)")
        }
    }

    // MARK: - `childEnvironment`: the full spawn-environment composition
    //
    // These two tests are the priority item from stage-2 review: they pin
    // that `OPENTYPE_SKILLS_DIR`/`OPENTYPE_AGENTS_DIR` actually reach the
    // composed environment `start()` hands to the child process, not merely
    // that `bundledSkillsAndAgentsEnvironment` computes the right value in
    // isolation. See the type-level doc comment above for the exact seam
    // Stage 3 must add.

    /// The full composition includes this batch's new vars, AND does not
    /// clobber anything that was already going to be there: the caller's
    /// base environment, the socket path, and the (separately, and already,
    /// pinned by `SidecarEnvironmentTests.swift`) data-directory vars. This
    /// is what actually proves the new vars flow all the way into what gets
    /// handed to `Process.environment` — a bug here (e.g. wiring
    /// `bundledSkillsAndAgentsEnvironment`'s result somewhere `start()`
    /// doesn't read, or overwriting it before assignment) would be invisible
    /// to `testResourcesDirectoryContainingBothSubdirectoriesSetsBothEnvVars`
    /// above, which only calls the isolated builder directly.
    func testChildEnvironmentComposesBundledSkillsAndAgentsIntoTheFullSpawnEnvironment() throws {
        let skillsDir = tempDir.appendingPathComponent("skills", isDirectory: true)
        let agentsDir = tempDir.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let socketURL = URL(
            fileURLWithPath: "/Users/someone/Library/Application Support/OpenType/sidecar.sock"
        )

        let env = SidecarClient.childEnvironment(
            baseEnvironment: ["PATH": "/usr/bin", "HOME": "/Users/someone"],
            resourcePath: tempDir.path,
            socketURL: socketURL
        )

        XCTAssertEqual(env["OPENTYPE_SKILLS_DIR"], skillsDir.path)
        XCTAssertEqual(env["OPENTYPE_AGENTS_DIR"], agentsDir.path)

        // Nothing else the merge is responsible for got lost along the way.
        XCTAssertEqual(env["PATH"], "/usr/bin", "the caller's base environment must survive the merge")
        XCTAssertEqual(env["OPENTYPE_SIDECAR_SOCKET"], socketURL.path)
        XCTAssertNotNil(env["OPENTYPE_SIDECAR_DB_PATH"], "dataDirectoryEnvironment's own vars must still be merged in")
    }

    /// The dev/source case, composed end to end: an unbundled resources
    /// directory must not introduce either var into the full spawn
    /// environment, matching the isolated-builder test above but proven at
    /// the same composition seam `start()` actually uses.
    func testChildEnvironmentSetsNeitherSkillsNorAgentsVarForAnUnbundledResourcesDirectory() {
        let socketURL = URL(fileURLWithPath: "/tmp/opentype-dev/sidecar.sock")

        // tempDir has no skills/ or agents/ subdirectories.
        let env = SidecarClient.childEnvironment(
            baseEnvironment: [:],
            resourcePath: tempDir.path,
            socketURL: socketURL
        )

        XCTAssertNil(env["OPENTYPE_SKILLS_DIR"])
        XCTAssertNil(env["OPENTYPE_AGENTS_DIR"])
    }
}
