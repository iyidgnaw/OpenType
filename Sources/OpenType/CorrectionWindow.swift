import Foundation

/// What pressing the hotkey means at this instant.
///
/// The hotkey has exactly one gesture but two meanings, and which one applies
/// is a function of the clock and the target app rather than of a second
/// chord: for a few seconds after a delivery that pasted straight into the
/// user's app it means "fix what I just said," and at every other moment it
/// means what it has always meant.
enum HotKeyIntent: Equatable {
    /// The ordinary meaning: begin a new dictation.
    case startNewRecording
    /// Record a spoken instruction and rewrite the text currently selected in
    /// the target app, in place (`AppModel.processInPlaceCorrection`).
    case correctSelection
}

/// The post-delivery correction window (P0-3,
/// `docs/superpowers/specs/2026-08-14-product-batch-plan.md`).
///
/// Direct and Tidy deliver instantly and add no latency — that is the whole
/// point of both, and this feature must not cost it. What it adds instead is an
/// *afterwards*: for `windowSeconds` following a delivery, if the user selects
/// text in the app that delivery landed in and presses the hotkey again, they
/// are correcting that selection by voice instead of starting a new dictation.
///
/// Tidy (P1-8) is the variant that needs this most, not merely the newest one
/// to qualify for it: it is the only delivering variant whose output differs
/// from what the user said, so a wrong word there can be the tool's doing
/// rather than only the recogniser's, and the fix has to be one keypress away.
///
/// It is deliberately **in-place** rather than "re-open the Review panel with
/// the delivered text prefilled." The text is already pasted into the target
/// app by then, so a panel commit would insert a second copy, and undoing the
/// first paste with Cmd+Z is unsafe the moment the user has touched the
/// keyboard at all. `ContextBridge.capture()` already reads the selection and
/// `ContextBridge.insert()` is Cmd+V — which natively *replaces* a selection —
/// so correcting in place needs no undo, no panel, and no new write path. As a
/// side effect it also works on text OpenType never produced.
///
/// Factored out of `AppModel` for the reason `OutputDeliveryPolicy` and
/// `VoiceSurfaceState` were: the decision is pure, and a screen-free seam is
/// the only place its boundaries can actually be tested (`AppModel.init` has
/// side effects and is not instantiable in tests). Nothing here touches AppKit
/// or the main actor.
enum CorrectionWindow {

    /// How long the window stays open, in seconds.
    ///
    /// Long enough to glance at what was just pasted and react, short enough
    /// that someone who just wants to keep dictating is not robbed of the
    /// hotkey. This is the batch's one intuition-picked constant (the spec
    /// marks it 待调) — everything else here derives from it, including the
    /// toast duration and its progress bar, so changing it moves the whole
    /// feature together.
    static let windowSeconds: TimeInterval = 8

    /// The copy the success toast carries while the window is open.
    ///
    /// The spec's make-or-break point: 「用户看不见这个窗口，这个功能就等于
    /// 不存在」. A toast that still reads 「完成」 teaches nobody that the
    /// hotkey changed meaning, so the copy names both halves of the gesture —
    /// select the wrong word, press again.
    static let hintText: String = OpenTypeL10n.text(
        "选中说错的词，再按一次快捷键即可纠正",
        english: "Select the wrong word and press the shortcut again to fix it"
    )

    /// What the hotkey means right now.
    ///
    /// - Parameters:
    ///   - lastDeliveryAt: When the still-open window was armed (a delivery, or
    ///     the last successful correction), or `nil` if there is no window.
    ///   - selectedText: What is selected in the frontmost app *at press time*.
    ///   - capturedBundleId: The app the window's delivery landed in.
    ///   - frontmostBundleId: The app in front now.
    ///   - mode: The mode the user is in **now**, not the one the delivery ran
    ///     in — the arming gate in `reduce(_:on:)` owns that half.
    static func intent(
        lastDeliveryAt: Date?,
        now: Date,
        selectedText: String?,
        capturedBundleId: String?,
        frontmostBundleId: String?,
        mode: InputMode,
        variant: TranscribeVariant
    ) -> HotKeyIntent {
        // Transcribe variants that actually deliver into the target app —
        // today Direct and Tidy (`TranscribeVariant.deliversIntoTargetApp`).
        // An ask/agent card on screen already gives a second utterance the
        // meaning "continue this conversation" (`VoiceFollowUp`), and Review's
        // open panel already gives the hotkey the meaning "correct the panel's
        // selection" — this feature exists to give the variants that paste
        // straight into someone else's app the same affordance those two
        // already have, not to fight either of them for the same key.
        guard mode == .transcribe, variant.deliversIntoTargetApp else {
            return .startNewRecording
        }

        // Half-open [delivery, delivery + windowSeconds): at exactly the
        // deadline the window has closed, so it has one unambiguous end and
        // `State.isExpired(at:)` can be the plain `now >= deadline`.
        guard let lastDeliveryAt,
              now < lastDeliveryAt.addingTimeInterval(windowSeconds)
        else { return .startNewRecording }

        // Deliberately *not* stealing the hotkey: someone who wants to correct
        // selects first, and someone who just wants to say the next sentence
        // must not be interrupted by a mode they did not ask for. A drag that
        // caught only whitespace has nothing to correct, so it counts as no
        // selection rather than sending an empty `fullText` to the sidecar.
        guard let selectedText,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .startNewRecording }

        // A correction writes through the very same `ContextBridge.insert`
        // path a delivery does, so the two must never disagree about the same
        // pair of apps: asking `OutputDeliveryPolicy` rather than re-deriving
        // the rule is what keeps them from drifting apart later.
        return OutputDeliveryPolicy.shouldInsert(
            capturedBundleId: capturedBundleId,
            frontmostBundleId: frontmostBundleId
        ) ? .correctSelection : .startNewRecording
    }

    /// An open window. Its existence is the whole state — expiry needs no
    /// timer and no clearing, since `intent(...)` and `isExpired(at:)` both
    /// read the clock (see `AppModel`'s window bookkeeping, which carries the
    /// audit anchors alongside this).
    struct State: Equatable {
        /// When the window started running: the delivery, or the last
        /// correction that re-armed it.
        let deliveredAt: Date
        /// The app that delivery landed in. A correction only makes sense
        /// while the user is still looking at it.
        let capturedBundleId: String?

        var deadline: Date {
            deliveredAt.addingTimeInterval(windowSeconds)
        }

        /// Exclusive, matching `intent(...)`'s boundary exactly.
        func isExpired(at now: Date) -> Bool {
            now >= deadline
        }
    }

    /// Everything that can open, extend, or close a window.
    enum Event: Equatable {
        /// A delivery finished. Carries `mode`/`variant` so the arming gate
        /// lives in `reduce(_:on:)` — the one place that decides whether a
        /// window exists at all — rather than in whichever call site happens
        /// to emit the event.
        case delivered(
            at: Date,
            capturedBundleId: String?,
            mode: InputMode,
            variant: TranscribeVariant
        )
        /// An in-place correction landed.
        case correctionSucceeded(at: Date)
        /// An in-place correction failed (ASR, sidecar, or paste).
        case correctionFailed
        /// A **new** dictation began — not merely "some recording began." The
        /// correction round records too, and if it emitted this the window
        /// would be gone before `.correctionSucceeded` ever arrived.
        case recordingStarted
        /// Esc: the user is done with this, including done with the offer.
        case cancelled
    }

    static func reduce(_ state: State?, on event: Event) -> State? {
        switch event {
        case .delivered(let at, let capturedBundleId, let mode, let variant):
            // Only a transcribe delivery that landed in the target app arms
            // one, matching `intent(...)`'s gate exactly. This matters in both
            // directions: `intent(...)` is told the mode the user is in *now*,
            // so a window armed by an ask/agent delivery would let a hotkey
            // press "correct" a selection that delivery never produced, if the
            // user switched back to a delivering variant inside those seconds.
            // An ineligible delivery therefore also closes an open window
            // rather than leaving it standing.
            guard mode == .transcribe, variant.deliversIntoTargetApp else {
                return nil
            }
            // A second delivery is a new subject: measured from itself, and
            // guarding whatever app *it* landed in.
            return State(deliveredAt: at, capturedBundleId: capturedBundleId)

        case .correctionSucceeded(let at):
            // Fixing two words in a row is common — correct one, look at the
            // next, select it, press again — so a correction restarts the
            // clock instead of ending the window. It cannot conjure one that
            // was never open.
            guard let state else { return nil }
            return State(deliveredAt: at, capturedBundleId: state.capturedBundleId)

        case .correctionFailed:
            // Neither re-arm nor clear: the window keeps running on its
            // original clock. Not re-armed, because a failure toast has by
            // then replaced the hint on screen, and a fresh window behind an
            // error message would leave the hotkey silently meaning "correct"
            // with nothing saying so — the exact invisible-window failure this
            // feature exists to avoid. Not cleared either, because a fast
            // failure leaves the selection untouched and whatever seconds
            // remain are still the user's to retry in (a slow one has expired
            // on its own by then anyway).
            return state

        case .recordingStarted, .cancelled:
            return nil
        }
    }
}
