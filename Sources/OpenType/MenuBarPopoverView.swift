import SwiftUI

/// The menubar `NSPopover`'s content (Part A of the Alfred-style split):
/// per the product owner, this is a simple mode-switch entry point only — a
/// hotkey starts recording, and the popover's whole job is picking which of
/// the 3 modes that hotkey uses next, plus a glance at whether things are
/// working. Settings, Agent history, and Memory/context all moved out to a
/// real app window (`RootView`, opened via the gear button here) rather than
/// living in this popover the way the old full-featured `RootView`-in-a-popover
/// did. Reuses `ModeGrid` from `Views.swift` rather than re-implementing the
/// mode cards — it was already compact and already matches this codebase's
/// existing card style.
struct MenuBarPopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configuration: AppConfiguration
    var onOpenMainWindow: () -> Void

    init(model: AppModel, onOpenMainWindow: @escaping () -> Void) {
        self.model = model
        self.configuration = model.configuration
        self.onOpenMainWindow = onOpenMainWindow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ModeGrid(model: model, configuration: configuration)
            if model.needsLLMForSelectedMode {
                llmSetupNudge
            }
            Divider()
            statusArea
            Divider()
            quitButton
        }
        .padding(16)
        // Widened from the original 264pt and given room to grow vertically:
        // at 264pt wide, 3-mode subtitles like "提出问题 · 弹窗直接回答" wrapped
        // across 2-3 lines and clipped. `configurePopover()` in
        // `OpenTypeApp.swift` sets the matching `NSPopover.contentSize`.
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(AppAccent.primary)
        .environment(\.locale, OpenTypeL10n.locale)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    Color(nsColor: MenuBarStatusIcon.backgroundColor(
                        for: model.state
                    ))
                )
                .frame(width: 8, height: 8)

            Text(model.state.title)
                .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 8)

            Button(action: onOpenMainWindow) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.045), in: Circle())
            }
            .buttonStyle(.plain)
            .help(OpenTypeL10n.text(
                "打开 OpenType（设置、历史、Agent 任务）",
                english: "Open OpenType (settings, history, Agent tasks)"
            ))
        }
    }

    /// The menu bar is the only surface that's always reachable — the app is
    /// `.accessory` whenever the main window is closed, so there's no Dock
    /// icon and no app menu to quit from. Spelled out with a label rather
    /// than an icon so it doesn't read as "close the popover".
    private var quitButton: some View {
        Button {
            model.quit()
        } label: {
            Label(
                OpenTypeL10n.text("退出 OpenType", english: "Quit OpenType"),
                systemImage: "power"
            )
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Shown when the user selects Ask/Agent but has no LLM configured (the
    /// case a transcribe-only user reaches after skipping AI setup). Guides
    /// them to configure one rather than silently letting the mode fail —
    /// tapping it opens the main window on the Settings tab's AI-model section.
    private var llmSetupNudge: some View {
        Button {
            onOpenMainWindow()
            model.selectedTab = .settings
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10.5, weight: .medium))
                VStack(alignment: .leading, spacing: 1) {
                    Text(OpenTypeL10n.text(
                        "该模式需要 AI 模型",
                        english: "This mode needs an AI model"
                    ))
                    .font(.system(size: 10.5, weight: .medium))
                    Text(OpenTypeL10n.text(
                        "点此前往设置配置",
                        english: "Tap to set one up in Settings"
                    ))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(model.shortcutStatus, systemImage: "keyboard")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Previously undiscoverable, and then wrong: the hint used to
            // promise "点 Shift 或 Tab" for every preset, naming a chord that
            // no longer exists and a key half the presets do not record with.
            // Driven off the preset now (`HotKeyPreset.modeSwitchHint`), and
            // rendered only when that preset is the one actually installed —
            // an Accessibility-less fallback is a Space chord, which has no
            // Tab handling and so no hint.
            if model.preferredShortcutActive,
               let hint = configuration.hotKeyPreset.modeSwitchHint {
                Label(hint, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.sidecarNeedsAttention {
                HStack(spacing: 6) {
                    Label(model.sidecarStatusText, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    Button {
                        model.restartSidecarManually()
                    } label: {
                        Text(OpenTypeL10n.text("重启服务", english: "Restart service"))
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                }
            } else {
                Label(model.sidecarStatusText, systemImage: "bolt.horizontal.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if model.runningAgentRunCount > 0 {
                Label(
                    OpenTypeL10n.text(
                        "\(model.runningAgentRunCount) 个 Agent 任务运行中",
                        english: "\(model.runningAgentRunCount) Agent task(s) running"
                    ),
                    systemImage: "wand.and.stars"
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
            }
        }
    }
}
