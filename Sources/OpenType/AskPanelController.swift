import AppKit
import SwiftUI

@MainActor
private final class AskPanelPresentation: ObservableObject {
    @Published var kind: AskPanelState.Kind = .ask
    @Published var query = ""
    @Published var answer: String?
}

/// A borderless floating panel for Ask and Agent mode: distinct from
/// `OverlayController`'s compact recording HUD, this shows the user's
/// transcribed question/task, a "thinking…" placeholder while the matching
/// sidecar call (`/oneshot/ask` or `/agent/run`) is in flight, then the
/// answer/result once it arrives. Follows the same
/// `NSPanel` + `NSHostingView` pattern `OverlayController` already
/// establishes in this codebase, but (unlike the HUD) needs to accept key
/// events so Escape/click-outside can dismiss it.
@MainActor
final class AskPanelController {
    private let panelSize = NSSize(width: 420, height: 280)
    private let presentation = AskPanelPresentation()
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?

    /// Fired when the user asks to dismiss the panel (close button, Escape,
    /// or a click outside it). The controller does not close itself on this
    /// signal — the caller (`AppModel`) owns the single source of truth
    /// (`askPanelState`) and is expected to clear it, which in turn calls
    /// `hide()`. This avoids a show/hide feedback loop.
    var onRequestDismiss: (() -> Void)?

    private lazy var hostingView = NSHostingView(
        rootView: AskPanelView(
            presentation: presentation,
            onClose: { [weak self] in self?.onRequestDismiss?() }
        )
    )

    func show(_ state: AskPanelState) {
        presentation.kind = state.kind
        presentation.query = state.query
        presentation.answer = state.answer

        let panel = panel ?? makePanel()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        installClickOutsideMonitor()
    }

    func hide() {
        removeClickOutsideMonitor()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyableFloatingPanel(
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
        let x = frame.midX - panelSize.width / 2
        let y = frame.midY - panelSize.height / 2
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: panelSize), display: false)
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
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
}

/// `NSPanel` with `.nonactivatingPanel` normally can't become key, which
/// would swallow keyboard events (Escape) meant for the SwiftUI content
/// inside it. Overriding `canBecomeKey` lets the panel receive keyboard
/// input while `.nonactivatingPanel` still keeps focus from stealing app
/// activation away from whatever the user was typing into.
private final class KeyableFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct AskPanelView: View {
    @ObservedObject var presentation: AskPanelPresentation
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 4) {
                Text(queryLabel)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(presentation.query)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            answerArea
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
            Image(systemName: presentation.kind == .agent ? "wand.and.stars" : "questionmark.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(titleText)
                .font(.system(size: 13, weight: .semibold))
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

    private var answerArea: some View {
        ScrollView {
            Group {
                if let answer = presentation.answer {
                    Text(answer)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(thinkingText)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minHeight: 64, maxHeight: 220)
    }

    private var titleText: String {
        presentation.kind == .agent
            ? OpenTypeL10n.text("Agent 任务", english: "Agent Task")
            : OpenTypeL10n.text("提问", english: "Ask")
    }

    private var queryLabel: String {
        presentation.kind == .agent
            ? OpenTypeL10n.text("任务", english: "Task")
            : OpenTypeL10n.text("问题", english: "Question")
    }

    private var thinkingText: String {
        presentation.kind == .agent
            ? OpenTypeL10n.text("Agent 正在处理…", english: "Agent is working…")
            : OpenTypeL10n.text("正在思考…", english: "Thinking…")
    }
}
