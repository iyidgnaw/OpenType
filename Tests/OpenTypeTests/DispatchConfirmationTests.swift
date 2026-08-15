import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the first half of P1-6, the pre-dispatch
/// confirmation window (`docs/superpowers/specs/2026-08-14-product-batch-plan.md`,
/// "P1-6 下发前确认 + 破坏性命令审批").
///
/// The product rule, in the spec's own words: 「把转写文本显示 ~1.5 秒，期间 Esc
/// 撤销。不是模态确认框——默认继续，只给一个反悔的机会」. So the shape being pinned
/// here is deliberately *not* a confirmation dialog:
///
/// - **Default is proceed.** Doing nothing dispatches. The only input that
///   changes the outcome is Esc, and only if it lands inside the window.
/// - **The window is short and fixed.** At the frequency this tool is used, a
///   blocking dialog would cost more than the mishears it prevents; 1.5s is
///   long enough to read a short task back and react, and short enough that
///   nobody learns to dread it.
/// - **The transcript travels with the pending state**, because the entire
///   point is that the user *sees what was heard*. A window that shows
///   「正在下发…」 catches nothing. The seam carries the text so the surface
///   has something to show and so this can be tested without SwiftUI.
///
/// Scope decision pinned below: **agent only, not ask.** See
/// `testAskIsDeliberatelyNotConfirmed` for the reasoning.
///
/// `AppModel.init` has side effects and is not instantiable in tests, so — the
/// established pattern in this repo (`OutputDeliveryPolicy`, `CorrectionWindow`,
/// `VoiceSurfaceState`, `OnboardingPolicy`) — the decision is factored into a
/// pure, screen-free seam and tested there. Nothing here touches AppKit, the
/// main actor, or the clock.
///
/// These tests are RED until Stage 3 adds `Sources/OpenType/DispatchConfirmation.swift`
/// with `DispatchConfirmation.windowSeconds`, `.hintText`, `.appliesTo(mode:)`,
/// `.arm(transcript:mode:at:)`, `DispatchConfirmation.Pending` and
/// `DispatchConfirmation.Decision` + `.decision(for:escapePressedAt:)`. They
/// currently fail to COMPILE because none of those symbols exist yet — that is
/// the intended red.
final class DispatchConfirmationTests: XCTestCase {

    /// A fixed, exactly-representable instant so the 1.5s boundary arithmetic
    /// is not at the mercy of `Date()` or floating-point drift.
    private let armedAt = Date(timeIntervalSinceReferenceDate: 2_000_000)

    /// A task with real consequences — the reason this feature exists. If
    /// Whisper heard 「把 build 目录删掉」 as 「把 backup 目录删掉」, this is the
    /// 1.5 seconds in which the user gets to notice.
    private let task = "把 build 目录删掉"

    // MARK: - A. The window length is a named constant

    func testTheConfirmationWindowIsOnePointFiveSeconds() {
        // The spec's number (~1.5s). Pinned as a named constant rather than a
        // literal at the call site so that everything derived from it — the
        // surface's countdown, the copy, any future progress bar — moves
        // together, and so changing the feel of the feature is one deliberate
        // edit here rather than a silent drift in `AppModel`.
        XCTAssertEqual(DispatchConfirmation.windowSeconds, 1.5)
    }

    func testTheHintNamesTheKeyThatCancels() {
        // Same make-or-break point `CorrectionWindow.hintText` makes: a window
        // nobody can see is a window that does not exist. 1.5 seconds is far
        // too short to discover Esc by experiment, so the affordance has to be
        // written on the surface. `OpenTypeL10n.text` returns the Chinese
        // string deterministically (InterfaceLanguage.swift), so this is not
        // locale-flaky — but the key's name is "Esc" in either language.
        XCTAssertFalse(DispatchConfirmation.hintText.isEmpty)
        XCTAssertTrue(
            DispatchConfirmation.hintText.contains("Esc"),
            "The hint must name the key that cancels; got: \(DispatchConfirmation.hintText)"
        )
    }

    // MARK: - B. Which modes confirm — agent only

    func testAgentIsConfirmedBeforeDispatch() {
        // Agent is the mode with hands: `opentype__bash` / `opentype__python`,
        // no sandbox, `yoloApprovalPolicy`. A misheard agent task is not a bad
        // answer, it is an executed one.
        XCTAssertTrue(DispatchConfirmation.appliesTo(mode: .agent))
    }

    func testAskIsDeliberatelyNotConfirmed() {
        // The scope decision, pinned. Ask runs `runAgentLoop` with a web-only
        // toolset (`opentype__web_search` + `opentype__web_fetch`, narrowed by
        // `filterToolSet`) and its answer is draft-only — clipboard plus the
        // voice surface, never auto-inserted. A misheard question therefore
        // costs one wrong answer that the user reads and discards; nothing on
        // their machine changed. Charging every question 1.5 seconds to
        // prevent that is a bad trade in exactly the way the spec warns about
        // (「否则高频使用会被拖垮」), and Ask is the higher-frequency of the two.
        //
        // The counter-argument, recorded because it is not nothing: Ask does
        // reach the network, so a misheard question can send unintended text
        // to a search engine, and confirmation is the only moment that could
        // stop it. Judged not to carry the day — the transcript reaches the
        // configured LLM provider in both modes regardless, so confirmation
        // buys a narrower disclosure win than it first appears, while the
        // agent's side effects are unbounded and local.
        XCTAssertFalse(DispatchConfirmation.appliesTo(mode: .ask))
    }

    func testTranscribeIsNotConfirmed() {
        // Transcribe never dispatches anything — it delivers text the user can
        // see and edit, and P0-3's post-delivery correction window is already
        // the "I misheard you" affordance for it. Adding 1.5s of latency to
        // the mode whose whole promise is instant delivery would break that
        // promise to solve a problem it does not have.
        XCTAssertFalse(DispatchConfirmation.appliesTo(mode: .transcribe))
    }

    // MARK: - C. Arming

    func testArmingAnAgentTaskProducesAPendingConfirmation() {
        XCTAssertNotNil(DispatchConfirmation.arm(transcript: task, mode: .agent, at: armedAt))
    }

    func testArmingIsSkippedForModesThatDoNotConfirm() {
        // `nil` is how the seam says "dispatch immediately" — the scope gate
        // lives here, in the one place that decides whether a window exists at
        // all, rather than being re-derived as an `if mode == .agent` at the
        // call site (the same structural choice `CorrectionWindow.reduce`
        // makes for its arming gate).
        XCTAssertNil(DispatchConfirmation.arm(transcript: task, mode: .ask, at: armedAt))
        XCTAssertNil(DispatchConfirmation.arm(transcript: task, mode: .transcribe, at: armedAt))
    }

    func testThePendingConfirmationCarriesTheTranscriptForTheSurfaceToShow() {
        // The heart of the feature: the user must see *what was heard*. The
        // seam carries the text, so this is assertable without instantiating
        // any SwiftUI view — the surface's job is only to render what is
        // already here.
        let pending = DispatchConfirmation.arm(transcript: task, mode: .agent, at: armedAt)
        XCTAssertEqual(pending?.transcript, task)
        XCTAssertEqual(pending?.armedAt, armedAt)
    }

    func testTheTranscriptIsCarriedVerbatimAndNeverCleanedUp() {
        // Showing the user a tidied-up version of what was heard would defeat
        // the purpose: the mishear could be exactly in the part that got
        // normalised away. Whatever string is dispatched is the string that
        // was displayed, character for character.
        let messy = "  把  build 目录删掉，然后 rm -rf ~/tmp\n（第二行）  "
        let pending = DispatchConfirmation.arm(transcript: messy, mode: .agent, at: armedAt)
        XCTAssertEqual(pending?.transcript, messy)
    }

    func testTheDeadlineIsTheArmingInstantPlusTheWindow() {
        let pending = DispatchConfirmation.arm(transcript: task, mode: .agent, at: armedAt)
        XCTAssertEqual(
            pending?.deadline,
            armedAt.addingTimeInterval(DispatchConfirmation.windowSeconds)
        )
    }

    func testExpiryIsHalfOpenSoTheWindowHasOneUnambiguousEnd() {
        // [armedAt, armedAt + 1.5): at exactly the deadline the window has
        // closed and the task has gone out. Matching `CorrectionWindow.State`'s
        // convention exactly, so the two windows in this batch cannot disagree
        // about what "expired" means.
        guard let pending = DispatchConfirmation.arm(transcript: task, mode: .agent, at: armedAt) else {
            return XCTFail("agent tasks must arm a confirmation window")
        }
        XCTAssertFalse(pending.isExpired(at: armedAt))
        XCTAssertFalse(pending.isExpired(at: armedAt.addingTimeInterval(1.4)))
        XCTAssertTrue(pending.isExpired(at: armedAt.addingTimeInterval(1.5)))
        XCTAssertTrue(pending.isExpired(at: armedAt.addingTimeInterval(9)))
    }

    // MARK: - D. The decision: proceed unless Esc arrived in time

    /// The pending confirmation every decision test below is asked about.
    private func armed(_ transcript: String? = nil) -> DispatchConfirmation.Pending {
        guard let pending = DispatchConfirmation.arm(
            transcript: transcript ?? task,
            mode: .agent,
            at: armedAt
        ) else {
            preconditionFailure("agent tasks must arm a confirmation window")
        }
        return pending
    }

    func testNoEscMeansTheTaskIsDispatchedUnchanged() {
        // The default, and the case that happens ~every time: the user says a
        // task, glances at it, does nothing, and it goes. `escapePressedAt:
        // nil` is "the window lapsed with no keypress" — the seam is asked
        // once, at the deadline.
        XCTAssertEqual(
            DispatchConfirmation.decision(for: armed(), escapePressedAt: nil),
            .dispatch(task)
        )
    }

    func testTheDispatchedTextIsTheTextThatWasShownByteForByte() {
        // A confirmation that shows one string and dispatches another is worse
        // than no confirmation, so the decision carries the transcript rather
        // than leaving the call site to re-read it from somewhere else that
        // might have moved on (a second recording, a tidied variant, a follow-
        // up thread).
        let messy = "帮我把 ~/Downloads 里的 *.dmg 都删了，别碰别的  "
        XCTAssertEqual(
            DispatchConfirmation.decision(for: armed(messy), escapePressedAt: nil),
            .dispatch(messy)
        )
    }

    func testEscInsideTheWindowCancelsAndNothingIsDispatched() {
        // The whole feature, in one case: Whisper heard the wrong directory,
        // the user reads it 0.4s in and hits Esc. `.cancelled` carries no
        // transcript — there is nothing to dispatch, and a payload here would
        // invite a call site to dispatch it anyway.
        XCTAssertEqual(
            DispatchConfirmation.decision(
                for: armed(),
                escapePressedAt: armedAt.addingTimeInterval(0.4)
            ),
            .cancelled
        )
    }

    func testEscAtTheVeryFirstInstantCancels() {
        // A user who is already reaching for Esc as the text appears — the
        // fastest possible reaction — must not fall outside the window on a
        // boundary technicality.
        XCTAssertEqual(
            DispatchConfirmation.decision(for: armed(), escapePressedAt: armedAt),
            .cancelled
        )
    }

    func testEscJustBeforeTheDeadlineStillCancels() {
        XCTAssertEqual(
            DispatchConfirmation.decision(
                for: armed(),
                escapePressedAt: armedAt.addingTimeInterval(1.499)
            ),
            .cancelled
        )
    }

    func testEscExactlyAtTheDeadlineIsTooLate() {
        // The half-open boundary again, from the decision side: at exactly
        // 1.5s the task has already been handed to `/agent/run`, and pretending
        // otherwise would report "cancelled" to a user whose task is running.
        // Stopping a run that already started is `/agent/cancel`'s job, not
        // this window's.
        XCTAssertEqual(
            DispatchConfirmation.decision(
                for: armed(),
                escapePressedAt: armedAt.addingTimeInterval(DispatchConfirmation.windowSeconds)
            ),
            .dispatch(task)
        )
    }

    func testEscFromBeforeTheWindowOpenedDoesNotCancelIt() {
        // The other side of the boundary, and the one an implementation gets
        // wrong by writing the obvious `pressed < deadline`: that predicate is
        // true for every instant in history, so a keypress the seam is told
        // about from *before* arming would cancel a task the user never saw.
        // The window is [armedAt, deadline) at both ends — `testEscAtTheVery
        // FirstInstantCancels` pins the inclusive lower edge, this pins that
        // there is a lower edge at all.
        //
        // It is reachable rather than theoretical: `AppModel` learns the
        // transcript only after recognition returns, so an Esc pressed while
        // the sidecar was still transcribing is a real event with a real
        // timestamp that predates arming — and the honest reading of it is
        // "cancel the recording", which is a different call site's job.
        XCTAssertEqual(
            DispatchConfirmation.decision(
                for: armed(),
                escapePressedAt: armedAt.addingTimeInterval(-0.5)
            ),
            .dispatch(task)
        )
    }

    func testEscLongAfterTheWindowIsIrrelevantToThisDecision() {
        XCTAssertEqual(
            DispatchConfirmation.decision(
                for: armed(),
                escapePressedAt: armedAt.addingTimeInterval(30)
            ),
            .dispatch(task)
        )
    }

    func testCancellingIsNotADispatchOfEmptyText() {
        // Guards the shape of the enum itself: `.cancelled` must be its own
        // case, not `.dispatch("")`. An empty task reaching `/agent/run` would
        // be a live agent run with an empty prompt — the exact outcome the
        // user pressed Esc to prevent.
        let decision = DispatchConfirmation.decision(
            for: armed(),
            escapePressedAt: armedAt.addingTimeInterval(0.2)
        )
        XCTAssertNotEqual(decision, .dispatch(""))
        XCTAssertEqual(decision, .cancelled)
    }
}
