import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for P0-3, the post-delivery correction window
/// (`docs/superpowers/specs/2026-08-14-product-batch-plan.md`,
/// "P0-3 交付后 N 秒纠错窗口（就地纠错）").
///
/// The product rule: Direct-mode transcription still delivers instantly, with
/// no added latency. But for **8 seconds after delivery** the hotkey changes
/// meaning — if the target app has text selected right then, pressing the
/// hotkey means "voice-correct this selection in place" instead of "start a
/// new recording." The correction round records only the instruction, sends
/// the selected text as `fullText` to `POST /transcribe/correct`, and pastes
/// the replacement back over the selection (`ContextBridge.insert` is Cmd+V,
/// which natively replaces a selection).
///
/// This is deliberately **not** the first design that was considered — that one
/// re-opened the Review panel prefilled with the delivered text, which is wrong
/// because the text is already pasted into the target app: committing the panel
/// would insert a second copy, and undoing the first paste with Cmd+Z is unsafe
/// once the user has touched the keyboard at all in those 8 seconds. Nothing
/// here tests that rejected design; in-place correction needs no undo, no
/// panel, and no new write path.
///
/// `AppModel.init` has side effects and is not instantiable in tests, so — the
/// established pattern in this repo (`OutputDeliveryPolicy`, `OnboardingPolicy`,
/// `VoiceSurfaceState`, `OverlayController.hideBehavior(for:)`) — the decision
/// is factored into a pure, screen-free seam and tested there.
///
/// These tests are RED until Stage 3 adds `Sources/OpenType/CorrectionWindow.swift`
/// with `HotKeyIntent`, `CorrectionWindow.windowSeconds`, `CorrectionWindow.intent(...)`,
/// `CorrectionWindow.State`, `CorrectionWindow.Event`, `CorrectionWindow.reduce(_:on:)`
/// and `CorrectionWindow.hintText`, plus the new `OverlayHideBehavior` case and
/// `OverlayController.hideBehavior(for:correctionWindowArmed:)` overload
/// exercised at the bottom of this file. They currently fail to COMPILE because
/// none of those symbols exist yet — that is the intended red.
final class CorrectionWindowTests: XCTestCase {

    /// A fixed, exactly-representable instant so the 8s boundary arithmetic is
    /// not at the mercy of `Date()` or floating-point drift.
    private let deliveredAt = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// The app the delivery landed in. Correction only makes sense while the
    /// user is still looking at that same app.
    private let targetApp = "com.apple.Notes"

    // MARK: - The window length is the one number in this batch chosen by feel

    func testTheWindowIsEightSeconds() {
        // Long enough to glance at what was just pasted and react, short enough
        // that someone who just wants to keep dictating is not robbed of the
        // hotkey. The spec marks this as the batch's single intuition-picked
        // constant (待调), so pin it: changing it should be a deliberate edit
        // here, not a silent drift.
        XCTAssertEqual(CorrectionWindow.windowSeconds, 8)
    }

    // MARK: - A. `CorrectionWindow.intent(...)`

    func testNoPreviousDeliveryStartsANewRecording() {
        // Nothing has been delivered yet, so there is no window to be inside of
        // and the hotkey keeps its ordinary meaning.
        XCTAssertEqual(
            CorrectionWindow.intent(
                lastDeliveryAt: nil,
                now: deliveredAt,
                selectedText: "PayPal",
                capturedBundleId: targetApp,
                frontmostBundleId: targetApp,
                mode: .transcribe,
                variant: .direct
            ),
            .startNewRecording
        )
    }

    func testInsideTheWindowWithASelectionInTheSameAppCorrectsInPlace() {
        // The whole feature, in one case: Direct transcribe delivered 2s ago,
        // the user double-clicked the word Whisper got wrong, and presses the
        // hotkey to say the right one.
        XCTAssertEqual(
            CorrectionWindow.intent(
                lastDeliveryAt: deliveredAt,
                now: deliveredAt.addingTimeInterval(2),
                selectedText: "PayPa",
                capturedBundleId: targetApp,
                frontmostBundleId: targetApp,
                mode: .transcribe,
                variant: .direct
            ),
            .correctSelection
        )
    }

    func testWindowHotButNothingSelectedStartsANewRecordingRatherThanStealingTheHotkey() {
        // The deliberate "don't steal the hotkey" rule. Someone who wants to
        // correct will select first; someone who just wants to say the next
        // sentence must not be interrupted by a mode they did not ask for.
        XCTAssertEqual(
            CorrectionWindow.intent(
                lastDeliveryAt: deliveredAt,
                now: deliveredAt.addingTimeInterval(1),
                selectedText: nil,
                capturedBundleId: targetApp,
                frontmostBundleId: targetApp,
                mode: .transcribe,
                variant: .direct
            ),
            .startNewRecording
        )
    }

    func testAnEmptySelectionIsNoSelection() {
        XCTAssertEqual(
            CorrectionWindow.intent(
                lastDeliveryAt: deliveredAt,
                now: deliveredAt.addingTimeInterval(1),
                selectedText: "",
                capturedBundleId: targetApp,
                frontmostBundleId: targetApp,
                mode: .transcribe,
                variant: .direct
            ),
            .startNewRecording
        )
    }

    func testAWhitespaceOnlySelectionIsNoSelection() {
        // A stray drag can select a run of spaces or a newline. There is
        // nothing there to correct, so this must behave exactly like no
        // selection at all rather than sending an empty `fullText` to
        // `/transcribe/correct`.
        for blank in [" ", "   ", "\n", "\t", " \n\t "] {
            XCTAssertEqual(
                CorrectionWindow.intent(
                    lastDeliveryAt: deliveredAt,
                    now: deliveredAt.addingTimeInterval(1),
                    selectedText: blank,
                    capturedBundleId: targetApp,
                    frontmostBundleId: targetApp,
                    mode: .transcribe,
                    variant: .direct
                ),
                .startNewRecording,
                "a selection of only whitespace (\(blank.debugDescription)) must count as no selection"
            )
        }
    }

    func testTheBoundaryIsExclusiveSoExactlyEightSecondsIsAlreadyTooLate() {
        // Pinned decision: the window is the half-open interval
        // [delivery, delivery + 8). At exactly 8.000s it has closed. Chosen so
        // the window has one unambiguous end and `isExpired(at:)` below can be
        // the plain `now >= deadline`.
        XCTAssertEqual(
            CorrectionWindow.intent(
                lastDeliveryAt: deliveredAt,
                now: deliveredAt.addingTimeInterval(CorrectionWindow.windowSeconds),
                selectedText: "PayPa",
                capturedBundleId: targetApp,
                frontmostBundleId: targetApp,
                mode: .transcribe,
                variant: .direct
            ),
            .startNewRecording
        )
    }

    func testJustInsideTheBoundaryStillCorrects() {
        XCTAssertEqual(
            CorrectionWindow.intent(
                lastDeliveryAt: deliveredAt,
                now: deliveredAt.addingTimeInterval(CorrectionWindow.windowSeconds - 0.001),
                selectedText: "PayPa",
                capturedBundleId: targetApp,
                frontmostBundleId: targetApp,
                mode: .transcribe,
                variant: .direct
            ),
            .correctSelection
        )
    }

    func testBeyondTheWindowStartsANewRecording() {
        XCTAssertEqual(
            CorrectionWindow.intent(
                lastDeliveryAt: deliveredAt,
                now: deliveredAt.addingTimeInterval(30),
                selectedText: "PayPa",
                capturedBundleId: targetApp,
                frontmostBundleId: targetApp,
                mode: .transcribe,
                variant: .direct
            ),
            .startNewRecording
        )
    }

    func testSwitchingAppsInsideTheWindowStartsANewRecording() {
        // The selection now belongs to some other app's text. Correcting it
        // would paste into a window the delivery never touched — the same
        // wrong-app failure `OutputDeliveryPolicy.shouldInsert` exists to
        // prevent, so the window must close on a focus change too.
        XCTAssertEqual(
            CorrectionWindow.intent(
                lastDeliveryAt: deliveredAt,
                now: deliveredAt.addingTimeInterval(1),
                selectedText: "PayPa",
                capturedBundleId: targetApp,
                frontmostBundleId: "com.tinyspeck.slackmacgap",
                mode: .transcribe,
                variant: .direct
            ),
            .startNewRecording
        )
    }

    func testAnUnknownCapturedAppAllowsCorrectionJustLikeOutputDeliveryPolicyAllowsInsert() {
        // `OutputDeliveryPolicy.shouldInsert` treats a nil captured bundle id
        // as "identity unknown, allow." Correction reuses the very same
        // `ContextBridge.insert` write path, so the two policies must not
        // disagree about the same situation: if the delivery was allowed to
        // paste, correcting that paste must be allowed too.
        let intent = CorrectionWindow.intent(
            lastDeliveryAt: deliveredAt,
            now: deliveredAt.addingTimeInterval(1),
            selectedText: "PayPa",
            capturedBundleId: nil,
            frontmostBundleId: targetApp,
            mode: .transcribe,
            variant: .direct
        )
        XCTAssertEqual(intent, .correctSelection)
        XCTAssertTrue(
            OutputDeliveryPolicy.shouldInsert(
                capturedBundleId: nil,
                frontmostBundleId: targetApp
            )
        )
    }

    func testTheAppIdentityRuleAgreesWithOutputDeliveryPolicyForEveryBundleIdPairing() {
        // Asserted as an equivalence rather than case by case, so the two
        // policies cannot drift apart later: with everything else about the
        // window favourable, `.correctSelection` must hold exactly when
        // `shouldInsert` does.
        let pairings: [(captured: String?, frontmost: String?)] = [
            (nil, targetApp),
            (nil, nil),
            (targetApp, targetApp),
            (targetApp, "com.tinyspeck.slackmacgap"),
            (targetApp, nil)
        ]

        for pairing in pairings {
            let intent = CorrectionWindow.intent(
                lastDeliveryAt: deliveredAt,
                now: deliveredAt.addingTimeInterval(1),
                selectedText: "PayPa",
                capturedBundleId: pairing.captured,
                frontmostBundleId: pairing.frontmost,
                mode: .transcribe,
                variant: .direct
            )
            let allowsInsert = OutputDeliveryPolicy.shouldInsert(
                capturedBundleId: pairing.captured,
                frontmostBundleId: pairing.frontmost
            )
            XCTAssertEqual(
                intent == .correctSelection,
                allowsInsert,
                "captured \(String(describing: pairing.captured)) / frontmost \(String(describing: pairing.frontmost)): correction and insert must agree"
            )
        }
    }

    func testAskAndAgentNeverCorrectBecauseTheirResultCardOwnsTheFollowUpUtterance() {
        // Speaking again while an ask/agent card is on screen already means
        // "continue this conversation" (commit eaa03f3, `VoiceFollowUp`). Two
        // features must not fight over the same hotkey, so the correction
        // window is Direct-transcribe-only and never arms for these modes.
        for mode in [InputMode.ask, InputMode.agent] {
            for variant in TranscribeVariant.allCases {
                XCTAssertEqual(
                    CorrectionWindow.intent(
                        lastDeliveryAt: deliveredAt,
                        now: deliveredAt.addingTimeInterval(1),
                        selectedText: "PayPa",
                        capturedBundleId: targetApp,
                        frontmostBundleId: targetApp,
                        mode: mode,
                        variant: variant
                    ),
                    .startNewRecording,
                    "\(mode) must leave the follow-up utterance to its result card"
                )
            }
        }
    }

    func testReviewVariantNeverCorrectsBecauseThePanelAlreadyOwnsTheHotkey() {
        // In Review, a second hotkey press already means "voice-correct the
        // panel's selection" while the panel is open
        // (`AppModel.hotKeyPressed` -> `beginCorrectionRecording`). This
        // feature exists to give Direct the same affordance, not to add a
        // second, conflicting one to Review.
        XCTAssertEqual(
            CorrectionWindow.intent(
                lastDeliveryAt: deliveredAt,
                now: deliveredAt.addingTimeInterval(1),
                selectedText: "PayPa",
                capturedBundleId: targetApp,
                frontmostBundleId: targetApp,
                mode: .transcribe,
                variant: .review
            ),
            .startNewRecording
        )
    }

    // MARK: - B. Window lifecycle

    private func armedWindow(
        at date: Date? = nil,
        bundleId: String? = nil
    ) -> CorrectionWindow.State? {
        CorrectionWindow.reduce(
            nil,
            on: .delivered(
                at: date ?? deliveredAt,
                capturedBundleId: bundleId ?? targetApp,
                mode: .transcribe,
                variant: .direct
            )
        )
    }

    func testDeliveryArmsAWindowThatExpiresEightSecondsLater() throws {
        let window = try XCTUnwrap(armedWindow())
        let expectedDeadline: Date =
            deliveredAt.addingTimeInterval(CorrectionWindow.windowSeconds)

        XCTAssertEqual(window.deliveredAt, deliveredAt)
        XCTAssertEqual(window.capturedBundleId, targetApp)
        XCTAssertEqual(window.deadline, expectedDeadline)
    }

    func testOnlyADirectTranscribeDeliveryArmsAWindowAtAll() {
        // `.delivered` carries the mode and variant precisely so that the
        // arming gate lives here — in the one place that decides whether a
        // window exists — rather than in whichever call site happens to emit
        // the event. It matters because `intent(...)` is told the mode the
        // user is in *now*, not the mode the delivery happened in: if an
        // ask/agent delivery armed a window and the user switched back to
        // Direct transcribe inside those 8 seconds, the next hotkey press
        // would "correct" a selection this window never delivered.
        let ineligible: [(InputMode, TranscribeVariant)] = [
            (.ask, .direct),
            (.ask, .review),
            (.agent, .direct),
            (.agent, .review),
            (.transcribe, .review)
        ]

        for (mode, variant) in ineligible {
            let event = CorrectionWindow.Event.delivered(
                at: deliveredAt,
                capturedBundleId: targetApp,
                mode: mode,
                variant: variant
            )
            XCTAssertNil(
                CorrectionWindow.reduce(nil, on: event),
                "\(mode)/\(variant) must not arm a correction window"
            )
            // And an ineligible delivery replaces an open window with
            // nothing, the same way an eligible one replaces it with itself
            // (`testDeliveringAgainReplacesTheWindowRatherThanExtendingTheOldOne`).
            XCTAssertNil(
                CorrectionWindow.reduce(armedWindow(), on: event),
                "\(mode)/\(variant) must close the window a Direct delivery opened"
            )
        }
    }

    func testASuccessfulCorrectionReArmsTheWindowWithAFreshDeadline() throws {
        // Fixing two words in a row is common: correct one, look at the next
        // one, select it, press again. Ending the window on the first fix would
        // make the second correction impossible without re-dictating.
        let armed = try XCTUnwrap(armedWindow())
        let correctedAt: Date = deliveredAt.addingTimeInterval(5)

        let reArmed = try XCTUnwrap(
            CorrectionWindow.reduce(armed, on: .correctionSucceeded(at: correctedAt))
        )

        XCTAssertEqual(reArmed.deliveredAt, correctedAt)
        XCTAssertEqual(
            reArmed.deadline,
            correctedAt.addingTimeInterval(CorrectionWindow.windowSeconds)
        )
        // The window still guards the same app it was armed for.
        XCTAssertEqual(reArmed.capturedBundleId, targetApp)
        // And the fresh deadline really is later than the one it replaced.
        let oldDeadline: Date = armed.deadline
        let newDeadline: Date = reArmed.deadline
        XCTAssertGreaterThan(newDeadline, oldDeadline)
    }

    func testAReArmedWindowIsStillHotAtATimeTheOriginalWouldHaveExpired() throws {
        // The point of re-arming, stated as behavior rather than as a field:
        // 11s after the original delivery — 3s past its deadline — a window
        // re-armed by a correction at 5s is still accepting the hotkey.
        let armed = try XCTUnwrap(armedWindow())
        let correctedAt: Date = deliveredAt.addingTimeInterval(5)
        let reArmed = try XCTUnwrap(
            CorrectionWindow.reduce(armed, on: .correctionSucceeded(at: correctedAt))
        )
        let now: Date = deliveredAt.addingTimeInterval(11)

        XCTAssertTrue(armed.isExpired(at: now))
        XCTAssertFalse(reArmed.isExpired(at: now))

        XCTAssertEqual(
            CorrectionWindow.intent(
                lastDeliveryAt: reArmed.deliveredAt,
                now: now,
                selectedText: "PayPa",
                capturedBundleId: reArmed.capturedBundleId,
                frontmostBundleId: targetApp,
                mode: .transcribe,
                variant: .direct
            ),
            .correctSelection
        )
    }

    func testACorrectionCannotReArmAWindowThatWasNeverOpen() {
        XCTAssertNil(
            CorrectionWindow.reduce(
                nil,
                on: .correctionSucceeded(at: deliveredAt.addingTimeInterval(5))
            )
        )
    }

    func testAFailedCorrectionLeavesTheWindowExactlyAsItWas() throws {
        // The spec re-arms on 「纠错**成功**」 and says nothing about failure.
        // Pinned decision: a failed correction neither re-arms nor clears —
        // the window keeps running on its original clock.
        //
        // Not re-arming, because a `.failure` toast has by then replaced the
        // correction hint on screen; a fresh 8s window behind an error toast
        // would leave the hotkey silently meaning "correct" with nothing on
        // screen saying so, which is the exact invisible-window failure the
        // spec calls this feature's make-or-break point. Not clearing either,
        // because a fast failure leaves the user's selection untouched and
        // whatever seconds remain are still theirs to retry in — and a slow
        // one has expired on its own by then anyway
        // (`testAnExpiredWindowIsIndistinguishableFromNoWindow`).
        let armed = try XCTUnwrap(armedWindow())
        let survivor = try XCTUnwrap(
            CorrectionWindow.reduce(armed, on: .correctionFailed)
        )

        XCTAssertEqual(survivor.deliveredAt, armed.deliveredAt)
        XCTAssertEqual(survivor.deadline, armed.deadline)
        XCTAssertEqual(survivor.capturedBundleId, armed.capturedBundleId)
    }

    func testAFailedCorrectionCannotConjureAWindowEither() {
        XCTAssertNil(CorrectionWindow.reduce(nil, on: .correctionFailed))
    }

    func testStartingANewRecordingClearsTheWindow() {
        // `.recordingStarted` means "a NEW dictation began," not "some
        // recording began." The in-place correction round records too, and if
        // that round also emitted this event the window would be cleared
        // before `.correctionSucceeded` ever arrived — making the re-arm above
        // unreachable, since a correction cannot re-arm a `nil` window
        // (`testACorrectionCannotReArmAWindowThatWasNeverOpen`). Only the
        // `.startNewRecording` branch of `intent(...)` may emit this.
        XCTAssertNil(CorrectionWindow.reduce(armedWindow(), on: .recordingStarted))
    }

    func testAnExplicitCancelClearsTheWindow() {
        // Esc means "I am done with this," including done with the offer to
        // correct it.
        XCTAssertNil(CorrectionWindow.reduce(armedWindow(), on: .cancelled))
    }

    func testAnExpiredWindowIsIndistinguishableFromNoWindow() {
        // Expiry needs no timer to fire and no state to be cleared: the hotkey
        // decision is a function of the clock, so a stale `State` left lying
        // around behaves exactly like `nil`.
        let expired = deliveredAt.addingTimeInterval(-60)
        let now = deliveredAt

        let withStaleWindow = CorrectionWindow.intent(
            lastDeliveryAt: expired,
            now: now,
            selectedText: "PayPa",
            capturedBundleId: targetApp,
            frontmostBundleId: targetApp,
            mode: .transcribe,
            variant: .direct
        )
        let withNoWindow = CorrectionWindow.intent(
            lastDeliveryAt: nil,
            now: now,
            selectedText: "PayPa",
            capturedBundleId: targetApp,
            frontmostBundleId: targetApp,
            mode: .transcribe,
            variant: .direct
        )

        XCTAssertEqual(withStaleWindow, withNoWindow)
        XCTAssertEqual(withStaleWindow, .startNewRecording)
    }

    func testExpiryUsesTheSameExclusiveBoundaryAsTheHotkeyDecision() throws {
        let window = try XCTUnwrap(armedWindow())
        let deadline: Date =
            deliveredAt.addingTimeInterval(CorrectionWindow.windowSeconds)

        XCTAssertFalse(window.isExpired(at: deadline.addingTimeInterval(-0.001)))
        XCTAssertTrue(window.isExpired(at: deadline))
        XCTAssertTrue(window.isExpired(at: deadline.addingTimeInterval(0.001)))
    }

    func testDeliveringAgainReplacesTheWindowRatherThanExtendingTheOldOne() throws {
        // A second Direct delivery is a new subject: the window it opens is
        // measured from itself, and guards whatever app that delivery landed
        // in.
        let first = try XCTUnwrap(armedWindow())
        let secondAt: Date = deliveredAt.addingTimeInterval(3)
        let second = try XCTUnwrap(
            CorrectionWindow.reduce(
                first,
                on: .delivered(
                    at: secondAt,
                    capturedBundleId: "com.tinyspeck.slackmacgap",
                    mode: .transcribe,
                    variant: .direct
                )
            )
        )

        XCTAssertEqual(second.deliveredAt, secondAt)
        XCTAssertEqual(second.capturedBundleId, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(
            second.deadline,
            secondAt.addingTimeInterval(CorrectionWindow.windowSeconds)
        )
    }
}

/// C. The visible affordance.
///
/// From the spec: 「**用户看不见这个窗口，这个功能就等于不存在**——这是这条的成败点，
/// 不是装饰。」 The success toast normally disappears after 0.9s
/// (`OverlayController.hideBehavior(for:)`), which is far too short to tell
/// anyone that the hotkey currently means something else. While a correction
/// window is armed, the same toast must instead stay up for the window's full
/// duration, carry the "select the wrong word and press again" copy, and run a
/// progress bar that empties as the window does.
///
/// That is a per-state *timing* decision, which this codebase already expresses
/// at one pure seam — `OverlayController.hideBehavior(for:)` returning an
/// `OverlayHideBehavior` — so it belongs there too, as an overload taking the
/// extra fact and a new case able to say "this toast is the correction
/// affordance." RED until Stage 3 adds both.
///
/// `@MainActor` for the same reason `OverlayHideBehaviorTests` is: `hideBehavior`
/// is a static member of the `@MainActor`-isolated `OverlayController`, so
/// calling it from a nonisolated synchronous test is a hard compile error even
/// in Swift 5 language mode. Only this class needs it — `CorrectionWindow`
/// itself must stay nonisolated, which the class above pins by not having it.
@MainActor
final class CorrectionWindowAffordanceTests: XCTestCase {

    /// §F made `OpenTypeL10n.text(_:english:)` depend on
    /// `OpenTypeL10n.current` rather than unconditionally returning Chinese —
    /// pinned here so `testTheHintTellsTheUserWhatToDoRatherThanJustSayingDone`'s
    /// assertion about the Chinese hint copy doesn't depend on whatever locale
    /// the test runner's process happens to report.
    override func setUp() {
        super.setUp()
        OpenTypeL10n.current = .chinese
    }

    override func tearDown() {
        OpenTypeL10n.current = .system
        super.tearDown()
    }

    func testAnArmedWindowKeepsTheSuccessToastUpForTheWholeWindow() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .success, correctionWindowArmed: true),
            .scheduleHideWithCorrectionHint(after: CorrectionWindow.windowSeconds)
        )
    }

    func testTheCopiedToastGetsTheSameTreatment() {
        // Clipboard-only delivery is still a delivery the user may want to fix
        // — and `OutputDeliveryPolicy` can downgrade an insert to `.copied` at
        // the last moment, so the affordance cannot depend on which of the two
        // toasts happened to be chosen.
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .copied, correctionWindowArmed: true),
            .scheduleHideWithCorrectionHint(after: CorrectionWindow.windowSeconds)
        )
    }

    func testTheToastAndTheWindowCannotDriftApart() {
        // The progress bar is only honest if it empties exactly when the hotkey
        // stops meaning "correct" — so the duration must come from
        // `CorrectionWindow.windowSeconds` itself, not from a second literal.
        guard case .scheduleHideWithCorrectionHint(let seconds) =
                OverlayController.hideBehavior(for: .success, correctionWindowArmed: true)
        else {
            return XCTFail("an armed window must produce the correction-hint toast")
        }
        XCTAssertEqual(seconds, CorrectionWindow.windowSeconds)
    }

    func testTheCorrectionToastOutlastsTheOrdinarySuccessToastByAWideMargin() {
        // The failure mode this guards against is a "fix" that leaves the
        // affordance invisible: 0.9s is not enough time to read a hint, let
        // alone select a word and press a key.
        guard case .scheduleHideWithCorrectionHint(let armedSeconds) =
                OverlayController.hideBehavior(for: .success, correctionWindowArmed: true),
              case .scheduleHide(let plainSeconds) =
                OverlayController.hideBehavior(for: .success, correctionWindowArmed: false)
        else {
            return XCTFail("expected a hinted toast when armed and a plain toast when not")
        }
        XCTAssertGreaterThan(armedSeconds, plainSeconds)
    }

    func testWithNoWindowArmedTheSuccessToastIsUnchanged() {
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .success, correctionWindowArmed: false),
            .scheduleHide(after: 0.9)
        )
        XCTAssertEqual(
            OverlayController.hideBehavior(for: .copied, correctionWindowArmed: false),
            .scheduleHide(after: 0.9)
        )
    }

    func testAnArmedWindowChangesNothingAboutAnyOtherState() {
        // Only the two delivery-success toasts are the correction affordance.
        // Errors, cancellations, mode switches and every in-flight state keep
        // the timings `OverlayHideBehaviorTests` already pins, so the overload
        // must agree with the single-argument seam everywhere else.
        let untouched: [ProcessingState] = [
            .idle,
            .modeChanged,
            .listening,
            .transcribing,
            .transforming,
            .inserting,
            .dispatched("已下发给 Agent"),
            .cancelled("已取消"),
            .failure("出错了")
        ]

        for state in untouched {
            XCTAssertEqual(
                OverlayController.hideBehavior(for: state, correctionWindowArmed: true),
                OverlayController.hideBehavior(for: state),
                "\(state) is not the correction affordance and must keep its existing timing"
            )
        }
    }

    func testTheHintTellsTheUserWhatToDoRatherThanJustSayingDone() {
        // A longer-lived toast that still reads 「完成」 teaches nobody that the
        // hotkey changed meaning. The copy has to name both halves of the
        // gesture: select the wrong word, press the hotkey again.
        let hint = CorrectionWindow.hintText

        XCTAssertFalse(hint.isEmpty)
        XCTAssertTrue(
            hint.contains("选中"),
            "the hint must tell the user to select the wrong word, got: \(hint)"
        )
        XCTAssertTrue(
            hint.contains("再按一次"),
            "the hint must tell the user to press the hotkey again, got: \(hint)"
        )
        XCTAssertNotEqual(hint, ProcessingState.success.title)
    }
}
