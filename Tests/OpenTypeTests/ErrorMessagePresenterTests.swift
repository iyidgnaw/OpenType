import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for two `ErrorMessagePresenter` defects:
///
/// - P1-2: `SidecarClientError` values fall through the presenter's
///   `OpenTypeError`/`URLError` handling to `error.localizedDescription`,
///   leaking raw low-level strings ("Sidecar request failed (curl exit 7): …",
///   the captured stderr, HTTP body dumps) into user-facing surfaces. The app
///   promises never to surface raw low-level errors, so the presenter must map
///   each case to a friendly localized (Chinese) summary.
/// - P1-3: the unauthorized / invalid-api-key branch names "DashScope", a
///   removed provider brand, which must no longer appear in any message.
///
/// These assert the DESIRED behavior and are expected to FAIL until Stage 3
/// updates `ErrorMessagePresenter`.
final class ErrorMessagePresenterTests: XCTestCase {

    // MARK: - P1-2: SidecarClientError must not leak raw technical strings

    func testRequestFailedErrorDoesNotLeakRawCurlDetails() {
        let stderr = "curl: (7) Failed to connect to unix socket: Connection refused"
        let message = ErrorMessagePresenter.message(
            for: SidecarClientError.requestFailed(exitCode: 7, stderr: stderr)
        )

        // Must be a friendly mapped summary, not the raw localizedDescription
        // ("Sidecar request failed (curl exit 7): …").
        XCTAssertFalse(
            message.contains("Sidecar request failed"),
            "Leaked raw error prefix: \(message)"
        )
        XCTAssertFalse(message.contains("curl"), "Leaked 'curl': \(message)")
        XCTAssertFalse(message.contains("exit"), "Leaked 'exit': \(message)")
        XCTAssertFalse(
            message.contains(stderr),
            "Leaked captured stderr text: \(message)"
        )
        XCTAssertFalse(message.isEmpty, "Presenter returned an empty message")
    }

    func testResponseDecodingFailedErrorDoesNotLeakRawBodyOrReason() {
        let reason = "Expected to decode Dictionary but found a string instead."
        let body = "<html><body>502 Bad Gateway</body></html>"
        let message = ErrorMessagePresenter.message(
            for: SidecarClientError.responseDecodingFailed(
                status: 502,
                reason: reason,
                body: body
            )
        )

        XCTAssertFalse(
            message.contains("Failed to decode sidecar response"),
            "Leaked raw decode-failure prefix: \(message)"
        )
        XCTAssertFalse(message.contains(reason), "Leaked decoding reason: \(message)")
        XCTAssertFalse(message.contains(body), "Leaked raw HTTP body: \(message)")
        XCTAssertFalse(message.contains("HTTP"), "Leaked 'HTTP' token: \(message)")
        XCTAssertFalse(message.isEmpty, "Presenter returned an empty message")
    }

    func testProcessFailedToStartErrorDoesNotLeakRawDetail() {
        let message = ErrorMessagePresenter.message(
            for: SidecarClientError.processFailedToStart(
                "launch path /nope/opentype-sidecar not found"
            )
        )

        XCTAssertFalse(
            message.contains("Failed to start opentype-sidecar"),
            "Leaked raw start-failure prefix: \(message)"
        )
        XCTAssertFalse(
            message.contains("opentype-sidecar"),
            "Leaked internal binary name: \(message)"
        )
        XCTAssertFalse(message.isEmpty, "Presenter returned an empty message")
    }

    // MARK: - P1-3: unauthorized error must not reference removed "DashScope" brand

    func testUnauthorizedServiceErrorDoesNotMentionDashScope() {
        let message = ErrorMessagePresenter.message(
            for: OpenTypeError.service("<401> Unauthorized: invalid api-key")
        )

        XCTAssertFalse(
            message.localizedCaseInsensitiveContains("DashScope"),
            "Message references removed provider brand DashScope: \(message)"
        )
        XCTAssertFalse(message.isEmpty, "Presenter returned an empty message")
    }
}
