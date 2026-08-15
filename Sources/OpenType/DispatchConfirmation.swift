import Foundation

/// The pre-dispatch confirmation window (P1-6,
/// `docs/superpowers/specs/2026-08-14-product-batch-plan.md`).
///
/// Voice is the least accurate input channel this app has, and Agent is the
/// one mode with real hands: `opentype__bash`, `opentype__python`, no sandbox.
/// A misheard agent task is not a bad answer, it is an executed one. So before
/// a task goes out, the transcript is shown for `windowSeconds` and Esc takes
/// it back.
///
/// Deliberately **not** a confirmation dialog, in the spec's own words
/// (「不是模态确认框——默认继续，只给一个反悔的机会」):
///
/// - **Default is proceed.** Doing nothing dispatches. The only input that
///   changes the outcome is Esc, and only if it lands inside the window. At the
///   frequency this tool is used, a blocking dialog would cost more than the
///   mishears it prevents — and a prompt people learn to dismiss is worse than
///   no prompt, because it buys the interruption without the attention.
/// - **The window is short and fixed.** Long enough to read a short task back
///   and react, short enough that nobody learns to dread it.
/// - **The transcript travels with the pending state**, because the whole point
///   is that the user sees *what was heard*. A window showing 「正在下发…」
///   catches nothing.
///
/// Agent only, not ask: a misheard question costs one wrong answer the user
/// reads and discards (Ask is draft-only — voice surface plus clipboard, never
/// auto-inserted), while an agent's side effects are unbounded and local. Ask
/// is also the higher-frequency of the two, so charging every question 1.5s
/// would be the bad trade the spec warns about.
///
/// Factored into a pure seam for the reason `CorrectionWindow`,
/// `OutputDeliveryPolicy` and `VoiceSurfaceState` were: `AppModel.init` has
/// side effects and is not instantiable in tests, so the decision is only
/// testable where it touches neither AppKit nor the clock.
enum DispatchConfirmation {

    /// How long the transcript stays on screen before the task goes out.
    ///
    /// The spec's number. Named rather than inlined at the call site so that
    /// everything derived from it — the surface's countdown bar, the copy —
    /// moves together, and so changing the feel of the feature is one
    /// deliberate edit here rather than a silent drift in `AppModel`.
    static let windowSeconds: TimeInterval = 1.5

    /// The copy the window carries.
    ///
    /// The same make-or-break point `CorrectionWindow.hintText` makes: 1.5
    /// seconds is far too short to discover Esc by experiment, so the
    /// affordance has to be written on the surface or it does not exist.
    static let hintText: String = OpenTypeL10n.text(
        "Esc 撤销",
        english: "Esc to cancel"
    )

    /// Whether `mode` gets a window at all.
    static func appliesTo(mode: InputMode) -> Bool {
        switch mode {
        case .agent:
            return true
        case .ask:
            // See the type's doc comment: draft-only answer, higher frequency.
            return false
        case .transcribe:
            // Never dispatches anything — it delivers text the user can see and
            // edit, and P0-3's post-delivery correction window is already its
            // "I misheard you" affordance. Adding latency to the mode whose
            // whole promise is instant delivery would break that promise to
            // solve a problem it does not have.
            return false
        }
    }

    /// An open window: what was heard, and when it went up.
    struct Pending: Equatable {
        /// Verbatim. Showing a tidied-up version would defeat the purpose —
        /// the mishear could be exactly in the part that got normalised away.
        let transcript: String
        let armedAt: Date

        var deadline: Date {
            armedAt.addingTimeInterval(windowSeconds)
        }

        /// Half-open `[armedAt, deadline)`, matching `CorrectionWindow.State`'s
        /// convention exactly so the two windows in this batch cannot disagree
        /// about what "expired" means.
        func isExpired(at now: Date) -> Bool {
            now >= deadline
        }
    }

    /// What to do when the window closes.
    enum Decision: Equatable {
        /// Send this text, character for character as it was shown.
        case dispatch(String)
        /// Send nothing. Carries no transcript on purpose: there is nothing to
        /// dispatch, and a payload here would invite a call site to dispatch it
        /// anyway.
        case cancelled
    }

    /// Opens a window, or returns `nil` for a mode that dispatches immediately.
    ///
    /// The scope gate lives here — the one place that decides whether a window
    /// exists at all — rather than being re-derived as an `if mode == .agent`
    /// at the call site, the same structural choice `CorrectionWindow.reduce`
    /// makes for its own arming gate.
    static func arm(transcript: String, mode: InputMode, at now: Date) -> Pending? {
        guard appliesTo(mode: mode) else { return nil }
        return Pending(transcript: transcript, armedAt: now)
    }

    /// The outcome, asked once when the window closes.
    ///
    /// - Parameters:
    ///   - pending: the window that was open.
    ///   - escapePressedAt: when Esc landed, or `nil` if the window lapsed with
    ///     no keypress.
    ///
    /// The bounds are checked at *both* ends. The obvious `pressed < deadline`
    /// is true for every instant in history, so a keypress from before arming
    /// would cancel a task the user never saw — and that is reachable, not
    /// theoretical: `AppModel` learns the transcript only after recognition
    /// returns, so an Esc pressed while the sidecar was still transcribing has
    /// a real timestamp that predates arming. The honest reading of that one is
    /// "cancel the recording", which is a different call site's job.
    static func decision(for pending: Pending, escapePressedAt: Date?) -> Decision {
        guard let escapePressedAt,
              escapePressedAt >= pending.armedAt,
              escapePressedAt < pending.deadline
        else { return .dispatch(pending.transcript) }
        return .cancelled
    }
}
