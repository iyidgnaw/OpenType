import AppKit
import SwiftUI

@MainActor
private final class OverlayPresentation: ObservableObject {
    @Published var state: ProcessingState = .idle
    @Published var mode: InputMode = InputMode.visibleModes[0]
    @Published var liveTranscript = ""
    @Published var audioLevel = 0.0
    @Published var colorTheme: AppColorTheme = .ocean
    @Published var interfaceLanguage: InterfaceLanguage = .chinese
}

@MainActor
final class OverlayController {
    private let compactSize = NSSize(width: 300, height: 60)
    private let listeningSize = NSSize(width: 388, height: 96)
    private let presentation = OverlayPresentation()
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private lazy var hostingView = NSHostingView(
        rootView: OverlayView(presentation: presentation)
    )

    func show(state: ProcessingState, mode: InputMode) {
        dismissWorkItem?.cancel()

        presentation.state = state
        presentation.mode = mode
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

        switch state {
        case .modeChanged:
            dismiss(after: 1.2)
        case .success, .copied:
            dismiss(after: 0.9)
        case .dispatched:
            // Informational, not an error, but carries a second line of copy
            // ("已下发给 Agent") the user has to actually read, so it needs
            // longer on screen than a bare success toast.
            dismiss(after: 1.6)
        case .cancelled:
            dismiss(after: 1.8)
        case .failure:
            dismiss(after: 2.4)
        default:
            break
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

    func updateColorTheme(_ theme: AppColorTheme) {
        presentation.colorTheme = theme
    }

    func updateInterfaceLanguage(_ language: InterfaceLanguage) {
        presentation.interfaceLanguage = language
    }

    func hide() {
        dismissWorkItem?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
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

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - panel.frame.width / 2
        let y = frame.minY + 54
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func dismiss(after seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}

private struct OverlayView: View {
    @ObservedObject var presentation: OverlayPresentation

    var body: some View {
        Group {
            if presentation.state == .listening {
                listeningContent
            } else {
                compactContent
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
        .tint(presentation.colorTheme.accent)
        .environment(\.locale, presentation.interfaceLanguage.locale)
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
                "说出你的问题，弹窗里直接获得答案…",
                english: "Ask your question — get a direct answer in a popup…"
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
