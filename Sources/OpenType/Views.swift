import AppKit
import SwiftUI

private enum OpenTypeTheme {
    static let surface = Color.primary.opacity(0.045)
    static let elevatedSurface = Color.primary.opacity(0.065)
    static let border = Color.primary.opacity(0.075)
    static let subtleText = Color.secondary.opacity(0.88)
}

private extension View {
    func openTypeSurface(
        cornerRadius: CGFloat = 16,
        selected: Bool = false
    ) -> some View {
        self
            .background(
                selected
                    ? Color.accentColor.opacity(0.11)
                    : OpenTypeTheme.surface,
                in: RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    selected
                        ? Color.accentColor.opacity(0.24)
                        : OpenTypeTheme.border,
                    lineWidth: 0.75
                )
            )
    }
}

/// Content of the real, resizable app window (Part A of the menubar split):
/// mode switching lives in the compact `MenuBarPopoverView` popover instead,
/// so everything here — Home's setup/last-result cards, History, the Q&A and
/// Agent tabs (past conversations + continuation), and Settings (Memory
/// panel, no free-text profile editing) — is what the product owner asked to
/// keep out of the menubar. Opened via the popover's gear button or
/// `AppModel.openMainWindow()`/`focusAgentRun(_:)`, hosted by
/// `MainWindowController` (`OpenTypeApp.swift`).
struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configuration: AppConfiguration

    init(model: AppModel) {
        self.model = model
        self.configuration = model.configuration
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model, configuration: model.configuration)

            Group {
                switch model.selectedTab {
                case .home:
                    HomeView(model: model, configuration: model.configuration)
                case .history:
                    HistoryView(model: model)
                case .qa:
                    QAConversationsView(model: model)
                case .agent:
                    AgentConversationsView(model: model)
                case .settings:
                    SettingsView(
                        model: model,
                        configuration: model.configuration,
                        agentMemory: model.agentMemory
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TabBar(model: model)
        }
        .frame(
            minWidth: 420,
            idealWidth: 460,
            maxWidth: .infinity,
            minHeight: 480,
            idealHeight: 600,
            maxHeight: .infinity
        )
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [
                        AppAccent.primary.opacity(0.045),
                        AppAccent.secondary.opacity(0.018),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .center
                )
            }
        }
        .tint(AppAccent.primary)
        .environment(\.locale, configuration.interfaceLanguage.locale)
    }
}

private struct HeaderView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configuration: AppConfiguration

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AppAccent.primary,
                                AppAccent.secondary
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .shadow(
                color: Color.accentColor.opacity(0.22),
                radius: 7,
                y: 3
            )

            VStack(alignment: .leading, spacing: 1) {
                Text("OpenType")
                    .font(.system(size: 16, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                    Text(configuration.selectedMode.title)
                        .font(.system(size: 10.5, weight: .medium))
                    Text("·")
                    Text(configuration.selectedMode.shortTitle)
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.quit()
            } label: {
                // "power", not "xmark": an x in a window header reads as
                // "close this window", which is a different action now that
                // closing the window just drops the app back to menu-bar-only.
                Label(
                    OpenTypeL10n.text("退出", english: "Quit"),
                    systemImage: "power"
                )
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 27)
                .background(
                    OpenTypeTheme.surface,
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .help(OpenTypeL10n.text(
                "退出 OpenType（完全关闭，不只是关窗口）",
                english: "Quit OpenType (fully exit, not just close the window)"
            ))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OpenTypeTheme.border)
                .frame(height: 0.5)
        }
    }
}

private struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configuration: AppConfiguration

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.setupReady {
                    SetupCard(model: model)
                }

                ShortcutHero(
                    state: model.state,
                    behavior: model.shortcutBehavior
                )

                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel("模式")

                    ModeGrid(model: model, configuration: configuration)
                }

                if !model.lastResult.isEmpty {
                    LastResultCard(model: model)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
    }
}

private struct ShortcutHero: View {
    let state: ProcessingState
    let behavior: HotKeyBehavior

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(stateColor.opacity(0.12))
                Image(systemName: state.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(stateColor)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(cardTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text(stateSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(OpenTypeTheme.subtleText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(13)
        .openTypeSurface(cornerRadius: 15)
    }

    private var cardTitle: String {
        switch state {
        case .idle, .modeChanged, .success, .copied, .cancelled:
            return OpenTypeL10n.text("开始语音输入", english: "Start voice input")
        case .listening:
            return OpenTypeL10n.text("正在听", english: "Listening")
        default:
            return state.title
        }
    }

    private var stateSubtitle: String {
        switch state {
        case .idle, .modeChanged, .success:
            return gestureHint
        case .copied:
            return OpenTypeL10n.text("已复制到剪贴板，按 ⌘V 即可粘贴", english: "Copied. Press ⌘V to paste")
        case .dispatched(let message):
            return message
        case .cancelled(let message):
            return message
        case .listening:
            return stopHint
        case .transcribing:
            return OpenTypeL10n.text("正在识别语音", english: "Transcribing speech")
        case .transforming:
            return OpenTypeL10n.text("正在整理表达", english: "Refining your words")
        case .inserting:
            return OpenTypeL10n.text("正在写入当前应用", english: "Inserting into the current app")
        case .failure(let message):
            return message
        }
    }

    private var gestureHint: String {
        switch behavior {
        case .optionHybrid:
            return OpenTypeL10n.text("按住说话，或双击后连续录音", english: "Hold to talk, or double-tap for continuous recording")
        case .doubleTapThenAnyKey:
            return OpenTypeL10n.text("双击开始，完成时按任意键", english: "Double-tap to start; press any key to finish")
        case .pressThenAnyKey:
            return OpenTypeL10n.text("按一下开始，完成时按任意键", english: "Press once to start; press any key to finish")
        case .holdToTalk:
            return OpenTypeL10n.text("按住说话，松开完成", english: "Hold to talk; release to finish")
        }
    }

    private var stopHint: String {
        behavior == .holdToTalk
            ? OpenTypeL10n.text("松开完成", english: "Release to finish")
            : OpenTypeL10n.text("完成时按任意键", english: "Press any key to finish")
    }

    private var stateColor: Color {
        switch state {
        case .failure: return .red
        case .success, .copied: return Color.accentColor
        case .listening: return .red
        default: return Color.accentColor
        }
    }
}

/// A vertical stack of equal-width rows, not a grid: with only 3 modes left
/// (post-cleanup), a 2-then-1 grid squeezed the first two cards into half
/// width each, which wrapped their subtitles into 2-3 lines and clipped the
/// last one. Equal full-width rows give every mode the same room regardless
/// of how long its title/subtitle text is.
struct ModeGrid: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configuration: AppConfiguration

    var body: some View {
        VStack(spacing: 8) {
            modeCard(.transcribe)
            modeCard(.ask)
            modeCard(.agent)
        }
    }

    private func modeCard(_ mode: InputMode) -> some View {
        ModeCard(
            mode: mode,
            isSelected: configuration.selectedMode == mode
        ) {
            model.selectMode(mode)
        }
    }
}

private struct ModeCard: View {
    let mode: InputMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(0.14)
                                : Color.primary.opacity(0.045)
                        )
                    Image(systemName: mode.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            isSelected ? Color.accentColor : Color.secondary
                        )
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(mode.shortTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if isSelected {
                    Circle()
                        .fill(Color.accentColor.opacity(0.72))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
            .openTypeSurface(cornerRadius: 13, selected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

private struct SetupCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(OpenTypeTheme.elevatedSurface, lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: setupProgress)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text("\(completedStepCount)/\(totalStepCount)")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(setupTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(setupDetail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(primaryActionTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                SetupStatusPill(
                    title: "麦克风",
                    status: model.microphonePermission
                )
                SetupStatusPill(
                    title: "辅助功能",
                    status: model.accessibilityGranted ? .granted : .notDetermined
                )
                if model.configuration.liveCaptionsEnabled {
                    SetupStatusPill(
                        title: "实时字幕",
                        status: model.speechRecognitionPermission
                    )
                }

                Spacer(minLength: 0)

                if model.setupReady {
                    Button {
                        model.togglePracticeDictation()
                    } label: {
                        Label(practiceButtonTitle, systemImage: "mic")
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(!model.canTogglePractice)
                }
            }
        }
        .padding(14)
        .openTypeSurface(cornerRadius: 17)
    }

    private var completedStepCount: Int {
        var checks = [
            model.microphonePermission == .granted,
            model.accessibilityGranted
        ]
        if model.configuration.liveCaptionsEnabled {
            checks.append(model.speechRecognitionPermission == .granted)
        }
        return checks.filter { $0 }.count
    }

    private var totalStepCount: Int {
        model.configuration.liveCaptionsEnabled ? 3 : 2
    }

    private var setupProgress: CGFloat {
        CGFloat(completedStepCount) / CGFloat(totalStepCount)
    }

    private var setupTitle: String {
        let remaining = totalStepCount - completedStepCount
        switch remaining {
        case 0: return OpenTypeL10n.text("OpenType 已准备就绪", english: "OpenType is ready")
        case 1: return OpenTypeL10n.text("还差最后一步", english: "One step left")
        default: return OpenTypeL10n.text("再完成 \(remaining) 步", english: "\(remaining) steps left")
        }
    }

    private var setupDetail: String {
        if model.microphonePermission != .granted {
            return OpenTypeL10n.text("允许麦克风后，就可以开始说话", english: "Allow microphone access to start speaking")
        }
        if !model.accessibilityGranted {
            return OpenTypeL10n.text("开启辅助功能后，自动启用你在设置中选择的快捷键", english: "Enable Accessibility to activate your chosen shortcut")
        }
        if model.configuration.liveCaptionsEnabled,
           model.speechRecognitionPermission != .granted {
            return OpenTypeL10n.text("允许语音识别后，说话时会显示实时字幕", english: "Allow Speech Recognition to show live captions")
        }
        return OpenTypeL10n.text("正在注册你选择的全局快捷键", english: "Registering your global shortcut")
    }

    private var primaryActionTitle: String {
        if model.microphonePermission == .denied { return OpenTypeL10n.text("打开麦克风设置", english: "Open Microphone Settings") }
        if model.microphonePermission != .granted { return OpenTypeL10n.text("允许麦克风", english: "Allow Microphone") }
        if !model.accessibilityGranted { return OpenTypeL10n.text("开启辅助功能", english: "Enable Accessibility") }
        if model.configuration.liveCaptionsEnabled,
           model.speechRecognitionPermission == .denied {
            return OpenTypeL10n.text("打开字幕权限", english: "Open Caption Settings")
        }
        if model.configuration.liveCaptionsEnabled,
           model.speechRecognitionPermission != .granted {
            return OpenTypeL10n.text("允许实时字幕", english: "Allow Live Captions")
        }
        return OpenTypeL10n.text("重试", english: "Retry")
    }

    private var primaryAction: () -> Void {
        if model.microphonePermission != .granted {
            return model.requestMicrophonePermission
        }
        if !model.accessibilityGranted {
            return model.requestAccessibility
        }
        if model.configuration.liveCaptionsEnabled,
           model.speechRecognitionPermission != .granted {
            return model.requestSpeechRecognitionPermission
        }
        return model.refreshPermissionStatus
    }

    private var practiceButtonTitle: String {
        if model.isPracticeSession, model.state == .listening {
            return OpenTypeL10n.text("结束并查看", english: "Stop & review")
        }
        return model.lastResultWasPractice
            ? OpenTypeL10n.text("再试一次", english: "Try again")
            : OpenTypeL10n.text("开始试用", english: "Try it")
    }
}

private struct SetupStatusPill: View {
    let title: String
    let status: PermissionStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(statusColor)
            Text(LocalizedStringKey(title))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(OpenTypeTheme.surface, in: Capsule())
    }

    private var statusColor: Color {
        switch status {
        case .notDetermined: return .orange
        case .granted: return .secondary
        case .denied: return .red
        }
    }
}

private struct LastResultCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionLabel(model.lastResultWasPractice ? "试用结果" : "刚刚写下")
                Spacer()
                if !model.lastApplication.isEmpty {
                    Text(model.lastApplication)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(model.lastResult)
                .font(.system(size: 12))
                .lineLimit(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button {
                    model.copyLastResult()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button {
                    model.undo()
                } label: {
                    Label("撤销写入", systemImage: "arrow.uturn.backward")
                }
                .controlSize(.small)

                Spacer()
            }
        }
        .padding(14)
        .openTypeSurface(cornerRadius: 15)
    }
}

private struct HistoryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.history.entries.isEmpty {
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(OpenTypeTheme.surface)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 48, height: 48)
                    Text("还没有输入历史")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("完成一次语音输入后会出现在这里")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text("\(model.history.entries.count) 条本地记录")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 5)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.history.entries) { entry in
                            HistoryRow(model: model, entry: entry)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct HistoryRow: View {
    @ObservedObject var model: AppModel
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(entry.mode.title, systemImage: entry.mode.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(entry.createdAt, style: .relative)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Text(entry.result)
                .font(.system(size: 12))
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            HStack {
                Text(entry.applicationName)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制") {
                    model.copy(entry.result)
                }
                .buttonStyle(.borderless)
                Button("重新使用") {
                    model.reuse(entry)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(13)
        .openTypeSurface(cornerRadius: 14)
    }
}

/// Q&A tab: past Ask conversations (`AppModel.askConversations`, sourced
/// from `GET /conversations?kind=ask` -- the sidecar-persisted, durable
/// list, survives relaunch). Tapping one opens its full thread and marks it
/// as the conversation a new Ask-mode voice dispatch should continue
/// (`AppModel.openAskConversation(_:)`); the thread view's back button /
/// "new conversation" affordance clear that focus again
/// (`AppModel.startNewAskConversation()`).
private struct QAConversationsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.focusedAskConversationId != nil {
                ConversationThreadView(
                    detail: model.askConversationDetail,
                    onBack: { model.startNewAskConversation() },
                    onNewConversation: { model.startNewAskConversation() }
                )
            } else if model.askConversations.isEmpty {
                ConversationEmptyState(
                    symbol: "questionmark.bubble.fill",
                    title: OpenTypeL10n.text("还没有问答记录", english: "No Q&A conversations yet"),
                    subtitle: OpenTypeL10n.text(
                        "用 Ask 模式提问后会出现在这里",
                        english: "Ask a question in Ask mode and it will show up here"
                    )
                )
            } else {
                ConversationListView(conversations: model.askConversations) { conversation in
                    model.openAskConversation(conversation.id)
                }
            }
        }
        .task { await model.refreshAskConversations() }
    }
}

/// Agent tab counterpart to `QAConversationsView`: past Agent conversations
/// (`AppModel.agentConversations`, `GET /conversations?kind=agent`) below an
/// "in progress" strip for runs still dispatched-but-not-yet-returned this
/// session (`AppModel.agentRuns`, `AgentRunTracking.swift`) -- `/agent/run`
/// is a single blocking call, so a run in flight has no persisted
/// conversation entry to show yet. Replaces the old Settings "Task List"
/// section as the one place Agent history lives.
private struct AgentConversationsView: View {
    @ObservedObject var model: AppModel

    private var runningRuns: [AgentRunRecord] {
        model.agentRuns.filter { $0.status.isRunning }
    }

    var body: some View {
        Group {
            if model.focusedAgentConversationId != nil {
                ConversationThreadView(
                    detail: model.agentConversationDetail,
                    onBack: { model.startNewAgentConversation() },
                    onNewConversation: { model.startNewAgentConversation() }
                )
            } else if runningRuns.isEmpty, model.agentConversations.isEmpty {
                ConversationEmptyState(
                    symbol: "wand.and.stars",
                    title: OpenTypeL10n.text("还没有 Agent 任务", english: "No Agent tasks yet"),
                    subtitle: OpenTypeL10n.text(
                        "用 Agent 模式说出任务后会出现在这里",
                        english: "Speak a task in Agent mode and it will show up here"
                    )
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !runningRuns.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(OpenTypeL10n.text("进行中", english: "In Progress"))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(runningRuns) { run in
                                    AgentRunRow(
                                        run: run,
                                        isFocused: model.focusedAgentRunID == run.id
                                    )
                                    .id(run.id)
                                }
                            }
                        }
                        ForEach(model.agentConversations) { conversation in
                            ConversationListRow(conversation: conversation) {
                                model.openAgentConversation(conversation.id)
                            }
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
            }
        }
        .task { await model.refreshAgentConversations() }
        .onChange(of: model.focusedAgentRunID) { newValue in
            // Same transient-highlight behavior the old Settings Task List
            // panel had: clear it after a moment so it reads as a pointer,
            // not a sticky selection.
            guard let newValue else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if model.focusedAgentRunID == newValue {
                    model.focusedAgentRunID = nil
                }
            }
        }
    }
}

private struct ConversationEmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(OpenTypeTheme.surface)
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 48)
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConversationListView: View {
    let conversations: [ConversationSummary]
    let onSelect: (ConversationSummary) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(conversations) { conversation in
                    ConversationListRow(conversation: conversation) {
                        onSelect(conversation)
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }
}

private struct ConversationListRow: View {
    let conversation: ConversationSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(Self.dateFormatter.string(
                        from: Date(timeIntervalSince1970: Double(conversation.updatedAt) / 1000)
                    ))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(13)
            .contentShape(Rectangle())
            .openTypeSurface(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Shared thread view for both the Q&A and Agent tabs: a back/"new
/// conversation" header plus a scrollable list of user/assistant bubbles
/// (`ConversationBubble`), matching this app's existing floating-panel chat
/// look (`AskPanelController.swift`'s `AskPanelView`) rather than inventing a
/// new visual language. `detail == nil` means the fetch
/// (`AppModel.openAskConversation(_:)`/`openAgentConversation(_:)`) is still
/// in flight.
private struct ConversationThreadView: View {
    let detail: ConversationDetail?
    let onBack: () -> Void
    let onNewConversation: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(OpenTypeL10n.text("返回列表", english: "Back to list"))

                Text(detail?.title ?? OpenTypeL10n.text("对话", english: "Conversation"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                Button(OpenTypeL10n.text("新对话", english: "New")) {
                    onNewConversation()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 8)

            Divider()

            if let detail {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(detail.messages) { message in
                            ConversationBubble(message: message)
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(OpenTypeL10n.text("正在加载对话…", english: "Loading conversation…"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ConversationBubble: View {
    let message: ConversationMessageSummary

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 36) }

            Text(message.content)
                .font(.system(size: 12))
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    isUser ? Color.accentColor : OpenTypeTheme.surface,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )

            if !isUser { Spacer(minLength: 36) }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configuration: AppConfiguration
    @ObservedObject var agentMemory: AgentMemoryStore
    @State private var dataManagementExpanded = false
    @State private var showingHistoryResetConfirmation = false
    @State private var showingAgentMemoryResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection("界面语言") {
                    Picker(
                        "界面语言",
                        selection: Binding(
                            get: { configuration.interfaceLanguage },
                            set: { model.changeInterfaceLanguage($0) }
                        )
                    ) {
                        ForEach(InterfaceLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                SettingsSection("快捷键") {
                    Picker(
                        "启动快捷键",
                        selection: Binding(
                            get: { configuration.hotKeyPreset },
                            set: { model.changeHotKey($0) }
                        )
                    ) {
                        ForEach(HotKeyPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(configuration.hotKeyPreset.note)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)

                    Label(
                        model.shortcutStatus,
                        systemImage: shortcutStatusSymbol
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(shortcutStatusColor)
                    .fixedSize(horizontal: false, vertical: true)

                    if !model.accessibilityGranted {
                        HStack {
                            Text("开启辅助功能后，可使用双击键，并由任意键结束。")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("打开设置") {
                                model.requestAccessibility()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                SettingsSection("输入体验") {
                    Toggle(
                        "完成后自动写入当前输入框",
                        isOn: $configuration.automaticallyInsert
                    )
                    Toggle(
                        "保留本地输入历史",
                        isOn: $configuration.keepHistory
                    )
                    Toggle(
                        isOn: Binding(
                            get: { configuration.isMuted },
                            set: { model.changeMuted($0) }
                        )
                    ) {
                        Label(
                            "静音",
                            systemImage: configuration.isMuted
                                ? "speaker.slash.fill"
                                : "speaker.wave.2.fill"
                        )
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OpenType Air")
                                .font(.system(size: 10.5, weight: .medium))
                            Text("开始、结束、完成和问题使用一组低响度提示音")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Menu("试听") {
                            ForEach(FeedbackSoundCue.allCases) { cue in
                                Button(cue.title) {
                                    model.previewFeedbackSound(cue)
                                }
                            }
                        }
                        .controlSize(.small)
                        .disabled(configuration.isMuted)
                    }
                    Toggle(
                        "录音时显示实时字幕",
                        isOn: $configuration.liveCaptionsEnabled
                    )
                    if configuration.liveCaptionsEnabled,
                       model.speechRecognitionPermission != .granted {
                        HStack {
                            Text("实时字幕需要 macOS 语音识别权限")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(
                                model.speechRecognitionPermission == .denied
                                    ? "打开设置"
                                    : "授权"
                            ) {
                                model.requestSpeechRecognitionPermission()
                            }
                            .controlSize(.small)
                        }
                    }
                    Toggle(
                        "识别“发送 / press enter”命令",
                        isOn: $configuration.pressEnterCommand
                    )
                    Text("Agent 模式的结果始终复制到剪贴板，由你手动粘贴，不会自动发送或执行。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }

                SettingsSection("记忆与偏好") {
                    Toggle(
                        "启用本地长期记忆与个性化",
                        isOn: $configuration.agentMemoryEnabled
                    )

                    Text("正式文字任务会追加保存原始转写、实际指令、上下文和结果；系统推断的偏好会单独存放。不保存原始录音。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Label(
                            "\(agentMemory.eventCount) 条本地记录",
                            systemImage: agentMemory.databaseReady
                                ? "cylinder.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(
                            agentMemory.databaseReady ? Color.secondary : Color.orange
                        )

                        Spacer()

                        Button("显示数据库") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [agentMemory.databaseURL]
                            )
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(!agentMemory.databaseReady)
                    }

                    Toggle(
                        "每 100 条更新“已学到的偏好”",
                        isOn: Binding(
                            get: {
                                configuration.automaticOwnerProfileUpdates
                            },
                            set: {
                                model.changeAutomaticOwnerProfileUpdates($0)
                            }
                        )
                    )
                    .disabled(!configuration.agentMemoryEnabled)

                    Text(automaticProfileUpdateDescription)
                        .font(.system(size: 8.8))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label("已学到的偏好", systemImage: "sparkles")
                                .font(.system(size: 10.5, weight: .semibold))
                            Spacer()
                            Text("自动归纳 · 只作参考")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }

                        if agentMemory.learnedPreferences.isEmpty {
                            Text("每完成 100 条正式输入，OpenType 会在本机归纳一次术语、任务和表达偏好，仅供参考。")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        } else {
                            memoryInsightRow(
                                "常用术语",
                                values: agentMemory.learnedPreferences.commonTerms
                            )
                            memoryInsightRow(
                                "常见任务",
                                values: agentMemory.learnedPreferences.taskDomains
                            )
                            memoryInsightRow(
                                "语言习惯",
                                values: agentMemory.learnedPreferences.languagePattern.map { [$0] } ?? []
                            )
                            memoryInsightRow(
                                "表达偏好",
                                values: agentMemory.learnedPreferences.stylePreferences
                            )
                        }
                    }

                    Text("当前明确指令 > 当前模式 > 已学到的偏好。系统只会把与当前任务相关的最少信息发送给你选择的文字模型。")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !agentMemory.entries.isEmpty {
                        Divider()
                        Text("最近 Agent 任务")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(agentMemory.entries.prefix(3)) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.request)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .lineLimit(1)
                                Text(entry.outcome)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(
                                Color.primary.opacity(0.028),
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                        }
                    }
                }

                SettingsSection(OpenTypeL10n.text("记忆面板（只读）", english: "Memory Panel (Read-only)")) {
                    MemoryPanelView(model: model)
                }

                SettingsSection("转写") {
                    Picker(
                        OpenTypeL10n.text("听写方式", english: "Transcribe mode"),
                        selection: Binding(
                            get: { configuration.transcribeVariant },
                            set: { model.changeTranscribeVariant($0) }
                        )
                    ) {
                        ForEach(TranscribeVariant.allCases) { variant in
                            Text(variant.title).tag(variant)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(configuration.transcribeVariant.explanation)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Picker(
                        "转写语言",
                        selection: Binding(
                            get: { configuration.transcriptionLanguage },
                            set: { model.changeTranscriptionLanguage($0) }
                        )
                    ) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("中英夹杂或一段音频包含多种语言时，请使用“自动识别”；单一语言可明确选择，以提高实时字幕预览的准确率。最终识别始终使用本机 MLX-Whisper。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection("个人词典") {
                    Text("用逗号或换行分隔。OpenType 会保留这些词的拼写。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    TextEditor(text: $configuration.personalDictionaryText)
                        .font(.system(size: 11))
                        .frame(height: 76)
                        .padding(7)
                        .scrollContentBackground(.hidden)
                        .background(
                            Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(.primary.opacity(0.1))
                        )
                }

                SettingsSection("连接与权限") {
                    HStack {
                        Label(
                            "麦克风\(model.microphonePermission.title)",
                            systemImage: model.microphonePermission.symbol
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(
                            model.microphonePermission == .granted
                                ? Color.secondary
                                : Color.orange
                        )
                        Spacer()
                        if model.microphonePermission != .granted {
                            Button(
                                model.microphonePermission == .denied
                                    ? "打开设置"
                                    : "授权"
                            ) {
                                model.requestMicrophonePermission()
                            }
                            .controlSize(.small)
                        }
                    }

                    HStack {
                        Label(
                            model.accessibilityGranted
                                ? "辅助功能已授权"
                                : "辅助功能未授权",
                            systemImage: model.accessibilityGranted
                                ? "circle.fill"
                                : "circle"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(
                            model.accessibilityGranted
                                ? Color.secondary
                                : Color.orange
                        )
                        Spacer()
                        if !model.accessibilityGranted {
                            Button("授权") {
                                model.requestAccessibility()
                            }
                            .controlSize(.small)
                        }
                    }

                    HStack {
                        Label(
                            "实时字幕\(model.speechRecognitionPermission.title)",
                            systemImage: model.speechRecognitionPermission.symbol
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(
                            model.speechRecognitionPermission == .granted
                                ? Color.secondary
                                : Color.orange
                        )
                        Spacer()
                        if model.speechRecognitionPermission != .granted {
                            Button(
                                model.speechRecognitionPermission == .denied
                                    ? "打开设置"
                                    : "授权"
                            ) {
                                model.requestSpeechRecognitionPermission()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                SettingsSection("隐私与数据") {
                    DisclosureGroup(
                        isExpanded: $dataManagementExpanded
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Divider()

                            dataManagementRow(
                                title: "输入历史",
                                detail: "\(model.history.entries.count) 条本地记录",
                                actionTitle: "重置输入历史",
                                disabled: model.history.entries.isEmpty
                            ) {
                                showingHistoryResetConfirmation = true
                            }

                            Divider()

                            dataManagementRow(
                                title: "长期记忆",
                                detail: "\(agentMemory.eventCount) 条学习记录",
                                actionTitle: "重新学习偏好",
                                disabled: agentMemory.eventCount == 0
                            ) {
                                showingAgentMemoryResetConfirmation = true
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("本地数据管理", systemImage: "externaldrive")
                            .font(.system(size: 10.5, weight: .semibold))
                    }

                    Text("高风险操作默认收起，需要时再展开。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }

                Text("实时字幕优先使用 Apple 本机识别，仅作为录音预览；最终识别始终在本机运行（MLX-Whisper），文字生成由本地 sidecar 转发给固定的 DeepSeek 模型，均不需要你手动配置或选择云端服务商。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .confirmationDialog(
            "重置输入历史？",
            isPresented: $showingHistoryResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认重置", role: .destructive) {
                model.resetHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机保存的输入记录会被移除。此操作不可撤销，建议先保存重要信息。")
        }
        .confirmationDialog(
            "重新学习偏好？",
            isPresented: $showingAgentMemoryResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认重新学习", role: .destructive) {
                model.resetAgentMemory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本地任务记录和系统推断会被移除。此操作不可撤销，建议先保存重要信息。")
        }
    }

    @ViewBuilder
    private func dataManagementRow(
        title: String,
        detail: String,
        actionTitle: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 10.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive, action: action) {
                Text(LocalizedStringKey(actionTitle))
            }
                .controlSize(.small)
                .disabled(disabled)
        }
    }

    private var automaticProfileUpdateDescription: String {
        guard configuration.automaticOwnerProfileUpdates else {
            return OpenTypeL10n.text("已暂停自动更新；已有内容会保留。", english: "Automatic updates are paused; existing content is kept.")
        }
        if agentMemory.automaticProfileUpdateDue {
            return OpenTypeL10n.text("已达到更新条件，下次启动或完成输入时将更新。整个过程在本机完成。", english: "Ready to update on the next launch or completed input. Everything runs locally.")
        }
        return OpenTypeL10n.text(
            "已记录 \(agentMemory.eventCount) 条；到 \(agentMemory.nextAutomaticProfileEventCount) 条时更新已学到的偏好。",
            english: "\(agentMemory.eventCount) recorded; learned preferences update at \(agentMemory.nextAutomaticProfileEventCount)."
        )
    }

    @ViewBuilder
    private func memoryInsightRow(
        _ title: String,
        values: [String]
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            Text(
                values.isEmpty
                    ? OpenTypeL10n.text("仍在学习", english: "Still learning")
                    : values.joined(separator: " · ")
            )
                .font(.system(size: 9.5, weight: values.isEmpty ? .regular : .medium))
                .foregroundStyle(values.isEmpty ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutStatusSymbol: String {
        if !model.shortcutReady {
            return "exclamationmark.triangle.fill"
        }
        return model.preferredShortcutActive
            ? "keyboard.badge.ellipsis"
            : "arrow.triangle.2.circlepath"
    }

    private var shortcutStatusColor: Color {
        model.shortcutReady && model.preferredShortcutActive ? .secondary : .orange
    }
}

/// Read-only display of the sidecar's memory system: the current entity
/// dictionary (`GET /memory/terms`) and the consolidation run log
/// (`GET /memory/consolidation-runs`) — the human-review surface described
/// in the memory design doc §4.1. Purely a convenience view: it refreshes
/// itself on appear and never mutates anything.
private struct MemoryPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(OpenTypeL10n.text(
                "本地记忆服务记录的实体词典与最近的整理记录，仅供查看，不可在此编辑。",
                english: "Entity dictionary and recent consolidation runs recorded by the local memory service. Read-only."
            ))
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Label(
                    OpenTypeL10n.text("实体词典", english: "Entity Terms"),
                    systemImage: "text.book.closed"
                )
                .font(.system(size: 10.5, weight: .semibold))

                if model.memoryTerms.isEmpty {
                    Text(OpenTypeL10n.text("暂无记录", english: "No entries yet"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.memoryTerms) { term in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(term.canonicalTerm)
                                    .font(.system(size: 10.5, weight: .medium))
                                Spacer()
                                Text(term.category)
                                    .font(.system(size: 8.8, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                Text(String(format: "%.0f%%", term.confidence * 100))
                                    .font(.system(size: 8.8))
                                    .foregroundStyle(.tertiary)
                            }
                            if !term.aliases.isEmpty {
                                Text(term.aliases.joined(separator: " · "))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.primary.opacity(0.028),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(
                        OpenTypeL10n.text("整理记录", english: "Consolidation Runs"),
                        systemImage: "clock.arrow.2.circlepath"
                    )
                    .font(.system(size: 10.5, weight: .semibold))

                    Spacer()

                    Button {
                        model.consolidateMemoryNow()
                    } label: {
                        if model.consolidateNowStatus == .running {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(OpenTypeL10n.text("立即整理", english: "Consolidate now"))
                        }
                    }
                    .controlSize(.small)
                    .disabled(model.consolidateNowStatus == .running)
                }

                switch model.consolidateNowStatus {
                case .succeeded(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                case .idle, .running:
                    EmptyView()
                }

                if model.memoryConsolidationRuns.isEmpty {
                    Text(OpenTypeL10n.text("暂无整理记录", english: "No consolidation runs yet"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.memoryConsolidationRuns) { run in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(Self.dateFormatter.string(
                                    from: Date(timeIntervalSince1970: Double(run.ranAt) / 1000)
                                ))
                                .font(.system(size: 9.5, weight: .medium))

                                if run.rolledBackAt != nil {
                                    Spacer()
                                    Label(
                                        OpenTypeL10n.text("已回滚", english: "Rolled back"),
                                        systemImage: "arrow.uturn.backward"
                                    )
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(.orange)
                                }
                            }
                            Text(run.summary)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.primary.opacity(0.028),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                }
            }
        }
        .task {
            await model.refreshMemoryPanel()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// A single row in the Agent tab's "in progress" strip
/// (`AgentConversationsView`): the task text, a status badge (running / done
/// / failed), the result or error once available, and an optional
/// expandable step-by-step log. Runs still in flight have no persisted
/// conversation entry yet (`/agent/run` is a single blocking call), so this
/// reads live off `AppModel.agentRuns` (`AgentRunTracking.swift`) rather than
/// the sidecar-persisted conversation list.
private struct AgentRunRow: View {
    let run: AgentRunRecord
    let isFocused: Bool
    @State private var stepsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.task)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(2)
                    Text(Self.dateFormatter.string(from: run.dispatchedAt))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                statusBadge
            }

            switch run.status {
            case .running:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(OpenTypeL10n.text("运行中…", english: "Running…"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            case .completed(let result):
                Text(result)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.primary)
                    .lineLimit(stepsExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !run.steps.isEmpty {
                Button {
                    stepsExpanded.toggle()
                } label: {
                    Text(stepsExpanded
                        ? OpenTypeL10n.text("收起步骤", english: "Hide steps")
                        : OpenTypeL10n.text("查看步骤（\(run.steps.count)）", english: "View steps (\(run.steps.count))"))
                        .font(.system(size: 8.8, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                if stepsExpanded {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(run.steps.enumerated()), id: \.offset) { _, step in
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: Self.symbol(for: step.type))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(Self.color(for: step.type))
                                    .frame(width: 13)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Self.label(for: step.type))
                                        .font(.system(size: 8.3, weight: .semibold))
                                        .foregroundStyle(Self.color(for: step.type))
                                    Text(step.detail)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isFocused ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.028),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.accentColor.opacity(0.55) : .clear,
                    lineWidth: 1.2
                )
        )
    }

    private var statusBadge: some View {
        let (text, symbol, color): (String, String, Color) = {
            switch run.status {
            case .running:
                return (
                    OpenTypeL10n.text("运行中", english: "Running"),
                    "circle.dotted",
                    .secondary
                )
            case .completed:
                return (
                    OpenTypeL10n.text("完成", english: "Done"),
                    "checkmark.circle.fill",
                    .green
                )
            case .failed:
                return (
                    OpenTypeL10n.text("失败", english: "Failed"),
                    "exclamationmark.triangle.fill",
                    .red
                )
            }
        }()
        return Label(text, systemImage: symbol)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static func symbol(for stepType: String) -> String {
        switch stepType {
        case "thinking": return "bubble.left.and.text.bubble.right"
        case "tool_call": return "wrench.and.screwdriver.fill"
        case "tool_result": return "arrow.turn.down.right"
        case "done": return "checkmark.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        default: return "circle.fill"
        }
    }

    private static func color(for stepType: String) -> Color {
        switch stepType {
        case "thinking": return .secondary
        case "tool_call": return .blue
        case "tool_result": return .purple
        case "done": return .green
        case "error": return .red
        default: return .secondary
        }
    }

    private static func label(for stepType: String) -> String {
        switch stepType {
        case "thinking":
            return OpenTypeL10n.text("思考", english: "Thinking")
        case "tool_call":
            return OpenTypeL10n.text("调用工具", english: "Tool Call")
        case "tool_result":
            return OpenTypeL10n.text("工具结果", english: "Tool Result")
        case "done":
            return OpenTypeL10n.text("完成", english: "Done")
        case "error":
            return OpenTypeL10n.text("错误", english: "Error")
        default:
            return stepType
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .openTypeSurface(cornerRadius: 14)
        }
    }
}

private struct TabBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    model.selectedTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(
                            model.selectedTab == tab
                                ? Color.accentColor.opacity(0.11)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .foregroundStyle(
                    model.selectedTab == tab ? Color.accentColor : Color.secondary
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OpenTypeTheme.border)
                .frame(height: 0.5)
        }
    }
}

private struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
