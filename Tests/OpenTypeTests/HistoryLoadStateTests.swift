import Foundation
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for a gap Task 7 of `docs/superpowers/plans/
/// 2026-08-25-unified-memory-and-recent-context.md` left open: the plan's own
/// pseudocode for `AppModel.refreshHistory()` is
///
///     guard let body: Body = try? await sidecarClient.request(...) else { return }
///     historyEntries = body.events.map(HistoryEntry.init(from:))
///
/// and `historyEntries` starts as `[]` at launch. A failed *first* fetch
/// therefore leaves it `[]` — indistinguishable from a genuinely empty
/// history — and `DictationViews` renders `[]` as "还没有听写记录" (no
/// history yet). Before this migration the page read a local file and was
/// always available, so this is a failure mode the migration introduces, not
/// one it inherits: a user whose sidecar is briefly down opens the page and
/// is told their history is gone, when it is not.
///
/// The fix is a state distinguishing three things `[HistoryEntry]` alone
/// cannot: never having attempted a fetch, a fetch that succeeded and
/// genuinely found nothing, and a fetch that failed. Modeled as one
/// `@Published` value rather than a second boolean/array pair, so there is
/// exactly one source of truth to keep in sync — `historyEntries` becomes a
/// computed forward onto it, and nothing can update one half without the
/// other by construction.
///
/// Expected shape (Stage 3 creates it; nothing here builds it) — a new pure
/// type, in the same spirit as `AppModel.HistoryEventsRequest` and
/// `EpisodicEventRecorder`: no I/O, no `AppModel`, fully testable on its own:
///
///     enum HistoryLoadState: Equatable {
///         case notYetLoaded
///         case loaded([HistoryEntry])
///         /// A fetch failed. Carries whatever was last successfully loaded
///         /// (`[]` if nothing ever was) so a transient failure does not
///         /// blank a list already on screen — only the messaging changes.
///         case unavailable(lastKnown: [HistoryEntry])
///
///         var entries: [HistoryEntry] { get }        // [] for notYetLoaded
///         var isConfirmedEmpty: Bool { get }          // true only for .loaded([])
///
///         static func afterFetch(
///             _ fetchedEntries: [HistoryEntry]?,      // nil == the fetch failed
///             previous: HistoryLoadState
///         ) -> HistoryLoadState
///     }
///
/// `AppModel` gains `@Published private(set) var historyLoadState:
/// HistoryLoadState = .notYetLoaded` as the actual source of truth;
/// `historyEntries` (the plan's own name, kept for every existing caller)
/// becomes `var historyEntries: [HistoryEntry] { historyLoadState.entries }`.
/// `refreshHistory()` becomes, in spirit:
///
///     let fetched: [HistoryEntry]? = /* the existing try?-guarded decode */
///     historyLoadState = .afterFetch(fetched, previous: historyLoadState)
///
/// `DictationViews` must branch on `isConfirmedEmpty`, not on
/// `entries.isEmpty` alone, to choose between "还没有听写记录" and a distinct
/// "无法读取，可能仍有记录" message — that branch is stage-4 reading, not
/// something this suite (which never constructs a view) can verify.
///
/// ## Why `afterFetch` takes `previous` rather than being a plain mapping
///
/// A naive `fetchedEntries == nil ? .unavailable([]) : .loaded(fetchedEntries!)`
/// would fix the launch-time case this file exists for, but introduce a
/// second one: a user with real history open on screen, whose *next*
/// periodic/triggered refresh hits a sidecar hiccup, would have their real,
/// already-displayed entries replaced by `[]` — the exact same "your history
/// is gone" lie, just reached on a later refresh instead of the first one.
/// Threading `previous` through lets `.unavailable` carry the last known-good
/// list forward, so a failed refresh degrades to "can't confirm, showing what
/// I last had" instead of "empty".
///
/// ## What this file does not pin
///
/// That `AppModel.refreshHistory()` actually calls `.afterFetch` with the
/// right arguments, that `deleteHistoryEntry`/a successful `POST
/// /memory/events` trigger a refresh at all, and that `DictationViews`
/// branches on `isConfirmedEmpty` rather than `entries.isEmpty` — all require
/// either a live `AppModel` (not constructible in this target) or a SwiftUI
/// view (not exercised by this suite). Stage-4 reading, same as the other
/// `AppModel`-adjacent seams in this task.
final class HistoryLoadStateTests: XCTestCase {

    // MARK: - `entries`

    func testNotYetLoadedHasNoEntries() {
        XCTAssertEqual(HistoryLoadState.notYetLoaded.entries, [])
    }

    func testLoadedExposesExactlyWhatWasLoaded() {
        let entries = [entry(id: 1), entry(id: 2)]
        XCTAssertEqual(HistoryLoadState.loaded(entries).entries, entries)
    }

    func testUnavailableExposesTheLastKnownEntriesNotAnEmptyList() {
        // The core of the fix: a failed refresh must not blank a list the
        // user was already looking at.
        let stale = [entry(id: 1), entry(id: 2)]
        XCTAssertEqual(HistoryLoadState.unavailable(lastKnown: stale).entries, stale)
    }

    func testUnavailableWithNothingEverLoadedHasNoEntriesToShow() {
        // There is genuinely nothing to render here — that is unavoidable —
        // but `isConfirmedEmpty` below is what keeps this from being *lied
        // about* as a confirmed-empty history.
        XCTAssertEqual(HistoryLoadState.unavailable(lastKnown: []).entries, [])
    }

    // MARK: - `isConfirmedEmpty`

    func testOnlyASuccessfulLoadOfZeroRowsIsConfirmedEmpty() {
        XCTAssertTrue(HistoryLoadState.loaded([]).isConfirmedEmpty)
    }

    func testALoadWithEntriesIsNotConfirmedEmpty() {
        XCTAssertFalse(HistoryLoadState.loaded([entry(id: 1)]).isConfirmedEmpty)
    }

    func testNotYetLoadedIsNotConfirmedEmptyEvenThoughItsEntriesAreEmpty() {
        // The whole point: `entries == []` must not be read as "confirmed
        // empty" for every case that produces an empty array.
        XCTAssertFalse(HistoryLoadState.notYetLoaded.isConfirmedEmpty)
    }

    func testUnavailableIsNeverConfirmedEmptyRegardlessOfWhatItIsCarrying() {
        XCTAssertFalse(HistoryLoadState.unavailable(lastKnown: []).isConfirmedEmpty)
        XCTAssertFalse(HistoryLoadState.unavailable(lastKnown: [entry(id: 1)]).isConfirmedEmpty)
    }

    // MARK: - `afterFetch`

    func testAFailedFetchAtLaunchBecomesUnavailableNotAConfirmedEmptyLoad() {
        // The bug this whole file exists to close: before the fix, this same
        // situation (`try?` failing on the very first call) left
        // `historyEntries == []` with no state distinguishing it from a
        // genuinely empty history.
        XCTAssertEqual(
            HistoryLoadState.afterFetch(nil, previous: .notYetLoaded),
            .unavailable(lastKnown: [])
        )
    }

    func testAFailedFetchAfterASuccessfulLoadKeepsTheOldEntriesVisible() {
        let stale = [entry(id: 1), entry(id: 2)]
        XCTAssertEqual(
            HistoryLoadState.afterFetch(nil, previous: .loaded(stale)),
            .unavailable(lastKnown: stale)
        )
    }

    func testAFailedFetchAfterAPriorFailureKeepsCarryingTheSameLastKnownEntries() {
        // Two failures in a row must not compound into losing the last
        // *successfully* loaded list a second time.
        let stale = [entry(id: 1)]
        XCTAssertEqual(
            HistoryLoadState.afterFetch(nil, previous: .unavailable(lastKnown: stale)),
            .unavailable(lastKnown: stale)
        )
    }

    func testASuccessfulFetchAlwaysWins() {
        XCTAssertEqual(
            HistoryLoadState.afterFetch([entry(id: 3)], previous: .notYetLoaded),
            .loaded([entry(id: 3)])
        )
        XCTAssertEqual(
            HistoryLoadState.afterFetch([entry(id: 3)], previous: .unavailable(lastKnown: [entry(id: 1)])),
            .loaded([entry(id: 3)])
        )
    }

    func testASuccessfulFetchThatGenuinelyFindsNothingIsTrustedAsConfirmedEmpty() {
        // Distinct from the failure case above: an actual `[]` response
        // (e.g. right after `resetHistory()`) is real information and must
        // be believed, not treated as "unavailable" out of caution. A
        // fetch that succeeds is not the failure mode this file exists for.
        let result = HistoryLoadState.afterFetch([], previous: .loaded([entry(id: 1)]))
        XCTAssertEqual(result, .loaded([]))
        XCTAssertTrue(result.isConfirmedEmpty)
    }

    // MARK: - Fixtures

    private func entry(id: Int) -> HistoryEntry {
        HistoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000),
            mode: .transcribe,
            applicationName: "Xcode",
            transcript: "第 \(id) 条",
            result: "第 \(id) 条",
            contextPreview: nil
        )
    }
}
