import SwiftUI

// MARK: - Icon metrics
//
// `DS` closes the *type* scale, not glyph sizes: an SF Symbol's `font(size:)`
// is a drawing metric, not one of the six text steps, and rendering a 16pt
// chevron at `DS.Text.body()` would size it off the wrong scale. These are the
// handoff's own icon values for §7, named rather than sprinkled as literals so
// the page has one place they can be checked against the mockup.
private enum McpIcon {
    static let back: CGFloat = 20
    static let rowChevron: CGFloat = 16
    static let cardGlyph: CGFloat = 17
    static let inlineGlyph: CGFloat = 15
    static let removeGlyph: CGFloat = 14
    static let sheetClose: CGFloat = 18
    /// The triangle on a row's startup-failure line. Not a handoff value — the
    /// mockup has no such line — so it is sized to the 11pt label it sits
    /// beside rather than to a new icon step of its own.
    static let statusWarning: CGFloat = 11
}

// MARK: - Built-in tools

/// One built-in tool as this page lists it: what it is called, one line about
/// what it does, and whether running it changes anything.
///
/// The list is transcribed from `sidecar/src/agent/coreTools.ts` (plus the two
/// memory tools it merges in) and `docs/tool-catalog.md` rather than fetched:
/// the built-in set is compiled into the sidecar binary that ships with this
/// app, so there is no version skew for a runtime query to protect against,
/// and a panel that goes blank when the sidecar is down would be answering
/// "what can the agent do" with silence.
private struct McpBuiltInTool: Identifiable, Equatable {
    let name: String
    let summary: String
    /// Shown as the orange 「有副作用」 tag.
    ///
    /// The line is drawn at "could this leave something different behind":
    /// `bash` and `python` execute arbitrary code, `open_file` launches
    /// whatever application the system associates with a path, and
    /// `remember_fact` writes to long-term memory that later runs read back.
    /// The other six only read — including `consolidate_memory_now`, which
    /// re-derives entries from history the user already dictated rather than
    /// introducing anything new.
    let hasSideEffects: Bool

    var id: String { name }
}

private enum McpBuiltInCatalog {
    /// 本机 — the six that touch this machine.
    static var local: [McpBuiltInTool] {
        [
            McpBuiltInTool(
                name: "opentype__bash",
                summary: OpenTypeL10n.text(
                    "在 /bin/bash -lc 里执行命令，默认工作目录是主目录",
                    english: "Runs a command through /bin/bash -lc; the working directory defaults to your home folder"
                ),
                hasSideEffects: true
            ),
            McpBuiltInTool(
                name: "opentype__python",
                summary: OpenTypeL10n.text(
                    "写入临时文件后用 python3 执行",
                    english: "Writes the snippet to a temporary file and runs it with python3"
                ),
                hasSideEffects: true
            ),
            McpBuiltInTool(
                name: "opentype__open_file",
                summary: OpenTypeL10n.text(
                    "调 /usr/bin/open，由系统默认应用预览或播放",
                    english: "Calls /usr/bin/open, so your default app previews or plays the file"
                ),
                hasSideEffects: true
            ),
            McpBuiltInTool(
                name: "opentype__read_file",
                summary: OpenTypeL10n.text(
                    "读取单个文件内容",
                    english: "Reads one file's contents"
                ),
                hasSideEffects: false
            ),
            McpBuiltInTool(
                name: "opentype__list_dir",
                summary: OpenTypeL10n.text(
                    "列出目录条目",
                    english: "Lists a directory's entries"
                ),
                hasSideEffects: false
            ),
            McpBuiltInTool(
                name: "opentype__grep",
                summary: OpenTypeL10n.text(
                    "grep -rn -I，默认范围 ~/Desktop 与 ~/Downloads",
                    english: "grep -rn -I, searching ~/Desktop and ~/Downloads by default"
                ),
                hasSideEffects: false
            ),
        ]
    }

    /// 网络与记忆 — the four that reach past this machine, or past this run.
    static var networkAndMemory: [McpBuiltInTool] {
        [
            McpBuiltInTool(
                name: "opentype__web_search",
                summary: OpenTypeL10n.text(
                    "DuckDuckGo 检索，无需 API key",
                    english: "Searches DuckDuckGo; needs no API key"
                ),
                hasSideEffects: false
            ),
            McpBuiltInTool(
                name: "opentype__web_fetch",
                summary: OpenTypeL10n.text(
                    "抓取网页并转成纯文本",
                    english: "Fetches a page and converts it to plain text"
                ),
                hasSideEffects: false
            ),
            McpBuiltInTool(
                name: "opentype__remember_fact",
                summary: OpenTypeL10n.text(
                    "写入一条关于你的长期记忆",
                    english: "Writes one long-term memory about you"
                ),
                hasSideEffects: true
            ),
            McpBuiltInTool(
                name: "opentype__consolidate_memory_now",
                summary: OpenTypeL10n.text(
                    "立即跑一次记忆整理",
                    english: "Runs a memory consolidation pass right now"
                ),
                hasSideEffects: false
            ),
        ]
    }

    static var count: Int { local.count + networkAndMemory.count }
}

// MARK: - 7A · The page

/// Settings → 引擎 → **Agent 工具** (handoff §7A): everything the agent can do,
/// on one page.
///
/// Built-in tools and MCP servers are listed together on purpose. The question
/// a user actually arrives with is "what can this thing do to my machine",
/// which is answered by the union of the two; splitting them into "the tools"
/// and "my configuration" would answer a question about provenance that nobody
/// asked. It also puts the four side-effecting built-ins on screen for the
/// first time — until now that fact lived only in `docs/tool-catalog.md`.
///
/// Read-only on the left, editable on the right, and the two cards below the
/// server list say the parts that are easy to get wrong: MCP tools run exactly
/// as unsandboxed and unconfirmed as the built-ins, and saved config replaces
/// `OPENTYPE_MCP_SERVERS` **wholesale** rather than merging with it.
struct AgentToolsPage: View {
    @ObservedObject var model: AppModel
    /// Pops back to Settings. The page is a second-level view, so it owns its
    /// own back affordance rather than assuming a navigation container.
    var onBack: () -> Void

    @State private var sheet: McpSheetTarget?
    /// Tools the last passing test found, per server name.
    ///
    /// Session-local on purpose: it is evidence from a probe this user just
    /// ran, not state the sidecar reports, and it is labelled as such in the
    /// row. Whether a server is *enabled* is not tracked here — that comes off
    /// `McpServerSummary.isEnabled`, which every save refreshes.
    @State private var toolCounts: [String: Int] = [:]
    @State private var copyNotice: String?
    @State private var isCopying = false

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { proxy in
                let narrow = proxy.size.width < DS.Size.narrowBreakpoint
                ScrollView {
                    columns(narrow: narrow)
                        .padding(.horizontal, narrow ? DS.Space.pageNarrow : DS.Space.pageWide)
                        .padding(.bottom, narrow ? DS.Space.pageNarrow : DS.Space.pageWide)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(DS.Colour.canvas)
        .task { await model.refreshMcpServers() }
        .sheet(item: $sheet) { target in
            McpServerSheet(
                model: model,
                existing: target.existing,
                onClose: { sheet = nil },
                onSaved: { outcome in
                    apply(outcome)
                    sheet = nil
                }
            )
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: McpIcon.back))
                    .foregroundStyle(DS.Colour.accent)
            }
            .buttonStyle(.plain)
            .help(OpenTypeL10n.text("返回设置", english: "Back to Settings"))

            Text(OpenTypeL10n.text("Agent 工具", english: "Agent tools"))
                .font(DS.Text.title())
                .tracking(DS.Tracking.title)

            Spacer()

            McpButton(
                title: OpenTypeL10n.text("重启服务并连接", english: "Restart and connect"),
                icon: "arrow.clockwise",
                border: DS.Colour.controlBorder,
                paddingH: 11
            ) {
                model.restartSidecarManually()
            }
            .help(OpenTypeL10n.text(
                "MCP 连接只在语音服务启动时建立，重启会用当前配置重新连接一次。",
                english: "MCP connections are made when the voice service starts; restarting reconnects with the current configuration."
            ))
        }
        .padding(.leading, DS.Space.content)
        .padding(.trailing, DS.Space.pageWide)
        .frame(height: DS.Size.headerHeight)
    }

    // MARK: Columns

    @ViewBuilder
    private func columns(narrow: Bool) -> some View {
        if narrow {
            VStack(alignment: .leading, spacing: DS.Space.group) {
                builtInColumn
                mcpColumn
            }
        } else {
            HStack(alignment: .top, spacing: DS.Space.group) {
                builtInColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                mcpColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var builtInColumn: some View {
        VStack(alignment: .leading, spacing: DS.Space.label) {
            McpGroupHeader(
                title: OpenTypeL10n.text(
                    "内置工具 · \(McpBuiltInCatalog.count)",
                    english: "Built-in tools · \(McpBuiltInCatalog.count)"
                )
            ) {
                Text(OpenTypeL10n.text("始终可用，不可关闭", english: "Always available, can't be turned off"))
                    .font(DS.Text.groupLabel())
                    .fontWeight(.regular)
                    .foregroundStyle(DS.Colour.ink(0.4))
            }

            VStack(spacing: 0) {
                McpCardSectionHeader(
                    title: OpenTypeL10n.text("本机", english: "This Mac"),
                    isFirst: true
                )
                toolRows(McpBuiltInCatalog.local)
                McpCardSectionHeader(
                    title: OpenTypeL10n.text("网络与记忆", english: "Web and memory"),
                    isFirst: false
                )
                toolRows(McpBuiltInCatalog.networkAndMemory)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCard()
        }
    }

    private func toolRows(_ tools: [McpBuiltInTool]) -> some View {
        ForEach(tools) { tool in
            McpBuiltInToolRow(tool: tool)
        }
    }

    private var mcpColumn: some View {
        VStack(alignment: .leading, spacing: DS.Space.group) {
            serverSection
            riskCard
            environmentCard
        }
    }

    // MARK: Server list

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.label) {
            McpGroupHeader(
                title: OpenTypeL10n.text(
                    "MCP 服务器 · \(servers.count)",
                    english: "MCP servers · \(servers.count)"
                ),
                alignment: .center
            ) {
                if isEnvironmentOnly {
                    // 7D puts both actions in the card itself, so the header
                    // link would be a second door to the same sheet.
                    EmptyView()
                } else {
                    McpLinkButton(title: OpenTypeL10n.text("添加服务器", english: "Add a server")) {
                        sheet = McpSheetTarget(existing: nil)
                    }
                }
            }

            if model.mcpConfig == nil {
                McpNoticeCard(text: OpenTypeL10n.text("正在读取…", english: "Loading…"))
            } else if isEnvironmentOnly {
                environmentOnlyCard
            } else if servers.isEmpty {
                emptyCard
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                        Button {
                            sheet = McpSheetTarget(existing: server)
                        } label: {
                            McpServerRowView(
                                server: server,
                                toolCount: toolCounts[server.name],
                                isFirst: index == 0
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .dsCard()
            }

            if let error = model.mcpEditError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Text.caption())
                    .foregroundStyle(DS.Colour.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            if let copyNotice {
                Text(copyNotice)
                    .font(DS.Text.groupLabel())
                    .fontWeight(.regular)
                    .foregroundStyle(DS.Colour.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            Text(OpenTypeL10n.text(
                "连接在语音服务启动时建立，改动从下次启动生效。",
                english: "Connections are made when the voice service starts; changes take effect from the next start."
            ))
            .font(DS.Text.groupLabel())
            .fontWeight(.regular)
            // 1.6 line height at 11pt.
            .lineSpacing(4)
            .foregroundStyle(DS.Colour.ink(0.45))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(OpenTypeL10n.text("还没有 MCP 服务器", english: "No MCP servers yet"))
                .font(DS.Text.body(.semibold))
            Text(OpenTypeL10n.text(
                "Agent 现在只有上面这 \(McpBuiltInCatalog.count) 个内置工具。",
                english: "Agent mode currently has only the \(McpBuiltInCatalog.count) built-in tools listed here."
            ))
            .font(DS.Text.caption())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.content)
        .padding(.vertical, 14)
        .dsCard()
    }

    // MARK: 7D · Environment-variable-only

    /// The state before the user has ever saved a server: `OPENTYPE_MCP_SERVERS`
    /// is supplying the list, it cannot be edited from here (a `PUT`/`DELETE`
    /// against one 404s — it lives in an environment variable, not in the
    /// store the routes address), and the first save switches the source
    /// **entirely**.
    private var environmentOnlyCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(OpenTypeL10n.text("当前来自环境变量，只读", english: "Currently from an environment variable, read-only"))
                    .font(DS.Text.size(12.5, .semibold))
                environmentOnlyBody
                .font(DS.Text.size(11.5))
                // 1.6 line height at 11.5pt.
                .lineSpacing(4)
                .foregroundStyle(DS.Colour.ink(0.55))
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.content)
            .padding(.vertical, 12)
            .background(DS.Colour.insetSurface)
            .dsHairline(.bottom)

            ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                McpEnvironmentRow(server: server, isFirst: index == 0)
            }

            HStack(spacing: 9) {
                McpButton(
                    title: isCopying
                        ? OpenTypeL10n.text("复制中…", english: "Copying…")
                        : OpenTypeL10n.text("复制成我的配置", english: "Copy into my config"),
                    isEnabled: !isCopying
                ) {
                    copyEnvironmentServers()
                }
                .help(OpenTypeL10n.text(
                    "把这些服务器保存成你自己的配置。密钥的值复制不过来 —— 本机只看得到遮盖值 —— 需要你重新填一次。",
                    english: "Saves these as your own config. Secret values don't come across — only masks ever reach this Mac — so you'll re-enter them."
                ))

                McpButton(
                    title: OpenTypeL10n.text("添加服务器", english: "Add a server"),
                    kind: .primary
                ) {
                    sheet = McpSheetTarget(existing: nil)
                }

                Spacer()
            }
            .padding(.horizontal, DS.Space.content)
            .padding(.vertical, 12)
            .dsHairline(.top)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCard()
    }

    /// 「整份忽略」 carries the handoff's own `<b>` — the sentence's whole point
    /// is that the environment variable is dropped rather than merged, and the
    /// mockup emphasises exactly that phrase.
    private var environmentOnlyBody: Text {
        Text(OpenTypeL10n.text(
            "这 \(servers.count) 个服务器由 ",
            english: "These \(servers.count) servers come from "
        ))
        + Text(McpCodeChip("OPENTYPE_MCP_SERVERS", fill: DS.Colour.control))
        + Text(OpenTypeL10n.text(
            " 提供，不能在这里改。一旦你在这里保存第一个服务器，环境变量会被",
            english: " and can't be edited here. The moment you save your first server, the environment variable is ignored "
        ))
        + Text(OpenTypeL10n.text("整份忽略", english: "in its entirety"))
            .fontWeight(.semibold)
        + Text(OpenTypeL10n.text(" —— 不是合并。", english: " — not merged."))
    }

    // MARK: The two standing cards

    /// The handoff gives this the same `0 1px 2px rgba(0,0,0,.04)` every other
    /// card on the page carries — it is a white card that happens to have an
    /// orange edge, not a flat callout — so it takes the card shadow too. It
    /// cannot use `dsCard()`, which hard-codes the neutral border.
    private var riskCard: some View {
        DS.Shadow.card(riskCardBody)
    }

    private var riskCardBody: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: McpIcon.cardGlyph))
                .foregroundStyle(DS.Colour.warningText)
            VStack(alignment: .leading, spacing: 4) {
                Text(OpenTypeL10n.text(
                    "MCP 工具和内置工具一样，直接执行",
                    english: "MCP tools run directly, exactly like the built-in ones"
                ))
                .font(DS.Text.size(12.5, .semibold))
                Text(OpenTypeL10n.text(
                    "不经沙箱、不逐条确认。添加一个服务器等于把它提供的每个工具都交给 Agent。只添加你信任来源的服务器。",
                    english: "No sandbox, no per-call confirmation. Adding a server hands the agent every tool it offers. Only add servers you trust."
                ))
                .font(DS.Text.size(11.5))
                // 1.6 line height at 11.5pt.
                .lineSpacing(4)
                .foregroundStyle(DS.Colour.ink(0.55))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.content)
        .padding(.vertical, 14)
        .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Colour.warning.opacity(0.35), lineWidth: 0.75)
        )
    }

    private var environmentCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(OpenTypeL10n.text("环境变量", english: "Environment variable"))
                .font(DS.Text.size(12.5, .semibold))
            environmentCardBody
                .font(DS.Text.size(11.5))
                // 1.6 line height at 11.5pt.
                .lineSpacing(4)
                .foregroundStyle(DS.Colour.ink(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.content)
        .padding(.vertical, 14)
        .dsCard()
    }

    private var environmentCardBody: Text {
        if isEnvironmentOnly {
            return McpCodeSentence(
                OpenTypeL10n.text("上面的列表来自 ", english: "The list above comes from "),
                "OPENTYPE_MCP_SERVERS",
                OpenTypeL10n.text(
                    "。你保存第一个服务器之后，这个变量会被整份忽略，不会合并 —— 那之后只用你保存的列表，删光了就是没有 MCP 服务器。",
                    english: ". Once you save your first server that variable is ignored in its entirety, not merged — from then on only your saved list is used, and emptying it means no MCP servers at all."
                )
            )
        }
        return McpCodeSentence(
            OpenTypeL10n.text("你已保存了自己的配置，所以 ", english: "You have your own saved config, so "),
            "OPENTYPE_MCP_SERVERS",
            OpenTypeL10n.text(
                " 被整份忽略，不会合并。删掉最后一个服务器的意思是「没有 MCP 服务器」，不是退回环境变量那一套。",
                english: " is ignored in its entirety rather than merged. Deleting the last server means no MCP servers — not a quiet fall back to the environment variable."
            )
        )
    }

    // MARK: Data

    private var servers: [McpServerSummary] { model.mcpConfig?.servers ?? [] }

    private var isEnvironmentOnly: Bool {
        guard let config = model.mcpConfig else { return false }
        return config.source == .env && !config.servers.isEmpty
    }

    private func apply(_ outcome: McpServerSheet.SaveOutcome) {
        if let previousName = outcome.previousName, previousName != outcome.name {
            toolCounts[previousName] = nil
        }
        toolCounts[outcome.name] = outcome.toolCount
        copyNotice = nil
    }

    /// Saves each environment-supplied server as the user's own — the moment
    /// the first one lands, `mcpConfigured` flips and the environment variable
    /// stops applying, which is why the card says so before this button.
    ///
    /// **Secret values are deliberately dropped.** All this Mac ever received
    /// for them is a mask, and on a *create* there is no stored record to
    /// resolve a mask against (`resolveMaskedSecrets` is a no-op with no
    /// `stored`), so sending one back would persist the mask itself as the
    /// literal credential — a server that looks configured and can never
    /// authenticate. Copying the keys but not the values would be the same
    /// mistake with extra steps, so the entries are left out entirely and the
    /// user is told which servers need one typed in.
    private func copyEnvironmentServers() {
        let sources = servers
        isCopying = true
        copyNotice = nil
        Task { @MainActor in
            var copied = 0
            var needSecrets: [String] = []
            for server in sources {
                let hadSecrets = !(server.envMasked ?? [:]).isEmpty
                    || !(server.headersMasked ?? [:]).isEmpty
                let request = McpServerRequest(
                    name: server.name,
                    transport: server.transport,
                    command: server.transport == .stdio ? server.command : nil,
                    args: server.transport == .stdio ? (server.args ?? []) : nil,
                    env: nil,
                    url: server.transport == .http ? server.url : nil,
                    headers: nil,
                    enabled: server.isEnabled
                )
                if await model.createMcpServer(request) {
                    copied += 1
                    if hadSecrets { needSecrets.append(server.name) }
                }
            }
            isCopying = false
            if needSecrets.isEmpty {
                copyNotice = copied == 0
                    ? nil
                    : OpenTypeL10n.text(
                        "已复制 \(copied) 个服务器。",
                        english: "Copied \(copied) servers."
                    )
            } else {
                copyNotice = OpenTypeL10n.text(
                    "已复制 \(copied) 个服务器。密钥的值没有跟着复制（本机只有遮盖值），请打开这些服务器重新填写：\(needSecrets.joined(separator: "、"))",
                    english: "Copied \(copied) servers. Secret values did not come across (only masks ever reach this Mac) — open these and enter them again: \(needSecrets.joined(separator: ", "))"
                )
            }
        }
    }
}

/// Which server the sheet is editing; `nil` is a create.
private struct McpSheetTarget: Identifiable {
    let existing: McpServerSummary?
    var id: String { existing?.name ?? "" }
}

// MARK: - Rows

private struct McpBuiltInToolRow: View {
    let tool: McpBuiltInTool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.name)
                    .font(DS.Text.mono(12))
                Text(tool.summary)
                    .font(DS.Text.size(11.5))
                    // 1.5 line height at 11.5pt.
                    .lineSpacing(3)
                    .foregroundStyle(DS.Colour.ink(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if tool.hasSideEffects {
                McpTag(
                    title: OpenTypeL10n.text("有副作用", english: "Has side effects"),
                    fill: DS.Colour.warningFill,
                    tint: DS.Colour.warningText
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .dsHairline(.top)
    }
}

/// One saved MCP server. The whole row is the button — the chevron says the
/// row opens something, and a separate hit target would be a smaller one.
private struct McpServerRowView: View {
    let server: McpServerSummary
    let toolCount: Int?
    let isFirst: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(server.name)
                        .font(DS.Text.mono(13, weight: .semibold))
                    McpTransportTag(transport: server.transport)
                }
                Text(endpoint)
                    .font(DS.Text.mono())
                    .foregroundStyle(DS.Colour.ink(0.45))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColour)
                        .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                    Text(statusText)
                        .font(DS.Text.groupLabel())
                        .fontWeight(.regular)
                        .foregroundStyle(DS.Colour.ink(0.45))
                        .lineLimit(1)
                }
                if let startupFailure {
                    McpStartupFailureLine(failure: startupFailure)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: McpIcon.rowChevron))
                .foregroundStyle(DS.Colour.ink(0.3))
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // After the padding, so the whole row is the hit target rather than
        // just the text inside it.
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(DS.Colour.hairline).frame(height: 0.75)
            }
        }
    }

    private var endpoint: String {
        switch server.transport {
        case .stdio:
            return ([server.command ?? ""] + (server.args ?? []))
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .http:
            return server.url ?? ""
        }
    }

    /// Why the last start skipped this server, when it did.
    ///
    /// Only asked of an enabled server. A disabled one already explains itself
    /// on the line above, and the verdict it would show is from a start where
    /// it was still enabled — stale by construction, and pointing at a fix the
    /// user has already made.
    private var startupFailure: McpStartupFailure? {
        server.isEnabled ? server.startupFailure : nil
    }

    /// Green claims "this is working", so a server the last start gave up on
    /// must not get one — that identical-looking dot is precisely the silent
    /// skip this row now reports.
    private var dotColour: Color {
        guard server.isEnabled else { return DS.Colour.ink(0.25) }
        return startupFailure == nil ? DS.Colour.ok : DS.Colour.warningText
    }

    /// What this row can honestly say.
    ///
    /// The handoff's 「6 个工具 · 上次启动已连接」 needs runtime facts the config
    /// API only half reports: `GET /config/mcp` answers with stored
    /// configuration plus `lastStartupError`, so Swift learns which servers the
    /// last start *skipped* but not how many tools the ones that connected
    /// contributed. A tool count is therefore shown only when this session's
    /// Test Connection produced one, labelled as the test rather than as the
    /// connection; the failures get their own line below; and the rest states
    /// the thing that is always true — that this takes effect at the next start.
    private var statusText: String {
        guard server.isEnabled else {
            return OpenTypeL10n.text(
                "已停用 · 不会在下次启动时连接",
                english: "Disabled · won't be connected at the next start"
            )
        }
        if let toolCount {
            return OpenTypeL10n.text(
                "\(toolCount) 个工具 · 测试通过 · 下次启动时连接",
                english: "\(toolCount) tools · test passed · connects at the next start"
            )
        }
        return OpenTypeL10n.text(
            "已启用 · 下次启动时连接",
            english: "Enabled · connects at the next start"
        )
    }
}

/// A 7D row: same information, no actions, and a lock instead of a chevron.
private struct McpEnvironmentRow: View {
    let server: McpServerSummary
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(server.name)
                            .font(DS.Text.mono(13, weight: .semibold))
                        McpTransportTag(transport: server.transport)
                    }
                    Text(endpoint)
                        .font(DS.Text.mono())
                        .foregroundStyle(DS.Colour.ink(0.45))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "lock.fill")
                    .font(.system(size: McpIcon.inlineGlyph))
                    .foregroundStyle(DS.Colour.ink(0.28))
            }
            // The dimming says "read-only", which is true of the configuration
            // above it and not of the warning below — an environment-supplied
            // server is connected at boot exactly like a saved one, so it fails
            // exactly like one, and a half-faded warning would be the quietest
            // possible way to report that.
            .opacity(0.62)

            if let failure = server.startupFailure {
                McpStartupFailureLine(failure: failure)
            }
        }
        .padding(.horizontal, DS.Space.content)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(DS.Colour.hairline).frame(height: 0.75)
            }
        }
    }

    private var endpoint: String {
        switch server.transport {
        case .stdio:
            return ([server.command ?? ""] + (server.args ?? []))
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .http:
            return server.url ?? ""
        }
    }
}

/// The one line that says a server the user saved is not actually running.
///
/// Its absence was the whole failure: `startMcpConnections` has always recorded
/// why each server was skipped, but nothing read that report, so a server that
/// timed out at startup drew identically to one contributing tools — and the
/// user's model of the product ("I saved it, so the agent has it") stayed wrong
/// with nothing on screen to correct it.
///
/// Two wordings, because the fix differs. A timeout gets a sentence, since the
/// recorded text ("No response within 12000ms.") says less to the reader than
/// the fact that the server was given up on. A failure gets the server's own
/// message verbatim behind a label that places it at startup — `spawn npx
/// ENOENT` is the actionable half, and paraphrasing it would delete the only
/// evidence the user has.
private struct McpStartupFailureLine: View {
    let failure: McpStartupFailure

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: McpIcon.statusWarning))
                .foregroundStyle(DS.Colour.warningText)
            Text(text)
                .font(DS.Text.groupLabel())
                .fontWeight(.regular)
                .foregroundStyle(DS.Colour.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: String {
        switch failure {
        case .timedOut:
            return OpenTypeL10n.text(
                "启动超时，已跳过",
                english: "Timed out at startup and was skipped"
            )
        case .failed(let message):
            return OpenTypeL10n.text(
                "启动失败：\(message)",
                english: "Failed at startup: \(message)"
            )
        }
    }
}

// MARK: - 7B / 7C · The add/edit sheet

/// Add or edit one MCP server (`existing == nil` is a create), handoff §7B/§7C.
///
/// Two rules shape this form, and both are about not lying to the person
/// filling it in.
///
/// **A saved secret is never editable.** The sidecar answers with
/// `envMasked`/`headersMasked` only, so a real token never reaches Swift; a
/// saved entry is therefore drawn as static masked text with a 「更改」 link,
/// never as a field. A field would invite someone to trim a character off what
/// they believe is their token and save the result — which would store that
/// edited *mask* as the literal credential, because the sidecar only recognises
/// a mask it reported for that same server and that same key. The key is static
/// for the same reason one level up: renaming it orphans the mask.
/// `McpServerDraft.request(...)` submits every entry, untouched ones carrying
/// their masks verbatim, because the write is a **replace, not a patch** — a
/// key left out of the body is deleted.
///
/// **Saving requires a passing test.** Not a button beside Save; a step on the
/// way to it. A server that cannot be reached costs its tools and slows the
/// next start of the voice service, and the test is the only thing that tells
/// the user which of those they are about to buy. The result is invalidated
/// whenever the connection-relevant part of the draft changes, so the passing
/// test always describes the configuration actually being saved.
struct McpServerSheet: View {
    /// What the page needs to know about a save that just happened.
    struct SaveOutcome {
        /// The name the server was saved under.
        let name: String
        /// The name it had before, when this was an edit that renamed it.
        let previousName: String?
        /// Tools the passing test found, when there was one. `nil` after a
        /// 停用并保存 — a failed probe found nothing worth quoting.
        let toolCount: Int?
    }

    @ObservedObject var model: AppModel
    /// `nil` when adding a server.
    let existing: McpServerSummary?
    let onClose: () -> Void
    let onSaved: (SaveOutcome) -> Void

    /// Seeded at construction rather than in `onAppear`, because the sheet's
    /// width is a function of `draft.transport`: filling it in after the first
    /// layout would open every http server at the stdio sheet's 560pt and snap
    /// it to 460 a frame later.
    @State private var draft: McpServerDraft
    @State private var test: McpTestOutcome?
    /// The draft signature the result in `test` describes. Any later edit to
    /// the connection makes that result stale, and a stale pass must never
    /// unlock Save.
    @State private var testedSignature: String?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var confirmingDelete = false
    @State private var formHeight: CGFloat = 0

    init(
        model: AppModel,
        existing: McpServerSummary?,
        onClose: @escaping () -> Void,
        onSaved: @escaping (SaveOutcome) -> Void
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.existing = existing
        self.onClose = onClose
        self.onSaved = onSaved
        _draft = State(initialValue: McpServerDraft(seededFrom: existing))
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            form
            footer
        }
        .frame(width: sheetWidth)
        .background(DS.Colour.recessed)
        .confirmationDialog(
            OpenTypeL10n.text(
                "删除 MCP 服务器「\(existing?.name ?? "")」？",
                english: "Delete the MCP server “\(existing?.name ?? "")”?"
            ),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(OpenTypeL10n.text("确认删除", english: "Delete"), role: .destructive) {
                delete()
            }
            Button(OpenTypeL10n.text("取消", english: "Cancel"), role: .cancel) {}
        } message: {
            Text(OpenTypeL10n.text(
                "Agent 将不再获得这个服务器提供的工具，保存的密钥也一并删除。",
                english: "Agent mode stops getting this server's tools, and its saved secrets are deleted with it."
            ))
        }
    }

    // MARK: Metrics

    /// 560 for the stdio form, 460 for http.
    ///
    /// The handoff draws §7B at 560 and §7C at 460, and the thing it names as
    /// the difference between them is the transport, not add-versus-edit: stdio
    /// has to fit a command, an ordered argument list and an environment map,
    /// http has an address and a header map. Sizing the sheet to the form it is
    /// actually showing is why the http variant does not sit in 100pt of empty
    /// gutter.
    private var sheetWidth: CGFloat { draft.transport == .stdio ? 560 : 460 }

    /// The width inside the test-result block: the sheet less the form's 20pt
    /// gutters and the block's own 12pt ones. The tool chips pack themselves,
    /// so they need the number rather than a container to measure.
    private var resultContentWidth: CGFloat { sheetWidth - 64 }

    /// The fixed key column in an env/header row — 150 in the stdio sheet, 110
    /// in the narrower http one, both from the handoff. It is a fixed width
    /// rather than an intrinsic one so the masked values line up down the
    /// column instead of stepping in and out with each key's length.
    private var secretKeyWidth: CGFloat { draft.transport == .stdio ? 150 : 110 }

    // MARK: Header

    private var sheetHeader: some View {
        HStack(spacing: 10) {
            Text(existing.map {
                OpenTypeL10n.text("编辑 \($0.name)", english: "Edit \($0.name)")
            } ?? OpenTypeL10n.text("添加 MCP 服务器", english: "Add an MCP server"))
                .font(DS.Text.section())
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: McpIcon.sheetClose))
                    .foregroundStyle(DS.Colour.ink(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, DS.Space.content)
        .padding(.bottom, 14)
        .dsHairline(.bottom, color: DS.Colour.border)
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.content) {
                if existing?.isEnabled == false {
                    disabledNotice
                }
                nameField
                transportField
                if draft.transport == .stdio {
                    commandField
                    argumentsField
                    secretsField(
                        title: OpenTypeL10n.text("环境变量", english: "Environment variables"),
                        entries: $draft.env
                    )
                } else {
                    urlField
                    secretsField(
                        title: OpenTypeL10n.text("请求头", english: "Headers"),
                        entries: $draft.headers
                    )
                }
                if let test, testedSignature == draft.signature {
                    McpTestResultBlock(outcome: test, contentWidth: resultContentWidth)
                    if !test.success {
                        failureAdvice
                    }
                } else if test != nil {
                    // The result is dropped rather than left on screen next to
                    // a configuration it no longer describes — but silently
                    // dropping it would look like the test button did nothing,
                    // so the reason takes its place.
                    Text(OpenTypeL10n.text(
                        "配置改过了，上一次的测试结果不再作数。重新测试通过之后才能保存。",
                        english: "The configuration changed, so the previous test no longer describes it. Test again and pass before saving."
                    ))
                    .font(DS.Text.caption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Text.caption())
                        .foregroundStyle(DS.Colour.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: McpFormHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .scrollIndicators(.hidden)
        // Sized to the content up to a cap, so a two-field http server isn't a
        // half-empty panel and a long argument list still scrolls instead of
        // running off the screen.
        .frame(height: min(max(formHeight, 120), 520))
        .onPreferenceChange(McpFormHeightKey.self) { formHeight = $0 }
    }

    private var nameField: some View {
        McpField(title: OpenTypeL10n.text("名称", english: "Name")) {
            McpTextField(
                text: $draft.name,
                placeholder: OpenTypeL10n.text("例如 github", english: "e.g. github")
            )
            nameHint
                .font(DS.Text.groupLabel())
                .fontWeight(.regular)
                // 1.55 line height at 11pt.
                .lineSpacing(3)
                .foregroundStyle(nameViolation == nil ? DS.Colour.ink(0.45) : DS.Colour.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameHint: Text {
        if let nameViolation {
            return Text(nameViolation)
        }
        // Three chips, not one: the handoff sets `_` and `-` in the same code
        // treatment as the example tool name, and a rule about which literal
        // characters are allowed is exactly the copy where the reader has to be
        // able to tell the character from the punctuation around it.
        return Text(OpenTypeL10n.text(
            "会成为工具名的前缀 —— ",
            english: "Becomes the prefix of every tool name — "
        ))
        + Text(McpCodeChip("github__create_issue"))
        + Text(OpenTypeL10n.text(
            "。只能用字母、数字、",
            english: ". Letters, digits, "
        ))
        + Text(McpCodeChip("_"))
        + Text(OpenTypeL10n.text(" 和 ", english: " and "))
        + Text(McpCodeChip("-"))
        + Text(OpenTypeL10n.text("。", english: " only."))
    }

    private var transportField: some View {
        McpField(title: OpenTypeL10n.text("连接方式", english: "Transport")) {
            McpSegmentedControl(selection: $draft.transport)
        }
    }

    private var commandField: some View {
        McpField(title: OpenTypeL10n.text("命令", english: "Command")) {
            McpTextField(text: $draft.command, placeholder: "npx")
        }
    }

    private var urlField: some View {
        McpField(title: OpenTypeL10n.text("地址", english: "Address")) {
            McpTextField(text: $draft.url, placeholder: "https://mcp.example.com/mcp")
        }
    }

    private var argumentsField: some View {
        McpField(
            title: OpenTypeL10n.text("参数", english: "Arguments"),
            action: (OpenTypeL10n.text("添加一项", english: "Add one"), { draft.args.append(McpArgument()) })
        ) {
            VStack(spacing: 5) {
                ForEach(Array($draft.args.enumerated()), id: \.element.id) { index, $argument in
                    McpArgumentRow(index: index + 1, text: $argument.value) {
                        draft.args.removeAll { $0.id == argument.id }
                    }
                }
            }
        }
    }

    private func secretsField(title: String, entries: Binding<[McpSecretField]>) -> some View {
        McpField(
            title: title,
            action: (OpenTypeL10n.text("添加一项", english: "Add one"), {
                entries.wrappedValue.append(McpSecretField(key: "", value: .entered("")))
            })
        ) {
            if !entries.wrappedValue.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, $entry in
                        McpSecretRowView(
                            entry: $entry,
                            isFirst: index == 0,
                            keyWidth: secretKeyWidth
                        ) {
                            entries.wrappedValue.removeAll { $0.id == entry.id }
                        }
                    }
                }
                .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous)
                        .strokeBorder(DS.Colour.blockBorder, lineWidth: 0.75)
                )
            }
            Text(OpenTypeL10n.text(
                "保存后只回传遮盖值，原值不会再离开本机。键名可见，值不可见。",
                english: "Once saved, only the mask comes back — the real value never leaves this Mac again. Keys are visible, values are not."
            ))
            .font(DS.Text.groupLabel())
            .fontWeight(.regular)
            // 1.55 line height at 11pt.
            .lineSpacing(3)
            .foregroundStyle(DS.Colour.ink(0.45))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A disabled server is saved, visible and editable — this says how to get
    /// it back, because "disabled" with no stated way out is indistinguishable
    /// from broken.
    private var disabledNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: McpIcon.inlineGlyph))
                .foregroundStyle(DS.Colour.warningText)
            Text(OpenTypeL10n.text(
                "这个服务器已停用，不会在下次启动时连接。改好之后重新测试，通过再保存就会重新启用。",
                english: "This server is disabled and won't be connected at the next start. Fix it, test again, and a passing save turns it back on."
            ))
            .font(DS.Text.size(11.5))
            .foregroundStyle(DS.Colour.ink(0.6))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(DS.Colour.warningFill.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous)
                .strokeBorder(DS.Colour.warning.opacity(0.3), lineWidth: 0.75)
        )
    }

    /// 「停用」 is bold in the handoff, and it is the word that says what the
    /// button under this block will actually do to the server.
    private var failureAdviceText: Text {
        Text(OpenTypeL10n.text(
            "连不上的服务器会拖慢语音服务启动。仍要保存的话，它会以",
            english: "A server that can't be reached slows the voice service down at start. Save anyway and it is stored "
        ))
        + Text(OpenTypeL10n.text("停用", english: "disabled"))
            .fontWeight(.semibold)
        + Text(OpenTypeL10n.text(
            "状态存下，不参与下次连接。",
            english: ", taking no part in the next connection."
        ))
    }

    private var failureAdvice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: McpIcon.inlineGlyph))
                .foregroundStyle(DS.Colour.warningText)
            failureAdviceText
                .font(DS.Text.size(11.5))
                // 1.6 line height at 11.5pt.
                .lineSpacing(4)
                .foregroundStyle(DS.Colour.ink(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(DS.Colour.warningFill.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous)
                .strokeBorder(DS.Colour.warning.opacity(0.3), lineWidth: 0.75)
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 9) {
            if existing != nil {
                McpLinkButton(
                    title: OpenTypeL10n.text("删除", english: "Delete"),
                    tint: DS.Colour.error
                ) {
                    confirmingDelete = true
                }
            } else {
                Text(OpenTypeL10n.text(
                    "连接在下次启动语音服务时建立",
                    english: "The connection is made the next time the voice service starts"
                ))
                .font(DS.Text.size(11.5))
                .foregroundStyle(DS.Colour.ink(0.45))
            }

            Spacer()

            if let blocker = fieldBlocker {
                Text(blocker)
                    .font(DS.Text.groupLabel())
                    .fontWeight(.regular)
                    .foregroundStyle(DS.Colour.warningText)
                    .lineLimit(1)
            }

            McpButton(title: OpenTypeL10n.text("取消", english: "Cancel")) { onClose() }

            McpButton(
                title: isTesting
                    ? OpenTypeL10n.text("测试中…", english: "Testing…")
                    : (test == nil
                        ? OpenTypeL10n.text("测试连接", english: "Test connection")
                        : OpenTypeL10n.text("重新测试", english: "Test again")),
                isEnabled: fieldBlocker == nil && !isTesting && !isSaving
            ) {
                runTest()
            }

            if showsDisabledSave {
                McpButton(
                    title: OpenTypeL10n.text("停用并保存", english: "Save disabled"),
                    kind: .danger,
                    isEnabled: fieldBlocker == nil && !isSaving
                ) {
                    save(enabled: false)
                }
                .help(OpenTypeL10n.text(
                    "存下你填的内容，但标记为停用 —— 下次启动不会连接它。改好之后重新测试，通过再保存就会重新启用。",
                    english: "Keeps what you typed but marks it disabled, so the next start won't connect it. Fix it, test again, and a passing save turns it back on."
                ))
            } else {
                McpButton(
                    title: isSaving
                        ? OpenTypeL10n.text("保存中…", english: "Saving…")
                        : OpenTypeL10n.text("保存", english: "Save"),
                    kind: .primary,
                    isEnabled: canSave
                ) {
                    save(enabled: true)
                }
                .help(canSave
                    ? OpenTypeL10n.text("保存这个服务器", english: "Save this server")
                    : OpenTypeL10n.text(
                        "先测试连接。连不上的服务器会拖慢下次启动，测试是在保存前发现这件事的唯一方式。",
                        english: "Test the connection first. A server that can't be reached slows the next start down, and the test is the only way to learn that before saving."
                    ))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(DS.Colour.footerBar)
        .dsHairline(.top, color: DS.Colour.border)
    }

    // MARK: Validation

    /// The name rule is `mcpConfigStore.ts`'s `NAME_PATTERN`, checked while the
    /// user types rather than after a round trip: a violation is a 400, and the
    /// reason (the name becomes half of every tool name the provider sees)
    /// makes no sense as a surprise at save time.
    private var nameViolation: String? {
        let trimmed = draft.name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil {
            return OpenTypeL10n.text(
                "名称只能用字母、数字、_ 和 - —— 它会成为工具名的一半，别的字符会被服务拒绝。",
                english: "Names can only use letters, digits, _ and - — the name becomes half of every tool name, and anything else is rejected."
            )
        }
        return nil
    }

    /// Why the form cannot be submitted or tested at all, stated rather than
    /// left as a mysteriously grey button.
    private var fieldBlocker: String? {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty {
            return OpenTypeL10n.text("请填写名称", english: "Enter a name")
        }
        if nameViolation != nil {
            return OpenTypeL10n.text("名称不合法", english: "Invalid name")
        }
        if draft.transport == .stdio {
            if draft.command.trimmingCharacters(in: .whitespaces).isEmpty {
                return OpenTypeL10n.text("请填写命令", english: "Enter a command")
            }
            if draft.args.contains(where: { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return OpenTypeL10n.text("有一个参数是空的", english: "One argument is empty")
            }
        } else if draft.url.trimmingCharacters(in: .whitespaces).isEmpty {
            return OpenTypeL10n.text("请填写地址", english: "Enter an address")
        }

        let entries = draft.activeSecrets
        if entries.contains(where: { $0.submittedKey.isEmpty }) {
            return OpenTypeL10n.text("有一行还没填键名", english: "One row has no key yet")
        }
        // An empty replacement writes an empty secret — almost always someone
        // who pressed 更改 and then didn't type. Say so instead of saving it.
        if entries.contains(where: { entry in
            if case .entered(let text) = entry.value { return text.isEmpty }
            return false
        }) {
            return OpenTypeL10n.text("有一项的值还没填", english: "One value is still empty")
        }
        let keys = entries.map(\.submittedKey)
        if Set(keys).count != keys.count {
            return OpenTypeL10n.text("有重复的键名", english: "Two rows share a key")
        }
        return nil
    }

    private var passedTest: Bool {
        guard let test, testedSignature == draft.signature else { return false }
        return test.success
    }

    private var failedTest: Bool {
        guard let test, testedSignature == draft.signature else { return false }
        return !test.success
    }

    private var showsDisabledSave: Bool { failedTest }

    private var canSave: Bool { fieldBlocker == nil && passedTest && !isSaving }

    // MARK: Actions

    /// Probes the draft.
    ///
    /// An edit submits the **stored** name rather than the typed one. The probe
    /// never looks at the name (`mcpClient.ts` builds the transport from
    /// command/args/env or url/headers alone), but the sidecar resolves masks
    /// against the saved server of the *submitted* name — so testing a renamed
    /// server under its new name would find no stored record, send the masks as
    /// literal credentials, and fail with an auth error that has nothing to do
    /// with the user's configuration. Submitting the old name tests exactly the
    /// connection being saved, and the rename itself is carried by the `PUT`,
    /// which resolves against the name in its URL.
    private func runTest() {
        let signature = draft.signature
        let candidate = draft.request(name: existing?.name ?? draft.name, enabled: nil)
        isTesting = true
        test = nil
        saveError = nil
        let started = Date()
        Task { @MainActor in
            let result = await model.testMcpServer(candidate)
            let elapsed = Date().timeIntervalSince(started)
            test = McpTestOutcome(
                success: result.success,
                message: result.error,
                tools: (result.tools ?? []).map(\.name),
                elapsed: elapsed
            )
            testedSignature = signature
            isTesting = false
        }
    }

    private func save(enabled: Bool) {
        let request = draft.request(enabled: enabled)
        let toolCount = passedTest ? test?.tools.count : nil
        isSaving = true
        saveError = nil
        Task { @MainActor in
            let ok: Bool
            if let existing {
                ok = await model.updateMcpServer(name: existing.name, request)
            } else {
                ok = await model.createMcpServer(request)
            }
            isSaving = false
            if ok {
                onSaved(SaveOutcome(
                    name: request.name,
                    previousName: existing?.name,
                    toolCount: toolCount
                ))
            } else {
                // Take the message off the model and clear it there, so the one
                // sentence appears beside the button that produced it rather
                // than also at the top of the page behind this sheet.
                saveError = model.mcpEditError
                model.clearMcpEditError()
            }
        }
    }

    private func delete() {
        guard let existing else { return }
        isSaving = true
        Task { @MainActor in
            let ok = await model.deleteMcpServer(name: existing.name)
            isSaving = false
            if ok {
                onClose()
            } else {
                saveError = model.mcpEditError
                model.clearMcpEditError()
            }
        }
    }
}

// MARK: - Draft

private struct McpArgument: Identifiable, Equatable {
    let id = UUID()
    var value: String = ""
}

/// One `env`/`headers` entry while it is being edited.
///
/// The two cases are the entire point of the type: a `.saved` entry is a secret
/// that lives sidecar-side and reached this Mac only as a mask, a `.entered`
/// one is a value typed in this session. They render differently (static text
/// versus a `SecureField`) and submit differently (the mask, which the sidecar
/// resolves back to the stored secret, versus the literal text), so the
/// distinction cannot collapse into a plain string without losing the ability
/// to tell a mask from a credential.
private struct McpSecretField: Identifiable, Equatable {
    enum Value: Equatable {
        case saved(mask: String)
        case entered(String)
    }

    let id = UUID()
    var key: String
    var value: Value

    var isSaved: Bool {
        if case .saved = value { return true }
        return false
    }

    /// The key as submitted. A typed key is trimmed; a saved one is sent back
    /// **exactly** as it arrived, because the sidecar matches masks per key and
    /// a normalised key would leave its mask with no stored counterpart — at
    /// which point the mask is written as that key's literal value.
    var submittedKey: String {
        isSaved ? key : key.trimmingCharacters(in: .whitespaces)
    }

    /// For a saved entry this is the mask, and sending it verbatim is precisely
    /// how "unchanged" is expressed on the wire.
    var submittedValue: String {
        switch value {
        case .saved(let mask): return mask
        case .entered(let text): return text
        }
    }

    static func saved(from masked: [String: String]?) -> [McpSecretField] {
        (masked ?? [:]).keys.sorted().map { key in
            McpSecretField(key: key, value: .saved(mask: masked?[key] ?? ""))
        }
    }
}

private struct McpServerDraft: Equatable {
    var name: String = ""
    var transport: McpTransport = .stdio
    var command: String = ""
    var args: [McpArgument] = []
    var url: String = ""
    var env: [McpSecretField] = []
    var headers: [McpSecretField] = []

    /// An empty draft when adding, or the stored server's fields when editing.
    ///
    /// Secrets come across as `.saved` masks — the only form they exist in on
    /// this Mac — so the form starts out unable to show a real credential even
    /// before anything decides how to render one.
    init(seededFrom existing: McpServerSummary?) {
        guard let existing else { return }
        name = existing.name
        transport = existing.transport
        command = existing.command ?? ""
        args = (existing.args ?? []).map { McpArgument(value: $0) }
        url = existing.url ?? ""
        env = McpSecretField.saved(from: existing.envMasked)
        headers = McpSecretField.saved(from: existing.headersMasked)
    }

    var activeSecrets: [McpSecretField] {
        transport == .stdio ? env : headers
    }

    /// Everything a connection attempt depends on.
    ///
    /// The name is deliberately absent: the transport is built from
    /// command/args/env or url/headers alone, so renaming a server cannot
    /// change whether it connects, and invalidating a passing test over a
    /// rename would make the user re-probe a live server to prove something the
    /// probe never looked at. A duplicate name is caught by the save's 400.
    var signature: String {
        var parts: [String] = [transport.rawValue]
        if transport == .stdio {
            parts.append(command.trimmingCharacters(in: .whitespaces))
            parts.append(contentsOf: args.map(\.value))
        } else {
            parts.append(url.trimmingCharacters(in: .whitespaces))
        }
        for entry in activeSecrets.sorted(by: { $0.submittedKey < $1.submittedKey }) {
            parts.append(entry.submittedKey)
            parts.append(entry.submittedValue)
        }
        return parts.joined(separator: "\u{1F}")
    }

    /// Builds the request.
    ///
    /// Only the active transport's map is sent; the other is omitted entirely
    /// (`nil`, which `encodeIfPresent` leaves out of the JSON) rather than sent
    /// empty. The sidecar drops the inactive half anyway, and a mask from the
    /// *other* map has no stored counterpart under this one — carrying it
    /// across is exactly how a mask ends up saved as a literal value.
    ///
    /// Every entry of the active map goes out, untouched ones carrying their
    /// masks, because the write is a replace: a key left out of the body is
    /// deleted server-side. That is also how deleting a row deletes the secret.
    ///
    /// `enabled` is `nil` for a probe, where it means nothing: the sidecar
    /// builds the transport from the connection fields alone, and letting the
    /// key be omitted keeps the tested body identical to the saved one in every
    /// respect the probe actually reads.
    func request(name overrideName: String? = nil, enabled: Bool?) -> McpServerRequest {
        let submittedName = (overrideName ?? name).trimmingCharacters(in: .whitespaces)
        var map: [String: String] = [:]
        for entry in activeSecrets {
            map[entry.submittedKey] = entry.submittedValue
        }
        if transport == .stdio {
            return McpServerRequest(
                name: submittedName,
                transport: .stdio,
                command: command.trimmingCharacters(in: .whitespaces),
                args: args
                    .map { $0.value.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                env: map,
                url: nil,
                headers: nil,
                enabled: enabled
            )
        }
        return McpServerRequest(
            name: submittedName,
            transport: .http,
            command: nil,
            args: nil,
            env: nil,
            url: url.trimmingCharacters(in: .whitespaces),
            headers: map,
            enabled: enabled
        )
    }
}

/// A finished Test Connection, with the elapsed time the panel reports.
///
/// `McpTestResultSummary` carries no timing, and the number matters here more
/// than most: the difference between a 1.8s connection and a 60s timeout is
/// the difference between a server worth keeping and one that costs the user
/// every future startup.
private struct McpTestOutcome: Equatable {
    let success: Bool
    let message: String?
    let tools: [String]
    let elapsed: TimeInterval
}

// MARK: - Sheet pieces

private struct McpTestResultBlock: View {
    let outcome: McpTestOutcome
    /// Usable width inside the block, which the tool chips pack against.
    let contentWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // The handoff's symbol table splits `warning` and `error`:
                // advice takes the hollow triangle, a thing that actually went
                // wrong takes the filled one. This header is the only `error`
                // on the page — the orange block below it is advice.
                Image(systemName: outcome.success ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: McpIcon.inlineGlyph))
                    .foregroundStyle(outcome.success ? DS.Colour.ink(0.55) : DS.Colour.error)
                Text(title)
                    .font(DS.Text.size(12.5, .semibold))
                    .foregroundStyle(outcome.success ? AnyShapeStyle(.primary) : AnyShapeStyle(DS.Colour.error))
                Spacer()
                Text(String(format: "%.1fs", outcome.elapsed))
                    .font(DS.Text.mono())
                    .foregroundStyle(DS.Colour.ink(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .dsHairline(.bottom)

            body(for: outcome)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous)
                .strokeBorder(
                    outcome.success ? DS.Colour.controlBorder : DS.Colour.error.opacity(0.35),
                    lineWidth: 0.75
                )
        )
    }

    private var title: String {
        guard outcome.success else {
            return OpenTypeL10n.text("连接失败", english: "Connection failed")
        }
        return OpenTypeL10n.text(
            "连接成功，发现 \(outcome.tools.count) 个工具",
            english: "Connected, found \(outcome.tools.count) tools"
        )
    }

    /// The tool list is the decision-relevant part of a pass — it is literally
    /// the set of unsandboxed capabilities this server would hand the agent —
    /// so it is shown in full rather than summarised as a count. A failure
    /// shows the server's own words, unedited: "MCP error -32001: Request timed
    /// out" tells someone what to fix; a rephrased "couldn't connect" does not.
    @ViewBuilder
    private func body(for outcome: McpTestOutcome) -> some View {
        if outcome.success {
            if outcome.tools.isEmpty {
                Text(OpenTypeL10n.text(
                    "这个服务器没有提供任何工具。",
                    english: "This server exposes no tools."
                ))
                .font(DS.Text.caption())
                .foregroundStyle(.secondary)
            } else {
                McpWrappingTags(titles: outcome.tools, available: contentWidth)
            }
        } else {
            Text(outcome.message ?? OpenTypeL10n.text("没有更多信息", english: "No further detail"))
                .font(DS.Text.mono())
                // 1.6 line height at 11pt.
                .lineSpacing(4)
                .foregroundStyle(DS.Colour.ink(0.6))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The probed tool names as mono chips. Laid out by hand because macOS 13 has
/// no `Layout`-free flow container and a `LazyVGrid` would column-align names
/// of wildly different lengths.
private struct McpWrappingTags: View {
    let titles: [String]
    /// Width to pack into — the sheet is 560 for stdio and 460 for http, so
    /// this cannot be a constant.
    let available: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(row, id: \.self) { title in
                        Text(title)
                            .font(DS.Text.mono())
                            .foregroundStyle(DS.Colour.ink(0.65))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                DS.Colour.codeFill,
                                in: RoundedRectangle(cornerRadius: DS.Radius.tag, style: .continuous)
                            )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Greedy packing on an estimated width — mono glyphs are a fixed advance,
    /// so the estimate is exact enough for chips.
    private var rows: [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var used: CGFloat = 0
        for title in titles {
            let width = CGFloat(title.count) * 6.6 + 19
            if !current.isEmpty && used + width > available {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(title)
            used += width + 5
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

private struct McpArgumentRow: View {
    let index: Int
    @Binding var text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(DS.Text.mono())
                .foregroundStyle(DS.Colour.ink(0.3))
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(DS.Text.mono(12))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: McpIcon.removeGlyph))
                    .foregroundStyle(DS.Colour.ink(0.3))
            }
            .buttonStyle(.plain)
            .help(OpenTypeL10n.text("删除这一项", english: "Remove this one"))
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Colour.buttonBorder, lineWidth: 0.75)
        )
    }
}

/// One env/header row.
///
/// A saved value is `Text`, never a field, and its key is `Text` too. 「更改」
/// switches the row to an empty `SecureField` — never one seeded with the mask,
/// which is the difference between replacing a secret and editing a picture of
/// one.
private struct McpSecretRowView: View {
    @Binding var entry: McpSecretField
    let isFirst: Bool
    /// The handoff's fixed key column: 150 in the 560pt stdio sheet, 110 in the
    /// 460pt http one.
    let keyWidth: CGFloat
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch entry.value {
            case .saved(let mask):
                Text(entry.key)
                    .font(DS.Text.mono(12))
                    .lineLimit(1)
                    .frame(width: keyWidth, alignment: .leading)
                Text(mask)
                    .font(DS.Text.mono(12))
                    .foregroundStyle(DS.Colour.ink(0.4))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(OpenTypeL10n.text(
                        "已保存的密钥不会回传，这里显示的是遮盖值。保存时原值保持不变。",
                        english: "Saved secrets are never sent back; this is a mask. Saving leaves the stored value untouched."
                    ))
                McpLinkButton(title: OpenTypeL10n.text("更改", english: "Change")) {
                    // Deliberately empty, never seeded from the mask.
                    entry.value = .entered("")
                }

            case .entered:
                TextField(OpenTypeL10n.text("键名", english: "Key"), text: $entry.key)
                    .textFieldStyle(.plain)
                    .font(DS.Text.mono(12))
                    .frame(width: keyWidth, alignment: .leading)
                SecureField(
                    OpenTypeL10n.text("值", english: "Value"),
                    text: Binding(
                        get: {
                            if case .entered(let text) = entry.value { return text }
                            return ""
                        },
                        set: { entry.value = .entered($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(DS.Text.mono(12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: McpIcon.removeGlyph))
                    .foregroundStyle(DS.Colour.ink(0.3))
            }
            .buttonStyle(.plain)
            .help(OpenTypeL10n.text("删除这一项", english: "Remove this one"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(DS.Colour.hairline).frame(height: 0.75)
            }
        }
    }
}

// MARK: - Small shared pieces

private struct McpGroupHeader<Trailing: View>: View {
    let title: String
    /// The handoff aligns the two group headers differently — 内置工具's pair of
    /// 11pt runs on their baseline, MCP 服务器's 11pt label and 11.5pt link on
    /// their centres — so the caller says which of its own it is.
    var alignment: VerticalAlignment = .firstTextBaseline
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: alignment, spacing: 8) {
            Text(title)
                .font(DS.Text.groupLabel())
                .tracking(DS.Tracking.groupLabel)
                .foregroundStyle(DS.Colour.ink(0.42))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 4)
    }
}

/// The 「本机」/「网络与记忆」 strips inside the built-in card.
private struct McpCardSectionHeader: View {
    let title: String
    let isFirst: Bool

    var body: some View {
        Text(title)
            .font(DS.Text.groupLabel())
            .tracking(DS.Tracking.groupLabel)
            .foregroundStyle(DS.Colour.ink(0.42))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(DS.Colour.insetSurface)
            .overlay(alignment: .top) {
                if !isFirst {
                    Rectangle().fill(DS.Colour.hairline).frame(height: 0.75)
                }
            }
    }
}

private struct McpNoticeCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Text.caption())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.content)
            .padding(.vertical, 14)
            .dsCard()
    }
}

private struct McpTag: View {
    let title: String
    let fill: Color
    let tint: Color

    var body: some View {
        Text(title)
            .font(DS.Text.size(10.5, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill, in: RoundedRectangle(cornerRadius: DS.Radius.tag, style: .continuous))
    }
}

private struct McpTransportTag: View {
    let transport: McpTransport

    var body: some View {
        switch transport {
        case .stdio:
            McpTag(title: "stdio", fill: DS.Colour.control, tint: DS.Colour.ink(0.5))
        case .http:
            // `askTag`, not `accent`: the handoff darkens the text on a tinted
            // blue fill so it stays legible against its own 11% wash.
            McpTag(title: "http", fill: DS.Colour.accent.opacity(0.11), tint: DS.Colour.askTag)
        }
    }
}

private enum McpButtonKind {
    case chrome
    case primary
    /// White with a red edge: an action that is safe to take but not the happy
    /// path, so it reads as a decision rather than as a warning.
    case danger
}

private struct McpButton: View {
    let title: String
    var icon: String?
    var kind: McpButtonKind = .chrome
    /// The handoff draws a chrome button's edge at two weights — `.09` for the
    /// one in 7A's header, `.12` for the ones in the sheet and 7D footers — and
    /// pads that first one `0 11px` against everyone else's `0 12px`. Picking
    /// one of each pair would be visibly wrong at whichever end it landed, so
    /// the odd call site names what it needs and the common case is the default.
    var border: Color = DS.Colour.buttonBorder
    var paddingH: CGFloat = 12
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: McpIcon.inlineGlyph))
                        .foregroundStyle(kind == .primary ? .white : DS.Colour.ink(0.5))
                }
                Text(title)
                    .font(DS.Text.caption())
                    .fontWeight(kind == .primary ? .medium : .regular)
                    .foregroundStyle(foreground)
            }
            .padding(.horizontal, paddingH)
            .frame(height: 26)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous)
                    .strokeBorder(borderColour, lineWidth: 0.75)
            )
            .modifier(McpButtonShadow(kind: kind))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .chrome: return AnyShapeStyle(.primary)
        case .primary: return AnyShapeStyle(.white)
        case .danger: return AnyShapeStyle(DS.Colour.error)
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous)
            .fill(kind == .primary ? DS.Colour.accent : DS.Colour.card)
    }

    private var borderColour: Color {
        switch kind {
        case .chrome: return border
        case .primary: return .clear
        case .danger: return DS.Colour.error.opacity(0.4)
        }
    }
}

private struct McpButtonShadow: ViewModifier {
    let kind: McpButtonKind

    func body(content: Content) -> some View {
        switch kind {
        case .primary:
            DS.Shadow.accentControl(content)
        case .chrome, .danger:
            DS.Shadow.control(content)
        }
    }
}

/// A text-only action: 添加服务器 / 添加一项 / 更改 / 删除.
private struct McpLinkButton: View {
    let title: String
    var tint: Color = DS.Colour.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Text.size(11.5, .medium))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

/// Label, optional trailing action, and the control(s) under them.
private struct McpField<Content: View>: View {
    let title: String
    var action: (String, () -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(DS.Text.caption())
                    .fontWeight(.medium)
                Spacer()
                if let action {
                    McpLinkButton(title: action.0, action: action.1)
                }
            }
            content()
        }
    }
}

private struct McpTextField: View {
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        // Lifted, like every other 28pt control in the handoff — a field with
        // no shadow reads as a flat inset panel rather than as something you
        // type into.
        DS.Shadow.field(
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Text.mono(12.5))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous)
                        .strokeBorder(DS.Colour.fieldBorder, lineWidth: 0.75)
                )
        )
    }
}

/// The transport picker, drawn rather than `.pickerStyle(.segmented)` so it
/// matches the redesign's segmented spec (28pt, recessed track, lifted white
/// selection) instead of the system's.
private struct McpSegmentedControl: View {
    @Binding var selection: McpTransport

    var body: some View {
        HStack(spacing: 2) {
            ForEach(McpTransport.allCases) { candidate in
                Button {
                    selection = candidate
                } label: {
                    Text(label(for: candidate))
                        .font(DS.Text.caption())
                        .fontWeight(selection == candidate ? .medium : .regular)
                        .foregroundStyle(selection == candidate ? AnyShapeStyle(.primary) : AnyShapeStyle(DS.Colour.ink(0.55)))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(selectionBackground(for: candidate))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(height: 28)
        .background(DS.Colour.segmentTrack, in: RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous))
    }

    @ViewBuilder
    private func selectionBackground(for candidate: McpTransport) -> some View {
        if selection == candidate {
            // `lifted`, not `control`: the handoff raises the selected segment
            // harder than a plain small control, which is what separates it
            // from its own track rather than from the sheet.
            DS.Shadow.lifted(
                RoundedRectangle(cornerRadius: DS.Radius.tag, style: .continuous)
                    .fill(DS.Colour.card)
            )
        } else {
            Color.clear
        }
    }

    /// Short labels: the segment is the whole explanation, and
    /// `McpTransport.title` is the long form the old inline form needed.
    private func label(for transport: McpTransport) -> String {
        switch transport {
        case .stdio: return OpenTypeL10n.text("本地进程", english: "Local process")
        case .http: return OpenTypeL10n.text("远程 HTTP", english: "Remote HTTP")
        }
    }
}

/// A sentence with one machine identifier set in mono, the way the handoff
/// chips `OPENTYPE_MCP_SERVERS` and `github__create_issue` inside body copy.
///
/// Built by concatenating `Text` rather than by handing SwiftUI a markdown
/// string: the identifiers on this page contain `__`, which markdown would
/// read as emphasis and swallow — turning a tool name into a bold fragment of
/// itself in exactly the copy that exists to show the user its literal
/// spelling.
private func McpCodeSentence(
    _ prefix: String,
    _ code: String,
    _ suffix: String,
    fill: Color = DS.Colour.codeFill
) -> Text {
    Text(prefix) + Text(McpCodeChip(code, fill: fill)) + Text(suffix)
}

/// The identifier itself, tinted the way the handoff chips it inside body copy.
///
/// A run inside a concatenated `Text` can carry a font and a background colour
/// but not a box model, so the mockup's `padding: 1.5px 5px` and
/// `border-radius: 4px` have no direct expression. The horizontal breathing
/// room is approximated with thin spaces inside the tinted run — without them
/// the fill sits flush against the first and last glyph and reads as a
/// highlight rather than as a chip. The rounded corners are simply absent; see
/// `docs/design-review/07-mcp.md`.
/// `fill` is a parameter because the handoff uses two: `rgba(0,0,0,.045)` in
/// 7A and 7B's helper, `rgba(0,0,0,.05)` in 7D's read-only strip.
private func McpCodeChip(_ code: String, fill: Color = DS.Colour.codeFill) -> AttributedString {
    var chip = AttributedString("\u{2009}\(code)\u{2009}")
    chip.font = DS.Text.mono()
    chip.backgroundColor = fill
    return chip
}

private struct McpFormHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
