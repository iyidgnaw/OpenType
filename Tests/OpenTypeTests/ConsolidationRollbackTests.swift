import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the Memory panel's consolidation-log
/// rollback button.
///
/// The sidecar half already exists end to end: `rollbackRun` (in
/// `sidecar/src/memory/consolidator.ts`) restores `entity_terms` from a run's
/// `snapshotBeforeJSON`, is transactional, and is reachable over HTTP via
/// `POST /memory/consolidation-runs/:id/rollback` (see
/// `sidecar/test/memory/routes.test.ts`'s two
/// `"POST /memory/consolidation-runs/:id/rollback"*` blocks for that
/// contract). `MemoryViews.swift:582` already *renders* a rolled-back run
/// differently (「已回滚 · …」); what's missing is the button that gets a run
/// into that state at all (`docs/superpowers/specs/
/// 2026-08-09-current-system-state.md` §11, "No Memory-panel rollback UI").
///
/// ## Why this is list-aware, not a per-row property
///
/// A first pass at this modeled eligibility as a property of one row
/// (`rolledBackAt == nil`). That's wrong, and the reason is a real,
/// previously-latent bug a probe against the actual (untouched)
/// `rollbackRun`/`runConsolidation` surfaced: `rollbackRun` restores a
/// FULL-TABLE snapshot taken *before* the run being undone, not a diff.
/// Rolling back an older run while a newer one is still active silently
/// erases whatever the newer run added too, while the newer run's own row is
/// left claiming `rolledBackAt: null` -- the run log would lie. So the
/// sidecar route now enforces a stack-order rule: a run is eligible for
/// rollback iff (1) it is not already rolled back, and (2) every run that
/// ran after it has already been rolled back. That's a property of the run's
/// position among the *others*, which a lone row cannot know -- hence
/// `ConsolidationRollback.eligibleRunId(in:)`, a pure function of the whole
/// list, rather than a computed property on `ConsolidationRunSummary`.
///
/// Real row order, confirmed against `MemoryStore.listConsolidationRuns()`
/// (`sidecar/src/memory/MemoryStore.ts`): `ORDER BY ranAt DESC` -- the
/// sidecar always answers `GET /memory/consolidation-runs` **newest run
/// first**. `eligibleRunId(in:)`'s contract below is written against that
/// real order, not assumed.
///
/// `AppModel.init` has side effects and is not instantiable in tests
/// (`DispatchConfirmationTests`, `AssistantEscalationWiringTests` document
/// the same constraint), so — the established pattern in this repo — the
/// decision is factored into a pure, screen-free seam and tested here.
///
/// These tests are RED until Stage 3 adds `ConsolidationRollback` (an enum
/// namespace, matching e.g. `AssistantEscalationWiring`'s shape) with
/// `static func eligibleRunId(in runs: [ConsolidationRunSummary]) -> Int?`
/// to `Sources/OpenType/Models.swift`, near `ConsolidationRunSummary` (around
/// line 1593). They currently fail to COMPILE because that symbol does not
/// exist yet — the intended red, matching `DispatchConfirmationTests`'s own
/// documented convention for this repo.
final class ConsolidationRollbackTests: XCTestCase {

    private func run(id: Int, rolledBackAt: Int?) -> ConsolidationRunSummary {
        ConsolidationRunSummary(
            id: id,
            ranAt: 1_700_000_000_000 + id * 1000,
            eventsConsidered: 5,
            candidatesProposed: 2,
            candidatesAccepted: 1,
            summary: "added \"Test Org\" (aliases: none)",
            rolledBackAt: rolledBackAt
        )
    }

    /// The ordinary case: nothing has been rolled back yet. The eligible run
    /// is the newest one -- first in the sidecar's `ranAt DESC` order, which
    /// is exactly what a freshly-fetched, never-touched run list looks like.
    func testEligibleRunIsTheNewestWhenNothingHasBeenRolledBackYet() {
        // Newest-first, matching GET /memory/consolidation-runs's real order.
        let runs = [run(id: 3, rolledBackAt: nil), run(id: 2, rolledBackAt: nil), run(id: 1, rolledBackAt: nil)]

        XCTAssertEqual(ConsolidationRollback.eligibleRunId(in: runs), 3)
    }

    /// Once the newest run is already rolled back, the one immediately
    /// before it becomes eligible -- the rule "walks the stack down" rather
    /// than being hard-coded to "whatever is physically the newest row".
    /// This is the scenario the reverse-order design exists to support: the
    /// user can unwind several bad passes one at a time.
    func testEligibleRunIsTheOneBeforeTheNewestOnceTheNewestIsRolledBack() {
        let runs = [
            run(id: 3, rolledBackAt: 1_700_003_600_000),
            run(id: 2, rolledBackAt: nil),
            run(id: 1, rolledBackAt: nil),
        ]

        XCTAssertEqual(ConsolidationRollback.eligibleRunId(in: runs), 2)
    }

    /// A list where every run has already been rolled back offers nothing --
    /// there is no top of the stack left to pop.
    func testNoRunIsEligibleWhenEveryRunIsAlreadyRolledBack() {
        let runs = [
            run(id: 3, rolledBackAt: 1_700_003_600_000),
            run(id: 2, rolledBackAt: 1_700_003_500_000),
            run(id: 1, rolledBackAt: 1_700_003_400_000),
        ]

        XCTAssertNil(ConsolidationRollback.eligibleRunId(in: runs))
    }

    /// A single fresh run behaves the same as the general case -- it is its
    /// own "newest", and it is eligible.
    func testASingleUnrolledBackRunIsEligible() {
        let runs = [run(id: 1, rolledBackAt: nil)]

        XCTAssertEqual(ConsolidationRollback.eligibleRunId(in: runs), 1)
    }

    /// No consolidation has ever run: nothing to offer, and nothing should
    /// crash trying to find it.
    func testAnEmptyListOffersNothing() {
        XCTAssertNil(ConsolidationRollback.eligibleRunId(in: []))
    }
}
