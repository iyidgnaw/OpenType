import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the third leg of 「清除本地数据」
/// (`AppModel.resetHistory()`): run logs.
///
/// `run-logs/<runId>.jsonl` (`sidecar/src/agent/runLog.ts`, written from
/// `sidecar/src/agent/routes.ts`'s `void runLog?.append(...)`) is a durable
/// per-run record of every agent step -- what the user asked the agent to
/// do, and everything it did in response. `resetHistory()` today clears
/// exactly two sidecar-side stores (`DELETE /memory/events`,
/// `DELETE /memory/context-log` -- see `HistoryEventsRequestTests.swift` /
/// `HistoryResetContextLogTests.swift`) but never this one, even though it
/// is exactly the kind of "record of what the user asked" the reset button
/// already promises to clear. The new sidecar route this pairs with is
/// `DELETE /agent/run-logs` (pinned server-side by
/// `sidecar/test/agent/runLogRoutes.test.ts`).
///
/// ## Why a request-shape seam and not a mock sidecar
///
/// Same constraint `HistoryResetContextLogTests.swift` and
/// `HistoryEventsRequestTests.swift` already document and already solved:
/// `AppModel.init` spawns the sidecar child process, registers global
/// hotkeys, and touches `NSApp`, so no test in this suite constructs a live
/// instance. Following that exact precedent rather than inventing a second
/// pattern, the method/path this new leg sends is pulled out as its own
/// value, mirroring `ContextLogResetRequest` (a single DELETE-only resource,
/// not a CRUD family like `/memory/events`'s `HistoryEventsRequest`):
///
///     extension AppModel {
///         struct RunLogsResetRequest: Equatable {
///             let method: String
///             let path: String
///         }
///         static let runLogsResetRequest: RunLogsResetRequest
///     }
///
/// **Naming/type judgment call (flagging per pipeline instructions rather
/// than silently picking one and moving on):** the task only says to
/// "extend that same seam" -- it does not say whether the third leg should
/// reuse the existing `HistoryEventsRequest` type (the `/memory/events`
/// family's shape) or get its own type the way `ContextLogResetRequest`
/// already does for the *other* single-resource DELETE-only leg. This file
/// picks the latter (a new `RunLogsResetRequest` type) because `/agent/
/// run-logs`, like `/memory/context-log`, is one DELETE-only endpoint with
/// no per-row CRUD siblings -- structurally the `ContextLogResetRequest`
/// case, not the `HistoryEventsRequest` case. If stage 3 prefers reusing
/// `HistoryEventsRequest` instead, this file's type name is the one thing
/// that would need to change to match; the assertions themselves (method,
/// path, distinctness) do not depend on which choice wins.
///
/// `resetHistory()` must be `runLogsResetRequest`'s only reader, same
/// discipline as the other two legs.
///
/// ## What this file does *not* pin
///
/// Same three gaps `HistoryResetContextLogTests.swift` already documents,
/// now for the third leg too -- none of these are reachable without a live
/// `AppModel` (or a new mock-sidecar layer this codebase does not currently
/// have, which the pipeline's instructions say not to invent):
///
///   1. That `resetHistory()` actually issues this third request (not just
///      that the constant holds the right method/path).
///   2. That a failure in this third leg is recorded to
///      `historyResetError` the same way a failure in either existing leg
///      already is -- `resetHistory()`'s doc comment and implementation are
///      the contract stage 3/4 must honor by inspection; there is no
///      request-shape-only way to observe it.
///   3. That this third request fires *alongside*, not instead of, the
///      other two (mirrors `testResetRequestIsDistinctFromTheExisting
///      ContextLogResetRequest`'s reasoning in `HistoryEventsRequestTests`
///      -- guarded here the same way, via path distinctness, which is as
///      far as a request-shape seam can reach).
final class RunLogsResetRequestTests: XCTestCase {

    /// Pins the HTTP method and path `resetHistory()` must send to clear
    /// the sidecar's run-log files, matching what `buildAgentRoutes` serves
    /// as `DELETE /agent/run-logs`.
    func testRunLogsResetRequestMatchesTheSidecarRoute() {
        let request = AppModel.runLogsResetRequest

        XCTAssertEqual(
            request,
            AppModel.RunLogsResetRequest(method: "DELETE", path: "/agent/run-logs"),
            "resetHistory() must call the exact method/path buildAgentRoutes serves as DELETE /agent/run-logs"
        )
    }

    /// Design intent: run-log clearing is additive alongside the existing
    /// context-log clear, not a replacement for it -- guards against
    /// someone "simplifying" `resetHistory()` down to only one DELETE call
    /// per store.
    func testRunLogsResetRequestIsDistinctFromTheExistingContextLogResetRequest() {
        XCTAssertNotEqual(
            AppModel.runLogsResetRequest.path,
            AppModel.contextLogResetRequest.path
        )
    }

    /// Same guard against the events-store leg specifically: three distinct
    /// sidecar resources, three distinct requests.
    func testRunLogsResetRequestIsDistinctFromTheExistingHistoryEventsResetRequest() {
        XCTAssertNotEqual(
            AppModel.runLogsResetRequest.path,
            AppModel.historyEventsResetRequest.path
        )
    }
}
