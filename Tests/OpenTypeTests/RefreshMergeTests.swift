import XCTest
@testable import OpenType

/// Stage-1 (red) tests for the transient-refresh clobber bug.
///
/// `AppModel.refreshConversations` / `refreshMemoryPanel` currently reset an
/// already-populated list to `[]` inside their `catch` blocks, so a *transient*
/// refresh failure (e.g. the sidecar is momentarily unavailable) flashes the
/// Q&A / Agent / Memory lists to empty even though the previously-loaded data is
/// still perfectly valid.
///
/// The clean, pure seam Stage 3 must introduce is:
///
///     nonisolated static func mergedRefresh<T>(previous: [T], incoming: [T]?) -> [T]
///
/// where `incoming == nil` signals a *failed* refresh (keep `previous`) and
/// `incoming == some` signals a *successful* refresh whose result — even an
/// empty array — is authoritative and should replace `previous`. The catch
/// blocks then pass `nil` (keeping what's on screen) instead of `[]`.
///
/// These tests are RED until that helper exists: they will not compile against
/// the current code because `AppModel.mergedRefresh` does not yet exist.
final class RefreshMergeTests: XCTestCase {

    /// A failed refresh (incoming == nil) must preserve the previously-loaded
    /// list rather than clobbering it to empty. This is the actual bug: a
    /// transient sidecar hiccup must NOT wipe the visible conversations.
    @MainActor
    func testFailedRefreshKeepsPreviousList() {
        let previous = ["conversation-a", "conversation-b", "conversation-c"]

        let merged = AppModel.mergedRefresh(previous: previous, incoming: nil)

        XCTAssertEqual(
            merged,
            previous,
            "A failed refresh (nil) must keep the already-loaded list intact, not flash to empty."
        )
    }

    /// A failed refresh when nothing was loaded yet stays empty (no crash, no
    /// phantom data).
    @MainActor
    func testFailedRefreshOnEmptyStaysEmpty() {
        let previous: [String] = []

        let merged = AppModel.mergedRefresh(previous: previous, incoming: nil)

        XCTAssertEqual(merged, [], "A failed refresh with no prior data stays empty.")
    }

    /// A *successful* non-empty refresh replaces the previous list wholesale —
    /// the fix must not go so far as to merge/append stale entries.
    @MainActor
    func testSuccessfulNonEmptyRefreshReplacesPrevious() {
        let previous = ["old-1", "old-2"]
        let incoming = ["new-1", "new-2", "new-3"]

        let merged = AppModel.mergedRefresh(previous: previous, incoming: incoming)

        XCTAssertEqual(
            merged,
            incoming,
            "A successful refresh is authoritative and replaces the previous list."
        )
    }

    /// The critical distinction: a *successful empty* result (the list really
    /// is now empty — e.g. every conversation was deleted) MUST clear the list.
    /// This is why the failure signal has to be `nil`, not `[]`: an empty
    /// success and a failure are different and must behave differently.
    @MainActor
    func testSuccessfulEmptyRefreshClearsPrevious() {
        let previous = ["conversation-a", "conversation-b"]

        let merged = AppModel.mergedRefresh(previous: previous, incoming: [])

        XCTAssertEqual(
            merged,
            [],
            "A genuinely-empty successful refresh must clear the list; only failures keep the old one."
        )
    }

    /// The helper is generic; it works for the memory panel's own element type
    /// (integers stand in for any `[T]`), proving the same seam covers
    /// `memoryTerms` / `memoryConsolidationRuns` as well as conversations.
    @MainActor
    func testMergedRefreshIsGenericOverElementType() {
        let previousInts = [1, 2, 3]
        XCTAssertEqual(
            AppModel.mergedRefresh(previous: previousInts, incoming: nil),
            previousInts,
            "Failed refresh keeps previous for any element type."
        )
        XCTAssertEqual(
            AppModel.mergedRefresh(previous: previousInts, incoming: [9]),
            [9],
            "Successful refresh replaces previous for any element type."
        )
    }
}
