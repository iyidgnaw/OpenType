import AppKit
import SwiftUI

@MainActor
private final class OverlayPresentation: ObservableObject {
    @Published var state: ProcessingState = .idle
    @Published var mode: InputMode = InputMode.visibleModes[0]
    @Published var liveTranscript = ""
    @Published var audioLevel = 0.0
    /// The unified ask/agent surface. `.hidden` hands the panel back to the
    /// legacy transcribe HUD / toast content below.
    @Published var surface: VoiceSurfaceState = .hidden
    /// Non-nil while the toast on screen *is* the correction-window affordance
    /// (P0-3) rather than a plain success toast.
    @Published var correctionHint: CorrectionHint?
    /// Non-nil while the pre-dispatch confirmation window is open (P1-6). It
    /// preempts everything below — surface included — because for its 1.5
    /// seconds it is the only thing on this panel worth reading.
    @Published var pendingDispatch: PendingDispatch?
    /// The `m:ss` readout on the listening pill (P2-10), non-nil for exactly as
    /// long as a recording is being timed. `AppModel`'s recording tick is the
    /// only writer — the controller never reads a clock of its own.
    @Published var elapsedText: String?
    /// The two-minute warning's sentence, shown for a few seconds in place of
    /// the caption. Separate from the flag below because the sentence is
    /// transient and the fact that it fired is not.
    @Published var recordingWarning: String?
    /// Sticks for the rest of the recording once the warning has fired, so the
    /// elapsed readout stays tinted after the sentence has gone: the user is
    /// still in the stretch that ends by itself.
    @Published var pastWarningThreshold = false

    /// The visible half of an armed correction window.
    struct CorrectionHint: Equatable {
        let text: String
        let seconds: TimeInterval
        /// Identity for the progress bar: a re-armed window is a *new* bar
        /// that starts full again, not the old one continuing.
        let startedAt: Date
    }

    /// The visible half of a pre-dispatch confirmation (P1-6): the transcript
    /// about to be handed to `/agent/run`, and how long is left to take it
    /// back.
    struct PendingDispatch: Equatable {
        let transcript: String
        let seconds: TimeInterval
        /// Identity for the countdown bar, same as `CorrectionHint.startedAt`.
        let startedAt: Date
    }
}

/// How `OverlayController.show(...)` should treat the HUD panel for a given
/// `ProcessingState`, factored out of the inline `switch` so the per-state
/// timing decision is pure and unit-testable (see `OverlayHideBehaviorTests`).
enum OverlayHideBehavior: Equatable {
    /// Hide the panel right away (e.g. `.idle` — there is nothing to show).
    case hideImmediately
    /// Leave it up for `after` seconds, then hide (transient toast states).
    case scheduleHide(after: TimeInterval)
    /// Leave it up for `after` seconds carrying the correction-window
    /// affordance (`CorrectionWindow.hintText` plus a bar that empties as the
    /// window does) instead of the bare success copy — P0-3. Distinct from
    /// `.scheduleHide` because what changes is *what the toast says*, not only
    /// how long it stays: a longer-lived 「完成」 would teach nobody that the
    /// hotkey has temporarily changed meaning.
    case scheduleHideWithCorrectionHint(after: TimeInterval)
    /// Keep it on screen with no scheduled hide (active in-flight states).
    case keepVisible
}

extension OverlayHideBehavior {
    /// How long the panel stays up, for the two cases that schedule a hide.
    ///
    /// Exists so that consumers which only care about the *timing* ask once
    /// here rather than pattern-matching a single case and silently ignoring
    /// the other — the trap the spec calls out for `presentToast`, where an
    /// unhandled case does not fail to compile, it just stops restoring the
    /// preempted voice surface forever.
    var scheduledHideDelay: TimeInterval? {
        switch self {
        case .scheduleHide(let seconds),
             .scheduleHideWithCorrectionHint(let seconds):
            return seconds
        case .hideImmediately, .keepVisible:
            return nil
        }
    }
}

/// The app's single floating bottom-center panel. It plays two roles:
///
/// 1. The legacy transient HUD — transcribe mode's live-caption pill and every
///    mode's toast states (`show(state:mode:)`), unchanged.
/// 2. The **unified voice surface** (`apply(_:state:mode:)`): the whole
///    ask/agent lifecycle, from the same pill through breathing-dots
///    "processing"/"working" to a result card the panel *morphs into* by
///    animating its frame upward from a fixed bottom edge (spec:
///    `docs/superpowers/specs/2026-08-13-hud-morph-result-surface-design.md` §1).
///    This replaced both the center-screen Ask popup (`AskPanelController`) and
///    the top-right Agent progress panel (`AgentProgressPanelController`);
///    neither exists anymore.
///
/// `AppModel` owns all the state: it reduces its own
/// `(mode, ProcessingState, askPanelState, agentPanelState)` into a
/// `VoiceSurfaceState` and pushes it here. The controller decides nothing
/// except geometry and animation, and reports user intent back through
/// `onRequestDismiss` / `onCopyResult` / `onOpenMainWindow` rather than
/// mutating anything itself (same non-self-closing contract the old panels
/// had, which is what keeps show/hide from feedback-looping).
@MainActor
final class OverlayController {
    private let compactSize = NSSize(width: 300, height: 60)
    private let listeningSize = NSSize(width: 388, height: 96)
    /// Room for the hint's second line plus the window's progress bar.
    private let correctionHintSize = NSSize(width: 392, height: 84)
    /// Same footprint, with room for a two-line transcript (P1-6).
    private let pendingDispatchSize = NSSize(width: 392, height: 96)
    private let presentation = OverlayPresentation()
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    /// The surface state currently on screen (or, while a transient toast has
    /// preempted it, the one that comes back when the toast is done). While
    /// this is non-`.hidden` the surface owns the panel.
    private var surfaceState: VoiceSurfaceState = .hidden
    /// The last `(state, mode)` pushed *with* a surface, so a toast that
    /// preempted the surface can restore it with the right content. Only
    /// `apply(...)`/`applyWithToast(...)` update these: a bare `show(...)`
    /// toast carries a mode of its own (the newly selected one) that must not
    /// stick to the surface underneath it.
    private var lastState: ProcessingState = .idle
    private var lastMode: InputMode = InputMode.visibleModes[0]
    /// Non-nil while a transient toast has preempted the unified surface: the
    /// work item that puts the surface back when the toast's time is up. See
    /// `presentToast(state:mode:)`.
    private var toastOverride: DispatchWorkItem?
    /// What the legacy path last put on the panel, and only for as long as it
    /// is actually up. A live agent run re-applies the surface on every ~0.7s
    /// poll tick, so an unchanged `.hidden` push is common — replaying the
    /// legacy path for it would restart the visible toast's dismiss timer.
    /// Cleared the moment that content leaves the panel, so a genuinely new
    /// toast still shows even when it is identical to one that already came
    /// and went.
    private var legacyOnScreen: (state: ProcessingState, mode: InputMode)?
    private var clickOutsideMonitor: Any?
    /// The Esc watchers installed for the length of a pre-dispatch
    /// confirmation (P1-6), and only for that length.
    private var pendingDispatchKeyMonitors: [Any] = []
    /// Takes the two-minute warning's sentence back off the pill (P2-10).
    private var recordingWarningWorkItem: DispatchWorkItem?
    /// How long that sentence stays up.
    private let recordingWarningSeconds: TimeInterval = 4.5

    /// Whether a post-delivery correction window is open right now (P0-3).
    /// `AppModel` sets it *before* pushing the delivery state, since it is
    /// what turns that push's success toast into the window's affordance.
    /// A plain flag rather than the `CorrectionWindow.State` itself: the
    /// controller decides presentation, never policy.
    var correctionWindowArmed = false

    /// Escape, the 关闭 button, or a click outside a finished card.
    var onRequestDismiss: (() -> Void)?
    /// The 复制 button, with the card's Markdown body.
    var onCopyResult: ((String) -> Void)?
    /// The 打开主窗口 button.
    var onOpenMainWindow: (() -> Void)?
    /// The 停止 control shown while a stoppable agent run is on screen (T1).
    var onStopAgentRun: (() -> Void)?
    /// The user's answer to an agent question (T5): run id plus the answer.
    var onAnswerAgentQuestion: ((String, AgentQuestionAnswerItem) -> Void)?
    /// Esc while the pre-dispatch confirmation is on screen (P1-6). Reported
    /// rather than acted on, same non-self-closing contract as everything
    /// above: `AppModel` owns the window and decides what a keypress at this
    /// instant means (`DispatchConfirmation.decision`).
    var onCancelPendingDispatch: (() -> Void)?

    private lazy var hostingView = NSHostingView(
        rootView: OverlayView(
            presentation: presentation,
            onClose: { [weak self] in self?.onRequestDismiss?() },
            onCopy: { [weak self] text in self?.onCopyResult?(text) },
            onOpenMainWindow: { [weak self] in self?.onOpenMainWindow?() },
            onStop: { [weak self] in self?.onStopAgentRun?() },
            onAnswer: { [weak self] runId, answer in
                self?.onAnswerAgentQuestion?(runId, answer)
            }
        )
    )

    /// Legacy transient HUD for a state that does not itself change the
    /// surface — today only the mode-changed toast. One window, two owners:
    /// rather than being swallowed while the surface owns the panel, the
    /// toast *preempts* it for its usual duration and the surface comes back
    /// afterwards (`presentToast`).
    func show(state: ProcessingState, mode: InputMode) {
        presentToast(state: state, mode: mode)
    }

    /// Unified voice-surface entry point: the single call `AppModel` makes
    /// after anything that could change what the surface should look like.
    /// A `.hidden` surface falls through to the legacy HUD for `state`, so
    /// transcribe keeps behaving exactly as before.
    func apply(
        _ surface: VoiceSurfaceState,
        state: ProcessingState,
        mode: InputMode
    ) {
        let previous = surfaceState
        surfaceState = surface
        lastState = state
        lastMode = mode

        // A new recording is a fresh, user-initiated action: it always wins
        // over a toast still sitting on the panel.
        if state == .listening { cancelToastOverride() }

        // A transient toast owns the panel right now and restores the surface
        // — as it stands *then* — itself, so this push is bookkeeping only.
        guard toastOverride == nil else { return }

        // The legacy path is already showing exactly this: replaying it would
        // restart the toast's dismiss timer on every poll tick.
        if surface == .hidden,
           previous == .hidden,
           let legacyOnScreen,
           legacyOnScreen.state == state,
           legacyOnScreen.mode == mode {
            return
        }

        presentation.mode = mode
        presentation.state = state

        guard surface != .hidden else {
            presentation.surface = .hidden
            presentLegacy(state: state, mode: mode)
            return
        }

        dismissWorkItem?.cancel()
        if surface != .listening {
            presentation.liveTranscript = ""
            presentation.audioLevel = 0
        }
        presentation.surface = surface
        presentSurface(surface, grewFrom: previous)
    }

    /// `AppModel.fail(_:)`'s entry point: push the freshly-reduced `surface`
    /// **and** show `state`'s failure toast *over* it. A pipeline failure that
    /// lands while a previous run still owns the panel (a result card the user
    /// hasn't dismissed, an agent still ticking) must neither be swallowed by
    /// that surface — the user would get no feedback at all that their
    /// recording failed — nor tear it down, since the run it belongs to is
    /// still going. So the toast preempts the surface for its usual duration
    /// and the surface comes back when it expires.
    func applyWithToast(
        _ surface: VoiceSurfaceState,
        state: ProcessingState,
        mode: InputMode
    ) {
        surfaceState = surface
        lastState = state
        lastMode = mode
        presentToast(state: state, mode: mode)
    }

    /// Pure per-state timing decision behind `show(...)`. `.idle` hides
    /// immediately (P1-18: the "ready" HUD must not stick), active in-flight
    /// states stay visible, and the transient toast states keep the exact
    /// durations `show(...)` historically used.
    static func hideBehavior(for state: ProcessingState) -> OverlayHideBehavior {
        switch state {
        case .idle:
            return .hideImmediately
        case .listening, .transcribing, .transforming, .inserting:
            return .keepVisible
        case .modeChanged:
            return .scheduleHide(after: 1.2)
        case .success, .copied:
            return .scheduleHide(after: 0.9)
        case .dispatched:
            // Informational, not an error, but carries a second line of copy
            // ("已下发给 Agent") the user has to actually read, so it needs
            // longer on screen than a bare success toast.
            return .scheduleHide(after: 1.6)
        case .cancelled:
            return .scheduleHide(after: 1.8)
        case .failure:
            return .scheduleHide(after: 2.4)
        }
    }

    /// The same decision, told whether a correction window is open (P0-3).
    ///
    /// Only the two delivery-success toasts change: they *are* the affordance,
    /// so they stay up for exactly the window's length — 0.9s is not enough
    /// time to read a hint, let alone select a word and press a key — and the
    /// duration comes from `CorrectionWindow.windowSeconds` itself so the bar
    /// cannot promise more time than the hotkey actually honors. Errors,
    /// cancellations, mode switches and every in-flight state are not the
    /// affordance and keep the timings above unchanged.
    ///
    /// `OutputDeliveryPolicy` can downgrade an insert to clipboard-only at the
    /// last moment, so `.copied` gets the same treatment as `.success`: which
    /// of the two toasts was chosen says nothing about whether the delivered
    /// text is worth fixing.
    static func hideBehavior(
        for state: ProcessingState,
        correctionWindowArmed: Bool
    ) -> OverlayHideBehavior {
        guard correctionWindowArmed else { return hideBehavior(for: state) }
        switch state {
        case .success, .copied:
            return .scheduleHideWithCorrectionHint(
                after: CorrectionWindow.windowSeconds
            )
        case .idle, .modeChanged, .listening, .transcribing, .transforming,
             .inserting, .dispatched, .cancelled, .failure:
            return hideBehavior(for: state)
        }
    }

    func updateLiveTranscript(_ text: String) {
        guard presentation.state == .listening else { return }
        presentation.liveTranscript = text
    }

    /// The elapsed-time readout, pushed by `AppModel`'s recording tick (P2-10).
    /// Formatting is the tick's job (`RecordingClock.elapsedText(seconds:)`) —
    /// what arrives here is already the string to draw.
    func updateRecordingElapsed(_ text: String) {
        guard presentation.state == .listening else { return }
        presentation.elapsedText = text
    }

    /// The one-time two-minute warning (P2-10). The sentence takes the pill's
    /// caption line for a few seconds — long enough to read, short enough that
    /// someone mid-thought gets their live transcript back — while the tint on
    /// the elapsed readout stays for the rest of the recording.
    func showRecordingWarning(_ text: String) {
        guard presentation.state == .listening else { return }
        presentation.pastWarningThreshold = true
        presentation.recordingWarning = text

        recordingWarningWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.recordingWarningWorkItem = nil
            self?.presentation.recordingWarning = nil
        }
        recordingWarningWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + recordingWarningSeconds,
            execute: item
        )
    }

    /// Called when the recording ends, however it ends.
    func clearRecordingElapsed() {
        recordingWarningWorkItem?.cancel()
        recordingWarningWorkItem = nil
        presentation.elapsedText = nil
        presentation.recordingWarning = nil
        presentation.pastWarningThreshold = false
    }

    func updateAudioLevel(_ level: Double) {
        guard presentation.state == .listening else { return }
        presentation.audioLevel = level
    }

    func hide() {
        dismissWorkItem?.cancel()
        cancelToastOverride()
        removeClickOutsideMonitor()
        removePendingDispatchMonitors()
        clearRecordingElapsed()
        legacyOnScreen = nil
        surfaceState = .hidden
        presentation.surface = .hidden
        presentation.correctionHint = nil
        presentation.pendingDispatch = nil
        panel?.orderOut(nil)
    }

    // MARK: - Pre-dispatch confirmation (P1-6)

    /// Shows `transcript` for `seconds` with the Esc affordance, and starts
    /// watching for that key.
    ///
    /// It preempts whatever the panel was showing (during this window the
    /// surface would read 「正在整理…」, which catches nothing) without
    /// disturbing `surfaceState`, so the next push from `AppModel` — the
    /// dispatched run's working pill, or the cancelled toast — lays the panel
    /// out again on its own.
    func showPendingDispatch(transcript: String, seconds: TimeInterval) {
        dismissWorkItem?.cancel()
        cancelToastOverride()
        presentation.pendingDispatch = OverlayPresentation.PendingDispatch(
            transcript: transcript,
            seconds: seconds,
            startedAt: Date()
        )

        let panel = panel ?? makePanel()
        hostingView.frame = NSRect(origin: .zero, size: pendingDispatchSize)
        panel.setContentSize(pendingDispatchSize)
        position(panel)
        // Never `makeKey`: the user may still be typing into the app they
        // dictated from, and 1.5 seconds is not worth stealing focus for. The
        // global monitor below is what hears Esc from over there.
        panel.orderFrontRegardless()
        self.panel = panel

        installPendingDispatchMonitors()
    }

    /// Takes the window down, however it ended. Layout is left to `AppModel`'s
    /// next push, which follows immediately in the same main-actor turn.
    func hidePendingDispatch() {
        removePendingDispatchMonitors()
        guard presentation.pendingDispatch != nil else { return }
        presentation.pendingDispatch = nil
        legacyOnScreen = nil
    }

    /// Esc's key code. Named here rather than importing Carbon for one number.
    private static let escapeKeyCode: UInt16 = 53

    private func installPendingDispatchMonitors() {
        removePendingDispatchMonitors()
        // Two monitors, because the keypress can land in either place: local
        // if our own window happens to be frontmost, global if the user is
        // still in the app they were dictating into — which is the normal case,
        // since the pill never takes key focus.
        //
        // Two things a global monitor cannot do, both acceptable here. It
        // cannot *consume* the event (only an event tap can), so Esc also
        // reaches the app in front — in practice a no-op or a dismissed popup,
        // and not worth an event tap of our own for 1.5 seconds. And it needs
        // Accessibility trust, which this app already requires for its hotkey
        // and write-back; without it, Esc still works whenever OpenType is
        // frontmost via the local monitor.
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == Self.escapeKeyCode else { return event }
            self.onCancelPendingDispatch?()
            return nil
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == Self.escapeKeyCode else { return }
            self.onCancelPendingDispatch?()
        }
        pendingDispatchKeyMonitors = [local, global].compactMap { $0 }
    }

    private func removePendingDispatchMonitors() {
        for monitor in pendingDispatchKeyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        pendingDispatchKeyMonitors = []
    }

    // MARK: - Legacy transient HUD

    private func presentLegacy(state: ProcessingState, mode: InputMode) {
        dismissWorkItem?.cancel()
        removeClickOutsideMonitor()

        let behavior = Self.hideBehavior(
            for: state,
            correctionWindowArmed: correctionWindowArmed
        )

        presentation.state = state
        presentation.mode = mode
        presentation.surface = .hidden
        if state != .listening {
            presentation.liveTranscript = ""
            presentation.audioLevel = 0
        }
        // The affordance and the timing are the same decision, so they are
        // read off the same answer rather than tested for separately.
        if case .scheduleHideWithCorrectionHint(let seconds) = behavior {
            presentation.correctionHint = OverlayPresentation.CorrectionHint(
                text: CorrectionWindow.hintText,
                seconds: seconds,
                startedAt: Date()
            )
        } else {
            presentation.correctionHint = nil
        }

        let size: NSSize
        if state == .listening {
            size = listeningSize
        } else if presentation.correctionHint != nil {
            size = correctionHintSize
        } else {
            size = compactSize
        }
        let panel = panel ?? makePanel()
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        switch behavior {
        case .hideImmediately:
            hide()
        case .scheduleHide(let seconds),
             .scheduleHideWithCorrectionHint(let seconds):
            legacyOnScreen = (state, mode)
            dismiss(after: seconds)
        case .keepVisible:
            legacyOnScreen = (state, mode)
        }
    }

    /// Shows a transient legacy toast, preempting the unified surface when it
    /// owns the panel instead of being swallowed by it. The surface is put
    /// back — as it stands *then*, not as it stood now — when the toast's
    /// `hideBehavior` duration is up, so a long agent run's ticker survives a
    /// failure toast and picks up whatever steps arrived meanwhile.
    ///
    /// Nothing to preempt (`surfaceState == .hidden`) means this is exactly
    /// the legacy path, and a state that isn't a scheduled-hide toast (only
    /// `.idle` today, which hides immediately) schedules no restore.
    ///
    /// The restore delay is taken from `scheduledHideDelay` rather than by
    /// matching one case: this `guard` is not exhaustiveness-checked, so a
    /// `case .scheduleHide` that silently failed to match a newer toast case
    /// would return early and leave the preempted surface off screen forever.
    private func presentToast(state: ProcessingState, mode: InputMode) {
        cancelToastOverride()
        let preempted = surfaceState

        presentLegacy(state: state, mode: mode)

        guard preempted != .hidden,
              let seconds = Self.hideBehavior(
                for: state,
                correctionWindowArmed: correctionWindowArmed
              ).scheduledHideDelay
        else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.toastOverride = nil
            self.restoreSurfaceAfterToast()
        }
        toastOverride = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func restoreSurfaceAfterToast() {
        guard surfaceState != .hidden else {
            hide()
            return
        }
        presentation.state = lastState
        presentation.mode = lastMode
        presentation.surface = surfaceState
        // The surface owns the panel again; the toast's hint went with it.
        presentation.correctionHint = nil
        // `grewFrom: .hidden` suppresses the frame animation: coming back from
        // a toast is not the pill-morphs-into-the-card moment, so it snaps.
        presentSurface(surfaceState, grewFrom: .hidden)
    }

    private func cancelToastOverride() {
        toastOverride?.cancel()
        toastOverride = nil
    }

    // MARK: - Unified voice surface

    private func presentSurface(
        _ surface: VoiceSurfaceState,
        grewFrom previous: VoiceSurfaceState
    ) {
        let panel = panel ?? makePanel()
        self.panel = panel
        // The surface owns the panel from here on; no legacy toast is up.
        legacyOnScreen = nil
        presentation.correctionHint = nil

        let size = VoiceSurfacePanelLayout.size(for: surface)
        let frame = VoiceSurfacePanelLayout.frame(
            for: size,
            visibleFrame: visibleFrame() ?? panel.frame
        )
        hostingView.frame = NSRect(origin: .zero, size: size)

        // Animate only a real size change on an already-visible panel: that is
        // the pill-morphs-into-the-card moment. A first appearance just snaps
        // in at the right size.
        let shouldAnimate = panel.isVisible
            && previous != .hidden
            && !NSEqualSizes(panel.frame.size, NSSize(width: size.width, height: size.height))
        panel.setFrame(frame, display: true, animate: shouldAnimate)

        if surface.allowsClickOutsideDismiss {
            // A finished card is interactive (buttons, selectable Markdown,
            // Escape), so it takes key status — but only on the way in, never
            // on a re-render, so it can't keep yanking focus back.
            if !panel.isVisible || previous.allowsClickOutsideDismiss == false {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
            installClickOutsideMonitor()
        } else {
            // Listening/processing/working must never steal key focus from
            // whatever the user is typing into.
            removeClickOutsideMonitor()
            panel.orderFrontRegardless()
        }
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self,
                  let panel = self.panel,
                  panel.isVisible,
                  self.surfaceState.allowsClickOutsideDismiss
            else { return }
            let clickLocation = NSEvent.mouseLocation
            guard !panel.frame.contains(clickLocation) else { return }
            self.onRequestDismiss?()
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
        }
        clickOutsideMonitor = nil
    }

    // MARK: - Panel plumbing

    private func makePanel() -> NSPanel {
        let panel = KeyableOverlayPanel(
            contentRect: NSRect(origin: .zero, size: compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView
        return panel
    }

    /// The screen the panel is laid out on: whichever display the pointer is on,
    /// falling back to `NSScreen.main` (P2-10 — see `ScreenPlacement`). Called
    /// on every `presentSurface`/`position`, never cached, so an already-open
    /// panel follows the user to another display.
    private func visibleFrame() -> CGRect? {
        ScreenPlacement.currentVisibleFrame()
    }

    private func position(_ panel: NSPanel) {
        guard let frame = visibleFrame() else { return }
        panel.setFrameOrigin(
            VoiceSurfacePanelLayout.frame(
                for: panel.frame.size,
                visibleFrame: frame
            ).origin
        )
    }

    private func dismiss(after seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.legacyOnScreen = nil
            self?.panel?.orderOut(nil)
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}

/// A `.nonactivatingPanel` normally can't become key, which would swallow the
/// Escape keypress meant for the result card's `onExitCommand`. Overriding
/// `canBecomeKey` lets the panel receive keyboard input while
/// `.nonactivatingPanel` still keeps it from stealing app activation away from
/// whatever the user was typing into. Key status is only ever *taken* for the
/// result/failed card (see `presentSurface`), never for the pill.
private final class KeyableOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct OverlayView: View {
    @ObservedObject var presentation: OverlayPresentation
    let onClose: () -> Void
    let onCopy: (String) -> Void
    let onOpenMainWindow: () -> Void
    let onStop: () -> Void
    let onAnswer: (String, AgentQuestionAnswerItem) -> Void

    var body: some View {
        Group {
            // The pre-dispatch confirmation (P1-6) preempts everything: for
            // its 1.5 seconds the only thing worth showing is what was heard.
            if let pending = presentation.pendingDispatch {
                pendingDispatchContent(pending)
            } else {
                surfaceContent
            }
        }
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.6)
        )
        .tint(AppAccent.primary)
        .environment(\.locale, OpenTypeL10n.locale)
        // The content crossfade half of the morph: the panel's frame animates
        // (`setFrame(_:display:animate:)`), the contents fade between states.
        .animation(.easeInOut(duration: 0.2), value: presentation.surface)
    }

    @ViewBuilder
    private var surfaceContent: some View {
        Group {
            switch presentation.surface {
            case .hidden:
                if presentation.state == .listening {
                    listeningContent
                } else if let hint = presentation.correctionHint {
                    correctionHintContent(hint)
                } else {
                    compactContent
                }
            case .listening:
                listeningContent
            case .processing:
                WorkingPill(
                    headline: OpenTypeL10n.text("正在整理…", english: "Transcribing…"),
                    modeTitle: presentation.mode.title,
                    ticker: nil
                )
            case .working(let detail):
                WorkingPill(
                    headline: detail.kind == .agent
                        ? OpenTypeL10n.text("Agent 正在执行…", english: "Agent is working…")
                        : OpenTypeL10n.text("正在思考…", english: "Thinking…"),
                    // The badge names the run this pill belongs to, not the
                    // currently-selected mode: a dispatched run outlives the
                    // recording (and the user is free to switch modes while it
                    // is still working), so `presentation.mode` would be able
                    // to label an Agent run "听写".
                    modeTitle: (detail.kind == .agent ? InputMode.agent : .ask).title,
                    ticker: detail.currentStep,
                    onStop: presentation.surface.stoppableAgentRun ? onStop : nil
                )
            case .asking(let detail):
                AgentQuestionCard(
                    detail: detail,
                    onAnswer: { answer in onAnswer(detail.runId, answer) },
                    onStop: onStop
                )
            case .result(let card):
                VoiceSurfaceCard(
                    card: card,
                    failed: false,
                    onClose: onClose,
                    onCopy: onCopy,
                    onOpenMainWindow: onOpenMainWindow
                )
            case .failed(let card):
                VoiceSurfaceCard(
                    card: card,
                    failed: true,
                    onClose: onClose,
                    onCopy: onCopy,
                    onOpenMainWindow: onOpenMainWindow
                )
            }
        }
    }

    /// The pre-dispatch confirmation (P1-6): what was heard, verbatim, with a
    /// bar that empties exactly as the window does and the key that stops it.
    ///
    /// The transcript is the headline rather than a subtitle, because reading
    /// it back is the entire function of this window — a card that led with
    /// 「正在下发…」 would occupy the same 1.5 seconds and catch nothing. The
    /// bar is what lets the user tell at a glance how much of the offer is
    /// left instead of counting.
    private func pendingDispatchContent(
        _ pending: OverlayPresentation.PendingDispatch
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                Image(systemName: "paperplane")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.transcript)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        OpenTypeL10n.text(
                            "即将下发给 Agent · \(DispatchConfirmation.hintText)",
                            english: "Dispatching to Agent · \(DispatchConfirmation.hintText)"
                        )
                    )
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            WindowCountdownBar(seconds: pending.seconds)
                .id(pending.startedAt)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 392, height: 96, alignment: .leading)
    }

    private var listeningContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                ListeningPulse(level: presentation.audioLevel)

                Text("正在听")
                    .font(.system(size: 12.5, weight: .semibold))

                Text(modeBadgeTitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.055), in: Capsule())

                // How long this recording has been running (P2-10). Monospaced
                // digits so the pill's contents don't shuffle sideways once a
                // second; tinted for the rest of the recording once the
                // two-minute warning has fired.
                if let elapsed = presentation.elapsedText {
                    Text(elapsed)
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(
                            presentation.pastWarningThreshold
                                ? Color.orange
                                : Color.secondary
                        )
                }

                Spacer(minLength: 4)

                LiveWaveform(level: presentation.audioLevel)
            }

            Text(captionText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(captionColor)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                .contentTransition(.opacity)
                .animation(
                    .easeOut(duration: 0.16),
                    value: presentation.liveTranscript
                )
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(width: 388, height: 96)
    }

    private var compactContent: some View {
        HStack(spacing: 11) {
            Image(systemName: presentation.state.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(symbolColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.state.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(presentation.state.overlayDetail(for: presentation.mode))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: 300, height: 60)
    }

    /// The delivery toast while a correction window is open (P0-3): the same
    /// 完成/已复制 headline, but with the hint that names the gesture and a bar
    /// that empties exactly as the window does. The bar is the honest part —
    /// it is why the user can tell at a glance how much of the offer is left,
    /// rather than having to count seconds.
    private func correctionHintContent(
        _ hint: OverlayPresentation.CorrectionHint
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                Image(systemName: presentation.state.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(symbolColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.state.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(hint.text)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            WindowCountdownBar(seconds: hint.seconds)
                // A re-armed window is a new bar starting full again, not the
                // old one continuing — new identity, fresh `onAppear`.
                .id(hint.startedAt)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 392, height: 84, alignment: .leading)
    }

    /// The pill's second line: the two-minute warning while it is up, then the
    /// live transcript, then the mode's own invitation to speak.
    ///
    /// The warning deliberately preempts the live caption rather than being
    /// squeezed in beside it — the pill is two lines tall by design, and a
    /// warning the user has to notice while reading their own words back is a
    /// warning half of them will miss. It hands the line back after a few
    /// seconds (`OverlayController.recordingWarningSeconds`).
    private var captionText: String {
        if let warning = presentation.recordingWarning {
            return warning
        }
        if !presentation.liveTranscript.isEmpty {
            return presentation.liveTranscript
        }
        switch presentation.mode {
        case .transcribe:
            return OpenTypeL10n.text(
                "直接说话，松开后原样转成文字…",
                english: "Just speak — released speech becomes text as-is…"
            )
        case .ask:
            return OpenTypeL10n.text(
                "说出你的问题，松开后直接获得答案…",
                english: "Ask your question — get a direct answer here…"
            )
        case .agent:
            return OpenTypeL10n.text(
                "说出希望 Agent Runtime 完成的任务…",
                english: "Describe the task for the Agent Runtime…"
            )
        }
    }

    private var captionColor: Color {
        if presentation.recordingWarning != nil { return .orange }
        return presentation.liveTranscript.isEmpty ? .secondary : .primary
    }

    private var modeBadgeTitle: String {
        presentation.mode.title
    }

    private var symbolColor: Color {
        switch presentation.state {
        case .failure: return .red
        case .cancelled: return .secondary
        case .success, .copied: return .accentColor
        default: return .accentColor
        }
    }
}

/// A timed window running out, drawn rather than counted: a bar that starts
/// full and reaches zero at the same instant the window closes. Shared by the
/// two windows that have one — the post-delivery correction offer (P0-3) and
/// the pre-dispatch confirmation (P1-6) — so neither can promise more time
/// than its own deadline. Driven by one linear animation over the window's own
/// duration rather than a ticking timer, so it costs nothing while it runs and
/// cannot drift away from what it is drawing.
private struct WindowCountdownBar: View {
    let seconds: TimeInterval

    @State private var remaining: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: max(0, proxy.size.width * remaining))
            }
        }
        .frame(height: 3)
        .onAppear {
            withAnimation(.linear(duration: seconds)) { remaining = 0 }
        }
    }
}

/// The `processing`/`working` pill: the same footprint as the listening pill,
/// with three breathing dots where the waveform was, plus (agent only) a
/// one-line live step ticker.
private struct WorkingPill: View {
    let headline: String
    let modeTitle: String
    let ticker: String?
    /// Non-nil only while the surface is showing a stoppable agent run
    /// (`VoiceSurfaceState.stoppableAgentRun`). Separate from the card's
    /// 关闭: closing the panel and stopping the run are different intentions,
    /// and dismissal deliberately never cancels an agent run.
    var onStop: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                BouncingDots()

                Text(headline)
                    .font(.system(size: 12.5, weight: .semibold))

                Text(modeTitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.055), in: Capsule())

                Spacer(minLength: 4)

                if let onStop {
                    // Plain rather than bordered: a bordered control is ~24pt
                    // tall and forced this whole row taller than the text it
                    // sits beside, which is what made the working pill look
                    // padded and crowded at once. The HUD's register is text,
                    // not chrome.
                    Button(OpenTypeL10n.text("停止", english: "Stop"), action: onStop)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text(ticker ?? OpenTypeL10n.text("请稍候…", english: "One moment…"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.16), value: ticker)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(width: 388, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// The agent asking the user something mid-run (T5). Deliberately plain: a
/// question list with buttons, plus a free-text field for "something else".
/// The answer encoding is the same whichever control the user touches, so a
/// richer presentation later changes nothing the agent receives.
private struct AgentQuestionCard: View {
    let detail: VoiceSurfaceState.AskingDetail
    let onAnswer: (AgentQuestionAnswerItem) -> Void
    let onStop: () -> Void

    @State private var custom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(OpenTypeL10n.text("Agent 有个问题", english: "The agent has a question"))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 4)
                Button(OpenTypeL10n.text("停止", english: "Stop"), action: onStop)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Text(detail.question.question)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            if let text = detail.question.detail, !text.isEmpty {
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let options = detail.question.options, !options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options, id: \.label) { option in
                        Button {
                            onAnswer(
                                AgentQuestionAnswerItem(
                                    id: detail.question.id,
                                    selected: [option.label],
                                    custom: nil
                                )
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label)
                                    .font(.system(size: 11.5, weight: .medium))
                                if let description = option.description, !description.isEmpty {
                                    Text(description)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField(
                    OpenTypeL10n.text("其他…", english: "Something else…"),
                    text: $custom
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit(submitCustom)

                Button(OpenTypeL10n.text("发送", english: "Send"), action: submitCustom)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 480, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func submitCustom() {
        let text = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAnswer(
            AgentQuestionAnswerItem(id: detail.question.id, selected: [], custom: text)
        )
    }
}

/// Three dots breathing in sequence — the "received, still working" signal
/// that replaces the waveform once the user stops speaking.
private struct BouncingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .scaleEffect(animating ? 1.0 : 0.55)
                    .opacity(animating ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.52)
                            .repeatForever()
                            .delay(Double(index) * 0.16),
                        value: animating
                    )
            }
        }
        .frame(width: 20, height: 20)
        .onAppear { animating = true }
    }
}

/// The result/failed card the pill morphs into: mode badge, the spoken
/// query/task as plain user text, the Markdown-rendered answer, a collapsible
/// agent step list, and the 复制 / 打开主窗口 / 关闭 actions.
private struct VoiceSurfaceCard: View {
    let card: VoiceSurfaceState.ResultCard
    let failed: Bool
    let onClose: () -> Void
    let onCopy: (String) -> Void
    let onOpenMainWindow: () -> Void

    @State private var stepsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header

            Text(card.query)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ScrollView {
                AssistantMarkdownView(markdown: card.body, fontSize: 13)
                    .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.visible)

            if card.kind == .agent, !card.steps.isEmpty {
                stepList
            }

            footer
        }
        .padding(16)
        .frame(width: 620, height: 480, alignment: .topLeading)
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: card.kind == .agent ? "wand.and.stars" : "questionmark.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(card.kind == .agent
                ? OpenTypeL10n.text("Agent", english: "Agent")
                : OpenTypeL10n.text("问答", english: "Ask"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.055), in: Capsule())

            HStack(spacing: 5) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(failed ? Color.red : Color.accentColor)
                Text(failed
                    ? OpenTypeL10n.text("失败", english: "Failed")
                    : OpenTypeL10n.text("完成", english: "Done"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(failed ? Color.red : Color.secondary)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(OpenTypeL10n.text("关闭", english: "Close"))
        }
    }

    private var stepList: some View {
        DisclosureGroup(isExpanded: $stepsExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(card.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: symbol(for: step.kind))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(
                                    step.kind == .error
                                        ? AnyShapeStyle(.red)
                                        : AnyShapeStyle(.secondary)
                                )
                                .frame(width: 14)
                            Text(step.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(step.kind == .error ? .red : .secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 108)
        } label: {
            Text(OpenTypeL10n.text(
                "执行步骤（\(card.steps.count)）",
                english: "Steps (\(card.steps.count))"
            ))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(OpenTypeL10n.text("复制", english: "Copy")) {
                onCopy(card.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(OpenTypeL10n.text("关闭", english: "Close"), action: onClose)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button(
                OpenTypeL10n.text("打开主窗口", english: "Open main window"),
                action: onOpenMainWindow
            )
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func symbol(for kind: AgentProgressStep.Kind) -> String {
        switch kind {
        case .thinking: return "brain"
        case .toolCall: return "wrench.and.screwdriver"
        case .toolResult: return "arrow.turn.down.left"
        case .error: return "exclamationmark.triangle"
        }
    }
}

private struct ListeningPulse: View {
    let level: Double
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.13))
                .scaleEffect(breathing ? 1.16 : 0.88)
                .opacity(breathing ? 0.32 : 0.8)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .scaleEffect(0.92 + level * 0.42)
        }
        .frame(width: 20, height: 20)
        .animation(.spring(response: 0.16), value: level)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.95).repeatForever()) {
                breathing = true
            }
        }
    }
}

private struct LiveWaveform: View {
    let level: Double
    private let weights = [0.48, 0.82, 1.0, 0.68, 0.42]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: 3,
                        height: 5 + max(level, 0.08) * 23 * weight
                    )
            }
        }
        .frame(width: 30, height: 28)
        .animation(.interactiveSpring(response: 0.12), value: level)
    }
}
