import SwiftUI

/// The redesign's type, shape, colour and spacing scale (2026-08 handoff,
/// `design_handoff_opentype_redesign_v1`).
///
/// This exists because the old UI had twelve font sizes (8.3 / 8.5 / 8.8 / 9 /
/// 9.5 / 10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 13) and eight corner radii on
/// screen at once. Nobody chose that; it accumulated one reasonable-looking
/// local decision at a time, and the result reads as noise even though no
/// single value is wrong. A closed scale is the only thing that stops it
/// happening again — when the nearest size is a step away rather than 0.5pt
/// away, the cheap fix stops being "invent a new value".
///
/// Everything here is a value from the handoff, not an interpretation of it.
/// Deviations belong in a comment saying why, not in a quietly different
/// number.
enum DS {

    // MARK: - Type

    /// Six steps, all SF. Anything outside them is a bug in the caller.
    enum Text {
        /// Page titles (会话 / 听写 / 记忆 / 设置).
        static func title() -> Font { .system(size: 20, weight: .bold) }
        /// Section headings, and headings inside an answer.
        static func section() -> Font { .system(size: 15, weight: .semibold) }
        /// Body, and the main line of a list row.
        static func body(_ weight: Font.Weight = .regular) -> Font {
            .system(size: 13, weight: weight)
        }
        /// Secondary explanation. Pair with `.secondary`.
        static func caption() -> Font { .system(size: 12) }
        /// Group labels (今天 / 进行中 / 内置工具). Pair with `.tertiary`.
        static func groupLabel() -> Font { .system(size: 11, weight: .semibold) }
        /// Every machine-produced string.
        ///
        /// The scope is deliberately narrow and worth naming, because the
        /// failure is asymmetric: timestamps, durations, counts, tool names,
        /// paths, commands, server names, masked secrets and confidence
        /// percentages all read better aligned — and Chinese body text set in a
        /// monospaced face reads as a terminal dump. Never use this on prose.
        static func mono(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }

    /// The tracking the handoff specifies for the two steps that carry it.
    enum Tracking {
        static let title: CGFloat = -0.4   // -.02em at 20pt
        static let groupLabel: CGFloat = 0.55 // .05em at 11pt
    }

    // MARK: - Shape

    /// Four radii. A fifth on the same screen is the thing this prevents.
    enum Radius {
        /// Controls: buttons, filter chips, segmented controls, dropdowns, tags.
        static let control: CGFloat = 6
        /// Blocks nested inside a card; icon buttons; progress containers.
        static let inset: CGFloat = 10
        /// Cards: list containers, settings groups, the stats band.
        static let card: CGFloat = 14
        /// Floating panels.
        static let panel: CGFloat = 18
    }

    // MARK: - Colour

    /// One accent, and colour reserved for things that need an action.
    ///
    /// The rule that changes the most on screen: **success is no longer
    /// green.** Success is the common case, and colouring the common case
    /// spends the user's attention on the outcome they expected. A neutral row
    /// with a `checkmark` says the same thing and leaves colour meaning
    /// "something wants you".
    enum Colour {
        /// The only accent. Already `AppAccent.primary`; aliased rather than
        /// redefined so there is still one definition.
        static let accent = AppAccent.primary
        /// Agent identity — type tags and tool names in a step log, nothing else.
        static let agent = Color(red: 0.294, green: 0.271, blue: 0.910)

        static let canvas = Color(red: 0.961, green: 0.961, blue: 0.953)
        static let card = Color(nsColor: .textBackgroundColor)
        /// A recessed block inside a card.
        static let inset = Color.primary.opacity(0.035)

        static let hairline = Color.primary.opacity(0.06)
        static let border = Color.primary.opacity(0.07)

        /// Unconfirmed memory, side-effecting tools, connection risk.
        static let warning = Color(red: 0.910, green: 0.592, blue: 0.227)
        static let warningText = Color(red: 0.698, green: 0.416, blue: 0.086)
        static let warningFill = Color(red: 0.910, green: 0.592, blue: 0.227).opacity(0.14)
        /// Real errors only.
        static let error = Color(red: 0.851, green: 0.282, blue: 0.231)
        /// A 5pt status dot, never a text colour.
        static let ok = Color(red: 0.204, green: 0.659, blue: 0.325)
    }

    // MARK: - Depth

    enum Shadow {
        static func card(_ view: some View) -> some View {
            view.shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 1)
        }
        /// Lifted small controls: icon buttons, the selected segment.
        static func control(_ view: some View) -> some View {
            view.shadow(color: .black.opacity(0.05), radius: 0.75, x: 0, y: 1)
        }
        /// A running card, which also takes an accent border.
        static func running(_ view: some View) -> some View {
            view.shadow(color: DS.Colour.accent.opacity(0.10), radius: 4, x: 0, y: 2)
        }
    }

    // MARK: - Metrics

    /// Fixed widths from the handoff. Measured, not eyeballed — the README's
    /// verification step checks these with screenshots.
    enum Size {
        static let sidebar: CGFloat = 212
        /// The sidebar collapsed to icons in the narrow layout.
        static let iconRail: CGFloat = 52
        static let list: CGFloat = 334
        /// Below this the window uses the narrow layout.
        static let narrowBreakpoint: CGFloat = 720
        /// Raised from 420: three columns do not fit in less.
        static let windowMinWidth: CGFloat = 460
        /// The title-bar-height strip every column starts with.
        static let headerHeight: CGFloat = 52
        static let statusDot: CGFloat = 5
    }

    /// Multiples of 4.
    enum Space {
        static let rowV: CGFloat = 11
        static let rowH: CGFloat = 13
        static let content: CGFloat = 16
        static let pageWide: CGFloat = 24
        static let pageNarrow: CGFloat = 14
        static let group: CGFloat = 16
        /// Between a group label and the card it labels.
        static let label: CGFloat = 8
    }
}

extension View {
    /// A card: white, 14pt corners, hairline border, the card shadow.
    func dsCard() -> some View {
        DS.Shadow.card(
            background(DS.Colour.card, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(DS.Colour.border, lineWidth: 0.75)
                )
        )
    }

    /// The one hairline in the design, as a divider between rows in a card.
    func dsHairline(_ edge: Edge = .top) -> some View {
        overlay(alignment: edge == .top ? .top : .bottom) {
            Rectangle()
                .fill(DS.Colour.hairline)
                .frame(height: 0.75)
        }
    }
}
