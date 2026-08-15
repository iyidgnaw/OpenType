import SwiftUI

/// The redesigned 会话 screen: the merged Q&A + Agent list, and the thread
/// beside it (2026-08 handoff, sections 01 and 02).
///
/// Two tabs became one because they were never two places. A user who asks a
/// question and then gives a task should not have to remember which tab it
/// landed in — the data shape was already identical (a `conversationId` and a
/// message list; only the toolset differs), so the split was an artifact of
/// there having been two fetches. One list, and a 5pt dot carries the
/// distinction.
///
/// Everything here is measured from the handoff, and where the mockup and a
/// token disagree the **mockup wins** — 稿子优先, the owner's ruling of
/// 2026-08-15. An earlier pass rounded the markup's 11.5pt chips to 12, its 8pt
/// inner block to 10, its 5pt tag to 6 and its six border alphas to one, on the
/// theory that a closed scale is worth a point here and there. Across six
/// screens that stopped being a rounding convention and became the
/// implementation overruling the design, so the literals are back and
/// `DesignTokens.swift` carries a step for each of them.

// MARK: - List column

/// The 334pt middle column: header, filter chips, the pinned 进行中 card, and
/// the date-grouped history.
///
/// The list is grouped into **one card per day holding N rows**, not one card
/// per row. A card per row spends a border, a shadow and 8pt of gutter on
/// every entry to say something the rows already say by being adjacent; at
/// twelve conversations it reads as twelve objects rather than one list.
struct SessionsListColumn: View {
    @ObservedObject var model: AppModel
    /// Only changes the content gutter (12 → 14). Row and card metrics are
    /// identical in both layouts, so nothing has to be re-learned on resize.
    var narrow: Bool = false

    @State private var searching = false
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if searching { searchField }
            filterChips
            list
        }
        .background(DS.Colour.canvas)
        .task {
            await model.refreshAskConversations()
            await model.refreshAgentConversations()
        }
    }

    // MARK: Header

    private var header: some View {
        // Deliberately not `ColumnHeader(narrow:)`: that component hardcodes the
        // page gutter (24 wide / 14 narrow) and the handoff gives this column 16
        // in *both* layouts — only the scrolling content below tightens to 14.
        // Passing `narrow` would move the title relative to the chips it heads.
        SessionColumnHeader(leading: DS.Space.content, trailing: DS.Space.content, spacing: 10) {
            Text(OpenTypeL10n.text("会话", english: "Sessions"))
                .font(DS.Text.title())
                .tracking(DS.Tracking.title)
                .frame(maxWidth: .infinity, alignment: .leading)

            SessionIconButton(
                symbol: "magnifyingglass",
                filled: false,
                help: OpenTypeL10n.text("搜索会话", english: "Search sessions")
            ) {
                searching.toggle()
                if !searching { query = "" }
            }

            SessionIconButton(
                symbol: "plus",
                filled: true,
                help: OpenTypeL10n.text("新对话", english: "New conversation")
            ) {
                startNewConversation()
            }
        }
    }

    /// The magnifying glass has to do something, and the handoff draws the
    /// button without drawing a results screen — so it filters what is already
    /// rendered, exactly like the chips, rather than opening a search mode with
    /// its own state.
    private var searchField: some View {
        // Undrawn, so it borrows 3A's search box wholesale rather than
        // inventing a fourth header-control spec: 26pt, r7, 11pt gutter, a .09
        // edge and the control lift.
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(DS.Text.size(15))
                .foregroundStyle(DS.Colour.ink(0.5))
            TextField(
                "",
                text: $query,
                prompt: Text(OpenTypeL10n.text("搜索会话标题", english: "Search titles"))
                    .font(DS.Text.caption())
                    .foregroundColor(DS.Colour.ink(0.4))
            )
            .textFieldStyle(.plain)
            .font(DS.Text.caption())
        }
        .padding(.horizontal, 11)
        .frame(height: DS.Size.headerControl)
        .modifier(SessionHeaderControlChrome())
        .padding(.horizontal, DS.Space.content)
        .padding(.bottom, 8)
    }

    private var filterChips: some View {
        HStack(spacing: 5) {
            ForEach(SessionFilter.allCases) { filter in
                SessionFilterChip(
                    filter: filter,
                    selected: model.sessionFilter == filter
                ) {
                    model.sessionFilter = filter
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.content)
        .padding(.bottom, 10)
    }

    // MARK: Body

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !runningRuns.isEmpty {
                    runningGroup
                }
                ForEach(SessionDay.grouped(visibleConversations)) { day in
                    dayGroup(day)
                }
                if runningRuns.isEmpty, visibleConversations.isEmpty {
                    empty
                }
            }
            .padding(.horizontal, narrow ? DS.Space.pageNarrow : 12)
            .padding(.bottom, narrow ? DS.Space.pageNarrow : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    /// The mockup does not draw the empty case, but the tabs this screen
    /// replaces each had one, and a blank column reads as broken rather than
    /// as new.
    private var empty: some View {
        Text(
            query.isEmpty
                ? OpenTypeL10n.text("还没有会话。按住快捷键说一句，就有了。", english: "No sessions yet. Hold the shortcut and say something.")
                : OpenTypeL10n.text("没有匹配的会话", english: "No matching sessions")
        )
        .font(DS.Text.caption())
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 40)
        .padding(.horizontal, 16)
    }

    private var runningGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                SessionPulseDot()
                SessionGroupLabel(OpenTypeL10n.text("进行中", english: "In progress"))
            }
            .padding(.horizontal, DS.Space.labelInset)

            ForEach(runningRuns) { run in
                SessionRunningCard(run: run) {
                    model.cancelAgentRun(run.id)
                }
            }
        }
    }

    private func dayGroup(_ day: SessionDay) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SessionGroupLabel(day.title)
                .padding(.horizontal, DS.Space.labelInset)

            VStack(spacing: 0) {
                ForEach(Array(day.conversations.enumerated()), id: \.element.id) { index, conversation in
                    SessionRow(
                        conversation: conversation,
                        selected: model.focusedConversation?.id == conversation.id,
                        firstInCard: index == 0
                    ) {
                        open(conversation)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCard()
        }
    }

    // MARK: Data

    private var runningRuns: [AgentRunRecord] {
        model.agentRuns.filter { $0.status.isRunning }
    }

    /// Chips and search narrow what is drawn, never what was fetched — so
    /// switching either costs no refetch and can never lose a row.
    private var visibleConversations: [ConversationSummary] {
        let byChip = SessionList.filtered(model.sessionConversations, by: model.sessionFilter)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return byChip }
        return byChip.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private func open(_ conversation: ConversationSummary) {
        // A conversation written by a newer sidecar has a `kind` this build
        // cannot route. It stays listed rather than silently impersonating an
        // ask thread, which would send its next turn to the wrong endpoint.
        guard let kind = conversation.sessionKind else { return }
        model.focusedConversation = FocusedConversation(id: conversation.id, kind: kind)
        switch kind {
        case .ask: model.openAskConversation(conversation.id)
        case .agent: model.openAgentConversation(conversation.id)
        }
    }

    private func startNewConversation() {
        model.focusedConversation = nil
        model.startNewAskConversation()
        model.startNewAgentConversation()
    }
}

// MARK: - Thread column

/// The detail column: one conversation, its step log, and a composer that
/// continues it.
///
/// Two decisions from the handoff carry most of the weight here. **Assistant
/// turns get no bubble** — a bubble frames a remark, and an Agent's answer is
/// a document with headings, tables and paths in it; boxing it at 78% width
/// and centring the reader's eye on a chat rhythm fights what it is. The user's
/// own turn keeps its bubble precisely because it *is* a remark. And **the
/// composer continues `conversationId`** rather than starting a fresh
/// conversation, so a thread you are reading is a thread you can talk to.
struct SessionThreadColumn: View {
    @ObservedObject var model: AppModel
    var narrow: Bool = false
    /// Sends a typed turn into `conversation`, continuing it.
    ///
    /// A closure rather than a call into `AppModel` because no entry point for
    /// a *typed* turn exists yet — every dispatch today starts from a
    /// recording (`dispatchAskRun`/`dispatchAgentRun` are private and take a
    /// transcript). Left required, not defaulted, so wiring it is a decision
    /// someone makes rather than a no-op they inherit.
    var onSubmit: (String, FocusedConversation) -> Void

    @State private var draft = ""

    var body: some View {
        Group {
            if let focused = model.focusedConversation {
                thread(focused)
            } else {
                placeholder
            }
        }
        .background(DS.Colour.card)
    }

    private func thread(_ focused: FocusedConversation) -> some View {
        VStack(spacing: 0) {
            header(focused)
            if let detail = detail(for: focused) {
                messages(detail, focused: focused)
            } else {
                loading
            }
            composer(focused)
        }
    }

    // MARK: Header

    private func header(_ focused: FocusedConversation) -> some View {
        // The handoff gives this header its own gutters — 20 on both sides wide,
        // and 10/14 narrow so the back chevron sits closer to the edge than the
        // ellipsis does. `ColumnHeader`'s fixed 24/14 would put the type tag a
        // step out from the content under it.
        SessionColumnHeader(
            leading: narrow ? 10 : 20,
            trailing: narrow ? DS.Space.pageNarrow : 20,
            spacing: narrow ? 8 : 10
        ) {
            if narrow {
                // Narrow pushes the thread over the list, so the only way
                // back is here. Wide keeps the list visible beside it.
                Button(action: clearFocus) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(DS.Colour.accent)
                }
                .buttonStyle(.plain)
                .help(OpenTypeL10n.text("返回列表", english: "Back to list"))
            }

            SessionKindTag(kind: focused.kind)

            Text(detail(for: focused)?.title ?? OpenTypeL10n.text("对话", english: "Conversation"))
                // 14/600 — a heading for one conversation, deliberately a step
                // under the 15/600 that heads a section of a page.
                .font(DS.Text.size(14, .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Narrow drops the copy button and keeps only 「更多」: the back
            // chevron has already taken a slot, and the same action is one row
            // down the menu. The handoff draws it exactly this way.
            if !narrow {
                Button {
                    copyTranscript(focused)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(DS.Text.size(17))
                        .foregroundStyle(DS.Colour.ink(0.45))
                }
                .buttonStyle(.plain)
                .help(OpenTypeL10n.text("复制全文", english: "Copy transcript"))
            }

            Menu {
                Button(OpenTypeL10n.text("新对话", english: "New conversation")) {
                    clearFocus()
                }
                Button(OpenTypeL10n.text("复制全文", english: "Copy transcript")) {
                    copyTranscript(focused)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(DS.Text.size(17))
                    .foregroundStyle(DS.Colour.ink(0.45))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .modifier(SessionEdgeBorder(edge: .bottom))
    }

    // MARK: Messages

    private func messages(_ detail: ConversationDetail, focused: FocusedConversation) -> some View {
        GeometryReader { proxy in
            let gutter = narrow ? 18.0 : 28.0
            let available = max(proxy.size.width - gutter * 2, 1)

            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: narrow ? 18 : 20) {
                        ForEach(Array(detail.messages.enumerated()), id: \.element.id) { index, message in
                            // The log and the answer it produced are one turn at
                            // 12pt, not two messages at 20 — they are the same
                            // reply, seen from two distances.
                            VStack(alignment: .leading, spacing: 12) {
                                if index == stepLogAnchor(in: detail), let log = stepLog(for: focused) {
                                    log
                                }
                                // 78% wide, 80% narrow: the same bubble reads as
                                // narrower when the column is, so the handoff
                                // gives the tighter layout the looser cap.
                                SessionTurn(message: message, maxBubbleWidth: available * (narrow ? 0.80 : 0.78))
                            }
                            .id(message.id)
                        }
                        if isWorking(focused) {
                            SessionWorkingRow()
                                .id(Self.workingRowID)
                        }
                    }
                    .padding(.horizontal, gutter)
                    .padding(.vertical, narrow ? 20 : DS.Space.pageWide)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .onAppear { scroller.scrollTo(bottomAnchor(detail, focused: focused), anchor: .bottom) }
                .onChange(of: detail.messages.count) { _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        scroller.scrollTo(bottomAnchor(detail, focused: focused), anchor: .bottom)
                    }
                }
            }
        }
    }

    private static let workingRowID = "session.working"

    private func bottomAnchor(_ detail: ConversationDetail, focused: FocusedConversation) -> AnyHashable {
        isWorking(focused)
            ? AnyHashable(Self.workingRowID)
            : AnyHashable(detail.messages.last?.id ?? 0)
    }

    /// Where the step log goes: immediately before the answer it produced, so
    /// the reading order is task → what it did → what it found.
    private func stepLogAnchor(in detail: ConversationDetail) -> Int? {
        detail.messages.lastIndex { $0.role != "user" }
    }

    /// The steps for this conversation, if this session still has them.
    ///
    /// Steps are not persisted with the conversation — `GET /conversations/:id`
    /// returns roles and content only — so a thread from a previous launch has
    /// no log to show. Live runs are matched through the voice surface, which
    /// is the only place a *running* run's conversation id is known
    /// (`AgentRunRecord.conversationId` is filled in on completion).
    private func stepLog(for focused: FocusedConversation) -> StepLog? {
        // Only Agent threads have steps. Conversation ids are unique across
        // both kinds, so matching on id alone would also be correct — but the
        // rule is "step logs belong to agent runs", and code that relies on an
        // id space instead of saying so breaks quietly if that ever changes.
        guard focused.kind == .agent else { return nil }
        if let panel = model.agentPanelState,
           panel.conversationId == focused.id,
           !panel.steps.isEmpty {
            return StepLog(progress: panel.steps)
        }
        guard let run = model.agentRuns.first(where: { $0.conversationId == focused.id }),
              !run.steps.isEmpty
        else { return nil }
        return StepLog(steps: run.steps, elapsed: SessionFormat.elapsed(of: run))
    }

    private func isWorking(_ focused: FocusedConversation) -> Bool {
        if let panel = model.agentPanelState,
           panel.conversationId == focused.id,
           panel.phase == .running {
            return true
        }
        if let ask = model.askPanelState,
           ask.conversationId == focused.id,
           ask.answer == nil {
            return true
        }
        return false
    }

    private var loading: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(OpenTypeL10n.text("正在加载对话…", english: "Loading conversation…"))
                .font(DS.Text.caption())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 22))
                .foregroundStyle(.quaternary)
            Text(OpenTypeL10n.text("选一条会话，或按住快捷键说话", english: "Pick a session, or hold the shortcut and speak"))
                .font(DS.Text.caption())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Composer

    private func composer(_ focused: FocusedConversation) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(OpenTypeL10n.text("接着说，或按住 ⌥ 口述…", english: "Keep talking, or hold ⌥ to dictate…"))
                            .font(DS.Text.body())
                            .foregroundStyle(DS.Colour.ink(0.35))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(DS.Text.body())
                        .lineLimit(1...6)
                        .onSubmit { send(focused) }
                }
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

                SessionComposerButton(symbol: "mic.fill", filled: false, help: OpenTypeL10n.text("说话", english: "Speak")) {
                    model.hotKeyToggled()
                }
                SessionComposerButton(symbol: "arrow.up", filled: true, help: OpenTypeL10n.text("发送", english: "Send")) {
                    send(focused)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .background(DS.Colour.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                // .08, a step heavier than a card's own edge: the composer is
                // the same colour as the page behind it, so its own edge is the
                // only thing that says where it starts.
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Colour.borderStrong, lineWidth: 0.75)
            )
        }
        .padding(.horizontal, narrow ? DS.Space.content : 20)
        .padding(.top, narrow ? 12 : 14)
        .padding(.bottom, narrow ? DS.Space.content : 18)
        .modifier(SessionEdgeBorder(edge: .top))
    }

    private func send(_ focused: FocusedConversation) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSubmit(text, focused)
    }

    // MARK: Actions

    private func detail(for focused: FocusedConversation) -> ConversationDetail? {
        let candidate = focused.kind == .agent
            ? model.agentConversationDetail
            : model.askConversationDetail
        // The two details are fetched independently, so a stale one from the
        // previously-open thread can still be sitting in the other slot.
        return candidate?.id == focused.id ? candidate : nil
    }

    private func copyTranscript(_ focused: FocusedConversation) {
        guard let detail = detail(for: focused) else { return }
        model.copy(detail.messages.map(\.content).joined(separator: "\n\n"))
    }

    private func clearFocus() {
        model.focusedConversation = nil
        model.startNewAskConversation()
        model.startNewAgentConversation()
    }
}

// MARK: - Step log

/// The Agent's step-by-step log, as one collapsible monospaced block.
///
/// Extracted rather than inlined because the thread and the result card both
/// show it, and they showed *different* logs before: the overlay had a live
/// ticker, the run row had its own list, and a finished conversation had none
/// at all. Three renderings of one thing is three places for it to drift.
///
/// The three columns are a table on purpose — index, tool, detail — because
/// what a reader does with a step log is scan for the one tool call that
/// explains the result, and a ragged left edge makes that a read instead of a
/// scan.
struct StepLog: View {
    private let entries: [StepLogEntry]
    private let elapsed: String?
    @State private var expanded: Bool

    /// From a completed run's persisted summary (`AgentRunRecord.steps`).
    init(steps: [AgentStepSummary], elapsed: String? = nil, initiallyExpanded: Bool = true) {
        self.entries = steps.map(StepLogEntry.init(step:))
        self.elapsed = elapsed
        self._expanded = State(initialValue: initiallyExpanded)
    }

    /// From the live progress feed (`AgentProgressPanelState.steps`).
    init(progress: [AgentProgressStep], elapsed: String? = nil, initiallyExpanded: Bool = true) {
        self.entries = progress.map(StepLogEntry.init(progress:))
        self.elapsed = elapsed
        self._expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(DS.Text.size(14))
                        .foregroundStyle(DS.Colour.ink(0.45))
                    Text(OpenTypeL10n.text("执行了 \(entries.count) 步", english: "\(entries.count) steps"))
                        .font(DS.Text.caption())
                        .fontWeight(.semibold)
                        .foregroundStyle(DS.Colour.ink(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let elapsed {
                        Text(elapsed)
                            .font(DS.Text.mono())
                            .foregroundStyle(DS.Colour.ink(0.4))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(SessionConditionalHairline(active: expanded, edge: .bottom))

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Text(String(format: "%02d", index + 1))
                                .font(DS.Text.mono(10.5))
                                .foregroundStyle(DS.Colour.ink(0.3))
                                .frame(width: 16, alignment: .leading)
                            Text(entry.label)
                                .font(DS.Text.mono(10.5))
                                .foregroundStyle(entry.tint)
                                .lineLimit(1)
                                .frame(width: 64, alignment: .leading)
                            Text(entry.detail)
                                .font(DS.Text.mono())
                                .foregroundStyle(DS.Colour.ink(0.6))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .background(DS.Colour.insetSurface, in: RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous)
                .strokeBorder(DS.Colour.border, lineWidth: 0.75)
        )
    }
}

/// One row of a `StepLog`, normalised away from whichever of the two step
/// types it came from.
private struct StepLogEntry {
    var label: String
    var detail: String
    var tint: Color

    init(step: AgentStepSummary) {
        self.init(type: step.type, detail: step.detail)
    }

    init(progress: AgentProgressStep) {
        let type: String
        switch progress.kind {
        case .thinking: type = "thinking"
        case .toolCall: type = "tool_call"
        case .toolResult: type = "tool_result"
        case .error: type = "error"
        }
        self.init(type: type, detail: progress.detail)
    }

    private init(type: String, detail: String) {
        switch type {
        case "tool_call":
            let call = StepLogEntry.parseToolCall(detail)
            label = call.name
            self.detail = call.arguments
            // Colour marks the calls that changed something. A run that only
            // read is a run you do not have to audit, and spending the Agent
            // tint on every row would stop saying which is which.
            tint = StepLogEntry.sideEffecting.contains(call.name)
                ? DS.Colour.agent
                : StepLogEntry.readOnlyTint
        case "error":
            label = OpenTypeL10n.text("错误", english: "error")
            self.detail = detail
            tint = DS.Colour.error
        case "tool_result":
            label = OpenTypeL10n.text("结果", english: "result")
            self.detail = detail
            tint = StepLogEntry.readOnlyTint
        case "done":
            label = OpenTypeL10n.text("完成", english: "done")
            self.detail = detail
            tint = StepLogEntry.readOnlyTint
        default:
            label = type
            self.detail = detail
            tint = StepLogEntry.readOnlyTint
        }
    }

    /// The four tools that can change something, from the handoff's tool
    /// catalogue (`sidecar/src/agent/coreTools.ts`), named without the
    /// `opentype__` prefix the parser has already stripped.
    private static let sideEffecting: Set<String> = ["bash", "python", "open_file", "remember_fact"]

    /// What a read-only step's tool column is set in — the handoff's
    /// `rgba(28,28,30,.45)`, one step lighter than the detail beside it.
    private static let readOnlyTint = DS.Colour.ink(0.45)

    /// Splits `Calling opentype__bash({"command":"…"})` into `bash` and the
    /// argument string.
    ///
    /// The sidecar emits tool calls as one prose-wrapped line
    /// (`loop.ts`), so the tool name and its arguments have to be recovered
    /// here to make the log a table. A line that does not match the shape
    /// falls through as its own label with no arguments rather than being
    /// dropped — an unparsed step is still a step that happened.
    static func parseToolCall(_ detail: String) -> (name: String, arguments: String) {
        var body = detail.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("Calling ") { body.removeFirst("Calling ".count) }

        guard let open = body.firstIndex(of: "(") else {
            return (StepLogEntry.shortName(String(body)), "")
        }
        let name = StepLogEntry.shortName(String(body[body.startIndex..<open]))
        var arguments = String(body[body.index(after: open)...])
        if arguments.hasSuffix(")") { arguments.removeLast() }
        return (name, arguments)
    }

    /// Drops our own `opentype__` prefix; an MCP server's prefix
    /// (`github__create_issue`) stays, because there it identifies which
    /// server the tool came from.
    private static func shortName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("opentype__")
            ? String(trimmed.dropFirst("opentype__".count))
            : trimmed
    }
}

// MARK: - List pieces

/// A running Agent task, as a whole card.
///
/// It gets a card because it is the only thing on this screen with time
/// pressure: everything else already happened and will still be there in a
/// minute. Current tool, progress, elapsed time and 停止 in one glance is what
/// a row of grey text could not do.
private struct SessionRunningCard: View {
    let run: AgentRunRecord
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(run.task)
                .font(DS.Text.body(.medium))
                // 1.5 line height at 13pt.
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colour.agent)
                    Text(currentTool)
                        .font(DS.Text.mono())
                        .foregroundStyle(DS.Colour.ink(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                SessionIndeterminateBar()

                HStack(spacing: 6) {
                    // A live counter, so "已用" stays true without any state of
                    // its own.
                    TimelineView(.periodic(from: run.dispatchedAt, by: 1)) { context in
                        Text(stepAndElapsed(now: context.date))
                            .font(DS.Text.mono(10))
                            .foregroundStyle(DS.Colour.ink(0.42))
                    }
                    Spacer(minLength: 0)
                    Button(action: onStop) {
                        Text(OpenTypeL10n.text("停止", english: "Stop"))
                            // 11/500, not the 11/600 group-label step: this is
                            // an action sitting beside a 10pt mono line, and
                            // semibold makes it the loudest thing in the card.
                            .font(DS.Text.size(11, .medium))
                            .foregroundStyle(DS.Colour.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(DS.Colour.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SessionRunningCardChrome())
    }

    private var currentTool: String {
        guard let last = run.steps.last(where: { $0.type == "tool_call" }) else {
            return OpenTypeL10n.text("准备中…", english: "starting…")
        }
        let call = StepLogEntry.parseToolCall(last.detail)
        return call.arguments.isEmpty ? call.name : "\(call.name) · \(call.arguments)"
    }

    private func stepAndElapsed(now: Date) -> String {
        // The handoff's "第 6 / ~9 步" needs a total the sidecar never sends,
        // so this shows the step reached and nothing it cannot know.
        let step = run.steps.filter { $0.type == "tool_call" }.count
        let seconds = max(now.timeIntervalSince(run.dispatchedAt), 0)
        return OpenTypeL10n.text(
            "第 \(max(step, 1)) 步 · 已用 \(SessionFormat.duration(seconds))",
            english: "Step \(max(step, 1)) · \(SessionFormat.duration(seconds)) elapsed"
        )
    }
}

/// The accent border and lifted shadow that mark a card as live.
private struct SessionRunningCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        DS.Shadow.running(
            content
                .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(DS.Colour.accent.opacity(0.28), lineWidth: 0.75)
                )
        )
    }
}

/// One conversation in the list: a type dot, a title, a time, and a preview.
private struct SessionRow: View {
    let conversation: ConversationSummary
    let selected: Bool
    /// Interior rows carry the hairline; the first does not, or the card would
    /// have a line across its top edge.
    let firstInCard: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(SessionKindStyle.dot(conversation.sessionKind))
                        .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                    Text(conversation.title)
                        .font(DS.Text.body(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(SessionFormat.time(millis: conversation.updatedAt))
                        .font(DS.Text.mono())
                        .foregroundStyle(DS.Colour.ink(0.35))
                }
                // The second line: the newest message, whoever wrote it.
                // Without it every row read as an unanswered question, which
                // is the opposite of what a session list is for. Absent for a
                // thread with no messages yet, and the row collapses to one
                // line rather than reserving empty space.
                if let preview = conversation.preview, !preview.isEmpty {
                    Text(preview)
                        .font(DS.Text.caption())
                        .foregroundStyle(DS.Colour.ink(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, DS.Space.rowH)
            .padding(.vertical, DS.Space.rowV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? DS.Colour.accent.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
            .modifier(SessionConditionalHairline(active: !firstInCard, edge: .top))
        }
        .buttonStyle(.plain)
    }
}

private struct SessionFilterChip: View {
    let filter: SessionFilter
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let kind = filter.kind {
                    Circle()
                        .fill(SessionKindStyle.dot(kind))
                        .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                }
                Text(filter.title)
                    // 11.5, not the 12pt caption step. A chip 22pt tall with
                    // 10pt of gutter is sized around this half point, and
                    // rounding it up is what made the three chips crowd the
                    // 334pt column.
                    .font(DS.Text.size(11.5, selected ? .medium : .regular))
                    .foregroundStyle(selected ? DS.Colour.card : DS.Colour.ink(0.6))
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                // `labelColor` rather than a literal #1C1C1E: the selected chip
                // has to invert in dark mode, and a fixed near-black there is
                // white text on black in a white-on-dark window.
                selected ? AnyShapeStyle(Color(nsColor: .labelColor)) : AnyShapeStyle(DS.Colour.chipFill),
                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private extension SessionFilter {
    /// The kind whose dot the chip carries. 全部 has none.
    var kind: SessionKind? {
        switch self {
        case .all: return nil
        case .agent: return .agent
        case .ask: return .ask
        }
    }
}

// MARK: - Thread pieces

/// One turn. The user's is a bubble; the assistant's is not.
private struct SessionTurn: View {
    let message: ConversationMessageSummary
    let maxBubbleWidth: CGFloat

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        if isUser {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(message.content)
                    .font(DS.Text.body())
                    // 1.6 line height at 13pt.
                    .lineSpacing(5)
                    .foregroundStyle(Color.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                    .background(DS.Colour.accent, in: SessionBubbleShape())
            }
        } else {
            // No bubble, no width cap: a long answer is a document.
            AssistantMarkdownView(markdown: message.content, fontSize: 13.5)
                // 1.75 line height at 13.5pt.
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The bubble's `14 14 4 14` corners.
///
/// Hand-rolled because `UnevenRoundedRectangle` is macOS 14 and this app
/// targets 13.
private struct SessionBubbleShape: Shape {
    var topLeading: CGFloat = DS.Radius.card
    var topTrailing: CGFloat = DS.Radius.card
    var bottomTrailing: CGFloat = 4
    var bottomLeading: CGFloat = DS.Radius.card

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeading, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topTrailing, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + topTrailing),
            radius: topTrailing
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomTrailing))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - bottomTrailing, y: rect.maxY),
            radius: bottomTrailing
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomLeading),
            radius: bottomLeading
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeading))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + topLeading, y: rect.minY),
            radius: topLeading
        )
        path.closeSubpath()
        return path
    }
}

/// The 问答 / Agent tag in the thread header.
private struct SessionKindTag: View {
    let kind: SessionKind

    var body: some View {
        Text(kind.title)
            .font(DS.Text.groupLabel())
            .foregroundStyle(SessionKindStyle.tagText(kind))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                SessionKindStyle.tagFill(kind),
                in: RoundedRectangle(cornerRadius: DS.Radius.tag, style: .continuous)
            )
            .fixedSize()
    }
}

/// "The answer is on its way", inside the thread rather than only on the
/// floating panel — the panel is transient, and a thread the user opened on
/// purpose should say what it is doing.
private struct SessionWorkingRow: View {
    var body: some View {
        HStack(spacing: 7) {
            SessionPulseDot(period: 1.2)
            Text(OpenTypeL10n.text("正在检索…", english: "Working…"))
                .font(DS.Text.mono())
                .foregroundStyle(DS.Colour.ink(0.4))
        }
    }
}

private struct SessionComposerButton: View {
    let symbol: String
    let filled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: SessionMetrics.glyph))
                .foregroundStyle(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(DS.Colour.accent))
                .frame(width: 30, height: 30)
                .modifier(SessionButtonChrome(filled: filled, radius: DS.Radius.nested))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Shared small parts

private struct SessionIconButton: View {
    let symbol: String
    let filled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: SessionMetrics.glyph))
                .foregroundStyle(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 26, height: 26)
                .modifier(SessionButtonChrome(filled: filled, radius: DS.Radius.smallControl))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Either an accent-filled button with its coloured lift, or a white one with a
/// `.09` edge and the neutral one.
///
/// `.09` rather than the card edge's `.07`: a 26pt white square on a `#F5F5F3`
/// page has almost no value contrast to sit on, so the handoff spends two
/// hundredths of alpha on the outline instead.
private struct SessionButtonChrome: ViewModifier {
    let filled: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        if filled {
            DS.Shadow.accentControl(
                content
                    .background(DS.Colour.accent, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            )
        } else {
            DS.Shadow.control(
                content
                    .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(DS.Colour.controlBorder, lineWidth: 0.75)
                    )
            )
        }
    }
}

/// The same white pill as an unfilled `SessionButtonChrome`, for the header
/// controls that are a field rather than a button.
private struct SessionHeaderControlChrome: ViewModifier {
    func body(content: Content) -> some View {
        DS.Shadow.control(
            content
                .background(
                    DS.Colour.card,
                    in: RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous)
                        .strokeBorder(DS.Colour.controlBorder, lineWidth: 0.75)
                )
        )
    }
}

private struct SessionGroupLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DS.Text.groupLabel())
            .tracking(DS.Tracking.groupLabel)
            // .42, the α the handoff sets on every group label in the app.
            // `.tertiary` is ≈ .26 and reads as disabled at 11pt.
            .foregroundStyle(DS.Colour.ink(0.42))
    }
}

/// The breathing dot that marks something as live.
///
/// Two periods, both from the handoff: 1.4s for the 进行中 group label, 1.2s for
/// the 正在检索 row in a thread. The faster one is next to a line of text that
/// is itself waiting, and matching them would have made the two read as one
/// object blinking together.
private struct SessionPulseDot: View {
    var period: Double = 1.4

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(DS.Colour.accent)
            .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
            .opacity(pulsing ? 0.35 : 1)
            .scaleEffect(pulsing ? 0.82 : 1)
            .animation(.easeInOut(duration: period).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

/// A 2pt bar that shows motion without claiming a percentage.
///
/// The handoff draws a determinate fill, but `/agent/run` never reports a step
/// total — the loop stops when the model stops calling tools. A bar at 58%
/// would be a number we made up; a moving segment says "still going", which is
/// the whole of what is actually known.
private struct SessionIndeterminateBar: View {
    @State private var shifted = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Capsule()
                .fill(DS.Colour.accent)
                .frame(width: max(width * 0.32, 1))
                .offset(x: shifted ? width * 0.68 : 0)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: shifted)
        }
        .frame(height: 2)
        .background(DS.Colour.border)
        .clipShape(Capsule())
        .onAppear { shifted = true }
    }
}

/// The 52pt strip a column starts with, at gutters this screen chooses.
///
/// `ColumnHeader` bakes in the page gutter (24 wide / 14 narrow). Both of this
/// screen's headers want something else — 16/16 for the list, 20/20 then 10/14
/// for the thread — and a header that does not share a left edge with the cards
/// under it is the one misalignment a reader notices without being able to say
/// why. Same height, so headers still line up across all three columns.
private struct SessionColumnHeader<Content: View>: View {
    var leading: CGFloat
    var trailing: CGFloat
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: spacing) {
            content()
        }
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        .frame(height: DS.Size.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A 0.75pt line at the *border* weight rather than the hairline one.
///
/// The design uses two: `border` (0.07) where one region ends and another
/// begins — the thread header, the composer — and `hairline` (0.06) between
/// rows inside a single card. `dsHairline` is the second; this is the first.
private struct SessionEdgeBorder: ViewModifier {
    let edge: Edge

    func body(content: Content) -> some View {
        content.overlay(alignment: edge == .top ? .top : .bottom) {
            Rectangle()
                .fill(DS.Colour.border)
                .frame(height: 0.75)
        }
    }
}

/// `dsHairline` only when a condition holds — SwiftUI has no conditional
/// modifier, and branching on the view itself would give the two branches
/// different identities and re-create their state.
private struct SessionConditionalHairline: ViewModifier {
    let active: Bool
    let edge: Edge

    func body(content: Content) -> some View {
        content.overlay(alignment: edge == .top ? .top : .bottom) {
            Rectangle()
                .fill(active ? DS.Colour.hairline : Color.clear)
                .frame(height: 0.75)
        }
    }
}

// MARK: - Values

private enum SessionMetrics {
    /// The glyph inside a 26 or 30pt button. One value because the handoff uses
    /// one (`font-size:16px` for 搜索 / 新对话 / 口述 / 发送 alike) — the button
    /// grows, the icon in it does not.
    static let glyph: CGFloat = 16
}

private enum SessionKindStyle {
    static func dot(_ kind: SessionKind?) -> Color {
        switch kind {
        case .agent: return DS.Colour.agent
        case .ask: return DS.Colour.accent
        case nil: return Color.secondary
        }
    }

    /// Both at 11%. The README says 12 for the Agent tag; §01's markup says 11
    /// for both, and the markup is what ships.
    static func tagFill(_ kind: SessionKind) -> Color {
        switch kind {
        case .agent: return DS.Colour.agent.opacity(0.11)
        case .ask: return DS.Colour.accent.opacity(0.11)
        }
    }

    /// The 问答 tag darkens its text rather than reusing the accent: 11% accent
    /// behind #0D73FA is a tag you have to look at twice.
    static func tagText(_ kind: SessionKind) -> Color {
        switch kind {
        case .agent: return DS.Colour.agent
        case .ask: return DS.Colour.askTag
        }
    }
}

private enum SessionFormat {
    static func time(millis: Int) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    /// `42s` / `2m 04s`. Seconds alone stop being readable somewhere around a
    /// minute and a half.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total)s" }
        return String(format: "%dm %02ds", total / 60, total % 60)
    }

    /// A finished run's wall-clock time, for the step log's header.
    static func elapsed(of run: AgentRunRecord) -> String? {
        guard let completedAt = run.completedAt else { return nil }
        let seconds = completedAt.timeIntervalSince(run.dispatchedAt)
        guard seconds >= 0 else { return nil }
        return seconds < 60 ? String(format: "%.1fs", seconds) : duration(seconds)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = OpenTypeL10n.locale
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// One 今天 / 昨天 / dated group of the list.
private struct SessionDay: Identifiable {
    let id: Date
    let title: String
    let conversations: [ConversationSummary]

    /// Buckets an already-sorted list by calendar day, preserving order.
    ///
    /// Grouping happens here rather than in `SessionList` because it is a
    /// rendering concern with a calendar and a locale in it — the merge and the
    /// filter are pure list operations, and mixing "what is in the list" with
    /// "how today is spelled" is how one of them ends up needing the other's
    /// tests.
    static func grouped(_ conversations: [ConversationSummary]) -> [SessionDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = OpenTypeL10n.locale

        var order: [Date] = []
        var buckets: [Date: [ConversationSummary]] = [:]
        for conversation in conversations {
            let date = Date(timeIntervalSince1970: Double(conversation.updatedAt) / 1000)
            let day = calendar.startOfDay(for: date)
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(conversation)
        }

        return order.map { day in
            SessionDay(id: day, title: title(for: day, calendar: calendar), conversations: buckets[day] ?? [])
        }
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) {
            return OpenTypeL10n.text("今天", english: "Today")
        }
        if calendar.isDateInYesterday(day) {
            return OpenTypeL10n.text("昨天", english: "Yesterday")
        }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: Date())
        let formatter = sameYear ? monthDayFormatter : fullDateFormatter
        return formatter.string(from: day)
    }

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = OpenTypeL10n.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = OpenTypeL10n.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter
    }()
}
