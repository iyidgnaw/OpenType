import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for Task 7 of `docs/superpowers/plans/
/// 2026-08-25-unified-memory-and-recent-context.md` ("听写历史换源") — the
/// request-shape half: which HTTP method/path `AppModel.refreshHistory()`,
/// `deleteHistoryEntry(id:)` and `resetHistory()` must send now that the
/// dictation history page reads the sidecar's `episodic_events` table
/// instead of the local `history.json`. The serving side already shipped
/// (Task 6, `sidecar/src/memory/routes.ts`): `GET /memory/events?limit=&mode=`
/// (newest-first, `EVENTS_LIMIT_CEILING = 200`), `DELETE /memory/events/:id`
/// (404 if the row is already gone), `DELETE /memory/events` (bulk reset,
/// paired with the existing `DELETE /memory/context-log`).
///
/// ## Why a request-shape seam and not a mock sidecar
///
/// The same constraint `HistoryResetContextLogTests.swift` already
/// documents and already solved once in this codebase: `AppModel.init`
/// spawns the sidecar child process, registers global hotkeys, and touches
/// `NSApp`, so no test in this suite constructs a live instance. Following
/// that file's precedent (`AppModel.contextLogResetRequest`) rather than
/// inventing a second pattern, the exact method/path each call sends is
/// pulled out as its own constant/function:
///
///     extension AppModel {
///         struct HistoryEventsRequest: Equatable {
///             let method: String
///             let path: String
///         }
///         static let historyEventsFetchRequest: HistoryEventsRequest
///         static func historyEventsDeleteRequest(id: Int) -> HistoryEventsRequest
///         static let historyEventsResetRequest: HistoryEventsRequest
///     }
///
/// `refreshHistory()`, `deleteHistoryEntry(id:)` and `resetHistory()` must
/// each be their constant's only reader — the same discipline
/// `contextLogResetRequest` already establishes in this file — a parallel,
/// unused constant that merely happens to hold the right string would pin
/// nothing real. `historyEventsDeleteRequest` is a function rather than a
/// constant because, unlike the other two, the path is per-row; a single
/// shared constant cannot express that.
///
/// ## What this file does not pin
///
/// Everything about a *live* `AppModel` is out of reach the same way it is
/// for `HistoryResetContextLogTests.swift`: that `refreshHistory()` actually
/// issues this exact request and decodes the response into `historyEntries`
/// via `HistoryEntry.init(from:)` (mapping pinned separately, without any
/// request at all, in `HistoryEntryMappingTests.swift`); that a failed fetch
/// leaves `historyEntries` untouched rather than clearing it; that
/// `deleteHistoryEntry(id:)` re-fetches afterward; that `resetHistory()`
/// fires this new request *alongside*, not instead of,
/// `contextLogResetRequest`; and that a successful `POST /memory/events`
/// (already wired — `AppModel.recordEpisodicEvent`) triggers a refresh
/// (design §3.7's "刷新时机两处"). These are stage-4 reading.
final class HistoryEventsRequestTests: XCTestCase {

    func testFetchRequestMatchesTheSidecarRouteAtTheDocumentedCeiling() {
        // `EVENTS_LIMIT_CEILING` in `sidecar/src/memory/routes.ts` is 200 —
        // the dictation history page wants everything the sidecar will hand
        // back in one page, which is the ceiling, not the smaller default a
        // caller that omitted `limit` would get.
        XCTAssertEqual(
            AppModel.historyEventsFetchRequest,
            AppModel.HistoryEventsRequest(method: "GET", path: "/memory/events?limit=200")
        )
    }

    func testDeleteRequestTargetsTheExactEventId() {
        XCTAssertEqual(
            AppModel.historyEventsDeleteRequest(id: 42),
            AppModel.HistoryEventsRequest(method: "DELETE", path: "/memory/events/42")
        )
    }

    func testDeleteRequestPathTracksWhicheverIdItIsBuiltFor() {
        // Not a single shared constant: a wrong/stale path here deletes the
        // wrong row, or nothing, while the context-menu action still reports
        // success.
        XCTAssertEqual(AppModel.historyEventsDeleteRequest(id: 7).path, "/memory/events/7")
        XCTAssertEqual(AppModel.historyEventsDeleteRequest(id: 1001).path, "/memory/events/1001")
    }

    func testResetRequestMatchesTheSidecarRoute() {
        XCTAssertEqual(
            AppModel.historyEventsResetRequest,
            AppModel.HistoryEventsRequest(method: "DELETE", path: "/memory/events")
        )
    }

    func testResetRequestIsDistinctFromTheExistingContextLogResetRequest() {
        // Design §3.7: the new bulk-delete "接到「重置输入历史」，与现有的
        // `DELETE /memory/context-log` 并列" — alongside it, not instead of
        // it. Two different sidecar resources, two different requests; this
        // guards against someone "simplifying" `resetHistory()` down to only
        // one of them.
        XCTAssertNotEqual(
            AppModel.historyEventsResetRequest.path,
            AppModel.contextLogResetRequest.path
        )
    }
}
