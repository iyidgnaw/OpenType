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
}

/// How `OverlayController.show(...)` should treat the HUD panel for a given
/// `ProcessingState`, factored out of the inline `switch` so the per-state
/// timing decision is pure and unit-testable (see `OverlayHideBehaviorTests`).
enum OverlayHideBehavior: Equatable {
    /// Hide the panel right away (e.g. `.idle` — there is nothing to show).
    case hideImmediately
    /// Leave it up for `after` seconds, then hide (transient toast states).
    case scheduleHide(after: TimeInterval)
    /// Keep it on screen with no scheduled hide (active in-flight states).
    case keepVisible
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

    /// Escape, the 关闭 button, or a click outside a finished card.
    var onRequestDismiss: (() -> Void)?
    /// The 复制 button, with the card's Markdown body.
    var onCopyResult: ((String) -> Void)?
    /// The 打开主窗口 button.
    var onOpenMainWindow: (() -> Void)?
    /// The 停止 control shown while a stoppable agent run is on screen (T1).
    var onStopAgentRun: (() -> Void)?

    private lazy var hostingView = NSHostingView(
        rootView: OverlayView(
            presentation: presentation,
            onClose: { [weak self] in self?.onRequestDismiss?() },
            onCopy: { [weak self] text in self?.onCopyResult?(text) },
            onOpenMainWindow: { [weak self] in self?.onOpenMainWindow?() },
            onStop: { [weak self] in self?.onStopAgentRun?() }
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

    func updateLiveTranscript(_ text: String) {
        guard presentation.state == .listening else { return }
        presentation.liveTranscript = text
    }

    func updateAudioLevel(_ level: Double) {
        guard presentation.state == .listening else { return }
        presentation.audioLevel = level
    }

    func hide() {
        dismissWorkItem?.cancel()
        cancelToastOverride()
        removeClickOutsideMonitor()
        legacyOnScreen = nil
        surfaceState = .hidden
        presentation.surface = .hidden
        panel?.orderOut(nil)
    }

    // MARK: - Legacy transient HUD

    private func presentLegacy(state: ProcessingState, mode: InputMode) {
        dismissWorkItem?.cancel()
        removeClickOutsideMonitor()

        presentation.state = state
        presentation.mode = mode
        presentation.surface = .hidden
        if state != .listening {
            presentation.liveTranscript = ""
            presentation.audioLevel = 0
        }

        let size = state == .listening ? listeningSize : compactSize
        let panel = panel ?? makePanel()
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        switch Self.hideBehavior(for: state) {
        case .hideImmediately:
            hide()
        case .scheduleHide(let seconds):
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
    private func presentToast(state: ProcessingState, mode: InputMode) {
        cancelToastOverride()
        let preempted = surfaceState

        presentLegacy(state: state, mode: mode)

        guard preempted != .hidden,
              case .scheduleHide(let seconds) = Self.hideBehavior(for: state)
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

    private func visibleFrame() -> CGRect? {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
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

    var body: some View {
        Group {
            switch presentation.surface {
            case .hidden:
                if presentation.state == .listening {
                    listeningContent
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

                Spacer(minLength: 4)

                LiveWaveform(level: presentation.audioLevel)
            }

            Text(captionText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    presentation.liveTranscript.isEmpty
                        ? Color.secondary
                        : Color.primary
                )
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

    private var captionText: String {
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
                    Button(OpenTypeL10n.text("停止", english: "Stop"), action: onStop)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
