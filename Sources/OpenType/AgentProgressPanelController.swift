import AppKit
import SwiftUI

@MainActor
private final class AgentProgressPresentation: ObservableObject {
    @Published var task = ""
    @Published var steps: [AgentProgressStep] = []
    @Published var phase: AgentProgressPanelState.Phase = .running
    @Published var result: String?
}

/// The top-right floating Agent progress panel (spec:
/// docs/superpowers/specs/2026-08-13-agent-progress-panel-design.md §1):
/// appears the moment an Agent run is dispatched and shows the spoken task, a
/// live auto-following step feed, a status line, and — once done — the final
/// result. Follows `AskPanelController`'s NSPanel + NSHostingView pattern
/// (borderless, `.nonactivatingPanel`, floating, canJoinAllSpaces) with two
/// deliberate differences: it's positioned at the top-right of the screen's
/// `visibleFrame` (the macOS notification convention) rather than centered,
/// and it has NO click-outside dismiss — the user keeps working elsewhere
/// during a long run, so only the close button or Escape dismisses it.
/// Dismissing never cancels the run (`AppModel.dismissAgentPanel()` only
/// hides the panel and stops progress polling).
@MainActor
final class AgentProgressPanelController {
    private let panelSize = NSSize(width: 420, height: 360)
    private let presentation = AgentProgressPresentation()
    private var panel: NSPanel?

    /// Fired when the user asks to dismiss the panel (close button or
    /// Escape). Same contract as `AskPanelController.onRequestDismiss`: the
    /// controller does not close itself — `AppModel` owns the single source
    /// of truth (`agentPanelState`) and clears it, which calls `hide()`.
    var onRequestDismiss: (() -> Void)?
    /// Fired by the 打开主窗口 button — `AppModel` routes this through the
    /// same open-main-window-to-Agent-tab path a tapped completion
    /// notification uses, then dismisses the panel.
    var onOpenMainWindow: (() -> Void)?

    /// Top-right placement inside a screen's `visibleFrame` with a 16pt
    /// margin, in AppKit's bottom-left-origin coordinates. Pure and static so
    /// the geometry is unit-testable without a screen
    /// (`AgentProgressPanelTests`), same as `OverlayController.hideBehavior(for:)`.
    static func panelOrigin(visibleFrame: CGRect, panelSize: CGSize) -> CGPoint {
        CGPoint(
            x: visibleFrame.maxX - panelSize.width - 16,
            y: visibleFrame.maxY - panelSize.height - 16
        )
    }

    private lazy var hostingView = NSHostingView(
        rootView: AgentProgressPanelView(
            presentation: presentation,
            onClose: { [weak self] in self?.onRequestDismiss?() },
            onOpenMainWindow: { [weak self] in self?.onOpenMainWindow?() }
        )
    )

    func show(_ state: AgentProgressPanelState) {
        presentation.task = state.task
        presentation.steps = state.steps
        presentation.phase = state.phase
        presentation.result = state.result

        let panel = panel ?? makePanel()
        self.panel = panel
        // Position and take key status only when actually appearing — this
        // method is re-invoked on every polled steps update, and re-taking
        // key focus every ~0.7s would fight whatever the user moved on to.
        if !panel.isVisible {
            position(panel)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyableProgressPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
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

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let origin = Self.panelOrigin(visibleFrame: frame, panelSize: panelSize)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
    }
}

/// Same rationale as `AskPanelController`'s fileprivate `KeyableFloatingPanel`
/// (which isn't visible from this file): a `.nonactivatingPanel` normally
/// can't become key, which would swallow the Escape keypress meant for the
/// SwiftUI content's `onExitCommand`. Overriding `canBecomeKey` lets the
/// panel receive keyboard input without stealing app activation.
private final class KeyableProgressPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct AgentProgressPanelView: View {
    @ObservedObject var presentation: AgentProgressPresentation
    let onClose: () -> Void
    let onOpenMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text(presentation.task)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            stepFeed

            if presentation.phase != .running {
                Divider()
                resultArea
            }

            footer
        }
        .padding(16)
        .frame(width: 420)
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
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Agent")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.055), in: Capsule())
            statusLine
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

    private var statusLine: some View {
        HStack(spacing: 6) {
            if presentation.phase == .running {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: presentation.phase == .succeeded
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(presentation.phase == .succeeded ? Color.accentColor : .red)
            }
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(presentation.phase == .failed ? .red : .secondary)
        }
    }

    /// The live, auto-following step feed: newest step scrolled into view as
    /// it arrives (`ScrollViewReader` keyed on the step count).
    private var stepFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if presentation.steps.isEmpty {
                        Text(OpenTypeL10n.text("等待第一步…", english: "Waiting for the first step…"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(presentation.steps.enumerated()), id: \.offset) { index, step in
                        stepRow(step)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 72, maxHeight: presentation.phase == .running ? 200 : 110)
            .onChange(of: presentation.steps.count) { count in
                guard count > 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }

    private func stepRow(_ step: AgentProgressStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol(for: step.kind))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(step.kind == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 14)
            Text(step.detail)
                .font(.system(size: 11.5))
                .foregroundStyle(step.kind == .error ? .red : .primary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(presentation.result ?? "")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 40, maxHeight: 130)

            if presentation.phase == .succeeded {
                Text(OpenTypeL10n.text(
                    "已复制到剪贴板，按 ⌘V 即可粘贴",
                    english: "Copied. Press ⌘V to paste"
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
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

    private var statusText: String {
        switch presentation.phase {
        case .running:
            return OpenTypeL10n.text("执行中…", english: "Running…")
        case .succeeded:
            return OpenTypeL10n.text("完成", english: "Done")
        case .failed:
            return OpenTypeL10n.text("失败", english: "Failed")
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
