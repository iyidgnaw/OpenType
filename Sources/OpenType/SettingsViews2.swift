import AppKit
import SwiftUI

// The redesigned 设置 screen (2026-08 handoff §5, mockup 03C).
//
// The old Settings tab was nine stacked sections in a 420pt column, and three
// of them — provider setup, MCP, memory — were full configuration surfaces
// inlined into a list. That is why it had a `DisclosureGroup`: there was
// nowhere else to put anything, so everything was on one page and the
// dangerous parts had to be hidden behind a twisty.
//
// This splits it in two. `SettingsColumn` is five groups of short rows, laid
// out in two columns when there is room; anything that needs a form of its own
// becomes a row with a `chevron.right` that pushes a page into the detail
// column (`SettingsDetailColumn`). The two provider rows carry the answer to
// the question people actually open Settings for — *what is it using right
// now?* — in mono on the row itself, so the common case needs no click at all.
//
// Every value here comes from `DS`. The handoff's own verification step is
// "did a fifth radius or a seventh font size appear on this screen", and the
// only way to keep answering no is to never write a literal.

// MARK: - The settings list

/// 设置's list column: five groups, two columns when the column is wide
/// enough for them.
///
/// The two-column threshold is measured rather than passed in because this
/// view is used in both shell slots — it reads as one page when it owns the
/// content area (the mockup's 908pt case) and degrades to a single scrolling
/// column when it is the 334pt list beside a pushed sub-page. Neither layout
/// changes a row's own metrics; only the page padding moves, exactly as the
/// handoff specifies for every other screen.
struct SettingsColumn: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configuration: AppConfiguration
    @ObservedObject var agentMemory: AgentMemoryStore

    /// Line count of `audit-events.v1.jsonl`, for the 审计记录 row. `nil`
    /// until the first read finishes — the row prints nothing rather than a
    /// wrong `0`, the same rule the stats band uses for missing figures.
    @State private var auditEventCount: Int?

    init(model: AppModel) {
        self.model = model
        configuration = model.configuration
        agentMemory = model.agentMemory
    }

    /// Below this the five groups stack into one column. It is not the
    /// window's narrow breakpoint: two 300pt-ish columns plus the gutter need
    /// more than a 334pt list column can give regardless of how wide the
    /// window is.
    private let twoColumnWidth: CGFloat = 620

    var body: some View {
        GeometryReader { proxy in
            let twoColumn = proxy.size.width >= twoColumnWidth
            let pagePadding = twoColumn ? DS.Space.pageWide : DS.Space.pageNarrow

            VStack(spacing: 0) {
                ColumnHeader(narrow: !twoColumn) {
                    Text(OpenTypeL10n.text("设置", english: "Settings"))
                        .font(DS.Text.title())
                        .tracking(DS.Tracking.title)
                    Spacer(minLength: 0)
                }

                ScrollView {
                    if twoColumn {
                        HStack(alignment: .top, spacing: DS.Space.group) {
                            VStack(alignment: .leading, spacing: DS.Space.group) {
                                shortcutGroup
                                dictationOutputGroup
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(alignment: .leading, spacing: DS.Space.group) {
                                engineGroup
                                permissionsGroup
                                dataGroup
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, pagePadding)
                        .padding(.bottom, pagePadding)
                    } else {
                        VStack(alignment: .leading, spacing: DS.Space.group) {
                            shortcutGroup
                            dictationOutputGroup
                            engineGroup
                            permissionsGroup
                            dataGroup
                        }
                        .padding(.horizontal, pagePadding)
                        .padding(.bottom, pagePadding)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(DS.Colour.canvas)
        .task {
            auditEventCount = await auditEventCountFromDisk()
            await model.refreshWhisperConfigSummary()
            await model.refreshLLMConfigSummary()
        }
    }

    // MARK: 快捷键

    private var shortcutGroup: some View {
        SettingsGroup(OpenTypeL10n.text("快捷键", english: "Shortcut")) {
            SettingsRow(
                divided: false,
                title: OpenTypeL10n.text("启动方式", english: "Trigger"),
                subtitle: configuration.hotKeyPreset.note
            ) {
                Menu {
                    ForEach(HotKeyPreset.allCases) { preset in
                        Button(preset.title) { model.changeHotKey(preset) }
                    }
                } label: {
                    ControlChip(
                        text: configuration.hotKeyPreset.title,
                        mono: true
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            // Only when something is wrong. A permanently-present "it works"
            // line is the kind of reassurance that stops being read, and the
            // handoff reserves colour for things that want an action.
            if !shortcutHealthy {
                SettingsRow(
                    title: model.shortcutStatus,
                    subtitle: model.accessibilityGranted
                        ? nil
                        : OpenTypeL10n.text(
                            "开启辅助功能后可使用双击触发，并用任意键结束。",
                            english: "With Accessibility granted, double-tap triggers work and any key can stop a recording."
                        ),
                    tinted: true
                ) {
                    if !model.accessibilityGranted {
                        SmallButton(OpenTypeL10n.text("授权", english: "Grant")) {
                            model.requestAccessibility()
                        }
                    }
                }
            }

            SettingsRow(
                title: OpenTypeL10n.text("录音中切换模式", english: "Switch mode while recording")
            ) {
                Text(verbatim: "Tab")
                    .font(DS.Text.mono(12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shortcutHealthy: Bool {
        model.shortcutReady && model.preferredShortcutActive
    }

    // MARK: 听写输出

    private var dictationOutputGroup: some View {
        SettingsGroup(OpenTypeL10n.text("听写输出", english: "Dictation output")) {
            // The one row that is a stacked control rather than a trailing
            // one: three named destinations do not fit in a trailing slot, and
            // this is the setting that decides what the app does with your
            // voice, so it gets the width.
            SettingsStackedRow(
                divided: false,
                title: OpenTypeL10n.text("松开之后", english: "On release"),
                note: OpenTypeL10n.text(
                    "三档都不经过 AI 模型 —— 轻整理只按固定规则去口癖和标点。",
                    english: "None of the three involves an AI model — Tidy only applies fixed rules to fillers and punctuation."
                )
            ) {
                SegmentedControl(
                    options: TranscribeVariant.allCases,
                    selection: configuration.transcribeVariant,
                    title: { $0.releaseTitle },
                    help: { $0.explanation },
                    select: { model.changeTranscribeVariant($0) }
                )
            }

            SettingsRow(
                title: OpenTypeL10n.text("自动写入当前输入框", english: "Insert into the focused field"),
                subtitle: OpenTypeL10n.text(
                    "结果始终会复制到剪贴板",
                    english: "The result is always copied to the clipboard"
                )
            ) {
                SettingsSwitch(isOn: $configuration.automaticallyInsert)
                    .accessibilityLabel(
                        OpenTypeL10n.text("自动写入当前输入框", english: "Insert into the focused field")
                    )
            }

            // Shown even when auto-insert is off, dimmed. The old Settings
            // hid it, which made the row above jump the list around every
            // time it was toggled — and hiding a setting is how a user comes
            // to believe it was removed.
            SettingsRow(
                title: OpenTypeL10n.text("写入后恢复原剪贴板", english: "Restore the clipboard after inserting")
            ) {
                SettingsSwitch(isOn: $configuration.retainClipboardAfterInsert)
                    .accessibilityLabel(
                        OpenTypeL10n.text("写入后恢复原剪贴板", english: "Restore the clipboard after inserting")
                    )
            }
            .disabled(!configuration.automaticallyInsert)

            SettingsRow(
                title: OpenTypeL10n.text("录音时显示实时字幕", english: "Live captions while recording")
            ) {
                SettingsSwitch(isOn: $configuration.liveCaptionsEnabled)
                    .accessibilityLabel(
                        OpenTypeL10n.text("录音时显示实时字幕", english: "Live captions while recording")
                    )
            }

            SettingsRow(
                title: OpenTypeL10n.text("提示音", english: "Sounds"),
                subtitle: OpenTypeL10n.text(
                    "OpenType Air · 一组低响度提示音",
                    english: "OpenType Air · a set of quiet cues"
                )
            ) {
                Menu {
                    ForEach(FeedbackSoundCue.allCases) { cue in
                        Button(cue.title) { model.previewFeedbackSound(cue) }
                    }
                } label: {
                    ControlChip(
                        text: OpenTypeL10n.text("试听", english: "Preview"),
                        showsIndicator: false,
                        horizontalPadding: 10
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(configuration.isMuted)

                SettingsSwitch(
                    isOn: Binding(
                        get: { !configuration.isMuted },
                        set: { model.changeMuted(!$0) }
                    )
                )
                .accessibilityLabel(OpenTypeL10n.text("提示音", english: "Sounds"))
            }
        }
    }

    // MARK: 引擎

    private var engineGroup: some View {
        SettingsGroup(OpenTypeL10n.text("引擎", english: "Engines")) {
            SettingsRow(
                divided: false,
                title: SettingsRoute.speechRecognition.title,
                mono: whisperSummaryLine,
                statusDot: whisperConfigured ? DS.Colour.ok : DS.Colour.warning,
                pushes: .speechRecognition,
                model: model
            )

            SettingsRow(
                title: SettingsRoute.languageModel.title,
                mono: llmSummaryLine,
                statusDot: llmConfigured ? DS.Colour.ok : DS.Colour.warning,
                pushes: .languageModel,
                model: model
            )

            SettingsRow(
                title: SettingsRoute.agentTools.title,
                subtitle: OpenTypeL10n.text(
                    "内置工具与 MCP 服务器",
                    english: "Built-in tools and MCP servers"
                ),
                pushes: .agentTools,
                model: model
            )

            SettingsRow(
                title: OpenTypeL10n.text("转写语言", english: "Transcription language")
            ) {
                Menu {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Button(language.title) {
                            model.changeTranscriptionLanguage(language)
                        }
                    }
                } label: {
                    ControlChip(text: configuration.transcriptionLanguage.title)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    /// `mlx-whisper · 本机`, or the remote model and host the user configured.
    private var whisperSummaryLine: String {
        guard let summary = model.whisperConfigSummary, summary.mode == .remote else {
            return OpenTypeL10n.text("mlx-whisper · 本机", english: "mlx-whisper · local")
        }
        return [summary.model, host(of: summary.baseUrl), OpenTypeL10n.text("远程", english: "remote")]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }

    private var whisperConfigured: Bool {
        model.whisperConfigSummary?.configured
            ?? (model.providerConfigStatus?.whisperConfigured ?? false)
    }

    /// `deepseek-v4-flash · OpenAI 兼容`, or the zero-config fallback's own
    /// label when nothing was ever saved.
    private var llmSummaryLine: String {
        guard let summary = model.llmConfigSummary, summary.configured else {
            return OpenTypeL10n.text("未配置", english: "Not configured")
        }
        return [summary.model, summary.type?.title]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }

    private var llmConfigured: Bool {
        model.llmConfigSummary?.configured
            ?? (model.providerConfigStatus?.llmConfigured ?? false)
    }

    private func host(of urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString) else { return urlString }
        return url.host ?? urlString
    }

    // MARK: 权限

    private var permissionsGroup: some View {
        SettingsGroup(OpenTypeL10n.text("权限", english: "Permissions")) {
            PermissionRow(
                divided: false,
                title: OpenTypeL10n.text("麦克风", english: "Microphone"),
                status: model.microphonePermission,
                deniedNote: OpenTypeL10n.text(
                    "未授权时无法录音，快捷键不会有反应",
                    english: "Without it nothing can be recorded and the hotkey does nothing"
                ),
                grant: { model.requestMicrophonePermission() }
            )

            PermissionRow(
                title: OpenTypeL10n.text("辅助功能", english: "Accessibility"),
                status: model.accessibilityGranted ? .granted : .denied,
                deniedNote: OpenTypeL10n.text(
                    "未授权时无法写入当前输入框，结果仍会复制到剪贴板",
                    english: "Without it nothing is inserted into the focused field; results are still copied"
                ),
                grant: { model.requestAccessibility() }
            )

            PermissionRow(
                title: OpenTypeL10n.text("语音识别（实时字幕）", english: "Speech recognition (live captions)"),
                status: model.speechRecognitionPermission,
                deniedNote: OpenTypeL10n.text(
                    "未授权时字幕不显示，不影响最终识别",
                    english: "Without it captions stay hidden; final recognition is unaffected"
                ),
                grant: { model.requestSpeechRecognitionPermission() }
            )
        }
    }

    // MARK: 数据

    private var dataGroup: some View {
        SettingsGroup(OpenTypeL10n.text("数据", english: "Data")) {
            SettingsRow(
                divided: false,
                title: OpenTypeL10n.text("本地长期记忆", english: "Local long-term memory"),
                subtitle: OpenTypeL10n.text(
                    "听写内容不参与整理，也不发给模型",
                    english: "Dictation is never consolidated and never sent to a model"
                )
            ) {
                SettingsSwitch(isOn: $configuration.agentMemoryEnabled)
                    .accessibilityLabel(
                        OpenTypeL10n.text("本地长期记忆", english: "Local long-term memory")
                    )
            }

            SettingsRow(
                title: OpenTypeL10n.text("每 100 条更新已学到的偏好", english: "Relearn preferences every 100 records"),
                subtitle: automaticProfileUpdateDescription
            ) {
                SettingsSwitch(
                    isOn: Binding(
                        get: { configuration.automaticOwnerProfileUpdates },
                        set: { model.changeAutomaticOwnerProfileUpdates($0) }
                    )
                )
                .accessibilityLabel(
                    OpenTypeL10n.text("每 100 条更新已学到的偏好", english: "Relearn preferences every 100 records")
                )
            }
            .disabled(!configuration.agentMemoryEnabled)

            SettingsRow(
                title: OpenTypeL10n.text("保留本地输入历史", english: "Keep local input history"),
                subtitle: OpenTypeL10n.text(
                    "关闭后不再写入听写记录；审计记录不受影响",
                    english: "When off, no dictation records are written; the audit trail is unaffected"
                )
            ) {
                SettingsSwitch(isOn: $configuration.keepHistory)
                    .accessibilityLabel(
                        OpenTypeL10n.text("保留本地输入历史", english: "Keep local input history")
                    )
            }

            SettingsRow(
                title: SettingsRoute.auditLog.title,
                mono: auditSummaryLine,
                pushes: .auditLog,
                model: model
            )

            SettingsRow(
                title: OpenTypeL10n.text("清除本地数据…", english: "Clear local data…"),
                destructive: true,
                pushes: .clearLocalData,
                model: model
            )
        }
    }

    private var auditSummaryLine: String {
        guard let auditEventCount else { return "audit-events.v1.jsonl" }
        return OpenTypeL10n.text(
            "audit-events.v1.jsonl · \(auditEventCount.formatted()) 条",
            english: "audit-events.v1.jsonl · \(auditEventCount.formatted()) events"
        )
    }

    private var automaticProfileUpdateDescription: String {
        guard configuration.automaticOwnerProfileUpdates else {
            return OpenTypeL10n.text(
                "已暂停自动更新；已有内容会保留。",
                english: "Automatic updates are paused; existing content is kept."
            )
        }
        if agentMemory.automaticProfileUpdateDue {
            return OpenTypeL10n.text(
                "已达到更新条件，下次启动或完成输入时将更新。",
                english: "Ready to update on the next launch or completed input."
            )
        }
        return OpenTypeL10n.text(
            "已记录 \(agentMemory.eventCount) 条；到 \(agentMemory.nextAutomaticProfileEventCount) 条时更新。",
            english: "\(agentMemory.eventCount) recorded; the next update lands at \(agentMemory.nextAutomaticProfileEventCount)."
        )
    }
}

// MARK: - The pushed sub-pages

/// The detail column for 设置: whichever `SettingsRoute` is pushed, or a
/// placeholder when none is.
///
/// The back control clears `model.settingsRoute` rather than owning any
/// navigation state of its own — the route *is* the navigation state, and the
/// narrow layout's push in `SidebarShell` reads the same flag, so one tap can
/// never leave the two disagreeing about which page is on screen.
struct SettingsDetailColumn: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let route = model.settingsRoute {
                ColumnHeader {
                    Button {
                        model.settingsRoute = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.Colour.accent)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(OpenTypeL10n.text("返回", english: "Back"))

                    Text(route.title)
                        .font(DS.Text.title())
                        .tracking(DS.Tracking.title)
                    Spacer(minLength: 0)
                }
                .dsHairline(.bottom)

                page(for: route)
            } else {
                Spacer(minLength: 0)
                Text(OpenTypeL10n.text(
                    "从左侧选择一项设置",
                    english: "Pick a setting on the left"
                ))
                .font(DS.Text.caption())
                .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colour.card)
    }

    @ViewBuilder
    private func page(for route: SettingsRoute) -> some View {
        switch route {
        case .speechRecognition:
            SettingsPageScroll { WhisperSetupContent(model: model) }
        case .languageModel:
            SettingsPageScroll { LLMProviderSetupContent(model: model) }
        case .agentTools:
            AgentToolsPage(model: model) { model.settingsRoute = nil }
        case .auditLog:
            AuditLogPage()
        case .clearLocalData:
            ClearLocalDataPage(model: model)
        }
    }
}

/// The scrolling body every sub-page shares, so a page cannot quietly pick its
/// own page padding.
private struct SettingsPageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.group) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.pageWide)
            .padding(.vertical, DS.Space.content)
        }
        .scrollIndicators(.hidden)
    }
}

/// 审计记录: what the trail is, where it lives, and how big it is.
///
/// Read-only by construction. `ImmutableAuditStore` has no delete or rewrite
/// API and the 清除本地数据 page deliberately does not touch this file, so the
/// page's job is to make that promise legible rather than to offer actions
/// that would break it.
private struct AuditLogPage: View {
    @State private var eventCount: Int?

    private let fileURL = ImmutableAuditStore().fileURL

    var body: some View {
        SettingsPageScroll {
            Text(OpenTypeL10n.text(
                "每一次识别、纠错、完成、取消与失败都会向这个文件追加一行 JSON。它只增不删，不受「清除本地数据」影响；原始录音不会保存。",
                english: "Every recognition, correction, completion, cancellation and failure appends one JSON line to this file. It is append-only and untouched by Clear local data; raw audio is never kept."
            ))
            .font(DS.Text.caption())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                SettingsRow(
                    divided: false,
                    title: OpenTypeL10n.text("文件", english: "File"),
                    mono: fileURL.path
                ) {
                    SmallButton(OpenTypeL10n.text("在访达中显示", english: "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                }

                SettingsRow(
                    title: OpenTypeL10n.text("记录条数", english: "Events")
                ) {
                    Text(eventCount.map { $0.formatted() } ?? "—")
                        .font(DS.Text.mono(12))
                        .foregroundStyle(.secondary)
                }
            }
            .dsCard()
        }
        .task { eventCount = await auditEventCountFromDisk() }
    }
}

/// 清除本地数据: the two resettable local stores, each with its own
/// confirmation.
///
/// A page rather than a `DisclosureGroup`. The twisty made a destructive
/// action feel like a detail of the section above it; a page you have to
/// navigate to states the cost up front and gives the confirmation somewhere
/// to live that is not a popover over a settings list.
private struct ClearLocalDataPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var agentMemory: AgentMemoryStore

    @State private var confirmingHistoryReset = false
    @State private var confirmingMemoryReset = false

    init(model: AppModel) {
        self.model = model
        agentMemory = model.agentMemory
    }

    var body: some View {
        SettingsPageScroll {
            Text(OpenTypeL10n.text(
                "以下操作只影响本机数据，无法撤销。审计记录（audit-events.v1.jsonl）不在其中，它只增不删。",
                english: "These act on local data only and cannot be undone. The audit trail (audit-events.v1.jsonl) is not included — it is append-only."
            ))
            .font(DS.Text.caption())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                SettingsRow(
                    divided: false,
                    title: OpenTypeL10n.text("输入历史", english: "Input history"),
                    subtitle: OpenTypeL10n.text(
                        "\(model.history.entries.count) 条本地记录",
                        english: "\(model.history.entries.count) local records"
                    )
                ) {
                    SmallButton(
                        OpenTypeL10n.text("重置", english: "Reset"),
                        destructive: true
                    ) {
                        confirmingHistoryReset = true
                    }
                    .disabled(model.history.entries.isEmpty)
                }

                SettingsRow(
                    title: OpenTypeL10n.text("长期记忆", english: "Long-term memory"),
                    subtitle: OpenTypeL10n.text(
                        "\(agentMemory.eventCount) 条学习记录",
                        english: "\(agentMemory.eventCount) learned records"
                    )
                ) {
                    SmallButton(
                        OpenTypeL10n.text("重新学习", english: "Relearn"),
                        destructive: true
                    ) {
                        confirmingMemoryReset = true
                    }
                    .disabled(agentMemory.eventCount == 0)
                }

                SettingsRow(
                    title: OpenTypeL10n.text("记忆数据库", english: "Memory database"),
                    mono: agentMemory.databaseURL.lastPathComponent,
                    statusDot: agentMemory.databaseReady ? DS.Colour.ok : DS.Colour.warning
                ) {
                    SmallButton(OpenTypeL10n.text("在访达中显示", english: "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([agentMemory.databaseURL])
                    }
                    .disabled(!agentMemory.databaseReady)
                }
            }
            .dsCard()
        }
        .confirmationDialog(
            OpenTypeL10n.text("重置输入历史？", english: "Reset input history?"),
            isPresented: $confirmingHistoryReset,
            titleVisibility: .visible
        ) {
            Button(OpenTypeL10n.text("确认重置", english: "Reset"), role: .destructive) {
                model.resetHistory()
            }
            Button(OpenTypeL10n.text("取消", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(OpenTypeL10n.text(
                "本机保存的输入记录会被移除。此操作不可撤销，建议先保存重要信息。",
                english: "Locally stored input records are removed. This cannot be undone — save anything you need first."
            ))
        }
        .confirmationDialog(
            OpenTypeL10n.text("重新学习偏好？", english: "Relearn preferences?"),
            isPresented: $confirmingMemoryReset,
            titleVisibility: .visible
        ) {
            Button(OpenTypeL10n.text("确认重新学习", english: "Relearn"), role: .destructive) {
                model.resetAgentMemory()
            }
            Button(OpenTypeL10n.text("取消", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(OpenTypeL10n.text(
                "本地任务记录和系统推断会被移除。此操作不可撤销，建议先保存重要信息。",
                english: "Local task records and inferred preferences are removed. This cannot be undone — save anything you need first."
            ))
        }
    }
}

// MARK: - Building blocks

/// A labelled card of rows. The label sits outside the card, 8pt above it, per
/// the handoff's spacing table.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.label) {
            Text(title)
                .font(DS.Text.groupLabel())
                .tracking(DS.Tracking.groupLabel)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)

            // `overflow:hidden` in the mockup, and not decorative: the
            // ungranted permission row carries a full-bleed warning tint and is
            // the last row of its card, so without the clip its square corners
            // would poke out past the card's 14pt radius.
            VStack(spacing: 0) { content() }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .dsCard()
        }
    }
}

/// One row of a settings card: a title, an optional second line, and either a
/// trailing control or a `chevron.right` that pushes a page.
///
/// The two are one type on purpose. A row that pushes and a row that toggles
/// have to be the same height, the same padding and the same hairline or the
/// card reads as two lists stacked; keeping them one view means that can't
/// drift.
private struct SettingsRow<Trailing: View>: View {
    var divided = true
    /// 11pt vertical padding instead of 12. The mockup gives the permission
    /// rows — a dot, a name and a word — one point less than every other row,
    /// which is what keeps a three-row card of one-line rows from reading as
    /// taller than the two-row cards beside it.
    var compact = false
    let title: String
    var subtitle: String?
    /// A machine-produced second line — provider and model, a path, a count.
    var mono: String?
    /// A 5pt dot before the title. Permissions use it; a provider row puts its
    /// dot on the trailing side instead, beside the chevron it belongs to.
    var leadingDot: Color?
    var statusDot: Color?
    /// Red title, for 清除本地数据…
    var destructive = false
    /// Warning-tinted row, for a shortcut that isn't working.
    var tinted = false
    var pushes: SettingsRoute?
    var model: AppModel?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        if let pushes, let model {
            Button {
                model.settingsRoute = pushes
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            if let leadingDot {
                Circle()
                    .fill(leadingDot)
                    .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
            }

            // 2pt under a prose subtitle, 3pt under a mono one. The mono line
            // sits on a smaller face with tighter leading, so the mockup buys
            // the point back to keep the optical gap equal.
            VStack(alignment: .leading, spacing: mono == nil ? 2 : 3) {
                Text(title)
                    .font(DS.Text.body())
                    .foregroundStyle(destructive ? DS.Colour.error : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Text.caption())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let mono {
                    Text(mono)
                        .font(DS.Text.mono())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                trailing()
                if let statusDot {
                    Circle()
                        .fill(statusDot)
                        .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                }
                if pushes != nil {
                    // The mockup's `chevron_right` is a 16px Material glyph.
                    // Material sizes the em box; SF Symbols size the cap
                    // height, and a chevron fills about two thirds of a
                    // Material box — so 16px of box is ~13pt of symbol.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, compact ? 11 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tinted ? DS.Colour.warning.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .modifier(RowDivider(divided: divided))
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(
        divided: Bool = true,
        compact: Bool = false,
        title: String,
        subtitle: String? = nil,
        mono: String? = nil,
        leadingDot: Color? = nil,
        statusDot: Color? = nil,
        destructive: Bool = false,
        tinted: Bool = false,
        pushes: SettingsRoute? = nil,
        model: AppModel? = nil
    ) {
        self.init(
            divided: divided,
            compact: compact,
            title: title,
            subtitle: subtitle,
            mono: mono,
            leadingDot: leadingDot,
            statusDot: statusDot,
            destructive: destructive,
            tinted: tinted,
            pushes: pushes,
            model: model,
            trailing: { EmptyView() }
        )
    }
}

/// A row whose control sits under the title rather than beside it, for the
/// one control too wide to be trailing.
private struct SettingsStackedRow<Content: View>: View {
    var divided = true
    let title: String
    var note: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(DS.Text.body())
            content()
            if let note {
                Text(note)
                    .font(DS.Text.caption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RowDivider(divided: divided))
    }
}

/// One of three uniform permission rows.
///
/// Uniform is the point. The old Settings gave each permission its own
/// phrasing, its own symbol and its own colour rule, so "which of these is a
/// problem" took reading rather than looking. A dot, a name, a status — and
/// colour only on the one that wants something.
private struct PermissionRow: View {
    var divided = true
    let title: String
    let status: PermissionStatus
    /// Shown only when the permission is missing; there is nothing to explain
    /// about one that is granted.
    let deniedNote: String?
    let grant: () -> Void

    var body: some View {
        SettingsRow(
            divided: divided,
            compact: true,
            title: title,
            subtitle: status == .granted ? nil : deniedNote,
            leadingDot: status == .granted ? DS.Colour.ok : DS.Colour.warning,
            tinted: status != .granted
        ) {
            if status == .granted {
                Text(OpenTypeL10n.text("已授权", english: "Granted"))
                    .font(DS.Text.caption())
                    .foregroundStyle(.tertiary)
            } else {
                SmallButton(
                    status == .denied
                        ? OpenTypeL10n.text("打开设置", english: "Open Settings")
                        : OpenTypeL10n.text("授权", english: "Grant"),
                    action: grant
                )
            }
        }
    }
}

/// The hairline between rows, as a modifier so both row shapes get exactly
/// one implementation of it.
private struct RowDivider: ViewModifier {
    let divided: Bool

    func body(content: Content) -> some View {
        if divided {
            content.dsHairline(.top)
        } else {
            content
        }
    }
}

// MARK: - Controls

/// The 38×22 switch from the handoff. Custom because `Toggle(.switch)` is a
/// different size and cannot be restyled, and this control appears seven
/// times on one screen — the one place a stock control being 2pt off is
/// visible as a ragged right edge.
private struct SettingsSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Capsule()
                .fill(isOn ? DS.Colour.accent : Color.primary.opacity(0.14))
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityValue(
            isOn
                ? OpenTypeL10n.text("开", english: "On")
                : OpenTypeL10n.text("关", english: "Off")
        )
    }
}

/// The 26pt segmented control: a recessed track, a lifted white selected
/// segment.
private struct SegmentedControl<Option: Identifiable & Equatable>: View {
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    let help: (Option) -> String
    let select: (Option) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    select(option)
                } label: {
                    Text(title(option))
                        .font(DS.Text.caption())
                        .fontWeight(isSelected ? .medium : .regular)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background {
                            if isSelected {
                                DS.Shadow.control(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(DS.Colour.card)
                                )
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(option))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .frame(height: 26)
        // The mockup's track is `#F0F0EE`, which is darker than
        // `DS.Colour.inset` (the token for a recessed block inside a card) and
        // slightly warm. 6% black over the white card lands on `#F0F0F0` —
        // right on two channels and 2/255 off on the third. Closing that last
        // step needs a literal colour token the scale doesn't have yet; it is
        // reported rather than invented here.
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }
}

/// The 24pt dropdown / chip a `Menu` wears.
private struct ControlChip: View {
    let text: String
    var mono = false
    var showsIndicator = true
    /// 8 with a chevron, 10 without. The mockup pads a bare label wider so the
    /// two shapes end up the same optical size — the chevron already carries
    /// the trailing 2pt of air that a plain word doesn't have.
    var horizontalPadding: CGFloat = 8

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(mono ? DS.Text.mono(12) : DS.Text.caption())
                .foregroundStyle(.primary)
                .lineLimit(1)
            if showsIndicator {
                // `unfold_more` at 14px of Material em box. Two stacked
                // chevrons fill a box more completely than one does, so this
                // maps lower than the 16px `chevron.right` above, not higher.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: 24)
        .background(
            DS.Colour.canvas,
            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
        )
        .contentShape(Rectangle())
    }
}

/// The 24pt lifted button: 授权, 试听, 在访达中显示, and the two resets.
private struct SmallButton: View {
    let title: String
    var destructive = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Text.caption())
                .fontWeight(.medium)
                .foregroundStyle(destructive ? DS.Colour.error : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background {
                    DS.Shadow.control(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(DS.Colour.card)
                    )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(
                            destructive ? DS.Colour.error.opacity(0.35) : Color.primary.opacity(0.12),
                            lineWidth: 0.75
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Shared bits

/// The mockup's 原样写入 / 轻整理 / 先复核.
///
/// Local rather than a change to `TranscribeVariant.title`, which reads
/// 直接模式 / 轻整理 / 复核模式 and is used elsewhere (the mode menus, the
/// Review panel). The handoff's copy is final for *this* control, where the
/// three sit side by side under 「松开之后」 and name what happens rather than
/// what the setting is called.
private extension TranscribeVariant {
    var releaseTitle: String {
        switch self {
        case .direct: return OpenTypeL10n.text("原样写入", english: "As spoken")
        case .tidy: return OpenTypeL10n.text("轻整理", english: "Tidy")
        case .review: return OpenTypeL10n.text("先复核", english: "Review first")
        }
    }
}

/// Counts the records in `audit-events.v1.jsonl` off the main actor.
///
/// The trail is append-only and never trimmed, so for a heavy user it is the
/// one file in this app big enough that reading it on the main thread would be
/// felt as a hitch when Settings opens — the same reason
/// `AppModel.refreshUsageStats()` reads it detached. Counting `\n` bytes
/// rather than decoding avoids materialising the whole file as a `String`;
/// every append ends in one, so the byte count *is* the record count.
private func auditEventCountFromDisk() async -> Int {
    let url = ImmutableAuditStore().fileURL
    return await Task.detached(priority: .utility) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        return data.reduce(into: 0) { total, byte in
            if byte == 0x0A { total += 1 }
        }
    }.value
}
