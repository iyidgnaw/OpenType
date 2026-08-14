import SwiftUI

/// 「记忆」 as a first-class page, out of Settings' fourth level.
///
/// It was buried because it reads like configuration. It is not — it is the
/// record of what this app has concluded about you, and the only place you can
/// see what an agent wrote into that record from untrusted context (P1-12).
/// Something you are expected to *review* cannot live four levels down; nobody
/// reviews what they have to go looking for.
///
/// Two columns at roughly 1.15 : 1, which is the ratio of the work: the entity
/// dictionary is a long dense list, while 「关于你」 and 「整理记录」 are short
/// and read like prose. Below `MemoryMetrics.twoColumnMinimum` they stack —
/// the left column's four parts (term, aliases, confidence, provenance) stop
/// fitting long before the window does.
struct MemoryColumn: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            let narrow = proxy.size.width < MemoryMetrics.twoColumnMinimum
            // Matches `ColumnHeader`'s own padding so the title, the status
            // line and every card below share one left edge.
            let pagePadding = narrow ? DS.Space.pageNarrow : DS.Space.content

            VStack(spacing: 0) {
                header(narrow: narrow)

                if let error = model.memoryEditError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(DS.Text.caption())
                        .foregroundStyle(DS.Colour.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, pagePadding)
                        .padding(.bottom, DS.Space.label)
                }

                if narrow {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.group) {
                            dictionary
                            ownerFacts
                            consolidationRuns
                        }
                        .padding(.horizontal, pagePadding)
                        .padding(.bottom, pagePadding)
                    }
                } else {
                    // Two independent scrollers, one per column: a 34-term
                    // dictionary must not push 「整理记录」 off the bottom of a
                    // page whose right half is three rows long.
                    HStack(alignment: .top, spacing: DS.Space.content) {
                        let available = proxy.size.width - pagePadding * 2 - DS.Space.content

                        ScrollView { dictionary }
                            .frame(width: available * MemoryMetrics.leftColumnShare)

                        ScrollView {
                            VStack(alignment: .leading, spacing: DS.Space.group) {
                                ownerFacts
                                consolidationRuns
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, pagePadding)
                    .padding(.bottom, pagePadding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(DS.Colour.canvas)
        .task { await model.refreshMemoryPanel() }
    }

    // MARK: - Header

    private func header(narrow: Bool) -> some View {
        ColumnHeader(narrow: narrow) {
            Text(OpenTypeL10n.text("记忆", english: "Memory"))
                .font(DS.Text.title())
                .tracking(DS.Tracking.title)

            // One line, three jobs: where this lives, when it last ran, and how
            // the last manual run went. They are the same fact at different
            // moments, so they take turns rather than stacking up.
            Text(statusLine)
                .font(DS.Text.mono())
                .foregroundStyle(statusIsFailure ? AnyShapeStyle(DS.Colour.warningText) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.consolidateMemoryNow()
            } label: {
                Group {
                    if model.consolidateNowStatus == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(OpenTypeL10n.text("立即整理", english: "Consolidate now"))
                            .font(DS.Text.caption())
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: MemoryMetrics.headerControlHeight)
                .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Colour.border, lineWidth: 0.75)
                )
                .modifier(ControlShadow())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.consolidateNowStatus == .running)
        }
    }

    private var statusLine: String {
        switch model.consolidateNowStatus {
        case .succeeded(let message), .failed(let message):
            return message
        case .idle, .running:
            let store = OpenTypeL10n.text("本机 SQLite", english: "Local SQLite")
            guard let last = model.memoryConsolidationRuns.first else {
                return store + " · " + OpenTypeL10n.text("尚未整理", english: "not consolidated yet")
            }
            let when = MemoryFormatters.readable.string(from: Self.date(last.ranAt))
            return store + " · " + OpenTypeL10n.text("上次整理 \(when)", english: "last consolidated \(when)")
        }
    }

    private var statusIsFailure: Bool {
        if case .failed = model.consolidateNowStatus { return true }
        return false
    }

    static func date(_ epochMilliseconds: Int) -> Date {
        Date(timeIntervalSince1970: Double(epochMilliseconds) / 1000)
    }

    // MARK: - Sections

    private var dictionary: some View {
        MemoryDictionaryCard(model: model)
    }

    private var ownerFacts: some View {
        MemoryOwnerFactsCard(model: model)
    }

    private var consolidationRuns: some View {
        MemoryConsolidationRunsCard(runs: model.memoryConsolidationRuns)
    }
}

// MARK: - Entity dictionary

/// 「实体词典」: the terms the app biases recognition towards and rewrites
/// aliases into. One card, N rows, hairlines between — not one card per row.
private struct MemoryDictionaryCard: View {
    @ObservedObject var model: AppModel
    @State private var showingAddTerm = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.label) {
            HStack(spacing: DS.Space.label) {
                MemorySectionLabel(
                    OpenTypeL10n.text("实体词典", english: "Entity dictionary"),
                    count: model.memoryTerms.count
                )
                Spacer(minLength: 0)
                Button {
                    showingAddTerm = true
                } label: {
                    Text(OpenTypeL10n.text("添加词条", english: "Add term"))
                        .font(DS.Text.caption().weight(.medium))
                        .foregroundStyle(DS.Colour.accent)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingAddTerm, arrowEdge: .bottom) {
                    MemoryTermForm(
                        title: OpenTypeL10n.text("添加词条", english: "Add term"),
                        term: nil
                    ) { canonicalTerm, aliases, _ in
                        await model.createMemoryTerm(canonicalTerm: canonicalTerm, aliases: aliases)
                    } onDismiss: {
                        showingAddTerm = false
                    }
                }
            }
            .padding(.horizontal, MemoryMetrics.labelInset)

            if model.memoryTerms.isEmpty {
                MemoryEmptyRow(
                    OpenTypeL10n.text(
                        "还没有词条。整理记忆时会自动学到一些，你也可以直接添加。",
                        english: "No terms yet. Consolidation learns some on its own, and you can add your own here."
                    )
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.memoryTerms.enumerated()), id: \.element.id) { index, term in
                        MemoryTermRowView(model: model, term: term)
                            .modifier(MemoryRowSeparator(isFirst: index == 0))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .dsCard()
            }
        }
    }
}

/// One dictionary row: term and aliases, how sure the app is, where it came
/// from, and — only while the pointer is on the row — edit and delete.
///
/// The two actions are hover-revealed but their space is *not*: an always-empty
/// trailing slot costs a fixed strip of the column, while a slot that appears
/// on hover reflows every row under the pointer. In a list you are scanning,
/// the reflow is the more expensive of the two.
private struct MemoryTermRowView: View {
    @ObservedObject var model: AppModel
    let term: EntityTermSummary

    @State private var isHovered = false
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false

    /// The editor's popover is anchored to the pencil, so the actions have to
    /// outlast the pointer leaving the row — otherwise opening the editor
    /// yanks its own anchor away.
    private var revealsActions: Bool { isHovered || showingEditor }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(term.canonicalTerm)
                    .font(DS.Text.body(.medium))
                    .lineLimit(1)
                Text(term.aliases.isEmpty
                     ? OpenTypeL10n.text("无别名", english: "no aliases")
                     : term.aliases.joined(separator: " · "))
                    .font(DS.Text.mono())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.0f%%", term.confidence * 100))
                    .font(DS.Text.mono())
                    .foregroundStyle(.tertiary)
                ConfidenceBar(value: term.confidence)
            }
            .frame(width: MemoryMetrics.confidenceColumn, alignment: .trailing)

            MemoryOriginTag(origin: term.origin, style: .compact)
                .frame(width: MemoryMetrics.originColumn, alignment: .trailing)

            HStack(spacing: 2) {
                MemoryRowAction(
                    symbol: "pencil",
                    help: OpenTypeL10n.text("编辑这个词条", english: "Edit this term")
                ) {
                    showingEditor = true
                }
                .popover(isPresented: $showingEditor, arrowEdge: .bottom) {
                    MemoryTermForm(
                        title: OpenTypeL10n.text("编辑词条", english: "Edit term"),
                        term: term
                    ) { canonicalTerm, aliases, confidence in
                        await model.updateMemoryTerm(
                            id: term.id,
                            canonicalTerm: canonicalTerm,
                            aliases: aliases,
                            confidence: confidence
                        )
                    } onDismiss: {
                        showingEditor = false
                    }
                }

                MemoryRowAction(
                    symbol: "trash",
                    help: OpenTypeL10n.text("删除这个词条", english: "Delete this term")
                ) {
                    showingDeleteConfirmation = true
                }
            }
            .frame(width: MemoryMetrics.actionColumn, alignment: .trailing)
            // The editor's popover has to survive the pointer leaving the row.
            .opacity(revealsActions ? 1 : 0)
            // An invisible view still takes clicks, and an invisible *delete*
            // button that takes clicks is a way to lose a term without seeing
            // what you hit.
            .allowsHitTesting(revealsActions)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, DS.Space.rowV)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // `DELETE /memory/terms/:id` drops the row and there is no undo, so it
        // gets the same confirm step Settings puts in front of a history reset.
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
}

/// A 40×2pt reading of one confidence value.
///
/// Drawn in a neutral tone rather than the accent: this is a description of
/// what the app currently believes, not a thing that wants the user's
/// attention. Colour on this page is reserved for the unconfirmed rows.
private struct ConfidenceBar: View {
    let value: Double

    var body: some View {
        let fraction = min(max(value, 0), 1)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(DS.Colour.border)
                .frame(width: MemoryMetrics.barWidth, height: MemoryMetrics.barHeight)
            Capsule()
                .fill(.tertiary)
                .frame(width: MemoryMetrics.barWidth * fraction, height: MemoryMetrics.barHeight)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Owner facts

/// 「关于你」: free-text facts the app carries into the assistant's context.
private struct MemoryOwnerFactsCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.label) {
            MemorySectionLabel(
                OpenTypeL10n.text("关于你", english: "About you"),
                count: model.memoryOwnerFacts.count
            )
            .padding(.horizontal, MemoryMetrics.labelInset)

            if model.memoryOwnerFacts.isEmpty {
                MemoryEmptyRow(
                    OpenTypeL10n.text(
                        "还没有记忆。助理在对话里记住的事会出现在这里。",
                        english: "Nothing remembered yet. What the assistant picks up in conversation shows up here."
                    )
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.memoryOwnerFacts.enumerated()), id: \.element.id) { index, fact in
                        MemoryOwnerFactRowView(model: model, fact: fact)
                            .modifier(MemoryRowSeparator(isFirst: index == 0))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .dsCard()
            }
        }
    }
}

/// One remembered fact, its provenance, and — when that provenance is anything
/// but the owner's own word — the two things a reviewer can do about it.
///
/// 「确认」 is why this row exists. Provenance is here so the user can review
/// what an agent planted from untrusted context (P1-12), and until now the only
/// answer to a flagged fact that happened to be *true* was to delete it, which
/// throws away something correct in order to silence a warning. A flag the user
/// cannot clear is noise, and a user who learns the flag never goes away learns
/// to ignore it — costing exactly the signal it was added for.
///
/// No confirmation dialog in front of 「确认」, deliberately, even though the
/// promotion is one-way. The fact's text is directly above the button, so the
/// user is already looking at what they are vouching for; a dialog would turn
/// reviewing five facts into ten clicks, which is how a review surface becomes
/// a thing people skip. 「删除」 keeps its dialog: that one destroys content.
private struct MemoryOwnerFactRowView: View {
    @ObservedObject var model: AppModel
    let fact: OwnerFactSummary

    @State private var showingDeleteConfirmation = false

    /// The amber tint is for `untrusted` alone — a fact that reached the store
    /// through the agent loop, where the content can have come from a web page.
    /// That is a different claim from "not yet vouched for", and spending the
    /// warning colour on both would flatten it.
    private var isUntrusted: Bool { fact.origin == "untrusted" }

    /// 「确认」 is offered on *every* non-owner origin, not just the tinted
    /// ones, because the sidebar's dot (`hasUnconfirmedMemory`) counts every
    /// non-owner origin. If an `agent` or `system` fact could not be confirmed,
    /// a user with one of those and nothing else would carry a dot they have no
    /// way to clear — the exact "flag you learn to ignore" this action exists
    /// to prevent.
    private var canConfirm: Bool { fact.origin != "owner" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fact.content)
                .font(DS.Text.body())
                .lineSpacing(MemoryMetrics.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DS.Space.label) {
                MemoryOriginTag(origin: fact.origin, style: .full)

                if canConfirm {
                    Button {
                        Task { await model.confirmMemoryOwnerFact(id: fact.id) }
                    } label: {
                        Text(OpenTypeL10n.text("确认", english: "Confirm"))
                            .font(DS.Text.caption().weight(.medium))
                            .foregroundStyle(DS.Colour.accent)
                    }
                    .buttonStyle(.plain)
                    .help(OpenTypeL10n.text(
                        "确认后这条记忆记为你亲自认可，不再标为未确认",
                        english: "Marks this fact as vouched for by you, clearing the unverified flag"
                    ))

                    Button {
                        showingDeleteConfirmation = true
                    } label: {
                        Text(OpenTypeL10n.text("删除", english: "Delete"))
                            .font(DS.Text.caption().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A tint rather than a border: it marks the row as needing a look
        // without competing with the accent, and it disappears the moment the
        // row is confirmed, which is the whole feedback loop.
        .background(isUntrusted ? DS.Colour.warning.opacity(MemoryMetrics.reviewTint) : Color.clear)
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

// MARK: - Consolidation log

/// 「整理记录」: what each consolidation pass concluded, newest first.
private struct MemoryConsolidationRunsCard: View {
    let runs: [ConsolidationRunSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.label) {
            MemorySectionLabel(
                OpenTypeL10n.text("整理记录", english: "Consolidation log"),
                count: nil
            )
            .padding(.horizontal, MemoryMetrics.labelInset)

            if runs.isEmpty {
                MemoryEmptyRow(
                    OpenTypeL10n.text("还没有整理过。", english: "No consolidation has run yet.")
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(MemoryFormatters.log.string(from: MemoryColumn.date(run.ranAt)))
                                .font(DS.Text.mono())
                                .foregroundStyle(.tertiary)
                                .frame(width: MemoryMetrics.logTimeColumn, alignment: .leading)
                            // A rolled-back run still happened, so the row
                            // stays; its summary describes changes that are no
                            // longer in effect, so it reads at the level of a
                            // footnote rather than a result.
                            Text(run.rolledBackAt == nil
                                 ? run.summary
                                 : OpenTypeL10n.text("已回滚 · \(run.summary)", english: "Rolled back · \(run.summary)"))
                                .font(DS.Text.caption())
                                .foregroundStyle(run.rolledBackAt == nil
                                                 ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                                                 : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                                .lineSpacing(MemoryMetrics.logLineSpacing)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, DS.Space.rowV)
                        .modifier(MemoryRowSeparator(isFirst: index == 0))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .dsCard()
            }
        }
    }
}

// MARK: - Shared pieces

/// The provenance badge, in two lengths.
///
/// `compact` exists because the dictionary gives it a fixed narrow column
/// beside three other things; `full` is for a fact, where the badge is the row's
/// only label and has room to say what it means. Both draw `untrusted` in the
/// warning palette and everything else neutral — the point of the badge is to
/// separate "you said this" from "something else said this", not to grade five
/// shades of origin.
private struct MemoryOriginTag: View {
    enum Style { case compact, full }

    let origin: String?
    let style: Style

    private var needsReview: Bool { origin == "untrusted" }

    var body: some View {
        Text(label)
            .font(DS.Text.groupLabel())
            .foregroundStyle(needsReview ? AnyShapeStyle(DS.Colour.warningText) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                needsReview ? DS.Colour.warningFill : DS.Colour.inset,
                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            )
    }

    private var label: String {
        switch (origin, style) {
        case ("owner", .compact):
            return OpenTypeL10n.text("确认", english: "Yours")
        case ("owner", .full):
            return OpenTypeL10n.text("你确认过", english: "Confirmed by you")
        case ("untrusted", .compact):
            return OpenTypeL10n.text("未确认", english: "Unverified")
        case ("untrusted", .full):
            return OpenTypeL10n.text("未经确认", english: "Unverified")
        case ("agent", .compact):
            return OpenTypeL10n.text("助理", english: "Agent")
        case ("agent", .full):
            return OpenTypeL10n.text("助理写入", english: "Written by the agent")
        case ("system", .compact):
            return OpenTypeL10n.text("自动", english: "Auto")
        case ("system", .full):
            return OpenTypeL10n.text("自动整理", english: "Auto-consolidated")
        case (_, .compact):
            return OpenTypeL10n.text("未知", english: "Unknown")
        case (_, .full):
            return OpenTypeL10n.text("来源未知", english: "Unknown source")
        }
    }
}

/// The group label above a card, optionally carrying its own count.
private struct MemorySectionLabel: View {
    let title: String
    let count: Int?

    init(_ title: String, count: Int?) {
        self.title = title
        self.count = count
    }

    var body: some View {
        Text(count.map { "\(title) · \($0)" } ?? title)
            .font(DS.Text.groupLabel())
            .tracking(DS.Tracking.groupLabel)
            .foregroundStyle(.tertiary)
    }
}

/// An empty section still gets a card, so the page keeps its shape and the
/// line explaining the emptiness sits where the rows will be.
private struct MemoryEmptyRow: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(DS.Text.caption())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
    }
}

/// The hairline between rows of one card — never above the first row, which
/// would double up with the card's own border.
private struct MemoryRowSeparator: ViewModifier {
    let isFirst: Bool

    func body(content: Content) -> some View {
        if isFirst {
            content
        } else {
            content.dsHairline(.top)
        }
    }
}

/// A hover-revealed row action: small, square, no chrome until it is under the
/// pointer.
private struct MemoryRowAction: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: MemoryMetrics.actionButton, height: MemoryMetrics.actionButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Add and edit share one form, because they are one operation with a
/// different starting point — and because a separate add form is how the two
/// drift into validating different things.
///
/// It is a popover rather than an inline editor: the row it edits is 11pt tall
/// in a list you scan by rhythm, and flipping one row into a three-field form
/// breaks that rhythm for every row below it.
private struct MemoryTermForm: View {
    let title: String
    let term: EntityTermSummary?
    let submit: (String, [String], Double) async -> Bool
    let onDismiss: () -> Void

    @State private var canonicalTerm: String = ""
    @State private var aliases: String = ""
    @State private var confidence: Double = 1.0
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(DS.Text.body(.semibold))

            TextField(OpenTypeL10n.text("词条", english: "Term"), text: $canonicalTerm)
                .textFieldStyle(.roundedBorder)
                .font(DS.Text.body())

            TextField(
                OpenTypeL10n.text("别名，用逗号分隔", english: "Aliases, comma-separated"),
                text: $aliases
            )
            .textFieldStyle(.roundedBorder)
            .font(DS.Text.body())

            if term != nil {
                HStack(spacing: DS.Space.label) {
                    Text(OpenTypeL10n.text("置信度", english: "Confidence"))
                        .font(DS.Text.caption())
                        .foregroundStyle(.secondary)
                    // A slider, not a field: confidence is 0…1 on the sidecar
                    // side and anything outside that is a 400, so the control
                    // simply cannot express an invalid value.
                    Slider(value: $confidence, in: 0...1)
                    Text(String(format: "%.0f%%", confidence * 100))
                        .font(DS.Text.mono())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: DS.Space.label) {
                Spacer(minLength: 0)
                Button(OpenTypeL10n.text("取消", english: "Cancel")) { onDismiss() }
                    .controlSize(.small)
                Button(OpenTypeL10n.text("保存", english: "Save")) { save() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || canonicalTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Space.content)
        .frame(width: MemoryMetrics.formWidth)
        .onAppear {
            canonicalTerm = term?.canonicalTerm ?? ""
            aliases = term?.aliases.joined(separator: ", ") ?? ""
            confidence = term?.confidence ?? 1.0
        }
    }

    private func save() {
        let canonical = canonicalTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return }
        let parsed = MemoryTermForm.parseAliases(aliases)
        let value = confidence
        isSubmitting = true
        Task {
            let ok = await submit(canonical, parsed, value)
            isSubmitting = false
            if ok { onDismiss() }
        }
    }

    /// Splits the comma-separated alias field. Accepts the full-width comma
    /// too — the aliases people type here are frequently Chinese, and a Chinese
    /// keyboard produces "，" without the user thinking about it.
    static func parseAliases(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// `DS.Shadow.control` as a modifier, so it can sit in a `.modifier(_:)` chain
/// alongside the rest of a button's styling.
private struct ControlShadow: ViewModifier {
    func body(content: Content) -> some View {
        DS.Shadow.control(content)
    }
}

// MARK: - Metrics and formatting

/// Fixed widths this page owns, named rather than inlined for the same reason
/// `DS.Size` exists: a number that appears twice is a number that will
/// eventually appear as two different numbers.
private enum MemoryMetrics {
    /// 1.15 : 1, as a share of the space left after the gap.
    static let leftColumnShare: CGFloat = 1.15 / 2.15
    /// Below this the two columns stack. A dictionary row carries four things
    /// across its width; they stop fitting well before the window itself does.
    static let twoColumnMinimum: CGFloat = 640

    static let confidenceColumn: CGFloat = 44
    static let originColumn: CGFloat = 52
    static let actionColumn: CGFloat = 46
    static let actionButton: CGFloat = 22
    static let logTimeColumn: CGFloat = 76

    static let barWidth: CGFloat = 40
    static let barHeight: CGFloat = 2

    static let headerControlHeight: CGFloat = 26
    static let formWidth: CGFloat = 300
    /// The group label sits slightly inside its card's edge rather than flush,
    /// so the label reads as belonging to the card below it.
    static let labelInset: CGFloat = 4

    /// 13pt at a 1.6 line height, and 12pt at 1.5, expressed the way SwiftUI
    /// takes it — as the extra space between lines.
    static let bodyLineSpacing: CGFloat = 13 * 0.6
    static let logLineSpacing: CGFloat = 12 * 0.5

    /// The tint behind a fact still waiting to be reviewed.
    static let reviewTint: Double = 0.05
}

private enum MemoryFormatters {
    /// The header's "last consolidated" stamp: prose, so it follows the
    /// interface language's own conventions rather than a hardcoded pattern.
    static let readable: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = OpenTypeL10n.locale
        formatter.setLocalizedDateFormatFromTemplate("Mdjmm")
        return formatter
    }()

    /// The run log's timestamp: a machine stamp in a fixed-width column, so it
    /// is deliberately pattern-based and identical in every language.
    static let log: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
