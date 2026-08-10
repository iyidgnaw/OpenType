import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for P1-18: a stuck "ready" HUD.
///
/// `OverlayController.show(state:mode:)` cancels the pending hide task on entry
/// and then, in a `switch state`, schedules a fresh hide only for the transient
/// toast states (`.modeChanged`, `.success`/`.copied`, `.dispatched`,
/// `.cancelled`, `.failure`). Every other state hits `default: break`, which
/// means NO hide is scheduled and the panel stays on screen. That is correct
/// for the active in-flight states (`.listening`, `.transcribing`,
/// `.transforming`, `.inserting`) — they should stay visible while work runs —
/// but wrong for `.idle`, which lands in the same `default` bucket. Because
/// `AppModel.processCorrection` calls `setState(.idle)` on all three of its
/// paths, every voice-correction leaves the "ready" HUD stuck on screen with no
/// hide ever scheduled.
///
/// The desired fix extracts the per-state timing decision into a pure seam
/// `OverlayController.hideBehavior(for:) -> OverlayHideBehavior` so it can be
/// unit-tested without instantiating the `@MainActor` AppKit controller. The
/// mapping must:
///   - map `.idle -> .hideImmediately` (the bug fix), and
///   - PRESERVE today's behavior for every other state:
///       * transient toasts -> `.scheduleHide(after:)` with the same durations
///         the current `show(...)` switch uses, and
///       * active in-flight states -> `.keepVisible`.
///
/// These tests assert that desired mapping and are RED until Stage 3 adds the
/// `OverlayHideBehavior` enum and the `hideBehavior(for:)` seam (and routes
/// `show(...)` through it). They currently fail to COMPILE because neither
/// symbol exists yet — that is the intended red.
@MainActor
final class OverlayHideBehaviorTests: XCTestCase {

    // MARK: - P1-18: the bug fix — `.idle` must hide immediately

    func testIdleHidesImmediately() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .idle),
            .hideImmediately
        )
    }

    // MARK: - Active in-flight states keep the HUD visible (unchanged)

    func testListeningKeepsVisible() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .listening),
            .keepVisible
        )
    }

    func testTranscribingKeepsVisible() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .transcribing),
            .keepVisible
        )
    }

    func testTransformingKeepsVisible() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .transforming),
            .keepVisible
        )
    }

    func testInsertingKeepsVisible() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .inserting),
            .keepVisible
        )
    }

    // MARK: - Transient toast states schedule a hide (durations unchanged)

    func testModeChangedSchedulesHideAfterCurrentDuration() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .modeChanged),
            .scheduleHide(after: 1.2)
        )
    }

    func testSuccessSchedulesHideAfterCurrentDuration() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .success),
            .scheduleHide(after: 0.9)
        )
    }

    func testCopiedSchedulesHideAfterCurrentDuration() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .copied),
            .scheduleHide(after: 0.9)
        )
    }

    func testDispatchedSchedulesHideAfterCurrentDuration() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .dispatched("已下发给 Agent")),
            .scheduleHide(after: 1.6)
        )
    }

    func testCancelledSchedulesHideAfterCurrentDuration() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .cancelled("已取消")),
            .scheduleHide(after: 1.8)
        )
    }

    func testFailureSchedulesHideAfterCurrentDuration() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .failure("出错了")),
            .scheduleHide(after: 2.4)
        )
    }
}
