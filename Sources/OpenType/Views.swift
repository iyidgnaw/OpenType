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
                if model.needsProviderOnboarding {
                    // First-run setup wizard (spec: "if the user hasn't
                    // configured Whisper or LLM yet, opening the app should
                    // enter a setup wizard") -- takes over the whole tab
                    // content area, in place of the normal Home tab, until
                    // both are configured. See `OnboardingWizardView`'s doc
                    // comment (`ProviderSetupViews.swift`) for why no
                    // explicit tab switch is needed once that happens.
                    OnboardingWizardView(model: model)
                } else {
                    switch model.selectedTab {
                    case .home:
                        HomeView(model: model, configuration: model.configuration)
                    case .history:
                        HistoryView(model: model, history: model.history)
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !model.needsProviderOnboarding {
                TabBar(model: model)
            }
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
        .environment(\.locale, OpenTypeL10n.locale)
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
                if model.sidecarNeedsAttention {
                    SidecarAttentionCard(model: model)
                }

                if model.auditWriteFailed {
                    AuditWriteFailedCard()
                }

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

/// Home-tab banner shown when the sidecar has crashed / can't restart, with a
/// manual "restart service" button (P1-4). Mirrors the menubar popover's error
/// affordance so the failure is visible wherever the user is looking.
private struct SidecarAttentionCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(OpenTypeL10n.text("语音服务异常", english: "Voice service problem"))
                    .font(.system(size: 13, weight: .semibold))
                Text(model.sidecarStatusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(OpenTypeTheme.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                model.restartSidecarManually()
            } label: {
                Text(OpenTypeL10n.text("重启服务", english: "Restart service"))
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(13)
        .openTypeSurface(cornerRadius: 15)
    }
}

/// Small Home-tab warning shown when an append to the immutable audit trail
/// failed. The audit log is the app's local source of truth, so a write failure
/// must be visible rather than silently swallowed. Minimal by design — a single
/// static notice, cleared automatically on the next successful audit append.
private struct AuditWriteFailedCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)

            Text(OpenTypeL10n.text(
                "审计记录写入失败，历史可能不完整",
                english: "Audit log write failed — history may be incomplete"
            ))
            .font(.system(size: 11))
            .foregroundStyle(OpenTypeTheme.subtleText)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(11)
        .openTypeSurface(cornerRadius: 13)
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

            if let notice = model.lastDeliveryNotice {
                Text(notice)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button {
                    model.copyLastResult()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
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
    /// `HistoryStore` is its own `ObservableObject`; observing it (not just
    /// `model`) is what makes `entries` changes re-render this view — `model`
    /// never republishes when the store's `@Published entries` mutates.
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(spacing: 0) {
            UsageStatsPanel(summary: model.usageSummary)
                .padding(.horizontal, 16)
                .padding(.top, 13)

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
        // Recomputed from the audit trail on open rather than kept live: the
        // figures are a week's worth, so they never change while the user is
        // looking at them except by dictating — which is what the newest-entry
        // watch below catches.
        .onAppear { model.refreshUsageStats() }
        // Keyed on the newest entry's identity, not on `entries.count`:
        // `HistoryStore` caps at 100 and drops the oldest, so past that cap the
        // count never changes again and a count-watch would silently stop
        // refreshing for exactly the users who dictate most.
        .onChange(of: model.history.entries.first?.id) { _ in
            model.refreshUsageStats()
        }
    }
}

/// The local statistics panel (P2-12): one week of this app's own numbers,
/// computed by `UsageStats` from the audit trail that was already on disk.
///
/// It sits at the top of History rather than on Home or in Settings because it
/// is the same thing History already is — a look back at deliveries that have
/// happened — only aggregated. Home is the pre-flight surface (is the shortcut
/// live, which mode am I in, what did I just say), and putting a week's
/// retrospective above the mode picker would push the one control the user came
/// for further down. Settings is for things you change; nothing here is
/// changeable.
private struct UsageStatsPanel: View {
    let summary: UsageStats.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Text(OpenTypeL10n.text("最近 7 天", english: "Last 7 days"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text(OpenTypeL10n.text(
                    "\(summary.deliveries) 次交付",
                    english: "\(summary.deliveries) deliveries"
                ))
                .font(.system(size: 10))
                .foregroundStyle(OpenTypeTheme.subtleText)
            }

            HStack(alignment: .top, spacing: 0) {
                UsageStatsFigure(
                    value: "\(summary.wordsDictated)",
                    label: OpenTypeL10n.text("说出的字数", english: "Words dictated"),
                    note: OpenTypeL10n.text(
                        "中文按字、英文按词",
                        english: "CJK by character, Latin by word"
                    )
                )
                UsageStatsFigure(
                    value: Self.latencyText(summary.averageEndToEndLatency),
                    label: OpenTypeL10n.text("平均等待", english: "Average wait"),
                    note: OpenTypeL10n.text(
                        "松开快捷键到出字",
                        english: "Key release to delivered text"
                    )
                )
                // Named as a rate, and paired with the reason it is on the
                // panel at all: it is the number that should keep falling as
                // the entity dictionary learns what this user says (P0-1/P0-2).
                // A bare ratio would read as a static property of the app.
                UsageStatsFigure(
                    value: Self.rateText(summary),
                    label: OpenTypeL10n.text(
                        "每 100 字纠错",
                        english: "Corrections per 100 words"
                    ),
                    note: OpenTypeL10n.text(
                        "词典学得越多应越低",
                        english: "Should fall as the dictionary learns"
                    )
                )
            }

            Text(OpenTypeL10n.text(
                "全部由本机审计日志算出，不联网、不上传。中英混说时字数是两种单位的合计，适合和自己过去比，不适合跨语言比较。",
                english: """
                    Computed on this Mac from the local audit log — nothing is \
                    uploaded. For mixed Chinese/English speech the word total \
                    blends two units, so compare it with your own past numbers \
                    rather than across languages.
                    """
            ))
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openTypeSurface(cornerRadius: 14)
    }

    /// "—" for an absent measurement, never "0.0 秒": a week whose sessions all
    /// predate `ImmutableAuditEvent.recordingEndedAt` has nothing to report,
    /// and "0.0 秒" would read as "instant".
    private static func latencyText(_ latency: TimeInterval?) -> String {
        guard let latency else { return "—" }
        return OpenTypeL10n.text(
            String(format: "%.1f 秒", latency),
            english: String(format: "%.1fs", latency)
        )
    }

    /// "—" when the week has no denominator at all. `Summary` reports the rate
    /// as `0` in that case (nothing was dictated, so nothing was corrected),
    /// but "0.0" printed under 「每 100 字纠错」 next to 「0 字」 reads as a perfect
    /// score rather than as an empty week — the one reading the panel must not
    /// invite.
    private static func rateText(_ summary: UsageStats.Summary) -> String {
        guard summary.wordsDictated > 0 else { return "—" }
        return String(format: "%.1f", summary.correctionsPerHundredWords)
    }
}

private struct UsageStatsFigure: View {
    let value: String
    let label: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10.5))
                // Three columns share a 420pt-minimum window, so 「Corrections
                // per 100 words」 has to wrap rather than truncate — a metric
                // labelled 「Corrections per 100…」 is a metric nobody can read.
                .fixedSize(horizontal: false, vertical: true)
            Text(note)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                                        isFocused: model.focusedAgentRunID == run.id,
                                        onStop: { model.cancelAgentRun(run.id) }
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
/// look (`OverlayController.swift`'s voice-surface card) rather than inventing a
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

/// One message in a Q&A/Agent thread. Assistant messages render as Markdown
/// (`AssistantMarkdownView`) — Ask answers and Agent results come back
/// GitHub-flavored, so a bare `Text` showed raw `##`/`|`/``` ``` `` noise. The
/// user's own turn stays a plain `Text`: it is transcribed speech, not
/// Markdown, and parsing it would mangle stray `*`/`#` characters.
private struct ConversationBubble: View {
    let message: ConversationMessageSummary

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 36) }

            Group {
                if isUser {
                    Text(message.content)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    AssistantMarkdownView(markdown: message.content, fontSize: 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
                    if configuration.automaticallyInsert {
                        Toggle(
                            "写入成功后保留原剪贴板内容",
                            isOn: $configuration.retainClipboardAfterInsert
                        )
                    }
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
                    Text("所有模式的结果都会复制到剪贴板，由你手动粘贴，不会自动发送或执行。")
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

                    Text("中英夹杂或一段音频包含多种语言时，请使用“自动识别”；单一语言可明确选择，以提高实时字幕预览的准确率。最终识别默认使用本机 MLX-Whisper，可在下方“语音识别”中切换为远程。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(OpenTypeL10n.text("语音识别", english: "Speech Recognition")) {
                    WhisperSetupContent(model: model)
                }

                SettingsSection(OpenTypeL10n.text("AI 模型", english: "AI Model Provider")) {
                    LLMProviderSetupContent(model: model)
                }

                SettingsSection(OpenTypeL10n.text("MCP 服务器", english: "MCP Servers")) {
                    McpServerPanelView(model: model)
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

                Text("实时字幕优先使用 Apple 本机识别，仅作为录音预览；最终识别与文字生成均由本地 sidecar 处理。默认使用本机 MLX-Whisper 与内置模型，无需额外配置即可使用；也可在上方「语音识别」「AI 模型」中改用自定义的服务商。")
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

/// The sidecar memory system's management surface (memory design doc §4.1,
/// made editable by P0-4): the entity dictionary (`GET /memory/terms`, plus
/// `POST`/`PUT`/`DELETE /memory/terms`), the free-text owner facts
/// (`GET`/`DELETE /memory/owner-facts`), and the consolidation run log
/// (`GET /memory/consolidation-runs`). Every row shows its `origin`, because
/// an `untrusted` entry — one the agent wrote from possibly-hostile context
/// (P1-12) — is exactly what a user comes here to find and delete.
private struct MemoryPanelView: View {
    @ObservedObject var model: AppModel
    @State private var newCanonicalTerm = ""
    @State private var newAliases = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(OpenTypeL10n.text(
                "本地记忆服务记录的实体词典、关于你的记忆条目与最近的整理记录。词条可以直接在这里增删改；改动立即生效，会影响后续识别与纠错。",
                english: "Entity dictionary, remembered facts, and recent consolidation runs from the local memory service. Terms are editable here, and edits take effect immediately for later recognition and correction."
            ))
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let error = model.memoryEditError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(
                    OpenTypeL10n.text("实体词典", english: "Entity Terms"),
                    systemImage: "text.book.closed"
                )
                .font(.system(size: 10.5, weight: .semibold))

                HStack(spacing: 6) {
                    TextField(
                        OpenTypeL10n.text("词条", english: "Term"),
                        text: $newCanonicalTerm
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))

                    TextField(
                        OpenTypeL10n.text("别名，用逗号分隔", english: "Aliases, comma-separated"),
                        text: $newAliases
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))

                    Button(OpenTypeL10n.text("添加", english: "Add")) {
                        addTerm()
                    }
                    .controlSize(.small)
                    .disabled(newCanonicalTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if model.memoryTerms.isEmpty {
                    Text(OpenTypeL10n.text("暂无记录", english: "No entries yet"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.memoryTerms) { term in
                        MemoryTermRow(model: model, term: term)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label(
                    OpenTypeL10n.text("关于你的记忆", english: "Remembered Facts"),
                    systemImage: "person.text.rectangle"
                )
                .font(.system(size: 10.5, weight: .semibold))

                if model.memoryOwnerFacts.isEmpty {
                    Text(OpenTypeL10n.text("暂无记录", english: "No entries yet"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.memoryOwnerFacts) { fact in
                        MemoryOwnerFactRow(model: model, fact: fact)
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

    private func addTerm() {
        let canonical = newCanonicalTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return }
        let aliases = MemoryTermRow.parseAliases(newAliases)
        Task {
            if await model.createMemoryTerm(canonicalTerm: canonical, aliases: aliases) {
                newCanonicalTerm = ""
                newAliases = ""
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// One entity-dictionary row: a compact read view that flips in place into an
/// editor (canonical term, aliases, confidence) plus a delete. Edit state is
/// local to the row and seeded from `term` at the moment editing starts, so a
/// background refresh of the list can't rewrite half-typed input.
private struct MemoryTermRow: View {
    @ObservedObject var model: AppModel
    let term: EntityTermSummary

    @State private var isEditing = false
    @State private var draftCanonicalTerm = ""
    @State private var draftAliases = ""
    @State private var draftConfidence = 1.0
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isEditing {
                editor
            } else {
                readOnlyRow
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.028),
            in: RoundedRectangle(cornerRadius: 8)
        )
        // Deleting a term is irreversible — `DELETE /memory/terms/:id` drops the
        // row and this app has no undo for it — so it gets the same confirm
        // step Settings puts in front of a history reset.
        .confirmationDialog(
            OpenTypeL10n.text(
                "删除词条「\(term.canonicalTerm)」？",
                english: "Delete the term “\(term.canonicalTerm)”?"
            ),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(OpenTypeL10n.text("确认删除", english: "Delete"), role: .destructive) {
                Task { await model.deleteMemoryTerm(id: term.id) }
            }
            Button(OpenTypeL10n.text("取消", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(OpenTypeL10n.text(
                "此操作不可撤销。删除后这个词条不再参与识别偏置与纠错替换。",
                english: "This cannot be undone. The term will stop biasing recognition and stop being applied as a correction."
            ))
        }
    }

    private var readOnlyRow: some View {
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
                Button {
                    beginEditing()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(OpenTypeL10n.text("编辑这个词条", english: "Edit this term"))
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(OpenTypeL10n.text("删除这个词条", english: "Delete this term"))
            }
            if !term.aliases.isEmpty {
                Text(term.aliases.joined(separator: " · "))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            MemoryOriginBadge(origin: term.origin)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(
                OpenTypeL10n.text("词条", english: "Term"),
                text: $draftCanonicalTerm
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10))

            TextField(
                OpenTypeL10n.text("别名，用逗号分隔", english: "Aliases, comma-separated"),
                text: $draftAliases
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10))

            HStack(spacing: 6) {
                Text(OpenTypeL10n.text("置信度", english: "Confidence"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                // A slider rather than a text field: confidence is 0..1 on the
                // sidecar side, and anything outside that is a 400 — so the
                // control simply cannot express an invalid value.
                Slider(value: $draftConfidence, in: 0...1)
                Text(String(format: "%.0f%%", draftConfidence * 100))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Spacer()
                Button(OpenTypeL10n.text("取消", english: "Cancel")) {
                    isEditing = false
                }
                .controlSize(.small)
                Button(OpenTypeL10n.text("保存", english: "Save")) {
                    save()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(draftCanonicalTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func beginEditing() {
        draftCanonicalTerm = term.canonicalTerm
        draftAliases = term.aliases.joined(separator: ", ")
        draftConfidence = term.confidence
        isEditing = true
    }

    private func save() {
        let canonical = draftCanonicalTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return }
        let aliases = Self.parseAliases(draftAliases)
        let confidence = draftConfidence
        Task {
            if await model.updateMemoryTerm(
                id: term.id,
                canonicalTerm: canonical,
                aliases: aliases,
                confidence: confidence
            ) {
                isEditing = false
            }
        }
    }

    /// Splits the comma-separated alias field. Accepts the full-width comma
    /// too — the aliases people type here are frequently Chinese, and a
    /// Chinese keyboard produces "，" without the user thinking about it.
    static func parseAliases(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// One free-text owner fact: its content, its provenance badge, and a delete.
/// Facts have no edit affordance — they are arbitrary prose rather than a
/// canonical-name-plus-aliases shape, and `owner_facts` has no update endpoint;
/// the operation a user actually needs here is removing a fact the agent
/// planted (P1-12), which delete covers.
private struct MemoryOwnerFactRow: View {
    @ObservedObject var model: AppModel
    let fact: OwnerFactSummary

    @State private var showingDeleteConfirmation = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(fact.content)
                    .font(.system(size: 9.5))
                    .fixedSize(horizontal: false, vertical: true)
                MemoryOriginBadge(origin: fact.origin)
            }
            Spacer(minLength: 6)
            Button {
                showingDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(OpenTypeL10n.text("删除这条记忆", english: "Delete this fact"))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.028),
            in: RoundedRectangle(cornerRadius: 8)
        )
        // Same irreversible-delete guard as `MemoryTermRow`.
        .confirmationDialog(
            OpenTypeL10n.text("删除这条记忆？", english: "Delete this fact?"),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(OpenTypeL10n.text("确认删除", english: "Delete"), role: .destructive) {
                Task { await model.deleteMemoryOwnerFact(id: fact.id) }
            }
            Button(OpenTypeL10n.text("取消", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(OpenTypeL10n.text(
                "此操作不可撤销。删除后助理不会再把这条记忆带进上下文。",
                english: "This cannot be undone. The assistant will stop carrying this fact into its context."
            ))
        }
    }
}

/// Provenance badge for a memory row. `owner` means the user vouched for it in
/// person; `untrusted` means it came out of the agent loop, where content can
/// originate from hostile context (P1-12) — which is why it is drawn in orange
/// rather than as one more grey label.
private struct MemoryOriginBadge: View {
    let origin: String?

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(origin == "untrusted" ? Color.orange : Color.secondary)
    }

    private var title: String {
        switch origin {
        case "owner":
            return OpenTypeL10n.text("你确认过", english: "Confirmed by you")
        case "untrusted":
            return OpenTypeL10n.text("未经确认", english: "Unverified")
        case "agent":
            return OpenTypeL10n.text("助理写入", english: "Written by the agent")
        case "system":
            return OpenTypeL10n.text("自动整理", english: "Auto-consolidated")
        default:
            return OpenTypeL10n.text("来源未知", english: "Unknown source")
        }
    }

    private var symbol: String {
        switch origin {
        case "owner":
            return "checkmark.seal"
        case "untrusted":
            return "exclamationmark.triangle"
        case "agent":
            return "sparkles"
        case "system":
            return "gearshape"
        default:
            return "questionmark.circle"
        }
    }
}

// MARK: - MCP servers (P2-13)

/// Settings' "MCP 服务器" panel: add, edit, remove and test the MCP servers the
/// agent gets its extra tools from (`sidecar/src/agent/mcpConfigRoutes.ts`,
/// via `AppModel`'s "MCP server configuration" section). Until this panel
/// existed, `OPENTYPE_MCP_SERVERS` was the only way in and a packaged `.app`
/// user has no way to set an env var.
///
/// **Secrets never round-trip through an editable field.** The sidecar answers
/// with `envMasked`/`headersMasked` only, so a real token never reaches Swift;
/// an already-saved secret therefore renders as its mask in *static* text with
/// a "已保存" tag, never inside a `TextField`/`SecureField` a user could be led
/// to believe holds the real value. Replacing one is an explicit action
/// (`McpSecretRow`'s "更换"), and it starts from an empty field. See
/// `McpServerEditor.request()` for the submit side.
private struct McpServerPanelView: View {
    @ObservedObject var model: AppModel

    /// Whether the "add a server" form is open. Held here rather than inside
    /// the editor so closing it discards the whole draft, secrets included,
    /// instead of leaving typed values parked in a hidden view's state.
    @State private var isAddingServer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(OpenTypeL10n.text(
                "MCP 服务器给 Agent 增加工具。连接是在后台服务启动时建立的，所以这里的改动要重启 OpenType 才生效；保存前先「测试连接」，一个连不上的服务器会拖慢、甚至卡住下次启动。",
                english: "MCP servers give Agent mode extra tools. Connections are made when the background service starts, so changes here apply after you restart OpenType — and use Test Connection before saving, since a server that can't be reached slows the next startup down, or stalls it."
            ))
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // The honest sentence. Anyone adding a server from a half-read
            // README needs to know what the grant actually is before they paste
            // a command in, so it sits above the list, not in a tooltip.
            Label(
                OpenTypeL10n.text(
                    "这些工具和内置工具一样，直接在你的电脑上运行，没有沙箱；除少数已知的破坏性 shell 命令会先弹窗确认外，它们做的事不会再经过你同意。只添加你自己信任的服务器。",
                    english: "Those tools run directly on your Mac with no sandbox, exactly like the built-in ones — and apart from a few named destructive shell commands that ask first, what they do is not confirmed with you. Only add servers you trust."
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 9.5))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)

            if let error = model.mcpEditError {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let config = model.mcpConfig {
                if config.source == .env && !config.servers.isEmpty {
                    Text(OpenTypeL10n.text(
                        "下面的服务器来自 OPENTYPE_MCP_SERVERS 环境变量（开发用的回退），不是你保存的配置，所以不能在这里改。一旦你在这里保存了任何服务器，就只使用你保存的列表，环境变量里的不再生效。",
                        english: "The servers below come from the OPENTYPE_MCP_SERVERS environment variable — a dev fallback, not your saved config, so they aren't editable here. Once you save any server here, only your saved list is used and the environment variable stops applying."
                    ))
                    .font(.system(size: 8.8))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if config.servers.isEmpty {
                    Text(OpenTypeL10n.text("还没有配置 MCP 服务器", english: "No MCP servers configured yet"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(config.servers) { server in
                        McpServerRow(
                            model: model,
                            server: server,
                            isEditable: config.source == .saved
                        )
                    }
                }
            } else {
                Text(OpenTypeL10n.text("正在读取…", english: "Loading…"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            if isAddingServer {
                McpServerEditor(
                    model: model,
                    existing: nil,
                    onDone: { isAddingServer = false },
                    onCancel: { isAddingServer = false }
                )
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.primary.opacity(0.028),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            } else {
                Button(OpenTypeL10n.text("添加服务器", english: "Add a server")) {
                    isAddingServer = true
                }
                .controlSize(.small)
            }
        }
        .task {
            await model.refreshMcpServers()
        }
    }
}

/// One configured server: a compact read view that flips in place into
/// `McpServerEditor`, plus a confirmed delete. Env-sourced rows
/// (`isEditable == false`) show the same information with no actions — they
/// live in an environment variable, not in the store the routes address, so a
/// `PUT`/`DELETE` against them would 404.
private struct McpServerRow: View {
    @ObservedObject var model: AppModel
    let server: McpServerSummary
    let isEditable: Bool

    @State private var isEditing = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isEditing {
                McpServerEditor(
                    model: model,
                    existing: server,
                    onDone: { isEditing = false },
                    onCancel: { isEditing = false }
                )
            } else {
                readOnlyRow
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.028),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .confirmationDialog(
            OpenTypeL10n.text(
                "删除 MCP 服务器「\(server.name)」？",
                english: "Delete the MCP server “\(server.name)”?"
            ),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(OpenTypeL10n.text("确认删除", english: "Delete"), role: .destructive) {
                Task { await model.deleteMcpServer(name: server.name) }
            }
            Button(OpenTypeL10n.text("取消", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(OpenTypeL10n.text(
                "Agent 将不再获得这个服务器提供的工具。保存的密钥也会一并删除。",
                english: "Agent mode will stop getting this server's tools. Its saved secrets are deleted too."
            ))
        }
    }

    private var readOnlyRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(server.name)
                    .font(.system(size: 10.5, weight: .medium))
                Text(server.transport.title)
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                if isEditable {
                    Button {
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(OpenTypeL10n.text("编辑这个服务器", english: "Edit this server"))

                    Button {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(OpenTypeL10n.text("删除这个服务器", english: "Delete this server"))
                } else {
                    Label(
                        OpenTypeL10n.text("来自环境变量", english: "From environment"),
                        systemImage: "terminal"
                    )
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                }
            }

            Text(endpointDescription)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !secretKeys.isEmpty {
                Text(OpenTypeL10n.text(
                    "已保存密钥：\(secretKeys.joined(separator: "、"))",
                    english: "Saved secrets: \(secretKeys.joined(separator: ", "))"
                ))
                .font(.system(size: 8.8))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var endpointDescription: String {
        switch server.transport {
        case .stdio:
            return ([server.command ?? ""] + (server.args ?? []))
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .http:
            return server.url ?? ""
        }
    }

    /// Key names only — the panel shows *that* a secret is set, never its
    /// value, not even masked, at this zoom level.
    private var secretKeys: [String] {
        let map = server.transport == .stdio ? server.envMasked : server.headersMasked
        return (map ?? [:]).keys.sorted()
    }
}

/// One `env`/`headers` entry while it is being edited.
///
/// The two cases are the whole point of this type: a `.stored` entry is a
/// secret that lives sidecar-side and reached Swift only as a mask, and a
/// `.typed` entry is a value the user actually entered in this session. They
/// render differently (static text vs. a `SecureField`) and submit differently
/// (the mask, which the sidecar resolves back to the stored secret, vs. the
/// literal text), so the distinction can't be collapsed into a plain string.
private struct McpSecretEntry: Identifiable, Equatable {
    enum Value: Equatable {
        /// Already saved sidecar-side; `mask` is all Swift ever sees of it.
        case stored(mask: String)
        /// Entered by the user in this editing session.
        case typed(String)
    }

    let id = UUID()
    var key: String
    var value: Value

    var isStored: Bool {
        if case .stored = value { return true }
        return false
    }

    /// What goes into the request. For a `.stored` entry this is the mask, and
    /// sending it verbatim is exactly how the sidecar is told "unchanged" —
    /// it resolves a value equal to the stored mask, for that same server and
    /// that same key, back to the stored secret.
    var submittedValue: String {
        switch value {
        case .stored(let mask): return mask
        case .typed(let text): return text
        }
    }
}

/// The add/edit form, used for both (`existing == nil` is a create).
///
/// Masking rules, which are the security-relevant part of this view:
///
///  1. A stored secret is seeded as `.stored(mask:)` and rendered as static
///     text with a "已保存" tag. It is never placed in an editable field, so no
///     edit to an unrelated field can carry a mask into a value the user
///     believes is real.
///  2. Its *key* is not editable either. The sidecar resolves masks per key, so
///     renaming a key while keeping its mask would store the mask itself as
///     that key's literal value — the exact bug rule 1 avoids, one level up.
///     Changing a key means replacing the entry.
///  3. "更换" starts from an empty `SecureField`, never from the mask.
///  4. A `.typed` entry that is left half-filled blocks Save with a stated
///     reason, rather than silently writing an empty secret or dropping the row.
///  5. Only the active transport's map is submitted, and the editor closes on a
///     successful save. Together those keep every `.stored` mask matched to a
///     secret the sidecar still holds under that same key.
private struct McpServerEditor: View {
    @ObservedObject var model: AppModel
    /// `nil` when adding a server.
    let existing: McpServerSummary?
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var transport: McpTransport = .stdio
    @State private var command = ""
    @State private var argsText = ""
    @State private var url = ""
    @State private var envEntries: [McpSecretEntry] = []
    @State private var headerEntries: [McpSecretEntry] = []
    @State private var testResult: McpTestResultSummary?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var didSeed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                OpenTypeL10n.text("名称（字母、数字、_ 或 -）", english: "Name (letters, digits, _ or -)"),
                text: $name
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10))

            Picker(
                OpenTypeL10n.text("连接方式", english: "Transport"),
                selection: $transport
            ) {
                ForEach(McpTransport.allCases) { candidate in
                    Text(candidate.title).tag(candidate)
                }
            }
            .pickerStyle(.segmented)

            if transport == .stdio {
                TextField(
                    OpenTypeL10n.text("命令，例如 npx", english: "Command, e.g. npx"),
                    text: $command
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(OpenTypeL10n.text("参数（每行一个）", english: "Arguments (one per line)"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $argsText)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
                        )
                }

                McpSecretEntryList(
                    title: OpenTypeL10n.text("环境变量", english: "Environment variables"),
                    entries: $envEntries
                )
            } else {
                TextField(
                    "URL",
                    text: $url,
                    prompt: Text("https://mcp.example.com/mcp")
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10))

                McpSecretEntryList(
                    title: OpenTypeL10n.text("请求头", english: "Headers"),
                    entries: $headerEntries
                )
            }

            if let blocker = saveBlocker {
                Label(blocker, systemImage: "exclamationmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(isTesting
                    ? OpenTypeL10n.text("测试中…", english: "Testing…")
                    : OpenTypeL10n.text("测试连接", english: "Test Connection")
                ) {
                    test()
                }
                .controlSize(.small)
                .disabled(saveBlocker != nil || isTesting || isSaving || renameBlocksTest)

                Button(isSaving
                    ? OpenTypeL10n.text("保存中…", english: "Saving…")
                    : OpenTypeL10n.text("保存", english: "Save")
                ) {
                    save()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(saveBlocker != nil || isSaving)

                Button(OpenTypeL10n.text("取消", english: "Cancel")) {
                    onCancel()
                }
                .controlSize(.small)
                .disabled(isSaving)
            }

            if renameBlocksTest {
                Text(OpenTypeL10n.text(
                    "改名后请先保存，再测试连接：已保存的密钥是按原来的名字存的。",
                    english: "Save the rename first, then test: the saved secrets are stored under the old name."
                ))
                .font(.system(size: 8.8))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else if hasStoredSecret {
                Text(OpenTypeL10n.text(
                    "「测试连接」会把已保存的密钥发送到上面填写的地址／命令。",
                    english: "Test Connection sends the saved secrets to whatever address/command is entered above."
                ))
                .font(.system(size: 8.8))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let testResult {
                McpTestResultView(result: testResult)
            }
        }
        .task {
            guard !didSeed else { return }
            didSeed = true
            seed()
        }
    }

    // MARK: Seeding

    /// Populates the form from `existing`. Secrets are seeded as their masks in
    /// `.stored` state — see the type's doc comment for why that is not the
    /// same thing as putting a mask in a field.
    private func seed() {
        guard let existing else {
            transport = .stdio
            return
        }
        name = existing.name
        transport = existing.transport
        command = existing.command ?? ""
        argsText = (existing.args ?? []).joined(separator: "\n")
        url = existing.url ?? ""
        envEntries = Self.entries(from: existing.envMasked)
        headerEntries = Self.entries(from: existing.headersMasked)
    }

    private static func entries(from masked: [String: String]?) -> [McpSecretEntry] {
        (masked ?? [:]).keys.sorted().map { key in
            McpSecretEntry(key: key, value: .stored(mask: masked?[key] ?? ""))
        }
    }

    // MARK: Validation

    private var activeEntries: [McpSecretEntry] {
        transport == .stdio ? envEntries : headerEntries
    }

    private var hasStoredSecret: Bool {
        activeEntries.contains(where: \.isStored)
    }

    /// Testing a renamed server would submit masks the sidecar can't resolve
    /// (it looks the stored record up by the *submitted* name), so they'd be
    /// probed as literal credentials and fail for a reason that has nothing to
    /// do with the user's config. Blocked with a stated reason instead.
    private var renameBlocksTest: Bool {
        guard let existing else { return false }
        return hasStoredSecret && name.trimmingCharacters(in: .whitespaces) != existing.name
    }

    /// Why Save is disabled, or `nil` when it isn't. Stated to the user rather
    /// than left as a mysteriously grey button.
    private var saveBlocker: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            return OpenTypeL10n.text("请填写名称", english: "Enter a name")
        }
        if transport == .stdio {
            if command.trimmingCharacters(in: .whitespaces).isEmpty {
                return OpenTypeL10n.text("请填写命令", english: "Enter a command")
            }
        } else if url.trimmingCharacters(in: .whitespaces).isEmpty {
            return OpenTypeL10n.text("请填写 URL", english: "Enter a URL")
        }

        let entries = activeEntries
        if entries.contains(where: { $0.key.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return OpenTypeL10n.text("有一行还没填名字", english: "One row has no name yet")
        }
        // An empty replacement would be written as an empty secret — almost
        // always someone who pressed 更换 and then didn't type. Say so instead.
        if entries.contains(where: { entry in
            if case .typed(let text) = entry.value { return text.isEmpty }
            return false
        }) {
            return OpenTypeL10n.text("有一项的值还没填", english: "One value is still empty")
        }
        let keys = entries.map { $0.key.trimmingCharacters(in: .whitespaces) }
        if Set(keys).count != keys.count {
            return OpenTypeL10n.text("有重复的名字", english: "Two rows share a name")
        }
        return nil
    }

    // MARK: Submission

    /// Builds the request. Only the active transport's map is sent, and the
    /// inactive one is left out entirely (`nil`, i.e. omitted from the JSON)
    /// rather than sent empty — the sidecar drops the other half anyway, and a
    /// mask from the *other* map has no stored counterpart under this one, so
    /// carrying it across is precisely how a mask would end up saved as a
    /// literal value.
    private func request() -> McpServerRequest {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var map: [String: String] = [:]
        for entry in activeEntries {
            map[entry.key.trimmingCharacters(in: .whitespaces)] = entry.submittedValue
        }
        if transport == .stdio {
            let args = argsText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return McpServerRequest(
                name: trimmedName,
                transport: .stdio,
                command: command.trimmingCharacters(in: .whitespaces),
                args: args,
                env: map,
                url: nil,
                headers: nil
            )
        }
        return McpServerRequest(
            name: trimmedName,
            transport: .http,
            command: nil,
            args: nil,
            env: nil,
            url: url.trimmingCharacters(in: .whitespaces),
            headers: map
        )
    }

    private func test() {
        isTesting = true
        testResult = nil
        let candidate = request()
        Task { @MainActor in
            testResult = await model.testMcpServer(candidate)
            isTesting = false
        }
    }

    private func save() {
        isSaving = true
        let candidate = request()
        Task { @MainActor in
            let ok: Bool
            if let existing {
                ok = await model.updateMcpServer(name: existing.name, candidate)
            } else {
                ok = await model.createMcpServer(candidate)
            }
            isSaving = false
            if ok {
                // Close on success so the next edit re-seeds from what the
                // sidecar now actually stores. A form kept open across a save
                // could still hold `.stored` masks for secrets that write just
                // dropped (a transport switch clears the other half), and those
                // masks would then save as literal values.
                onDone()
            }
        }
    }
}

/// The `env`/`headers` editor: existing secrets as static masked rows, new ones
/// as key + `SecureField` pairs.
private struct McpSecretEntryList: View {
    let title: String
    @Binding var entries: [McpSecretEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(OpenTypeL10n.text("添加一项", english: "Add")) {
                    entries.append(McpSecretEntry(key: "", value: .typed("")))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            ForEach($entries) { $entry in
                McpSecretRow(entry: $entry) {
                    entries.removeAll { $0.id == entry.id }
                }
            }
        }
    }
}

private struct McpSecretRow: View {
    @Binding var entry: McpSecretEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch entry.value {
            case .stored(let mask):
                // Static text, not a field: this is a mask, and it must never
                // sit somewhere that reads as "the real value, editable".
                // The key is static too — the sidecar matches masks per key, so
                // a renamed key would save the mask itself as its value.
                Text(entry.key)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                Text(mask)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Text(OpenTypeL10n.text("已保存", english: "Saved"))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.green)
                    .help(OpenTypeL10n.text(
                        "已保存的密钥不会回传，这里显示的是掩码。保存时保持不变。",
                        english: "Saved secrets are never sent back; this is a mask. Saving leaves the stored value untouched."
                    ))
                Spacer()
                Button(OpenTypeL10n.text("更换", english: "Replace")) {
                    // Deliberately empty, never seeded from the mask.
                    entry.value = .typed("")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

            case .typed:
                TextField(
                    OpenTypeL10n.text("名称", english: "Name"),
                    text: $entry.key
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10))
                .frame(maxWidth: 130)

                SecureField(
                    OpenTypeL10n.text("值", english: "Value"),
                    text: Binding(
                        get: {
                            if case .typed(let text) = entry.value { return text }
                            return ""
                        },
                        set: { entry.value = .typed($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10))
            }

            Button {
                onDelete()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(OpenTypeL10n.text("删除这一项", english: "Remove this entry"))
        }
    }
}

/// The Test Connection outcome. The tool list is the decision-relevant part —
/// it is literally the set of unsandboxed capabilities this server would hand
/// the agent — so it is shown in full rather than summarized as a count.
private struct McpTestResultView: View {
    let result: McpTestResultSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if result.success {
                Label(
                    OpenTypeL10n.text("连接成功", english: "Connected"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 9.5))
                .foregroundStyle(.green)

                let tools = result.tools ?? []
                if tools.isEmpty {
                    Text(OpenTypeL10n.text(
                        "这个服务器没有提供任何工具。",
                        english: "This server exposes no tools."
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                } else {
                    Text(OpenTypeL10n.text(
                        "Agent 将获得以下 \(tools.count) 个工具：",
                        english: "Agent mode would get these \(tools.count) tools:"
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                    ForEach(tools) { tool in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.name)
                                .font(.system(size: 9, design: .monospaced))
                            if let description = tool.description, !description.isEmpty {
                                Text(description)
                                    .font(.system(size: 8.8))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Label(
                    result.error ?? OpenTypeL10n.text("连接失败", english: "Connection failed"),
                    systemImage: "xmark.circle.fill"
                )
                .font(.system(size: 9.5))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
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
    /// Invoked by the row's stop control while the run is still `.running`.
    let onStop: () -> Void
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
                    Spacer(minLength: 4)
                    // The BACKSTOP stop control (T1). The voice surface is
                    // transient -- a new recording, a mode switch, or a newer
                    // dispatch all hide it -- so a stop button that lives only
                    // there disappears exactly when a long run is most likely
                    // to need stopping. This row is also the only place to
                    // reach a run that is no longer the most recent one.
                    Button(OpenTypeL10n.text("停止", english: "Stop")) {
                        onStop()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(Color.accentColor)
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
            case .cancelled(let message):
                Text(message)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
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
            case .cancelled:
                // Not red: the user stopping their own run is a normal
                // outcome, not an error to alarm them about.
                return (
                    OpenTypeL10n.text("已停止", english: "Stopped"),
                    "stop.circle.fill",
                    .secondary
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
