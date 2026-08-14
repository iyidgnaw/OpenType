import SwiftUI

/// 听写 — the redesign's version of the old History tab (handoff §3 「听写」 and
/// §6 「本地统计」).
///
/// Two things changed, and both are about what a list of past dictations is
/// *for*. It used to be one card per entry, each card repeating the mode name
/// and a relative timestamp, so a week of dictation read as a week of chrome.
/// Now one card holds a whole day and the rows inside it are separated by a
/// hairline: the card boundary means "a day", not "a row", which is the only
/// grouping a user actually scans by. And the week's own numbers moved from a
/// small panel wedged above the list to a band that is the page's header — they
/// are a summary *of* this list, so they belong at the top of it rather than
/// somewhere you have to remember to look.
///
/// Everything here is derived. `HistoryStore.entries` is the list;
/// `UsageStats.Summary` is the band. Nothing on this screen is stored for the
/// sake of being shown.

// MARK: - Missing type step

/// 11pt regular, non-monospaced.
///
/// The one step the design uses that `DS.Text` has no token for — `DS` has
/// 11pt only as `groupLabel()` (semibold) and as `mono()`. The design sets
/// figure notes, source-app names and the band's disclaimer at 11pt regular in
/// the system face, and semibold at that size reads as a heading rather than as
/// an aside. Declared once here rather than written as a literal at each call
/// site so there is still a single definition; it belongs in
/// `DesignTokens.swift` the next time that file is open for editing.
private func dsNote() -> Font { .system(size: 11) }

// MARK: - The page

/// The 听写 page: header, the week's stats band, then one card per day.
///
/// Sizes itself off its own width rather than taking a `narrow` flag, so it
/// behaves the same whether the shell hands it a full content area or a
/// column — the page's layout question is "how much room do I have", and the
/// window's breakpoint is a different question with a different answer.
struct DictationColumn: View {
    @ObservedObject var model: AppModel
    /// `HistoryStore` is its own `ObservableObject`; observing it (not just
    /// `model`) is what makes `entries` changes re-render — `model` never
    /// republishes when the store's `@Published entries` mutates.
    @ObservedObject var history: HistoryStore

    @State private var query = ""
    @State private var source: String?
    /// Pinned rather than read at every render so the bar strip's labels and
    /// the day headings do not shift underneath a user who leaves the window
    /// open across midnight without the numbers beside them moving too.
    @State private var now = Date()

    /// Below this the band drops its bar strip and folds to a 2×2 grid.
    ///
    /// Four figures plus three rules plus the 190pt strip need roughly 780pt;
    /// under 700 the figures start colliding with their own labels. It is a
    /// property of this band's contents, not of the window, which is why it is
    /// not `DS.Size.narrowBreakpoint`.
    private static let bandFoldWidth: CGFloat = 700

    var body: some View {
        GeometryReader { proxy in
            let narrow = proxy.size.width < Self.bandFoldWidth
            let page = narrow ? DS.Space.pageNarrow : DS.Space.pageWide

            VStack(spacing: 0) {
                header(narrow: narrow)

                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.group) {
                        UsageStatsBand(
                            summary: model.usageSummary,
                            narrow: narrow,
                            now: now
                        )

                        if history.entries.isEmpty {
                            emptyState(
                                symbol: "clock.arrow.circlepath",
                                title: OpenTypeL10n.text(
                                    "还没有听写记录",
                                    english: "No dictation yet"
                                ),
                                subtitle: OpenTypeL10n.text(
                                    "完成一次语音输入后会出现在这里",
                                    english: "Your first dictation will show up here"
                                )
                            )
                        } else if groups.isEmpty {
                            emptyState(
                                symbol: "magnifyingglass",
                                title: OpenTypeL10n.text(
                                    "没有匹配的记录",
                                    english: "Nothing matches"
                                ),
                                subtitle: OpenTypeL10n.text(
                                    "换个词，或把来源筛选改回「全部来源」",
                                    english: "Try another word, or reset the source filter"
                                )
                            )
                        } else {
                            ForEach(groups) { group in
                                DictationDayGroup(model: model, group: group)
                            }
                        }
                    }
                    .padding(.horizontal, page)
                    .padding(.bottom, page)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Recomputed on open rather than kept live: the figures cover a week, so
        // they never move while the user is looking at them except by dictating
        // — which the newest-entry watch below catches.
        .onAppear {
            now = Date()
            model.refreshUsageStats()
        }
        // Keyed on the newest entry's identity, not on `entries.count`:
        // `HistoryStore` caps at 100 and drops the oldest, so past that cap the
        // count never changes again and a count-watch would silently stop
        // refreshing for exactly the users who dictate most.
        .onChange(of: history.entries.first?.id) { _ in
            now = Date()
            model.refreshUsageStats()
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(narrow: Bool) -> some View {
        ColumnHeader(narrow: narrow) {
            Text(AppTab.dictation.title)
                .font(DS.Text.title())
                .tracking(DS.Tracking.title)

            if narrow {
                Spacer(minLength: 8)
            } else {
                // 「248 条 · 全部保存在本机」 — the count and where it lives, in
                // one line. Dropped in the narrow layout: at 460pt the search
                // field is the thing the user came to the header for, and a
                // count that truncates to 「248 条 · 全部保…」 tells them less
                // than the list under it already does.
                Text(OpenTypeL10n.text(
                    "\(displayedCount) 条 · 全部保存在本机",
                    english: "\(displayedCount) entries · all kept on this Mac"
                ))
                .font(DS.Text.mono())
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                Spacer(minLength: 8)
            }

            searchField(narrow: narrow)
            sourceFilter
        }
        // `ColumnHeader` pads to `DS.Space.content` (16) for the 334pt list
        // column; this page's padding is 24 when wide. Added outside rather
        // than by reaching into the shared header, which other columns rely on.
        .padding(.horizontal, narrow ? 0 : DS.Space.pageWide - DS.Space.content)
    }

    private func searchField(narrow: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(DS.Text.section())
                .foregroundStyle(.secondary)
            TextField(
                OpenTypeL10n.text("搜索转写内容", english: "Search transcripts"),
                text: $query
            )
            .textFieldStyle(.plain)
            .font(DS.Text.caption())
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(DS.Text.mono())
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(OpenTypeL10n.text("清除搜索", english: "Clear search"))
            }
        }
        .padding(.horizontal, 11)
        .frame(width: narrow ? 140 : 190, height: 26)
        .dsHeaderControl()
    }

    private var sourceFilter: some View {
        Menu {
            Button {
                source = nil
            } label: {
                // A leading checkmark rather than `Picker`: the menu also has to
                // carry a divider, and a `Picker` in a `Menu` renders its label
                // as a section header on macOS 13.
                Text(Self.marked(
                    OpenTypeL10n.text("全部来源", english: "All sources"),
                    selected: source == nil
                ))
            }
            if !sources.isEmpty {
                Divider()
                ForEach(sources, id: \.self) { name in
                    Button {
                        source = name
                    } label: {
                        Text(Self.marked(name, selected: source == name))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(source ?? OpenTypeL10n.text("全部来源", english: "All sources"))
                    .font(DS.Text.caption())
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(DS.Text.body())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .dsHeaderControl()
        .accessibilityLabel(OpenTypeL10n.text("来源筛选", english: "Filter by source"))
    }

    private static func marked(_ title: String, selected: Bool) -> String {
        selected ? "✓ " + title : "   " + title
    }

    // MARK: Data

    /// Every source app that has produced an entry, so the filter offers only
    /// choices that can return something.
    private var sources: [String] {
        var seen = Set<String>()
        return history.entries
            .map(\.applicationName)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted()
    }

    private var filtered: [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return history.entries.filter { entry in
            if let source, entry.applicationName != source { return false }
            guard !needle.isEmpty else { return true }
            // Both sides of the entry: a user searching for what they *said*
            // and a user searching for what they *got* are the same user, and
            // in transcribe mode the two strings differ by exactly the tidy-up.
            return entry.result.localizedCaseInsensitiveContains(needle)
                || entry.transcript.localizedCaseInsensitiveContains(needle)
                || entry.applicationName.localizedCaseInsensitiveContains(needle)
        }
    }

    private var displayedCount: Int { filtered.count }

    /// `filtered`, cut into calendar days, newest day first. `HistoryStore`
    /// already stores newest-first, so the rows inside a day keep that order
    /// without a second sort.
    private var groups: [DictationDay] {
        var order: [Date] = []
        var buckets: [Date: [HistoryEntry]] = [:]
        let calendar = Calendar.current

        for entry in filtered {
            let day = calendar.startOfDay(for: entry.createdAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(entry)
        }

        return order.map { day in
            DictationDay(id: day, title: Self.dayTitle(day), entries: buckets[day] ?? [])
        }
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) {
            return OpenTypeL10n.text("今天", english: "Today")
        }
        if calendar.isDateInYesterday(day) {
            return OpenTypeL10n.text("昨天", english: "Yesterday")
        }
        return DictationFormat.day.string(from: day)
    }

    // MARK: Empty

    private func emptyState(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(DS.Text.title())
                .foregroundStyle(.tertiary)
            Text(title)
                .font(DS.Text.body(.semibold))
            Text(subtitle)
                .font(DS.Text.caption())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

/// One calendar day's worth of dictations.
private struct DictationDay: Identifiable {
    let id: Date
    let title: String
    let entries: [HistoryEntry]
}

// MARK: - A day

/// A group label and the single card that holds that day's rows.
///
/// One card, N rows, hairlines between — not N cards. A card edge that means
/// "row" spends a shadow, a border and 8pt of gap on a boundary the user gets
/// for free from the line of text itself.
private struct DictationDayGroup: View {
    @ObservedObject var model: AppModel
    let group: DictationDay

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.label) {
            Text(group.title)
                .font(DS.Text.groupLabel())
                .tracking(DS.Tracking.groupLabel)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    if index == 0 {
                        DictationRow(model: model, entry: entry)
                    } else {
                        // Between rows only. A hairline above the first row
                        // would read as a second card edge 0.75pt inside the
                        // real one.
                        DictationRow(model: model, entry: entry)
                            .dsHairline(.top)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCard()
        }
    }
}

/// One dictation: when and where on the left, what was said in the middle,
/// what you can do with it on the right.
///
/// The left column is fixed at 64pt so the transcripts start on the same x in
/// every row — a ragged left edge on the one column the eye reads down is what
/// made the old list feel like a pile.
private struct DictationRow: View {
    @ObservedObject var model: AppModel
    let entry: HistoryEntry

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.content) {
            VStack(alignment: .leading, spacing: 3) {
                Text(DictationFormat.time.string(from: entry.createdAt))
                    .font(DS.Text.mono())
                    .foregroundStyle(.secondary)
                Text(entry.applicationName)
                    .font(dsNote())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 64, alignment: .leading)
            .padding(.top, 1)

            Text(entry.result)
                .font(DS.Text.body())
                // 13pt at a 1.6 line box: SwiftUI's `lineSpacing` is the extra
                // gap, not the box, so ~5 rather than ~21.
                .lineSpacing(5)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                DictationRowAction(
                    symbol: "doc.on.doc",
                    label: OpenTypeL10n.text("复制", english: "Copy")
                ) {
                    model.copy(entry.result)
                }
                DictationRowAction(
                    symbol: "arrow.counterclockwise",
                    label: OpenTypeL10n.text("重新使用", english: "Re-use")
                ) {
                    model.reuse(entry)
                }
            }
            // Hidden until the row is hovered, but never removed: the width
            // stays reserved so the transcript beside it does not reflow the
            // instant the pointer arrives.
            .opacity(hovering ? 1 : 0)
            .padding(.top, 1)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, DS.Space.content)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct DictationRowAction: View {
    let symbol: String
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DS.Text.section())
                .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - The stats band

/// 最近 7 天, as the 听写 page's own header (handoff §6).
///
/// Four figures and a bar strip, all of it recomputed from
/// `audit-events.v1.jsonl` at read time. Only the fourth figure is coloured,
/// and that is the whole editorial position of the band: 每 100 字纠错 is the
/// one number that is *supposed* to move — it should fall as the entity
/// dictionary learns what this user says — while the other three describe. If
/// all four were accented, none of them would be the one to watch.
struct UsageStatsBand: View {
    let summary: UsageStats.Summary
    let narrow: Bool
    /// Injected so the bar labels are stable across re-renders and testable
    /// without waiting for a real midnight.
    var now: Date = Date()

    /// The 34pt the tallest bar gets.
    private static let barHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            if narrow {
                narrowBody
            } else {
                wideBody
            }

            Text(OpenTypeL10n.text(
                """
                在这台 Mac 上从本地审计日志算出，不上传。中英混说时字数是两种单位的合计，\
                适合和自己过去比，不适合跨语言比较。
                """,
                english: """
                    Computed on this Mac from the local audit log — nothing is \
                    uploaded. For mixed Chinese/English speech the word total \
                    blends two units, so compare it with your own past numbers \
                    rather than across languages.
                    """
            ))
            .font(dsNote())
            .lineSpacing(4)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, narrow ? DS.Space.content : 20)
            .padding(.vertical, 9)
            .background(DS.Colour.inset)
            .dsHairline(.top)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCard()
    }

    // MARK: Wide

    private var wideBody: some View {
        HStack(alignment: .top, spacing: DS.Space.pageWide) {
            HStack(alignment: .top, spacing: 28) {
                figure(words)
                rule
                figure(endToEnd)
                rule
                figure(response)
                rule
                figure(rate)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            barStrip
                .frame(width: 190)
        }
        .padding(.horizontal, 20)
        .padding(.top, DS.Space.content)
        .padding(.bottom, 14)
    }

    private var rule: some View {
        Rectangle()
            .fill(DS.Colour.border)
            .frame(width: 0.75)
            .frame(maxHeight: .infinity)
    }

    // MARK: Narrow

    private var narrowBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                weekLabel
                Spacer(minLength: 0)
                deliveriesLabel
            }
            .padding(.horizontal, DS.Space.content)
            .padding(.top, 12)
            .padding(.bottom, 10)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 20, alignment: .leading),
                    GridItem(.flexible(), spacing: 20, alignment: .leading)
                ],
                alignment: .leading,
                spacing: 14
            ) {
                // The bar strip and the week-over-week trend both go: at this
                // width a 7-bar strip is 7 slivers, and the trend is the one
                // part of the fourth figure that can be dropped without the
                // figure itself stopping making sense.
                ForEach([words, endToEnd, response, rate]) { item in
                    compactFigure(item)
                }
            }
            .padding(.horizontal, DS.Space.content)
            .padding(.bottom, 14)
        }
    }

    // MARK: Figures

    private func figure(_ item: Figure) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                value(item, size: 26)
                if let trend = item.trend {
                    HStack(spacing: 2) {
                        Image(systemName: trend.symbol)
                            .font(DS.Text.body())
                        Text(trend.label)
                            .font(DS.Text.mono())
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            Text(item.label)
                .font(DS.Text.caption().weight(.medium))
                .foregroundStyle(item.hasData ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Text(item.note)
                .font(dsNote())
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactFigure(_ item: Figure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            value(item, size: 22)
            Text(item.label)
                .font(DS.Text.caption())
                .foregroundStyle(item.hasData ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(_ item: Figure, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(item.value)
                .font(DS.Text.mono(size, weight: .semibold))
                .tracking(DS.Tracking.title)
                .foregroundStyle(item.valueStyle)
            if let unit = item.unit {
                Text(unit)
                    // `DS.Text.section()` is the scale's 15pt step; the handoff
                    // draws the unit one weight lighter, which the token does
                    // not express. `.secondary` carries the same demotion.
                    .font(DS.Text.section())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label) \(item.value)\(item.unit ?? "")")
    }

    // MARK: Bars

    private var weekLabel: some View {
        Text(OpenTypeL10n.text("最近 7 天", english: "Last 7 days"))
            .font(DS.Text.groupLabel())
            .tracking(DS.Tracking.groupLabel)
            .foregroundStyle(.tertiary)
    }

    private var deliveriesLabel: some View {
        Text(OpenTypeL10n.text(
            "\(summary.deliveries) 次交付",
            english: "\(summary.deliveries) deliveries"
        ))
        .font(DS.Text.mono())
        .foregroundStyle(.tertiary)
    }

    private var barStrip: some View {
        let peak = max(summary.dailyWords.max() ?? 0, 1)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                weekLabel
                Spacer(minLength: 0)
                deliveriesLabel
            }

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(summary.dailyWords.enumerated()), id: \.offset) { index, count in
                    bar(index: index, count: count, peak: peak)
                }
            }
        }
    }

    private func bar(index: Int, count: Int, peak: Int) -> some View {
        // Rolling 24-hour buckets, oldest first: bar `i` covers the day ending
        // `(6 - i) * 86400` seconds ago. Not calendar days — `UsageStats` buckets
        // this way so the strip sums to the printed word total exactly.
        let day = now.addingTimeInterval(-Double(UsageStats.bucketCount - 1 - index) * 86_400)
        let isToday = index == summary.dailyWords.count - 1
        let height = count > 0
            ? max(2, Self.barHeight * CGFloat(count) / CGFloat(peak))
            : 0

        return VStack(spacing: 5) {
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(DS.Colour.hairline)
                    .frame(height: 0.75)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                UnevenRoundedTop(radius: 3)
                    .fill(DS.Colour.accent.opacity(0.55))
                    .frame(height: height)
            }
            .frame(height: Self.barHeight)
            .frame(maxWidth: .infinity)

            Text(isToday
                 ? OpenTypeL10n.text("今", english: "Now")
                 : DictationFormat.weekday.string(from: day))
                .font(DS.Text.mono(10))
                // The last bucket is the day the user is standing in, so it is
                // always short — it has had fewer hours to fill than the six
                // beside it. Marking it rather than letting it read as a
                // collapse is the whole reason this label differs.
                .foregroundStyle(isToday ? AnyShapeStyle(DS.Colour.accent) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
        }
        .help(isToday
              ? OpenTypeL10n.text(
                  "今天 · \(count) 字（当天还没过完）",
                  english: "Today · \(count) words (the day is still in progress)"
              )
              : OpenTypeL10n.text(
                  "\(DictationFormat.day.string(from: day)) · \(count) 字",
                  english: "\(DictationFormat.day.string(from: day)) · \(count) words"
              ))
    }

    // MARK: The four figures

    private struct Figure: Identifiable {
        let id: String
        let value: String
        /// 「秒」, set apart because it is prose riding on a number.
        var unit: String?
        let label: String
        let note: String
        /// `false` when the figure printed 「—」 or a dimmed zero. Drives the
        /// value's colour, and demotes the label with it.
        let hasData: Bool
        var accented = false
        var trend: Trend?

        var valueStyle: AnyShapeStyle {
            if !hasData { return AnyShapeStyle(HierarchicalShapeStyle.tertiary) }
            return accented ? AnyShapeStyle(DS.Colour.accent) : AnyShapeStyle(.primary)
        }
    }

    private struct Trend {
        let symbol: String
        let label: String
    }

    private var words: Figure {
        Figure(
            id: "words",
            // The one figure that prints a real `0` rather than 「—」: a week
            // that dictated nothing is a fact, where an unmeasurable latency is
            // an absence. Dimmed so the two still read differently.
            value: Self.grouped(summary.wordsDictated),
            label: OpenTypeL10n.text("说出的字数", english: "Words dictated"),
            note: OpenTypeL10n.text(
                "中文按字 · 英文按词",
                english: "CJK by character · Latin by word"
            ),
            hasData: summary.wordsDictated > 0
        )
    }

    private var endToEnd: Figure {
        Figure(
            id: "endToEnd",
            value: Self.latencyValue(summary.averageEndToEndLatency),
            unit: summary.averageEndToEndLatency == nil ? nil : Self.secondsUnit,
            label: OpenTypeL10n.text("平均等待", english: "Average wait"),
            note: OpenTypeL10n.text(
                "松开快捷键 → 出字",
                english: "Key release → delivered text"
            ),
            hasData: summary.averageEndToEndLatency != nil
        )
    }

    private var response: Figure {
        Figure(
            id: "response",
            value: Self.latencyValue(summary.averageResponseLatency),
            unit: summary.averageResponseLatency == nil ? nil : Self.secondsUnit,
            label: OpenTypeL10n.text("回答耗时", english: "Response time"),
            note: OpenTypeL10n.text(
                "识别之后 · 问答与 Agent",
                english: "After recognition · Ask and Agent"
            ),
            hasData: summary.averageResponseLatency != nil
        )
    }

    private var rate: Figure {
        let hasData = summary.wordsDictated > 0
        return Figure(
            id: "rate",
            // 「—」 rather than 「0.0」 when nothing was dictated: `Summary`
            // reports the rate as 0 in that case, and 「0.0」 under 每 100 字纠错
            // beside 「0 字」 reads as a perfect score rather than an empty week.
            value: hasData
                ? String(format: "%.1f", summary.correctionsPerHundredWords)
                : "—",
            label: OpenTypeL10n.text("每 100 字纠错", english: "Corrections per 100 words"),
            note: OpenTypeL10n.text(
                "词典学得越多应越低",
                english: "Should fall as the dictionary learns"
            ),
            hasData: hasData,
            accented: true,
            trend: trend(hasData: hasData)
        )
    }

    /// 「上周 N」, with the arrow pointing the way the number actually went.
    ///
    /// The handoff draws `arrow.down`, because down is the direction this
    /// metric is supposed to move. Drawing it unconditionally would print a
    /// falling arrow beside a rising number, so the glyph follows the
    /// comparison and the intent survives: down still means "better".
    private func trend(hasData: Bool) -> Trend? {
        guard hasData, let previous = summary.previousCorrectionsPerHundredWords else {
            return nil
        }
        let current = summary.correctionsPerHundredWords
        let symbol: String
        if current < previous {
            symbol = "arrow.down"
        } else if current > previous {
            symbol = "arrow.up"
        } else {
            symbol = "minus"
        }
        return Trend(
            symbol: symbol,
            label: OpenTypeL10n.text(
                String(format: "上周 %.1f", previous),
                english: String(format: "last week %.1f", previous)
            )
        )
    }

    // MARK: Formatting

    private static let secondsUnit = OpenTypeL10n.text("秒", english: "s")

    /// 「—」 for an absent measurement, never 「0.0」: a week whose sessions all
    /// predate `ImmutableAuditEvent.recordingEndedAt` has nothing to report, and
    /// 「0.0 秒」 would read as "instant".
    private static func latencyValue(_ latency: TimeInterval?) -> String {
        guard let latency else { return "—" }
        return String(format: "%.1f", latency)
    }

    private static func grouped(_ value: Int) -> String {
        DictationFormat.count.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Shapes

/// A bar with its top two corners rounded, per the handoff's `3 3 0 0`.
///
/// Hand-drawn because `UnevenRoundedRectangle` is macOS 14 and this target is
/// 13 — and because the radius has to shrink with the bar: a day worth 2pt
/// rounded at 3pt is a lozenge, not a bar, and the strip's shortest days are
/// exactly the ones a reader is trying to compare.
private struct UnevenRoundedTop: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, rect.height, rect.width / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + r),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Header control chrome

private extension View {
    /// The 26pt white pill the header's search field and source filter share.
    ///
    /// `DS.Radius.control` rather than the mock's 7pt: the token table assigns
    /// 6pt to 「控件：按钮、筛选 chip、分段控件、下拉、标签」, and both of these are
    /// controls. Keeping the closed scale is worth more than the 1pt.
    func dsHeaderControl() -> some View {
        DS.Shadow.control(
            background(
                DS.Colour.card,
                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Colour.border, lineWidth: 0.75)
            )
        )
    }
}

// MARK: - Formatters

/// Built once. `DateFormatter` construction is expensive enough that doing it
/// per row shows up in a list of 100.
private enum DictationFormat {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = OpenTypeL10n.locale
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 「8月13日」 in zh-Hans, 「Aug 13」 in English — from a template rather than
    /// a hardcoded pattern, so the order and separators follow the locale.
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = OpenTypeL10n.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// The single-character weekday under each bar.
    static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = OpenTypeL10n.locale
        formatter.dateFormat = "EEEEE"
        return formatter
    }()

    /// 「4,182」 — grouped, because the figure it sets is the one users read as
    /// a magnitude rather than a value.
    static let count: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = OpenTypeL10n.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}
