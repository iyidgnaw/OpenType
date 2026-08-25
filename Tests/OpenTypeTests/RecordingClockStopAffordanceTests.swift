import Foundation
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for **Part A** of the click-started-recording
/// stop-affordance fix.
///
/// ## The bug
///
/// `AppModel.startVoiceSurfaceFollowUpRecording()` (uncommitted in the
/// working tree, wired from `OverlayController`'s result-card mic button —
/// `OverlayController.swift` ~2799) starts a recording the instant the mic
/// button is tapped. The moment `state` becomes `.listening`, the surface
/// swaps the result card (and that button) for the listening pill, which:
///
/// - hardcodes its hint text to 「松开结束」 / "Release to finish"
///   (`OverlayController.swift` ~1468) — describing a key this recording was
///   never started with, and
/// - offers no click/tap control of its own — the pill has no controls at
///   all.
///
/// So a click-started recording has no discoverable way to stop: the only
/// exits are the physical hotkey (undiscoverable here, and contradicted by
/// what the pill says) or the 5-minute `RecordingLimits.maximumSeconds` cap.
///
/// ## The fix this pins
///
/// The stop affordance becomes explicit state rather than a hardcoded
/// string. A click-started recording's pill carries the click hint and a
/// stop affordance; a hotkey-started recording keeps today's hint and no
/// click affordance. The two are distinguishable by exactly one input.
///
/// ## The seam
///
/// `RecordingClock` (`Sources/OpenType/RecordingLimits.swift`) is already the
/// pure, non-`@MainActor`, locale-aware type the listening pill's
/// `presentation.elapsedText` is computed from — see
/// `RecordingElapsedTextTests` in `RecordingLimitsTests.swift`. The actual
/// `@Published var elapsedText`/`pastWarningThreshold` storage lives on
/// `OverlayPresentation`, a `private final class` inside
/// `OverlayController.swift` (`@MainActor`, and `private` at file scope, so
/// not reachable — even via `@testable import` — from this file or any other
/// outside `OverlayController.swift`); `AppModel` itself has never been
/// instantiable in this test target (`DispatchConfirmationTests`,
/// `AssistantEscalationWiringTests` document the same constraint). So, as
/// with `elapsedText`, the decision has to be factored out as a pure
/// computation the untestable `@MainActor` code merely *reads from* — hence
/// extending `RecordingClock` with `StopAffordance`/`stopAffordance(
/// startedByClick:)` here, rather than inventing a parallel type or trying to
/// reach `OverlayPresentation` directly.
///
/// RED until Stage 3 adds `RecordingClock.StopAffordance` (`Equatable`) and
/// `RecordingClock.stopAffordance(startedByClick:) -> StopAffordance` to
/// `Sources/OpenType/RecordingLimits.swift`. This file currently fails to
/// COMPILE because neither symbol exists yet — that is the intended red.
///
/// ## What this file does NOT cover (Part B, and the wiring half of Part A)
///
/// This file pins only the pure text/flag computation. Two things a Stage-4
/// reviewer must confirm by reading the diff instead, because neither is
/// reachable from a test in this target:
///
/// 1. **Part A's wiring**: that `OverlayController`/`AppModel` actually calls
///    `stopAffordance(startedByClick:)` with the right bit for each of the
///    two recording origins, and that the pill's tap gesture is gated on
///    `stopsOnClick` and calls `finishRecording()` (the same path letting go
///    of the hotkey takes — see `RecordingLimits.Termination.finishAndDeliver`'s
///    doc comment for why that path matters and `.cancel()` would be wrong).
///
/// 2. **Part B**: `startVoiceSurfaceFollowUpRecording()` currently guards
///    `state != .listening` and returns, so a second invocation while
///    recording is a no-op. The intended fix — following the precedent
///    `togglePracticeDictation()` sets (`AppModel.swift` ~842-860): a second
///    invocation while `state == .listening` should call `finishRecording()`
///    instead. That decision is inseparable from `AppModel`'s live,
///    side-effecting `state`/`isBusy`/`isStartingRecording`/`beginRecording`
///    machinery — there is no pure function left over once you subtract those
///    (unlike `togglePracticeDictation`, which itself has no pure seam
///    either: it is a plain stateful guard, not a decision anything in this
///    repo has ever factored out). Writing a test that only exercises a
///    reflection of the guard's shape (e.g. asserting the method exists,
///    or asserting `VoiceSurfaceFollowUp.target` is unaffected) would look
///    like coverage without being any — `VoiceSurfaceFollowUpTests.swift`
///    already pins `target(for:...)` in full for an unrelated, earlier fix,
///    and re-asserting it here would not touch the toggle guard at all. So
///    Part B has no automated coverage from Stage 1; Stage 4 must read
///    `startVoiceSurfaceFollowUpRecording()` against `togglePracticeDictation()`
///    line by line.
///
/// Also out of scope here, per the task: `shortcutBehavior == .pressThenAnyKey`
/// makes 「松开结束」 wrong for a *hotkey*-started recording too (a different,
/// older bug). Not touched by this fix or these tests.
final class RecordingClockStopAffordanceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        OpenTypeL10n.current = .chinese
    }

    override func tearDown() {
        OpenTypeL10n.current = .system
        super.tearDown()
    }

    // MARK: - Hotkey-started: today's behavior, unchanged

    func testAHotkeyStartedRecordingKeepsTodaysHintTextExactly() {
        // The exact string shipping today, in both languages. A regression
        // here would silently change copy for the overwhelmingly common case
        // (the hotkey) while "fixing" the rare one.
        OpenTypeL10n.current = .chinese
        XCTAssertEqual(
            RecordingClock.stopAffordance(startedByClick: false).hintText,
            "松开结束"
        )
        OpenTypeL10n.current = .english
        XCTAssertEqual(
            RecordingClock.stopAffordance(startedByClick: false).hintText,
            "Release to finish"
        )
    }

    func testAHotkeyStartedRecordingOffersNoClickAffordance() {
        XCTAssertFalse(RecordingClock.stopAffordance(startedByClick: false).stopsOnClick)
    }

    // MARK: - Click-started: the fix

    func testAClickStartedRecordingGetsTheClickHint() {
        // Names the actual control ("click"), not the key the user never
        // pressed to start this recording.
        OpenTypeL10n.current = .chinese
        XCTAssertEqual(
            RecordingClock.stopAffordance(startedByClick: true).hintText,
            "点击结束"
        )
        OpenTypeL10n.current = .english
        XCTAssertEqual(
            RecordingClock.stopAffordance(startedByClick: true).hintText,
            "Click to finish"
        )
    }

    func testAClickStartedRecordingOffersTheStopAffordance() {
        XCTAssertTrue(RecordingClock.stopAffordance(startedByClick: true).stopsOnClick)
    }

    // MARK: - Exactly one input distinguishes the two

    func testTheTwoOriginsProduceGenuinelyDifferentAffordances() {
        // Guards the degenerate "fix" where both branches end up equal and
        // the assertions above pass only because nothing actually varies.
        XCTAssertNotEqual(
            RecordingClock.stopAffordance(startedByClick: true),
            RecordingClock.stopAffordance(startedByClick: false)
        )
    }

    func testTheSameInputAlwaysProducesTheSameAffordance() {
        // Purity, pinned the same way `RecordingElapsedTextTests.
        // testTheSameElapsedValueAlwaysRendersTheSameWay` pins it for
        // `elapsedText`: no hidden state, no `Date()`, nothing but the one
        // declared input and the current locale.
        XCTAssertEqual(
            RecordingClock.stopAffordance(startedByClick: true),
            RecordingClock.stopAffordance(startedByClick: true)
        )
        XCTAssertEqual(
            RecordingClock.stopAffordance(startedByClick: false),
            RecordingClock.stopAffordance(startedByClick: false)
        )
    }
}
