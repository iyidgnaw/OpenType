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
        VStack(alignment: .leading, spacing: 12) {
            header
            ModeGrid(model: model, configuration: configuration)
            Divider()
            statusArea
        }
        .padding(14)
        .frame(width: 264, height: 246)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(configuration.colorTheme.accent)
        .environment(\.locale, configuration.interfaceLanguage.locale)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    Color(nsColor: MenuBarStatusIcon.backgroundColor(
                        for: model.state,
                        colorTheme: configuration.colorTheme
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

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(model.shortcutStatus, systemImage: "keyboard")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Label(model.sidecarStatus, systemImage: "bolt.horizontal.circle")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if model.runningAgentRunCount > 0 {
                Label(
                    OpenTypeL10n.text(
                        "\(model.runningAgentRunCount) 个 Agent 任务运行中",
                        english: "\(model.runningAgentRunCount) Agent task(s) running"
                    ),
                    systemImage: "gearshape.2.fill"
                )
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
            }
        }
    }
}
