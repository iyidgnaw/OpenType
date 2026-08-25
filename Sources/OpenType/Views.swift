import AppKit
import SwiftUI

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
        Group {
            if model.needsProviderOnboarding {
                // The first-run wizard still takes the whole window: there is
                // nothing to navigate between until a provider exists, and a
                // sidebar offering four destinations that all say "configure
                // something first" would be four ways to be told no.
                OnboardingWizardView(model: model)
            } else {
                SidebarShell(
                    model: model,
                    showsDetail: model.hasOpenDetail,
                    list: { destinationList },
                    detail: { destinationDetail }
                )
            }
        }
        .frame(
            minWidth: DS.Size.windowMinWidth,
            idealWidth: 1120,
            maxWidth: .infinity,
            minHeight: 480,
            idealHeight: 720,
            maxHeight: .infinity
        )
        .background(DS.Colour.canvas)
        .tint(DS.Colour.accent)
        .environment(\.locale, OpenTypeL10n.locale)
        // §F: rebuilds the whole tree on a live language switch rather than
        // waiting for whichever `@Published` a given subview happens to
        // observe — see `AppConfiguration.interfaceLanguageToken`.
        .id(configuration.interfaceLanguageToken)
    }

    /// The middle column: whatever the selected destination lists.
    @ViewBuilder
    private var destinationList: some View {
        switch model.selectedTab {
        case .sessions:
            SessionsListColumn(model: model)
        case .dictation:
            DictationColumn(model: model)
        case .memory:
            MemoryColumn(model: model)
        case .settings:
            SettingsColumn(model: model)
        }
    }

    /// The right column. 记忆 and 听写 are single pages that fill the width
    /// themselves, so they leave it empty and `hasOpenDetail` keeps the narrow
    /// layout from pushing an empty panel over them.
    @ViewBuilder
    private var destinationDetail: some View {
        switch model.selectedTab {
        case .sessions:
            SessionThreadColumn(model: model) { text, conversation in
                model.submitTypedTurn(text, in: conversation)
            }
        case .settings:
            SettingsDetailColumn(model: model)
        case .dictation, .memory:
            Color.clear
        }
    }
}
