import Foundation

/// The elapsed-time readout on the listening pill (P2-10,
/// `docs/superpowers/specs/2026-08-14-product-batch-plan.md`).
///
/// Separate from `RecordingLimits` below because it answers a different
/// question — *what the user reads* rather than *what the app does* — but the
/// two are pinned to each other: the numbers this renders at the policy's two
/// thresholds are exactly the minutes the spec names (`2:00`, `5:00`).
///
/// Pure and locale-free on purpose. A `DateComponentsFormatter` would render
/// this differently depending on where the app is running, and the pill is a
/// fixed-width element in a centred panel: a label whose width depends on the
/// user's region is a HUD that twitches on someone else's machine and not on
/// ours.
enum RecordingClock {

    /// `m:ss` — minutes unpadded, seconds always two digits.
    ///
    /// Truncating rather than rounding: rounding would show `1:00` at 59.5s, a
    /// number the user has not reached, and would then show it again at 60.0,
    /// so the label would jump early and then sit still for a full second.
    /// Truncation makes every tick honest.
    ///
    /// Negative input clamps to zero. A start timestamp can end up in the
    /// future across a system clock adjustment or a sleep/wake, and `-1:-5` on
    /// screen is worse than useless.
    ///
    /// Minutes are not wrapped at the hour: nothing should ever record that
    /// long (`RecordingLimits.maximumSeconds` sees to it), but a formatter that
    /// silently reports 60:00 as 0:00 only surfaces once the auto-stop is the
    /// part that broke.
    static func elapsedText(seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// What the listening pill offers as a way to end the recording in
    /// progress, and what its trailing hint should say. One value for both so
    /// the two can never disagree — see the call site in
    /// `OverlayController.listeningContent`, which reads `hintText` and
    /// `stopsOnClick` off the same instance rather than deriving clickability
    /// separately.
    struct StopAffordance: Equatable {
        /// What the pill's trailing hint reads.
        let hintText: String
        /// Whether a click/tap on that hint actually ends the recording.
        let stopsOnClick: Bool
    }

    /// - Parameter startedByClick: whether this recording began from a UI tap
    ///   (the result card's mic button —
    ///   `AppModel.startVoiceSurfaceFollowUpRecording()`) rather than the
    ///   physical hotkey.
    ///
    /// A hotkey-started recording keeps today's copy and offers no click
    /// affordance: the hotkey is already a perfectly good way out, and any
    /// hint here would be naming a control the pill does not have. A
    /// click-started recording has no such discoverable way out — the mic
    /// button that started it is gone the instant the pill replaces the
    /// result card, and the physical hotkey was never pressed to begin with
    /// (`hotKeyReleased()` still ends it too, but nothing on screen says so)
    /// — so it gets a hint naming the control that *is* actually there, and
    /// the affordance to make that hint true.
    ///
    /// A `func`, not a `static let`: see `RecordingLimits.warningText`'s doc
    /// comment below for why a memoized string is the wrong shape for
    /// anything that reads `OpenTypeL10n.current`.
    static func stopAffordance(startedByClick: Bool) -> StopAffordance {
        guard startedByClick else {
            return StopAffordance(
                hintText: OpenTypeL10n.text("松开结束", english: "Release to finish"),
                stopsOnClick: false
            )
        }
        return StopAffordance(
            hintText: OpenTypeL10n.text("点击结束", english: "Click to finish"),
            stopsOnClick: true
        )
    }
}

/// How long a single recording is allowed to run, and what happens when it has
/// run too long (P2-10).
///
/// 「hands-free 连续录音超过 **2 分钟**给一次视觉提醒，**5 分钟**自动停止并正常
/// 交付（不是丢弃——丢掉用户 5 分钟的口述是不可接受的失败模式）。」
///
/// Factored out of `AppModel` for the reason `CorrectionWindow`,
/// `OutputDeliveryPolicy` and `VoiceSurfaceState` were: the decision is pure,
/// and a screen-free, timer-free seam is the only place its boundaries can
/// actually be tested (`AppModel.init` has side effects and is not instantiable
/// in tests). Elapsed time is an *input* here — nothing in this file reads a
/// clock, and nothing in it is `@MainActor`, so the recording tick can consult
/// it from wherever it runs.
enum RecordingLimits {

    /// The visual warning, in seconds of elapsed recording.
    static let warningSeconds: TimeInterval = 120

    /// The hard cap. Past this the recording ends itself.
    static let maximumSeconds: TimeInterval = 300

    /// What the warning says.
    ///
    /// A wordless flash teaches nobody anything. Someone two minutes into a
    /// long thought needs to know both that they are being watched and that the
    /// recording will end on its own at five minutes — naming the deadline is
    /// what makes the auto-stop feel like a net rather than an ambush.
    ///
    /// A computed `static var`, not a `static let`: Swift memoizes a `static
    /// let` once per process, on whichever thread first touches it, so a
    /// literal `let` here would freeze at whatever `OpenTypeL10n.current` was
    /// at that first access — for the rest of the process — even though §F's
    /// interface-language switch is live, not restart-required. A `var` that
    /// re-evaluates `OpenTypeL10n.text` on every read is what makes this
    /// track the language actually current at the moment the warning fires.
    static var warningText: String {
        OpenTypeL10n.text(
            "已录 2 分钟，满 5 分钟会自动停止并照常交付",
            english: "Two minutes in — recording stops on its own at 5 minutes and is delivered as usual"
        )
    }

    /// What the recording tick should do at this instant.
    enum Action: Equatable, CaseIterable {
        /// Nothing to do. The overwhelmingly common answer.
        case keepRecording
        /// Show the one-time visual warning.
        case warn
        /// End the recording — see `termination(for:)` for what that means.
        case stop
    }

    /// What a `.stop` *does* to the recording in flight.
    ///
    /// A named type with two cases rather than an implication, because this is
    /// the one thing in P2-10 that can do real harm. The obvious implementation
    /// — reach for the code path that already ends a recording — is
    /// `AppModel.cancel()`, which calls `audioRecorder.cancel()`, which deletes
    /// the file. `.discard` exists here precisely so that choosing
    /// `.finishAndDeliver` is a choice on the record, and so a future edit
    /// toward the wrong path has to say so out loud.
    enum Termination: Equatable {
        /// `AppModel.finishRecording()`: stop the recorder, keep the file,
        /// transcribe it, deliver the result through the ordinary pipeline —
        /// the same path letting go of the hotkey takes. Nothing about the
        /// result is second-class for having been ended by the clock.
        case finishAndDeliver
        /// Stop and throw the audio away. Nothing this policy can produce ever
        /// selects it; it is here to be the thing that is *not* chosen.
        case discard
    }

    /// The transition, as a function of elapsed time plus the one bit of
    /// history that makes the warning fire once.
    ///
    /// - Parameters:
    ///   - elapsed: Seconds since the recording started. Negative values (clock
    ///     skew, sleep/wake) read as the very beginning, never as past a limit.
    ///   - alreadyWarned: Whether this recording has already shown the warning.
    ///     "Fires once" cannot be a property of elapsed time alone — at 121s,
    ///     122s, 123s the elapsed time keeps satisfying "past two minutes" — so
    ///     the caller owns that bit and clears it when a recording starts.
    ///   - hotKeyHeld: Present and required to make no difference. The spec's
    ///     wording (「hands-free 连续录音」) invites the reading that a
    ///     held-modifier recording is exempt because someone is obviously still
    ///     there with a finger on the key; but a stuck or repeating modifier is
    ///     exactly the case the cap exists for, and from inside the app it is
    ///     indistinguishable from a held key. Exempting held recordings would
    ///     switch the net off in the one situation where the user cannot switch
    ///     it off themselves. The parameter is not omitted so that a later
    ///     `guard !hotKeyHeld` is a visible, testable change rather than an
    ///     invisible one at whichever call site does or does not consult this.
    ///
    /// Thresholds are **inclusive** (`elapsed >= threshold`), matching
    /// `CorrectionWindow.isExpired(at:)`'s plain `now >= deadline`: in both
    /// cases the question is "has this instant been reached", and answering it
    /// with `>` makes a limit that never fires when a tick lands exactly on the
    /// boundary.
    static func action(
        elapsed: TimeInterval,
        alreadyWarned: Bool,
        hotKeyHeld: Bool
    ) -> Action {
        // Checked before the warning, so a first tick that arrives well past
        // the cap (the app was asleep, throttled, or simply behind) stops
        // rather than warning at a point where the alert is no longer useful
        // and the cap silently would not exist. Idempotent past the cap: there
        // is no window a stop can fall through.
        if elapsed >= maximumSeconds { return .stop }
        if elapsed >= warningSeconds, !alreadyWarned { return .warn }
        return .keepRecording
    }

    /// How an action ends the recording, or `nil` if it does not end it at all.
    static func termination(for action: Action) -> Termination? {
        switch action {
        case .keepRecording, .warn:
            return nil
        case .stop:
            return .finishAndDeliver
        }
    }
}
