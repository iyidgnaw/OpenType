import SwiftUI

/// The redesigned main window: a sidebar and one main thing, instead of five
/// equal tabs along the bottom.
///
/// Five equal tabs said all five were equally the point. They were not — the
/// app is a conversation with a voice, and everything else is somewhere you go
/// occasionally. The sidebar makes that ordering visible, and reclaims the
/// bottom strip that used to be spent restating it.
///
/// Two layouts, one breakpoint. Wide (`>= 720pt`) shows sidebar, list and
/// detail side by side; narrow collapses the sidebar to a 52pt icon rail and
/// **pushes** the detail over the list rather than squeezing three columns into
/// a width that cannot hold them. The row and card metrics are identical in
/// both — only the page padding changes — so nothing has to be re-learned when
/// the window is resized.
struct SidebarShell<List: View, Detail: View>: View {
    @ObservedObject var model: AppModel
    /// Whether the detail column has anything in it. Drives the narrow
    /// layout's push, and the wide layout's placeholder.
    var showsDetail: Bool
    @ViewBuilder var list: () -> List
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        GeometryReader { proxy in
            let narrow = proxy.size.width < DS.Size.narrowBreakpoint

            HStack(spacing: 0) {
                SidebarColumn(model: model, collapsed: narrow)
                    .frame(width: narrow ? DS.Size.iconRail : DS.Size.sidebar)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(DS.Colour.hairline).frame(width: 0.75)
                    }

                if narrow {
                    // Push, not squeeze. A 334pt list beside a detail column in
                    // a 460pt window leaves neither usable, and a thread is the
                    // thing you came to read.
                    ZStack {
                        list()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showsDetail {
                            detail()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(DS.Colour.card)
                                .transition(.move(edge: .trailing))
                        }
                    }
                    .animation(.easeInOut(duration: 0.22), value: showsDetail)
                } else if model.selectedTab.isFullWidthPage {
                    // 听写 and 记忆 are single pages with their own internal
                    // splits. Giving them the 334pt list slot capped them below
                    // their own two-column threshold, so they rendered stacked
                    // next to an empty half-window.
                    list()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list()
                        .frame(width: DS.Size.list)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(DS.Colour.hairline).frame(width: 0.75)
                        }
                    detail()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DS.Colour.card)
                }
            }
        }
        .background(DS.Colour.canvas)
    }
}

/// The sidebar, or its collapsed icon rail.
///
/// One view for both so the two can never drift into different navigation.
private struct SidebarColumn: View {
    @ObservedObject var model: AppModel
    var collapsed: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Left clear for the traffic lights: the window is
            // `titlebarAppearsTransparent`, so the sidebar runs up under them.
            Color.clear.frame(height: DS.Size.headerHeight)

            brand
                .padding(.horizontal, collapsed ? 0 : 12)
                .padding(.bottom, 14)

            VStack(spacing: 2) {
                ForEach(AppTab.allCases) { tab in
                    SidebarItem(
                        tab: tab,
                        collapsed: collapsed,
                        selected: model.selectedTab == tab,
                        badge: badge(for: tab),
                        needsAttention: tab == .memory && model.hasUnconfirmedMemory
                    ) {
                        model.selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, collapsed ? 0 : 10)

            Spacer(minLength: 12)

            if collapsed {
                SidebarModeButton(model: model)
                    .padding(.bottom, 12)
            } else {
                SidebarModeCard(model: model)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var brand: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [DS.Colour.accent, DS.Colour.agent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                }
            if !collapsed {
                Text("OpenType")
                    .font(DS.Text.body(.semibold))
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    /// Counts sit beside the destination they describe rather than in it, so a
    /// glance answers "is there anything new" without a click.
    private func badge(for tab: AppTab) -> String? {
        switch tab {
        case .sessions:
            let count = model.sessionConversations.count
            return count > 0 ? "\(count)" : nil
        case .dictation:
            let count = model.history.entries.count
            return count > 0 ? "\(count)" : nil
        case .memory, .settings:
            return nil
        }
    }
}

private struct SidebarItem: View {
    let tab: AppTab
    let collapsed: Bool
    let selected: Bool
    let badge: String?
    /// Replaces the count with a warning dot. Memory is the one destination
    /// where "there is something here" means "something is waiting on you".
    let needsAttention: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.symbol)
                    .font(.system(size: collapsed ? 17 : 16))
                    .foregroundStyle(selected ? .white : .secondary)
                    .frame(width: collapsed ? 34 : nil, height: 30)
                    .overlay(alignment: .topTrailing) {
                        if collapsed, needsAttention {
                            Circle()
                                .fill(DS.Colour.warning)
                                .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                                .offset(x: -5, y: 4)
                        }
                    }
                if !collapsed {
                    Text(tab.title)
                        .font(DS.Text.body(selected ? .medium : .regular))
                        .foregroundStyle(selected ? .white : .primary)
                    Spacer(minLength: 0)
                    if needsAttention {
                        Circle()
                            .fill(DS.Colour.warning)
                            .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                    } else if let badge {
                        Text(badge)
                            .font(DS.Text.mono())
                            .foregroundStyle(
                                selected
                                    ? AnyShapeStyle(Color.white.opacity(0.85))
                                    : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                            )
                    }
                }
            }
            .padding(.horizontal, collapsed ? 0 : 9)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: collapsed ? 7 : DS.Radius.control, style: .continuous)
                        .fill(DS.Colour.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The sidebar's foot: which mode the hotkey will use, and whether the voice
/// service is up.
///
/// This is where the deleted 「输入」 tab's only real content went. It was never
/// a destination — you do not *go* to picking a mode — so it becomes a control
/// that is always visible instead of a place you have to visit.
private struct SidebarModeCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(InputMode.visibleModes) { mode in
                    Button {
                        model.selectMode(mode)
                    } label: {
                        Label(mode.title, systemImage: mode.symbol)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.configuration.selectedMode.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(DS.Colour.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.configuration.selectedMode.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(model.shortcutHintText)
                            .font(DS.Text.mono(10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.top, 9)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Circle()
                    .fill(model.sidecarNeedsAttention ? DS.Colour.warning : DS.Colour.ok)
                    .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                Text(model.sidecarStatusText)
                    .font(DS.Text.mono(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .dsHairline(.top)
        }
        .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous)
                .strokeBorder(DS.Colour.border, lineWidth: 0.75)
        )
    }
}

/// The icon rail's version: the mode glyph alone, same menu behind it.
private struct SidebarModeButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(InputMode.visibleModes) { mode in
                Button {
                    model.selectMode(mode)
                } label: {
                    Label(mode.title, systemImage: mode.symbol)
                }
            }
        } label: {
            Image(systemName: model.configuration.selectedMode.symbol)
                .font(.system(size: 15))
                .foregroundStyle(DS.Colour.accent)
                .frame(width: 34, height: 34)
                .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(DS.Colour.border, lineWidth: 0.75)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.configuration.selectedMode.title)
    }
}

/// The 52pt strip every column starts with, so headers line up across all
/// three regardless of what each one puts in it.
struct ColumnHeader<Content: View>: View {
    var narrow: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
        }
        // The design's page padding, so a header and the cards under it share
        // one left edge. Was `content` (16) — a transcription slip that every
        // column then matched, which is how a wrong value becomes a convention.
        .padding(.horizontal, narrow ? DS.Space.pageNarrow : DS.Space.pageWide)
        .frame(height: DS.Size.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
