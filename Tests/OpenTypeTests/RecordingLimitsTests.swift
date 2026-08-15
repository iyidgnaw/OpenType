import Foundation
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the first two thirds of P2-10
/// (`docs/superpowers/specs/2026-08-14-product-batch-plan.md`,
/// "P2-10 录音计时 + 最长时长 + 浮层跟随焦点屏"):
///
///   「浮层显示已录时长；hands-free 连续录音超过 **2 分钟**给一次视觉提醒，
///    **5 分钟**自动停止并正常交付（不是丢弃——丢掉用户 5 分钟的口述是不可
///    接受的失败模式）。」
///
/// Two seams, both pure:
///
/// 1. `RecordingClock.elapsedText(seconds:)` — what the listening pill shows.
/// 2. `RecordingLimits` — elapsed time in, an action out
///    (`.keepRecording` / `.warn` / `.stop`), plus `termination(for:)` saying
///    what a `.stop` actually does to the recording.
///
/// `AppModel` is not instantiable in tests (its `init` has side effects), so —
/// following the established pattern in this repo (`OutputDeliveryPolicy`,
/// `OnboardingPolicy`, `VoiceSurfaceState`, `CorrectionWindow`,
/// `OverlayController.hideBehavior(for:)`) — the decisions are factored into a
/// pure, timer-free namespace and tested there. Nothing here starts a timer or
/// waits on wall-clock time: elapsed seconds are an *input*.
///
/// Neither class is `@MainActor`. That is deliberate and load-bearing: both
/// seams must stay nonisolated so the recording tick can consult them from
/// wherever it runs. Marking either type `@MainActor` in Stage 3 turns these
/// files red again.
///
/// RED until Stage 3 adds `Sources/OpenType/RecordingLimits.swift` with
/// `RecordingClock.elapsedText(seconds:)`, `RecordingLimits.warningSeconds`,
/// `.maximumSeconds`, `.warningText`, `RecordingLimits.Action` (`Equatable`
/// and `CaseIterable` — `testNoActionThisPolicyCanProduceEverDiscardsTheAudio`
/// sweeps `allCases`), `RecordingLimits.Termination` (`Equatable`),
/// `RecordingLimits.action(elapsed:alreadyWarned:hotKeyHeld:)` and
/// `RecordingLimits.termination(for:) -> Termination?`. They currently fail to
/// COMPILE because none of those symbols exist — that is the intended red.
///
/// **What these tests cannot reach, and what therefore has to be read by eye in
/// Stage 4.** `AppModel` has never been instantiable in this suite (no test in
/// `Tests/OpenTypeTests` constructs one), so the *wiring* is out of reach from
/// here in three places, all of which a Stage-4 review must confirm by reading
/// `AppModel`:
///
/// 1. The `.stop` branch must call `finishRecording()` — the same path
///    `hotKeyReleased()` takes — and must NOT call `cancel()` /
///    `cancelActiveVoiceSession()`, which reach `audioRecorder.cancel()` and
///    delete the file. Every test below can pass with the tick handler wired
///    straight to `cancel()`.
/// 2. The `alreadyWarned` bit must be owned by the recording session and reset
///    when one starts. `testTheWarningFiresOnceAndThenGetsOutOfTheWay` pins the
///    policy's half of "once"; a caller that never sets the flag re-warns every
///    tick and nothing here notices.
/// 3. The tick must keep arriving. A policy that is never consulted is green.
final class RecordingElapsedTextTests: XCTestCase {

    // MARK: - Shape

    /// Parses the rendered text back into whole seconds, and in doing so pins
    /// the format itself: `m:ss`, colon-separated, seconds always two digits
    /// and always < 60. Returns nil for anything that isn't that shape, so the
    /// sweeps below fail loudly rather than silently accepting "3661s".
    private func totalSeconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              minutes >= 0,
              parts[1].count == 2,
              let seconds = Int(parts[1]),
              (0..<60).contains(seconds)
        else { return nil }
        return minutes * 60 + seconds
    }

    func testASilentStartReadsAsZero() {
        // The pill appears the instant recording starts, before any audio has
        // arrived. It has to show something, and that something is 0:00 — not
        // an empty string that makes the pill jump a few pixels wide one tick
        // later.
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 0), "0:00")
    }

    func testSecondsAreAlwaysTwoDigitsSoTheLabelDoesNotJitter() {
        // "0:9" -> "0:10" changes the string's width mid-recording, which in a
        // centered pill reads as the whole HUD twitching once per ten seconds.
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 5), "0:05")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 9), "0:09")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 10), "0:10")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 59), "0:59")
    }

    func testTheMinuteIsNotPaddedBecauseNoRecordingGetsThatLong() {
        // "0:05", not "00:05". The auto-stop below caps a session at five
        // minutes, so a leading zero on the minutes buys nothing and costs a
        // character of width in a small pill.
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 5).first, "0")
        XCTAssertFalse(RecordingClock.elapsedText(seconds: 5).hasPrefix("00"))
    }

    func testCrossingAMinuteRollsTheSecondsOverRatherThanCountingPastSixty() {
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 59), "0:59")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 60), "1:00")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 61), "1:01")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 119), "1:59")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 120), "2:00")
    }

    func testTheDisplayTruncatesRatherThanRounds() {
        // Rounding would show "1:00" while the user is still at 59.5s — a
        // number they have not reached — and would then show "1:00" again at
        // 60.0, so the label would sit still for a full second at every minute
        // boundary after having jumped early. Truncation makes each tick honest:
        // the label says what has actually elapsed.
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 0.4), "0:00")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 0.9), "0:00")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 1.999), "0:01")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 59.5), "0:59")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 59.999), "0:59")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 119.999), "1:59")
    }

    func testMinutesKeepAccumulatingInsteadOfWrappingAtTheHour() {
        // Guards the classic `minutes % 60` slip. Nothing in this app should
        // record for an hour — the auto-stop sees to that — but a formatter
        // that silently reports 60:00 as 0:00 is the kind of thing that only
        // surfaces once the auto-stop is the part that broke.
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 3600), "60:00")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: 3661), "61:01")
    }

    func testAClockThatRunsBackwardsShowsZeroRatherThanAMinusSign() {
        // A start timestamp can end up in the future across a system clock
        // adjustment or a sleep/wake. "-1:-5" on screen would be worse than
        // useless; clamp at the floor.
        XCTAssertEqual(RecordingClock.elapsedText(seconds: -0.5), "0:00")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: -30), "0:00")
        XCTAssertEqual(RecordingClock.elapsedText(seconds: -3600), "0:00")
    }

    // MARK: - Stability across a whole recording

    func testEveryValueAcrossAFullRecordingRendersInTheSameShape() {
        // Sweeps past the 5-minute auto-stop so the format is pinned over the
        // entire range a real session can reach, boundaries included.
        for tick in 0...3_200 {
            let elapsed = Double(tick) / 10.0
            let text = RecordingClock.elapsedText(seconds: elapsed)
            XCTAssertNotNil(
                totalSeconds(text),
                "elapsed \(elapsed) rendered as \(text.debugDescription), which is not m:ss"
            )
        }
    }

    func testTheLabelNeverGoesBackwardsAndNeverSkipsASecond() {
        // "Stable and monotonic", stated as behavior: as elapsed time moves
        // forward the displayed value only ever holds still or advances by
        // exactly one second. A jump of two would mean a second the user never
        // saw; a step backwards would mean the recording appeared to un-happen.
        var previous = 0
        for tick in 0...3_200 {
            let elapsed = Double(tick) / 10.0
            let text = RecordingClock.elapsedText(seconds: elapsed)
            guard let current = totalSeconds(text) else {
                return XCTFail("elapsed \(elapsed) rendered as \(text.debugDescription)")
            }
            XCTAssertGreaterThanOrEqual(
                current,
                previous,
                "the label went backwards at elapsed \(elapsed)"
            )
            XCTAssertLessThanOrEqual(
                current - previous,
                1,
                "the label skipped from \(previous)s to \(current)s at elapsed \(elapsed)"
            )
            previous = current
        }
        // And it really did count all the way up, rather than sitting on 0:00.
        XCTAssertEqual(previous, 320)
    }

    func testTheSameElapsedValueAlwaysRendersTheSameWay() {
        // Purity, pinned: no `Date()`, no locale-sensitive formatter whose
        // output depends on when or where it ran.
        let first = RecordingClock.elapsedText(seconds: 137)
        let second = RecordingClock.elapsedText(seconds: 137)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "2:17")
    }

    func testTheThresholdsRenderAsTheMinutesTheSpecPromises() {
        // Ties the display to the policy: when the warning fires the pill must
        // actually read 2:00, and the recording must end with the pill reading
        // 5:00. If either constant drifts, the number the user was shown stops
        // matching the number the spec named.
        XCTAssertEqual(
            RecordingClock.elapsedText(seconds: RecordingLimits.warningSeconds),
            "2:00"
        )
        XCTAssertEqual(
            RecordingClock.elapsedText(seconds: RecordingLimits.maximumSeconds),
            "5:00"
        )
    }
}

/// The duration policy: a warning at two minutes, an automatic stop at five.
///
/// Shape of the seam, and why:
///
/// - **`action(elapsed:alreadyWarned:hotKeyHeld:)`** is a pure transition, not
///   a stateful object. "The warning fires once" cannot be a property of a
///   function of elapsed time alone — at 121s, 122s, 123s the elapsed time
///   keeps satisfying "past two minutes" — so the one bit of history that
///   makes it once is passed in explicitly. The caller owns that bit and
///   clears it when a recording starts; `testATickLoopWarnsExactlyOnceAndThenStops`
///   drives the whole loop the way `AppModel` will.
///
/// - **`hotKeyHeld`** is passed in and is required to make no difference. See
///   `testTheLimitsApplyWhetherOrNotTheHotkeyIsPhysicallyHeld` for why the
///   parameter exists at all rather than being left out.
///
/// - **`termination(for:)`** exists so that "stop" cannot quietly come to mean
///   "throw away". See the `Termination` section.
final class RecordingLimitsTests: XCTestCase {

    /// §F made `OpenTypeL10n.text(_:english:)` depend on
    /// `OpenTypeL10n.current` rather than unconditionally returning Chinese —
    /// pinned here so `testTheWarningTellsTheUserWhatIsAboutToHappen`'s
    /// assertion about the Chinese warning copy doesn't depend on whatever
    /// locale the test runner's process happens to report.
    override func setUp() {
        super.setUp()
        OpenTypeL10n.current = .chinese
    }

    override func tearDown() {
        OpenTypeL10n.current = .system
        super.tearDown()
    }

    // MARK: - The two numbers

    func testTheWarningIsAtTwoMinutesAndTheStopIsAtFive() {
        XCTAssertEqual(RecordingLimits.warningSeconds, 120)
        XCTAssertEqual(RecordingLimits.maximumSeconds, 300)
        XCTAssertLessThan(
            RecordingLimits.warningSeconds,
            RecordingLimits.maximumSeconds,
            "a warning that arrives at or after the stop is not a warning"
        )
    }

    // MARK: - Below the first threshold, nothing happens

    func testAnOrdinaryRecordingIsLeftCompletelyAlone() {
        // Most dictation is a sentence or two. The policy must be invisible
        // for all of it.
        for elapsed: TimeInterval in [0, 0.5, 1, 30, 60, 119, 119.999] {
            XCTAssertEqual(
                RecordingLimits.action(
                    elapsed: elapsed,
                    alreadyWarned: false,
                    hotKeyHeld: false
                ),
                .keepRecording,
                "elapsed \(elapsed) is well inside the limits"
            )
        }
    }

    func testANegativeElapsedIsTreatedAsTheStartOfTheRecording() {
        // Same clock-skew case `RecordingElapsedTextTests` clamps for. A
        // negative elapsed must never be read as "past the limit" through some
        // sign slip, and equally must not stop a recording that just started.
        for elapsed: TimeInterval in [-0.001, -1, -600] {
            XCTAssertEqual(
                RecordingLimits.action(
                    elapsed: elapsed,
                    alreadyWarned: false,
                    hotKeyHeld: false
                ),
                .keepRecording,
                "elapsed \(elapsed) must not trip any limit"
            )
        }
    }

    // MARK: - The warning

    func testTheWarningFiresAtExactlyTwoMinutes() {
        // Pinned decision: the thresholds are INCLUSIVE — the action is
        // `elapsed >= threshold`, so the half-open interval [120, 300) warns
        // and [300, ∞) stops. Chosen to match `CorrectionWindow.isExpired(at:)`,
        // which is likewise the plain `now >= deadline`: in both cases the
        // question is "has this instant been reached", and answering it with
        // `>` would make a limit that never fires when a tick lands exactly on
        // the boundary.
        XCTAssertEqual(
            RecordingLimits.action(
                elapsed: RecordingLimits.warningSeconds,
                alreadyWarned: false,
                hotKeyHeld: false
            ),
            .warn
        )
        XCTAssertEqual(
            RecordingLimits.action(
                elapsed: RecordingLimits.warningSeconds - 0.001,
                alreadyWarned: false,
                hotKeyHeld: false
            ),
            .keepRecording
        )
    }

    func testTheWarningFiresOnceAndThenGetsOutOfTheWay() {
        // The whole point of `alreadyWarned`. A visual alert re-firing every
        // tick for three solid minutes would be a strobe, not a warning, and
        // would bury the pill's own elapsed-time readout under it.
        for elapsed: TimeInterval in [120, 120.001, 150, 240, 299, 299.999] {
            XCTAssertEqual(
                RecordingLimits.action(
                    elapsed: elapsed,
                    alreadyWarned: true,
                    hotKeyHeld: false
                ),
                .keepRecording,
                "elapsed \(elapsed) has already been warned about"
            )
        }
    }

    func testTheWarningStaysUpForTheRestOfTheWindowWithoutBeingReIssued() {
        // Stated the other way round, because it is the case most likely to be
        // implemented wrong: between the two thresholds an un-warned session
        // warns, and a warned one is silent — at every single instant in that
        // window, not just at the boundary.
        for tick in 1_200...2_999 {
            let elapsed = Double(tick) / 10.0
            XCTAssertEqual(
                RecordingLimits.action(elapsed: elapsed, alreadyWarned: false, hotKeyHeld: false),
                .warn,
                "elapsed \(elapsed) is past the warning threshold and unwarned"
            )
            XCTAssertEqual(
                RecordingLimits.action(elapsed: elapsed, alreadyWarned: true, hotKeyHeld: false),
                .keepRecording,
                "elapsed \(elapsed) has already been warned about"
            )
        }
    }

    func testTheWarnedFlagCannotConjureAWarningBeforeItsTime() {
        // Defensive: a stale flag left over from a previous session must not
        // change what happens at the start of a new one, in either direction.
        for elapsed: TimeInterval in [0, 1, 60, 119.999] {
            XCTAssertEqual(
                RecordingLimits.action(
                    elapsed: elapsed,
                    alreadyWarned: true,
                    hotKeyHeld: false
                ),
                .keepRecording,
                "elapsed \(elapsed) is before the warning threshold"
            )
        }
    }

    func testTheWarningTellsTheUserWhatIsAboutToHappen() {
        // A wordless flash teaches nobody anything. Someone two minutes into a
        // long thought needs to know both that they are being watched and that
        // the recording will end on its own at five minutes — that is what
        // makes the auto-stop feel like a net rather than an ambush.
        let text = RecordingLimits.warningText

        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(
            text.contains("5"),
            "the warning must name the minute at which recording stops, got: \(text)"
        )
        XCTAssertTrue(
            text.contains("分钟"),
            "the warning must name the unit, got: \(text)"
        )
        // And it is a sentence, not the timer readout with a different colour.
        XCTAssertNotEqual(
            text,
            RecordingClock.elapsedText(seconds: RecordingLimits.warningSeconds)
        )
    }

    // MARK: - The stop

    func testTheStopFiresAtExactlyFiveMinutes() {
        for warned in [true, false] {
            XCTAssertEqual(
                RecordingLimits.action(
                    elapsed: RecordingLimits.maximumSeconds,
                    alreadyWarned: warned,
                    hotKeyHeld: false
                ),
                .stop,
                "the stop does not care whether the warning was seen (warned: \(warned))"
            )
        }
    }

    func testAMomentBeforeFiveMinutesIsStillARunningRecording() {
        XCTAssertEqual(
            RecordingLimits.action(
                elapsed: RecordingLimits.maximumSeconds - 0.001,
                alreadyWarned: true,
                hotKeyHeld: false
            ),
            .keepRecording
        )
    }

    func testAMissedWarningStillStopsRatherThanWarningLate() {
        // The app can be asleep, throttled, or simply behind on ticks, so the
        // first tick after the machine wakes can arrive well past five minutes
        // having never warned. Warning at that point — and continuing to
        // record — would be the worst of both: the alert fires when it is no
        // longer useful, and the cap silently does not exist.
        for elapsed: TimeInterval in [300, 301, 420, 3_600] {
            XCTAssertEqual(
                RecordingLimits.action(
                    elapsed: elapsed,
                    alreadyWarned: false,
                    hotKeyHeld: false
                ),
                .stop,
                "elapsed \(elapsed) is past the cap; the warning is moot"
            )
        }
    }

    func testTheStopKeepsSayingStopSoALateTickCannotSlipThrough() {
        // Idempotent past the cap: there is no window the stop can fall
        // through, no "already handled" state that turns it back off.
        for tick in 3_000...3_200 {
            let elapsed = Double(tick) / 10.0
            for warned in [true, false] {
                XCTAssertEqual(
                    RecordingLimits.action(
                        elapsed: elapsed,
                        alreadyWarned: warned,
                        hotKeyHeld: false
                    ),
                    .stop,
                    "elapsed \(elapsed) (warned: \(warned)) is past the cap"
                )
            }
        }
    }

    // MARK: - The auto-stop delivers. It never discards.

    /// From the spec, in the plainest terms it uses anywhere:
    /// 「**5 分钟**自动停止并正常交付（不是丢弃——丢掉用户 5 分钟的口述是不可
    /// 接受的失败模式）。」
    ///
    /// This is the one thing in P2-10 that can do real harm. Every other bug
    /// here is cosmetic — a label that jitters, a warning that fires twice, a
    /// panel on the wrong monitor. This one destroys five minutes of someone's
    /// speech, and it destroys it *via the safety net that exists to protect
    /// them*. The obvious implementation — reach for the code path that already
    /// ends a recording — is `AppModel.cancel()`, which calls
    /// `audioRecorder.cancel()`, which deletes the file. That is why the
    /// disposition is a named type with two cases rather than an implication:
    /// `.discard` exists in the enum precisely so that choosing `.finishAndDeliver`
    /// is a choice on the record, and so that a future edit toward the wrong
    /// path has to say so out loud.

    func testAnAutoStopFinishesTheRecordingTheSameWayLettingGoOfTheHotkeyDoes() {
        // `.finishAndDeliver` means `AppModel.finishRecording()`: stop the
        // recorder, keep the file, transcribe it, deliver the result through
        // the ordinary pipeline. Nothing about the result is second-class for
        // having been ended by the clock instead of by the user.
        XCTAssertEqual(
            RecordingLimits.termination(for: .stop),
            RecordingLimits.Termination.finishAndDeliver
        )
    }

    func testTheDeliverAndDiscardPathsAreGenuinelyDifferentOutcomes() {
        // Guards against the degenerate "fix" where both cases are made equal
        // and the assertion above passes vacuously.
        XCTAssertNotEqual(
            RecordingLimits.Termination.finishAndDeliver,
            RecordingLimits.Termination.discard
        )
    }

    func testNothingShortOfTheCapEndsTheRecordingAtAll() {
        XCTAssertNil(RecordingLimits.termination(for: .keepRecording))
        XCTAssertNil(RecordingLimits.termination(for: .warn))
    }

    func testNoActionThisPolicyCanProduceEverDiscardsTheAudio() {
        // Over the whole enum, not just the case we happen to think about.
        for action in RecordingLimits.Action.allCases {
            XCTAssertNotEqual(
                RecordingLimits.termination(for: action),
                RecordingLimits.Termination.discard,
                "\(action) must never throw away what the user said"
            )
        }
    }

    func testNoElapsedTimeAtAllCanProduceADiscard() {
        // And over the whole input space that reaches those actions: every
        // instant of a recording, warned or not, hotkey held or not.
        for tick in stride(from: -100, through: 3_600, by: 7) {
            let elapsed = Double(tick) / 10.0
            for warned in [true, false] {
                for held in [true, false] {
                    let action = RecordingLimits.action(
                        elapsed: elapsed,
                        alreadyWarned: warned,
                        hotKeyHeld: held
                    )
                    XCTAssertNotEqual(
                        RecordingLimits.termination(for: action),
                        RecordingLimits.Termination.discard,
                        "elapsed \(elapsed) (warned: \(warned), held: \(held)) produced a discard"
                    )
                }
            }
        }
    }

    // MARK: - Scope: a held modifier is not an exemption

    func testTheLimitsApplyWhetherOrNotTheHotkeyIsPhysicallyHeld() {
        // Pinned decision: same limits either way.
        //
        // The spec's wording — 「hands-free 连续录音超过 2 分钟」 — invites the
        // opposite reading, that a held-modifier recording is exempt because
        // someone is obviously still there with a finger on the key. A stuck
        // or repeating modifier is exactly the case the cap exists for, and it
        // is indistinguishable from a held key from inside the app. Exempting
        // held recordings would switch the net off in the one situation where
        // the user cannot switch it off themselves.
        //
        // The parameter is therefore present and required to be inert. It is
        // deliberately NOT omitted: with no parameter the decision would live
        // implicitly at whichever call site does or does not consult the
        // policy, invisible to review. Here, a later `guard !hotKeyHeld` turns
        // this test red instead of shipping quietly.
        for tick in stride(from: 0, through: 3_600, by: 3) {
            let elapsed = Double(tick) / 10.0
            for warned in [true, false] {
                XCTAssertEqual(
                    RecordingLimits.action(elapsed: elapsed, alreadyWarned: warned, hotKeyHeld: true),
                    RecordingLimits.action(elapsed: elapsed, alreadyWarned: warned, hotKeyHeld: false),
                    "elapsed \(elapsed) (warned: \(warned)) must not depend on the hotkey being held"
                )
            }
        }
    }

    func testAHeldModifierStillWarnsAndStillStops() {
        // The equivalence above would also be satisfied by a policy that never
        // fires for anyone, so state the held case concretely too.
        XCTAssertEqual(
            RecordingLimits.action(elapsed: 120, alreadyWarned: false, hotKeyHeld: true),
            .warn
        )
        XCTAssertEqual(
            RecordingLimits.action(elapsed: 300, alreadyWarned: true, hotKeyHeld: true),
            .stop
        )
        XCTAssertEqual(
            RecordingLimits.termination(
                for: RecordingLimits.action(elapsed: 300, alreadyWarned: true, hotKeyHeld: true)
            ),
            RecordingLimits.Termination.finishAndDeliver,
            "a stuck key must not cost the user their recording either"
        )
    }

    // MARK: - The whole loop

    func testATickLoopWarnsExactlyOnceAndThenStops() {
        // The seams above, driven the way `AppModel`'s recording tick will
        // drive them — which is where "fires once" becomes observable. A
        // half-second tick is fast enough that a threshold cannot be stepped
        // over, and slow enough that a re-firing warning would show up here as
        // hundreds of alerts.
        var alreadyWarned = false
        var warnCount = 0
        var stopCount = 0
        var warnedAt: TimeInterval?
        var stoppedAt: TimeInterval?

        var elapsed: TimeInterval = 0
        while elapsed <= 400 {
            switch RecordingLimits.action(
                elapsed: elapsed,
                alreadyWarned: alreadyWarned,
                hotKeyHeld: false
            ) {
            case .keepRecording:
                break
            case .warn:
                warnCount += 1
                if warnedAt == nil { warnedAt = elapsed }
                alreadyWarned = true
            case .stop:
                stopCount += 1
                if stoppedAt == nil { stoppedAt = elapsed }
            }
            // A real recording ends at the first `.stop`. This loop keeps
            // ticking past it on purpose — not to catch a second stop (a
            // repeated `.stop` is *correct*, and
            // `testTheStopKeepsSayingStopSoALateTickCannotSlipThrough` requires
            // it), but so that a policy which reverts to `.warn` or
            // `.keepRecording` after the cap shows up here as a second warning
            // or a missing stop.
            elapsed += 0.5
        }

        XCTAssertEqual(warnCount, 1, "the visual warning must be issued once per recording")
        XCTAssertEqual(warnedAt, 120)
        XCTAssertGreaterThan(stopCount, 0, "the recording must be stopped")
        XCTAssertEqual(stoppedAt, 300)
        // Every tick from the cap to the end of the loop said `.stop`, so the
        // policy never fell back out of the stopped region.
        XCTAssertEqual(stopCount, 201, "300.0...400.0 in 0.5s steps is 201 ticks, all past the cap")
        XCTAssertNotNil(warnedAt)
        XCTAssertNotNil(stoppedAt)
        if let warnedAt, let stoppedAt {
            XCTAssertLessThan(warnedAt, stoppedAt, "the warning must precede the stop")
        }
    }

    func testATickLoopThatEndsBeforeTwoMinutesNeverFiresAnything() {
        // The common case, end to end: nothing about this feature is visible
        // during ordinary dictation.
        var alreadyWarned = false
        var elapsed: TimeInterval = 0
        while elapsed <= 90 {
            XCTAssertEqual(
                RecordingLimits.action(
                    elapsed: elapsed,
                    alreadyWarned: alreadyWarned,
                    hotKeyHeld: true
                ),
                .keepRecording,
                "elapsed \(elapsed)"
            )
            alreadyWarned = false
            elapsed += 0.5
        }
    }
}
