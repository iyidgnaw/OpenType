import XCTest
@testable import OpenType

/// The Swift half of §G's cross-language contract: `McpServerSummary`
/// classifying `GET /config/mcp`'s `lastStartupError` into the
/// `McpStartupFailure` the MCP panel renders.
///
/// ---------------------------------------------------------------------------
/// Why this file exists separately from `McpServerCodingTests`
/// ---------------------------------------------------------------------------
///
/// That file pins payload *shapes* — what decodes into what. This one pins a
/// **coupling between two languages**, which is a different risk. The sidecar
/// reports both failure kinds through one string and marks the timeout kind by
/// stamping a prefix on it (`MCP_STARTUP_TIMEOUT_PREFIX` in
/// `sidecar/src/agent/mcpConfigRoutes.ts`); Swift prefix-matches that literal to
/// choose between 「启动超时，已跳过」 and showing the server's own error. Nothing
/// in the type system connects the two constants, so the only thing that can
/// keep them together is a test on each side that names the literal. The
/// TypeScript side has one (`test/agent/mcpStartupErrorReporting.test.ts`);
/// without this file the Swift side had none, and a reworded prefix would leave
/// both suites green while every timeout silently started rendering as a
/// generic failure — sending a user with a mistyped command off to check their
/// network.
///
/// **Every expected string below is written out in full, deliberately.**
/// Reusing `McpServerSummary`'s own private marker would make these tests pass
/// no matter what the sidecar actually sends, which is precisely the failure
/// they exist to catch. The literal here — including its trailing space — is a
/// transcription of what `startupErrorFor` emits, and it is meant to be
/// compared by eye against that function when either side moves.
///
/// Decoding goes through `SidecarClient.decodeResponse(fromRawOutput:)`, the
/// same seam `McpServerCodingTests` uses, so these exercise the real decode
/// path from the bytes the sidecar writes.
final class McpStartupFailureTests: XCTestCase {

    /// Verbatim from `MCP_STARTUP_TIMEOUT_PREFIX`, trailing space included.
    /// Swift's own marker omits that trailing space and `hasPrefix` absorbs the
    /// difference — a near-miss that is fine today and exactly the kind of thing
    /// that stops being fine unnoticed, so the wire form is what is pinned here.
    private static let timeoutPrefix = "Startup timed out: "

    /// What `startMcpConnections` records for a server that never answered,
    /// at the default 12s budget.
    private static let recordedTimeout = "No response within 12000ms."

    /// One `GET /config/mcp` response, in the shape the sidecar actually emits
    /// — `enabled` always present, `lastStartupError` present only when there
    /// is something to report.
    private func configJSON(servers: String) -> String {
        #"{"configured":true,"source":"saved","servers":[\#(servers)]}"#
    }

    private func serverJSON(name: String, lastStartupError: String? = nil) -> String {
        let error = lastStartupError.map { #","lastStartupError":"\#($0)""# } ?? ""
        return #"{"name":"\#(name)","transport":"stdio","command":"npx","args":["-y","@example/\#(name)"],"enabled":true\#(error)}"#
    }

    private func decodeServers(_ json: String) throws -> [String: McpServerSummary] {
        let summary: McpConfigSummary = try SidecarClient.decodeResponse(fromRawOutput: json)
        return Dictionary(uniqueKeysWithValues: summary.servers.map { ($0.name, $0) })
    }

    // MARK: - The timeout marker

    /// The load-bearing one: the exact bytes the sidecar writes for a server it
    /// gave up on must reach `.timedOut`.
    func testTheSidecarsTimeoutStringClassifiesAsTimedOut() throws {
        let json = configJSON(
            servers: serverJSON(
                name: "hungServer",
                lastStartupError: Self.timeoutPrefix + Self.recordedTimeout
            )
        )

        let servers = try decodeServers(json)
        let server = try XCTUnwrap(servers["hungServer"])

        XCTAssertEqual(server.lastStartupError, "Startup timed out: No response within 12000ms.")
        XCTAssertEqual(server.startupFailure, .timedOut)
    }

    /// The marker is what is matched, not the sentence after it. A shorter
    /// budget (or any later improvement to what `startMcpConnections` records)
    /// changes the tail and must not change the verdict — that pass-through is
    /// the reason the sidecar prefixes rather than replaces.
    func testAnyRecordedTailBehindTheMarkerIsStillATimeout() throws {
        let json = configJSON(
            servers: serverJSON(
                name: "hungServer",
                lastStartupError: Self.timeoutPrefix + "gave up after 8s waiting on listTools"
            )
        )

        let servers = try decodeServers(json)

        XCTAssertEqual(servers["hungServer"]?.startupFailure, .timedOut)
    }

    // MARK: - An outright failure

    /// `spawn npx ENOENT` is the actionable half of the message, so it must
    /// arrive whole — the row interpolates it verbatim, and paraphrasing would
    /// delete the only evidence the user has.
    func testAnOutrightFailureCarriesItsRealErrorAndIsNotATimeout() throws {
        let json = configJSON(
            servers: serverJSON(name: "badServer", lastStartupError: "spawn npx ENOENT")
        )

        let servers = try decodeServers(json)
        let server = try XCTUnwrap(servers["badServer"])

        XCTAssertEqual(server.startupFailure, .failed("spawn npx ENOENT"))
        XCTAssertNotEqual(server.startupFailure, .timedOut)
    }

    /// A failure whose own text happens to mention a timeout is still a
    /// failure. The distinction is the sidecar's marker at the *start* of the
    /// string, never timeout-ish words anywhere in it — matching by
    /// `contains` would classify this real, fixable connection error as "we
    /// skipped it" and drop the address the user needs.
    func testAFailureThatMentionsATimeoutInItsOwnTextStaysAFailure() throws {
        let message = "connect ETIMEDOUT 10.0.0.1:443"
        let json = configJSON(
            servers: serverJSON(name: "unreachable", lastStartupError: message)
        )

        let servers = try decodeServers(json)

        XCTAssertEqual(servers["unreachable"]?.startupFailure, .failed(message))
    }

    // MARK: - Nothing to report

    /// The common case: a server that connected, is still connecting, or was
    /// never in the boot set at all. The sidecar omits the key entirely, and
    /// omitted must mean "no line", not a decode failure.
    func testAnAbsentErrorMeansNoFailure() throws {
        let json = configJSON(servers: serverJSON(name: "healthyServer"))

        let servers = try decodeServers(json)
        let server = try XCTUnwrap(servers["healthyServer"])

        XCTAssertNil(server.lastStartupError)
        XCTAssertNil(server.startupFailure)
    }

    /// Blank is not a failure either. A `.failed("")` would draw the warning
    /// triangle and the amber dot under a server that is working fine, with an
    /// empty sentence beside it — the row would be lying in the one direction
    /// this feature exists to stop it lying in.
    func testBlankAndWhitespaceOnlyErrorsAreNotFailures() throws {
        let json = configJSON(
            servers: [
                serverJSON(name: "emptyString", lastStartupError: ""),
                serverJSON(name: "whitespaceOnly", lastStartupError: "   "),
            ].joined(separator: ",")
        )

        let servers = try decodeServers(json)

        XCTAssertNil(servers["emptyString"]?.startupFailure)
        XCTAssertNil(servers["whitespaceOnly"]?.startupFailure)
    }

    // MARK: - The two kinds, side by side

    /// One response, three servers, three different verdicts. This is what the
    /// panel actually renders off, and the same property the sidecar test
    /// asserts from its end: a timeout, a failure and a healthy server must not
    /// collapse into each other anywhere along the way.
    func testTheThreeVerdictsStayDistinctWithinOneResponse() throws {
        let json = configJSON(
            servers: [
                serverJSON(
                    name: "hungServer",
                    lastStartupError: Self.timeoutPrefix + Self.recordedTimeout
                ),
                serverJSON(name: "badServer", lastStartupError: "spawn npx ENOENT"),
                serverJSON(name: "healthyServer"),
            ].joined(separator: ",")
        )

        let servers = try decodeServers(json)

        XCTAssertEqual(servers["hungServer"]?.startupFailure, .timedOut)
        XCTAssertEqual(servers["badServer"]?.startupFailure, .failed("spawn npx ENOENT"))
        XCTAssertNil(servers["healthyServer"]?.startupFailure)
    }
}
