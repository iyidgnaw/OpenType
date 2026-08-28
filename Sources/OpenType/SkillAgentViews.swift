import AppKit
import SwiftUI

// MARK: - 8A · The page

/// Settings → 引擎 → **Skill 与 Agent** (design §3, screens 8A–8D,
/// `docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md`):
/// two columns, SKILL on the left and AGENT on the right, each grouped
/// 内置 / 我的 / Claude Code (decision A-2's bucketing), with editors for the
/// user's own copies and read-only viewers for everything else.
///
/// Modeled on `McpServerViews.swift`'s `AgentToolsPage` (the closest sibling:
/// a settings sub-page with a two-column layout, list cards, and sheets), but
/// this page carries no explanatory captions anywhere (E5) — only state
/// feedback (counts, the shadow badge, validation errors) and shortcut/
/// consequence copy.
struct SkillAgentPage: View {
    @ObservedObject var model: AppModel
    var onBack: () -> Void

    @State private var sheet: SkillAgentSheet?
    /// A sheet queued to open right after the current one finishes
    /// dismissing — SwiftUI needs a frame between a sheet closing and the
    /// next one presenting, so "复制到我的 Skill 再改" (which closes the viewer
    /// and opens the editor) routes through this rather than swapping `sheet`
    /// synchronously in one action.
    @State private var pendingSheet: SkillAgentSheet?

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
        .task {
            await model.refreshSkills()
            await model.refreshAgentDefinitions()
        }
        .sheet(item: $sheet, onDismiss: {
            if let pendingSheet {
                self.pendingSheet = nil
                self.sheet = pendingSheet
            }
        }) { target in
            sheetContent(for: target)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20))
                    .foregroundStyle(DS.Colour.accent)
            }
            .buttonStyle(.plain)
            .help(OpenTypeL10n.text("返回设置", english: "Back to Settings"))

            Text(SettingsRoute.skillsAndAgents.title)
                .font(DS.Text.title())
                .tracking(DS.Tracking.title)

            Spacer()
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
                skillColumn
                agentColumn
            }
        } else {
            HStack(alignment: .top, spacing: DS.Space.group) {
                skillColumn.frame(maxWidth: .infinity, alignment: .leading)
                agentColumn.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: SKILL column

    private var skillSections: [SkillListSection] {
        SkillListBuilder.sections(for: model.skills ?? [], homeDirectory: model.skillAgentHomeDirectory)
    }

    private var skillColumn: some View {
        VStack(alignment: .leading, spacing: DS.Space.label) {
            SkillAgentColumnHeader(
                title: OpenTypeL10n.text(
                    "SKILL · \(model.skills?.count ?? 0)",
                    english: "SKILL · \(model.skills?.count ?? 0)"
                ),
                actionTitle: OpenTypeL10n.text("新建 Skill", english: "New skill")
            ) {
                sheet = .skillEditor(.create)
            }

            skillCard

            SkillAgentLinkButton(title: OpenTypeL10n.text("在访达中打开", english: "Open in Finder")) {
                openSkillsFolderInFinder()
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var skillCard: some View {
        if model.skills == nil {
            SkillAgentNoticeCard(text: OpenTypeL10n.text("正在读取…", english: "Loading…"))
        } else if skillSections.isEmpty {
            SkillAgentNoticeCard(text: "—")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(skillSections.enumerated()), id: \.element.id) { index, section in
                    SkillAgentSectionHeader(
                        title: skillAgentSectionTitle(for: section.bucket, count: section.count),
                        isFirst: index == 0,
                        trailingCaption: section.bucket == .claude
                            ? OpenTypeL10n.text("只读", english: "Read-only")
                            : nil
                    )
                    ForEach(section.rows) { row in
                        Button {
                            openSkillRow(row)
                        } label: {
                            SkillRowView(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCard()
        }
    }

    private func openSkillRow(_ row: SkillListRow) {
        if row.isReadOnly {
            sheet = .skillViewer(SkillViewerTarget(name: row.skill.name, root: row.skill.root, bucket: row.bucket))
        } else {
            sheet = .skillEditor(.edit(name: row.skill.name, root: row.skill.root))
        }
    }

    private func openSkillsFolderInFinder() {
        let skillsURL = URL(fileURLWithPath: model.skillAgentHomeDirectory)
            .appendingPathComponent(".opentype", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(skillsURL)
    }

    // MARK: AGENT column

    private var agentSections: [AgentListSection] {
        AgentListBuilder.sections(for: model.agentDefinitions ?? [], homeDirectory: model.skillAgentHomeDirectory)
    }

    private var agentColumn: some View {
        VStack(alignment: .leading, spacing: DS.Space.label) {
            SkillAgentColumnHeader(
                title: OpenTypeL10n.text(
                    "AGENT · \(model.agentDefinitions?.count ?? 0)",
                    english: "AGENT · \(model.agentDefinitions?.count ?? 0)"
                ),
                actionTitle: OpenTypeL10n.text("新建 Agent", english: "New agent")
            ) {
                sheet = .agentEditor(.create)
            }

            agentCard
        }
    }

    @ViewBuilder
    private var agentCard: some View {
        if model.agentDefinitions == nil {
            SkillAgentNoticeCard(text: OpenTypeL10n.text("正在读取…", english: "Loading…"))
        } else if agentSections.isEmpty {
            SkillAgentNoticeCard(text: "—")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(agentSections.enumerated()), id: \.element.id) { index, section in
                    SkillAgentSectionHeader(
                        title: skillAgentSectionTitle(for: section.bucket, count: section.count),
                        isFirst: index == 0,
                        trailingCaption: section.bucket == .claude
                            ? OpenTypeL10n.text("只读", english: "Read-only")
                            : nil
                    )
                    ForEach(section.rows) { row in
                        Button {
                            openAgentRow(row)
                        } label: {
                            AgentRowView(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCard()
        }
    }

    private func openAgentRow(_ row: AgentListRow) {
        if row.isReadOnly {
            sheet = .agentViewer(AgentViewerTarget(name: row.agent.name, root: row.agent.root, bucket: row.bucket))
        } else {
            sheet = .agentEditor(.edit(name: row.agent.name, root: row.agent.root))
        }
    }

    // MARK: Sheet routing

    @ViewBuilder
    private func sheetContent(for target: SkillAgentSheet) -> some View {
        switch target {
        case .skillEditor(let editorTarget):
            SkillEditorSheet(
                model: model,
                target: editorTarget,
                onClose: { sheet = nil },
                onSaved: { sheet = nil }
            )
        case .skillViewer(let viewerTarget):
            SkillViewerSheet(
                model: model,
                target: viewerTarget,
                onClose: { sheet = nil },
                onCopyToMine: { prefill in
                    pendingSheet = .skillEditor(.createPrefilled(prefill))
                    sheet = nil
                }
            )
        case .agentEditor(let editorTarget):
            AgentEditorSheet(
                model: model,
                target: editorTarget,
                onClose: { sheet = nil },
                onSaved: { sheet = nil }
            )
        case .agentViewer(let viewerTarget):
            AgentViewerSheet(
                model: model,
                target: viewerTarget,
                onClose: { sheet = nil }
            )
        }
    }
}

/// 内置/我的/Claude Code, shared between the SKILL and AGENT columns.
private func skillAgentSectionTitle(for bucket: SkillAgentSourceBucket, count: Int) -> String {
    switch bucket {
    case .builtin:
        return OpenTypeL10n.text("内置 · \(count)", english: "Built-in · \(count)")
    case .user:
        return OpenTypeL10n.text("我的 · \(count)", english: "Mine · \(count)")
    case .claude:
        return OpenTypeL10n.text("Claude Code · \(count)", english: "Claude Code · \(count)")
    }
}

@ViewBuilder
private func skillAgentSourceBadge(for bucket: SkillAgentSourceBucket) -> some View {
    switch bucket {
    case .builtin:
        SkillAgentTag(title: OpenTypeL10n.text("内置", english: "Built-in"), fill: DS.Colour.control, tint: DS.Colour.ink(0.5))
    case .user:
        SkillAgentTag(title: OpenTypeL10n.text("我的", english: "Mine"), fill: DS.Colour.control, tint: DS.Colour.ink(0.5))
    case .claude:
        SkillAgentTag(title: OpenTypeL10n.text("Claude Code", english: "Claude Code"), fill: DS.Colour.accent.opacity(0.11), tint: DS.Colour.askTag)
    }
}

/// Which sheet is presented — a single `Identifiable` enum rather than four
/// parallel `@State` optionals, so exactly one `.sheet(item:)` modifier ever
/// governs presentation.
private enum SkillAgentSheet: Identifiable {
    case skillEditor(SkillEditorTarget)
    case skillViewer(SkillViewerTarget)
    case agentEditor(AgentEditorTarget)
    case agentViewer(AgentViewerTarget)

    var id: String {
        switch self {
        case .skillEditor(let target): return "skill-editor-\(target.id)"
        case .skillViewer(let target): return "skill-viewer-\(target.id)"
        case .agentEditor(let target): return "agent-editor-\(target.id)"
        case .agentViewer(let target): return "agent-viewer-\(target.id)"
        }
    }
}

private enum SkillEditorTarget: Identifiable {
    case create
    /// E2's "复制到我的 Skill 再改": a create prefilled from a builtin's detail.
    case createPrefilled(SkillEditorFormState)
    case edit(name: String, root: String)

    var id: String {
        switch self {
        case .create: return "create"
        case .createPrefilled(let state): return "create-prefilled-\(state.name)"
        case .edit(let name, let root): return "edit-\(root)|\(name)"
        }
    }
}

private struct SkillViewerTarget: Identifiable {
    let name: String
    let root: String
    let bucket: SkillAgentSourceBucket
    var id: String { "\(root)|\(name)" }
}

private enum AgentEditorTarget: Identifiable {
    case create
    case edit(name: String, root: String)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let name, let root): return "edit-\(root)|\(name)"
        }
    }
}

private struct AgentViewerTarget: Identifiable {
    let name: String
    let root: String
    let bucket: SkillAgentSourceBucket
    var id: String { "\(root)|\(name)" }
}

// MARK: - Rows

private struct SkillRowView: View {
    let row: SkillListRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.skill.name)
                        .font(DS.Text.mono(12, weight: .semibold))
                        .foregroundStyle(row.showsShadowedBadge ? DS.Colour.ink(0.4) : Color.primary)
                    if row.showsShadowedBadge {
                        SkillAgentTag(
                            title: OpenTypeL10n.text("被内置同名覆盖", english: "Overridden by a built-in"),
                            fill: DS.Colour.warningFill,
                            tint: DS.Colour.warningText
                        )
                    }
                }
                Text(row.skill.description)
                    .font(DS.Text.size(11.5))
                    .foregroundStyle(DS.Colour.ink(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: row.isReadOnly ? "lock.fill" : "chevron.right")
                .font(.system(size: row.isReadOnly ? 13 : 14))
                .foregroundStyle(DS.Colour.ink(0.3))
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .dsHairline(.top)
    }
}

private struct AgentRowView: View {
    let row: AgentListRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.agent.name)
                        .font(DS.Text.mono(12, weight: .semibold))
                        .foregroundStyle(row.showsShadowedBadge ? DS.Colour.ink(0.4) : Color.primary)
                    if row.showsShadowedBadge {
                        SkillAgentTag(
                            title: OpenTypeL10n.text("被内置同名覆盖", english: "Overridden by a built-in"),
                            fill: DS.Colour.warningFill,
                            tint: DS.Colour.warningText
                        )
                    }
                }
                Text(row.agent.description)
                    .font(DS.Text.size(11.5))
                    .foregroundStyle(DS.Colour.ink(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let metaLine {
                    Text(metaLine)
                        .font(DS.Text.mono())
                        .foregroundStyle(DS.Colour.ink(0.4))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: row.isReadOnly ? "lock.fill" : "chevron.right")
                .font(.system(size: row.isReadOnly ? 13 : 14))
                .foregroundStyle(DS.Colour.ink(0.3))
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .dsHairline(.top)
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let tools = row.agent.tools, !tools.isEmpty {
            parts.append(OpenTypeL10n.text("工具 \(tools)", english: "Tools \(tools)"))
        }
        if let model = row.agent.model, !model.isEmpty {
            parts.append(OpenTypeL10n.text("模型 \(model)", english: "Model \(model)"))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "   ")
    }
}

// MARK: - 8B · Skill editor sheet

private struct SkillEditorSheet: View {
    @ObservedObject var model: AppModel
    let target: SkillEditorTarget
    let onClose: () -> Void
    let onSaved: () -> Void

    @State private var state: SkillEditorFormState?
    @State private var loadFailed = false
    @State private var bodyMode: SkillAgentBodyEditMode = .write
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if state != nil {
                VStack(spacing: 0) {
                    SkillAgentSheetHeader(
                        title: target.headerTitle,
                        onClose: onClose
                    )
                    form
                    footer
                }
            } else if loadFailed {
                SkillAgentSheetLoadFailure(message: model.skillAgentEditError, onClose: onClose)
            } else {
                SkillAgentSheetLoading()
            }
        }
        .frame(width: 620, height: 620)
        .background(DS.Colour.recessed)
        .task { await load() }
        .confirmationDialog(
            OpenTypeL10n.text(
                "删除 Skill「\(stateBinding.wrappedValue.name)」？",
                english: "Delete the skill “\(stateBinding.wrappedValue.name)”?"
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
                "这个 Skill 的文件夹会被直接删除，不会进入废纸篓，无法恢复。",
                english: "The skill's folder is deleted immediately — not moved to the Trash — and can't be recovered."
            ))
        }
    }

    private var stateBinding: Binding<SkillEditorFormState> {
        Binding(get: { state ?? .blankForCreate() }, set: { state = $0 })
    }

    private func load() async {
        switch target {
        case .create:
            state = .blankForCreate()
        case .createPrefilled(let prefill):
            state = prefill
        case .edit(let name, let root):
            if let detail = await model.fetchSkillDetail(name: name, root: root) {
                state = .loadForEdit(from: detail)
            } else {
                loadFailed = true
            }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.content) {
                nameField
                descriptionField
                bodyField
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Text.caption())
                        .foregroundStyle(DS.Colour.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

    private var nameField: some View {
        SkillAgentField(title: OpenTypeL10n.text("名称", english: "Name")) {
            if stateBinding.wrappedValue.isNameEditable {
                SkillAgentTextField(
                    text: Binding(get: { stateBinding.wrappedValue.name }, set: { stateBinding.wrappedValue.name = $0 }),
                    placeholder: "my-skill"
                )
            } else {
                SkillAgentStaticValue(text: stateBinding.wrappedValue.name)
            }
            if let error = nameErrorText {
                SkillAgentValidationText(error)
            }
        }
    }

    private var descriptionField: some View {
        SkillAgentField(title: OpenTypeL10n.text("描述", english: "Description")) {
            SkillAgentTextEditor(
                text: Binding(get: { stateBinding.wrappedValue.description }, set: { stateBinding.wrappedValue.description = $0 }),
                minHeight: 54
            )
        }
    }

    private var bodyField: some View {
        SkillAgentField(title: OpenTypeL10n.text("正文", english: "Body")) {
            VStack(alignment: .leading, spacing: 8) {
                SkillAgentSegmentedToggle(mode: $bodyMode)
                if bodyMode == .write {
                    SkillAgentTextEditor(
                        text: Binding(get: { stateBinding.wrappedValue.body }, set: { stateBinding.wrappedValue.body = $0 }),
                        minHeight: 220,
                        mono: true
                    )
                } else {
                    ScrollView {
                        AssistantMarkdownView(markdown: stateBinding.wrappedValue.body, fontSize: 12.5)
                            .padding(10)
                    }
                    .frame(minHeight: 220, maxHeight: 220)
                    .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous)
                            .strokeBorder(DS.Colour.fieldBorder, lineWidth: 0.75)
                    )
                }
            }
        }
    }

    private var footer: some View {
        SkillAgentFooterBar {
            if case .edit = target {
                SkillAgentLinkButton(title: OpenTypeL10n.text("删除", english: "Delete"), tint: DS.Colour.error) {
                    confirmingDelete = true
                }
            }
            Text(targetPath)
                .font(DS.Text.mono())
                .foregroundStyle(DS.Colour.ink(0.4))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            SkillAgentButton(title: OpenTypeL10n.text("取消", english: "Cancel")) { onClose() }
            SkillAgentButton(
                title: isSaving ? OpenTypeL10n.text("保存中…", english: "Saving…") : OpenTypeL10n.text("保存", english: "Save"),
                kind: .primary,
                isEnabled: !isSaving && stateBinding.wrappedValue.isSaveEnabled(amongSkills: model.skills ?? [], homeDirectory: model.skillAgentHomeDirectory)
            ) {
                save()
            }
        }
    }

    private var targetPath: String {
        let name = stateBinding.wrappedValue.name.isEmpty ? "…" : stateBinding.wrappedValue.name
        return "~/.opentype/skills/\(name)/SKILL.md"
    }

    private var nameErrorText: String? {
        guard let error = stateBinding.wrappedValue.nameError(amongSkills: model.skills ?? [], homeDirectory: model.skillAgentHomeDirectory) else {
            return nil
        }
        return skillAgentNameErrorText(error, kind: .skill)
    }

    private func save() {
        guard let current = state else { return }
        isSaving = true
        saveError = nil
        Task { @MainActor in
            let ok = await model.saveSkill(current)
            isSaving = false
            if ok {
                onSaved()
            } else {
                saveError = model.skillAgentEditError
                model.clearSkillAgentEditError()
            }
        }
    }

    private func delete() {
        guard case .edit(let name, _) = target else { return }
        isSaving = true
        Task { @MainActor in
            let ok = await model.deleteSkill(name: name)
            isSaving = false
            if ok {
                onSaved()
            } else {
                saveError = model.skillAgentEditError
                model.clearSkillAgentEditError()
            }
        }
    }
}

private extension SkillEditorTarget {
    var headerTitle: String {
        switch self {
        case .create, .createPrefilled:
            return OpenTypeL10n.text("新建 Skill", english: "New skill")
        case .edit(let name, _):
            return OpenTypeL10n.text("编辑 \(name)", english: "Edit \(name)")
        }
    }
}

// MARK: - 8C · Skill read-only viewer sheet

private struct SkillViewerSheet: View {
    @ObservedObject var model: AppModel
    let target: SkillViewerTarget
    let onClose: () -> Void
    let onCopyToMine: (SkillEditorFormState) -> Void

    @State private var detail: SkillDetail?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let detail {
                VStack(spacing: 0) {
                    SkillAgentSheetHeader(title: detail.name, onClose: onClose)
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.content) {
                            HStack(spacing: 8) {
                                Text(detail.name).font(DS.Text.mono(13, weight: .semibold))
                                skillAgentSourceBadge(for: target.bucket)
                            }
                            Text(detail.description)
                                .font(DS.Text.caption())
                                .foregroundStyle(DS.Colour.ink(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                            AssistantMarkdownView(markdown: detail.body, fontSize: 12.5)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                    }
                    .scrollIndicators(.hidden)
                    footer
                }
            } else if loadFailed {
                SkillAgentSheetLoadFailure(message: model.skillAgentEditError, onClose: onClose)
            } else {
                SkillAgentSheetLoading()
            }
        }
        .frame(width: 560, height: 560)
        .background(DS.Colour.recessed)
        .task { await load() }
    }

    private var footer: some View {
        SkillAgentFooterBar {
            Spacer()
            if target.bucket == .builtin {
                SkillAgentButton(title: OpenTypeL10n.text("复制到我的 Skill 再改", english: "Copy to mine and edit")) {
                    if let detail {
                        onCopyToMine(.copyToMine(from: detail))
                    }
                }
            }
            SkillAgentButton(title: OpenTypeL10n.text("关闭", english: "Close")) { onClose() }
        }
    }

    private func load() async {
        if let fetched = await model.fetchSkillDetail(name: target.name, root: target.root) {
            detail = fetched
        } else {
            loadFailed = true
        }
    }
}

// MARK: - 8D · Agent editor sheet

private struct AgentEditorSheet: View {
    @ObservedObject var model: AppModel
    let target: AgentEditorTarget
    let onClose: () -> Void
    let onSaved: () -> Void

    @State private var state: AgentEditorFormState?
    @State private var loadFailed = false
    @State private var bodyMode: SkillAgentBodyEditMode = .write
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if state != nil {
                VStack(spacing: 0) {
                    SkillAgentSheetHeader(title: target.headerTitle, onClose: onClose)
                    form
                    footer
                }
            } else if loadFailed {
                SkillAgentSheetLoadFailure(message: model.skillAgentEditError, onClose: onClose)
            } else {
                SkillAgentSheetLoading()
            }
        }
        .frame(width: 620, height: 620)
        .background(DS.Colour.recessed)
        .task { await load() }
        .confirmationDialog(
            OpenTypeL10n.text(
                "删除 Agent「\(stateBinding.wrappedValue.name)」？",
                english: "Delete the agent “\(stateBinding.wrappedValue.name)”?"
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
                "这个 Agent 的文件会被直接删除，不会进入废纸篓，无法恢复。",
                english: "The agent's file is deleted immediately — not moved to the Trash — and can't be recovered."
            ))
        }
    }

    private var stateBinding: Binding<AgentEditorFormState> {
        Binding(get: { state ?? .blankForCreate() }, set: { state = $0 })
    }

    private func load() async {
        switch target {
        case .create:
            state = .blankForCreate()
        case .edit(let name, let root):
            if let detail = await model.fetchAgentDefinitionDetail(name: name, root: root) {
                state = .loadForEdit(from: detail)
            } else {
                loadFailed = true
            }
        }
    }

    private var allTools: [McpBuiltInTool] {
        McpBuiltInCatalog.local + McpBuiltInCatalog.networkAndMemory
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.content) {
                HStack(alignment: .top, spacing: 14) {
                    nameField.frame(maxWidth: .infinity, alignment: .leading)
                    displayNameField.frame(maxWidth: .infinity, alignment: .leading)
                }
                descriptionField
                toolsField
                systemPromptField
                if let existingModel = stateBinding.wrappedValue.existingModel {
                    modelField(existingModel)
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
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

    private var nameField: some View {
        SkillAgentField(title: OpenTypeL10n.text("名称", english: "Name")) {
            if stateBinding.wrappedValue.isNameEditable {
                SkillAgentTextField(
                    text: Binding(get: { stateBinding.wrappedValue.name }, set: { stateBinding.wrappedValue.name = $0 }),
                    placeholder: "researcher"
                )
            } else {
                SkillAgentStaticValue(text: stateBinding.wrappedValue.name)
            }
            if let error = nameErrorText {
                SkillAgentValidationText(error)
            }
        }
    }

    private var displayNameField: some View {
        SkillAgentField(title: OpenTypeL10n.text("显示名（可选）", english: "Display name (optional)")) {
            SkillAgentTextField(
                text: Binding(get: { stateBinding.wrappedValue.displayName }, set: { stateBinding.wrappedValue.displayName = $0 }),
                placeholder: "",
                mono: false
            )
        }
    }

    private var descriptionField: some View {
        SkillAgentField(title: OpenTypeL10n.text("描述", english: "Description")) {
            SkillAgentTextEditor(
                text: Binding(get: { stateBinding.wrappedValue.description }, set: { stateBinding.wrappedValue.description = $0 }),
                minHeight: 54
            )
        }
    }

    private var toolsField: some View {
        SkillAgentField(title: OpenTypeL10n.text("工具", english: "Tools")) {
            GeometryReader { proxy in
                SkillAgentToolChipFlow(
                    tools: allTools,
                    selected: Binding(get: { stateBinding.wrappedValue.selectedTools }, set: { stateBinding.wrappedValue.selectedTools = $0 }),
                    available: proxy.size.width
                )
            }
            .frame(height: toolsFlowHeight)
        }
    }

    /// A `GeometryReader`-based flow layout has no intrinsic height of its
    /// own, so this estimates enough rows for the full built-in catalog —
    /// generous rather than exact, since the chips wrap regardless. The wider
    /// 620pt sheet (was 520pt) packs the full 16-tool catalog into 3 rows
    /// instead of 4, so this was lowered from 110 to avoid leaving a visible
    /// gap of empty space below the chips.
    private var toolsFlowHeight: CGFloat { 90 }

    private var systemPromptField: some View {
        SkillAgentField(title: OpenTypeL10n.text("系统提示", english: "System prompt")) {
            VStack(alignment: .leading, spacing: 8) {
                SkillAgentSegmentedToggle(mode: $bodyMode)
                if bodyMode == .write {
                    SkillAgentTextEditor(
                        text: Binding(get: { stateBinding.wrappedValue.body }, set: { stateBinding.wrappedValue.body = $0 }),
                        minHeight: 160,
                        mono: true
                    )
                } else {
                    ScrollView {
                        AssistantMarkdownView(markdown: stateBinding.wrappedValue.body, fontSize: 12.5)
                            .padding(10)
                    }
                    .frame(minHeight: 160, maxHeight: 160)
                    .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous)
                            .strokeBorder(DS.Colour.fieldBorder, lineWidth: 0.75)
                    )
                }
            }
        }
    }

    private func modelField(_ value: String) -> some View {
        SkillAgentField(title: OpenTypeL10n.text("模型", english: "Model")) {
            SkillAgentStaticValue(text: value)
        }
    }

    private var footer: some View {
        SkillAgentFooterBar {
            if case .edit = target {
                SkillAgentLinkButton(title: OpenTypeL10n.text("删除", english: "Delete"), tint: DS.Colour.error) {
                    confirmingDelete = true
                }
            }
            Text(targetPath)
                .font(DS.Text.mono())
                .foregroundStyle(DS.Colour.ink(0.4))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            SkillAgentButton(title: OpenTypeL10n.text("取消", english: "Cancel")) { onClose() }
            SkillAgentButton(
                title: isSaving ? OpenTypeL10n.text("保存中…", english: "Saving…") : OpenTypeL10n.text("保存", english: "Save"),
                kind: .primary,
                isEnabled: !isSaving && stateBinding.wrappedValue.isSaveEnabled(amongAgents: model.agentDefinitions ?? [], homeDirectory: model.skillAgentHomeDirectory)
            ) {
                save()
            }
        }
    }

    private var targetPath: String {
        let name = stateBinding.wrappedValue.name.isEmpty ? "…" : stateBinding.wrappedValue.name
        return "~/.opentype/agents/\(name).md"
    }

    private var nameErrorText: String? {
        guard let error = stateBinding.wrappedValue.nameError(amongAgents: model.agentDefinitions ?? [], homeDirectory: model.skillAgentHomeDirectory) else {
            return nil
        }
        return skillAgentNameErrorText(error, kind: .agent)
    }

    private func save() {
        guard let current = state else { return }
        isSaving = true
        saveError = nil
        Task { @MainActor in
            let ok = await model.saveAgentDefinition(current)
            isSaving = false
            if ok {
                onSaved()
            } else {
                saveError = model.skillAgentEditError
                model.clearSkillAgentEditError()
            }
        }
    }

    private func delete() {
        guard case .edit(let name, _) = target else { return }
        isSaving = true
        Task { @MainActor in
            let ok = await model.deleteAgentDefinition(name: name)
            isSaving = false
            if ok {
                onSaved()
            } else {
                saveError = model.skillAgentEditError
                model.clearSkillAgentEditError()
            }
        }
    }
}

private extension AgentEditorTarget {
    var headerTitle: String {
        switch self {
        case .create:
            return OpenTypeL10n.text("新建 Agent", english: "New agent")
        case .edit(let name, _):
            return OpenTypeL10n.text("编辑 \(name)", english: "Edit \(name)")
        }
    }
}

// MARK: - Agent read-only viewer

/// A claude-root or builtin agent, read-only. No copy-to-mine button here —
/// that flow is skill-only per the design.
private struct AgentViewerSheet: View {
    @ObservedObject var model: AppModel
    let target: AgentViewerTarget
    let onClose: () -> Void

    @State private var detail: AgentDefinitionDetail?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let detail {
                VStack(spacing: 0) {
                    SkillAgentSheetHeader(title: detail.displayName ?? detail.name, onClose: onClose)
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.content) {
                            HStack(spacing: 8) {
                                Text(detail.name).font(DS.Text.mono(13, weight: .semibold))
                                skillAgentSourceBadge(for: target.bucket)
                            }
                            Text(detail.description)
                                .font(DS.Text.caption())
                                .foregroundStyle(DS.Colour.ink(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                            if let tools = detail.tools, !tools.isEmpty {
                                Text(OpenTypeL10n.text("工具 \(tools)", english: "Tools \(tools)"))
                                    .font(DS.Text.mono())
                                    .foregroundStyle(DS.Colour.ink(0.45))
                            }
                            if let model = detail.model, !model.isEmpty {
                                Text(OpenTypeL10n.text("模型 \(model)", english: "Model \(model)"))
                                    .font(DS.Text.mono())
                                    .foregroundStyle(DS.Colour.ink(0.45))
                            }
                            AssistantMarkdownView(markdown: detail.body, fontSize: 12.5)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                    }
                    .scrollIndicators(.hidden)
                    SkillAgentFooterBar {
                        Spacer()
                        SkillAgentButton(title: OpenTypeL10n.text("关闭", english: "Close")) { onClose() }
                    }
                }
            } else if loadFailed {
                SkillAgentSheetLoadFailure(message: model.skillAgentEditError, onClose: onClose)
            } else {
                SkillAgentSheetLoading()
            }
        }
        .frame(width: 560, height: 560)
        .background(DS.Colour.recessed)
        .task { await load() }
    }

    private func load() async {
        if let fetched = await model.fetchAgentDefinitionDetail(name: target.name, root: target.root) {
            detail = fetched
        } else {
            loadFailed = true
        }
    }
}

// MARK: - Name error copy

/// Copy for each `SkillAgentNameError` case — the only place the validation
/// enum's cases turn into user-facing sentences.
private func skillAgentNameErrorText(_ error: SkillAgentNameError, kind: SkillAgentKind) -> String {
    switch error {
    case .invalidCharset:
        return OpenTypeL10n.text(
            "只能用字母、数字和 - ，且不能以 - 开头",
            english: "Only letters, digits and - are allowed, and it can't start with -"
        )
    case .tooLong:
        return OpenTypeL10n.text("最长 64 个字符", english: "64 characters or fewer")
    case .reserved:
        return OpenTypeL10n.text("readme 是保留名称", english: "\"readme\" is a reserved name")
    case .conflictsWithBuiltin:
        return kind == .skill
            ? OpenTypeL10n.text("与内置 Skill 同名", english: "Same name as a built-in skill")
            : OpenTypeL10n.text("与内置 Agent 同名", english: "Same name as a built-in agent")
    case .duplicateInMine:
        return OpenTypeL10n.text("你已经有一个同名的了", english: "You already have one with this name")
    }
}

// MARK: - Shared small pieces

private struct SkillAgentColumnHeader: View {
    let title: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(DS.Text.groupLabel())
                .tracking(DS.Tracking.groupLabel)
                .foregroundStyle(DS.Colour.ink(0.42))
            Spacer()
            SkillAgentLinkButton(title: actionTitle, action: action)
        }
        .padding(.horizontal, 4)
    }
}

private struct SkillAgentSectionHeader: View {
    let title: String
    let isFirst: Bool
    var trailingCaption: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(DS.Text.groupLabel())
                .tracking(DS.Tracking.groupLabel)
                .foregroundStyle(DS.Colour.ink(0.42))
            Spacer()
            if let trailingCaption {
                Text(trailingCaption)
                    .font(DS.Text.groupLabel())
                    .fontWeight(.regular)
                    .foregroundStyle(DS.Colour.ink(0.35))
            }
        }
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

private struct SkillAgentNoticeCard: View {
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

private struct SkillAgentTag: View {
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

private enum SkillAgentButtonKind {
    case chrome
    case primary
}

private struct SkillAgentButton: View {
    let title: String
    var kind: SkillAgentButtonKind = .chrome
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Text.caption())
                .fontWeight(kind == .primary ? .medium : .regular)
                .foregroundStyle(kind == .primary ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous)
                        .fill(kind == .primary ? DS.Colour.accent : DS.Colour.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous)
                        .strokeBorder(kind == .primary ? Color.clear : DS.Colour.buttonBorder, lineWidth: 0.75)
                )
                .modifier(SkillAgentButtonShadow(kind: kind))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Same lift `McpButtonShadow` gives `McpButton`: a primary button gets the
/// accent-tinted shadow, a chrome one gets the plain control shadow.
private struct SkillAgentButtonShadow: ViewModifier {
    let kind: SkillAgentButtonKind

    func body(content: Content) -> some View {
        switch kind {
        case .primary:
            DS.Shadow.accentControl(content)
        case .chrome:
            DS.Shadow.control(content)
        }
    }
}

private struct SkillAgentLinkButton: View {
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

private struct SkillAgentField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DS.Text.caption())
                .fontWeight(.medium)
            content()
        }
    }
}

private struct SkillAgentTextField: View {
    @Binding var text: String
    var placeholder: String = ""
    var mono: Bool = true

    var body: some View {
        DS.Shadow.field(
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(mono ? DS.Text.mono(12.5) : DS.Text.caption())
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

private struct SkillAgentStaticValue: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Text.mono(12.5))
            .foregroundStyle(DS.Colour.ink(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(DS.Colour.control, in: RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous))
    }
}

private struct SkillAgentValidationText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DS.Text.groupLabel())
            .fontWeight(.regular)
            .lineSpacing(3)
            .foregroundStyle(DS.Colour.warningText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SkillAgentTextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 70
    var mono: Bool = false

    var body: some View {
        TextEditor(text: $text)
            .font(mono ? DS.Text.mono(12.5) : DS.Text.caption())
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(DS.Colour.card, in: RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous)
                    .strokeBorder(DS.Colour.fieldBorder, lineWidth: 0.75)
            )
    }
}

/// The 编写/预览 toggle shared by both editor sheets' markdown fields.
/// Not `McpServerViews.swift`'s `McpSegmentedControl` — that one is `private`
/// to that file and typed over `McpTransport` specifically.
private enum SkillAgentBodyEditMode: Equatable {
    case write
    case preview
}

private struct SkillAgentSegmentedToggle: View {
    @Binding var mode: SkillAgentBodyEditMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.write, title: OpenTypeL10n.text("编写", english: "Write"))
            segment(.preview, title: OpenTypeL10n.text("预览", english: "Preview"))
        }
        .padding(2)
        .frame(height: 28)
        .background(DS.Colour.segmentTrack, in: RoundedRectangle(cornerRadius: DS.Radius.smallControl, style: .continuous))
    }

    private func segment(_ candidate: SkillAgentBodyEditMode, title: String) -> some View {
        Button {
            mode = candidate
        } label: {
            Text(title)
                .font(DS.Text.caption())
                .fontWeight(mode == candidate ? .medium : .regular)
                .foregroundStyle(mode == candidate ? AnyShapeStyle(Color.primary) : AnyShapeStyle(DS.Colour.ink(0.55)))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background {
                    if mode == candidate {
                        DS.Shadow.lifted(
                            RoundedRectangle(cornerRadius: DS.Radius.tag, style: .continuous)
                                .fill(DS.Colour.card)
                        )
                    } else {
                        Color.clear
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Multi-select tool chips (8D), packed by hand for the same reason
/// `McpWrappingTags` is in `McpServerViews.swift`: no `Layout`-free flow
/// container on macOS 13. Chips use the BARE tool name (no `opentype__`
/// prefix) both for display and for `selectedTools`, matching the frontmatter
/// `tools:` line's own format and `AgentEditorFormState`'s contract.
private struct SkillAgentToolChipFlow: View {
    let tools: [McpBuiltInTool]
    @Binding var selected: Set<String>
    let available: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.name) { tool in
                        chip(for: tool)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private static let builtinPrefix = "opentype__"

    private func bareName(_ tool: McpBuiltInTool) -> String {
        tool.name.hasPrefix(Self.builtinPrefix) ? String(tool.name.dropFirst(Self.builtinPrefix.count)) : tool.name
    }

    private func chip(for tool: McpBuiltInTool) -> some View {
        let name = bareName(tool)
        let isSelected = selected.contains(name)
        return Button {
            if isSelected {
                selected.remove(name)
            } else {
                selected.insert(name)
            }
        } label: {
            HStack(spacing: 4) {
                if !isSelected {
                    Text("+").font(DS.Text.mono())
                }
                Text(name).font(DS.Text.mono())
                if tool.hasSideEffects {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.85) : DS.Colour.warningText)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(DS.Colour.ink(0.6)))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? AnyShapeStyle(DS.Colour.accent) : AnyShapeStyle(DS.Colour.codeFill),
                in: RoundedRectangle(cornerRadius: DS.Radius.tag, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    /// Greedy packing on an estimated width, same technique as
    /// `McpWrappingTags` — mono glyphs are a fixed advance, so the estimate is
    /// exact enough for chips.
    private var rows: [[McpBuiltInTool]] {
        var rows: [[McpBuiltInTool]] = []
        var current: [McpBuiltInTool] = []
        var used: CGFloat = 0
        for tool in tools {
            let width = CGFloat(bareName(tool).count) * 6.6 + 32
            if !current.isEmpty && used + width > available {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(tool)
            used += width + 6
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

private struct SkillAgentSheetHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(DS.Text.section())
                .lineLimit(1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 18))
                    .foregroundStyle(DS.Colour.ink(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, DS.Space.content)
        .padding(.bottom, 14)
        .dsHairline(.bottom, color: DS.Colour.border)
    }
}

private struct SkillAgentFooterBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 9) { content() }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(DS.Colour.footerBar)
            .dsHairline(.top, color: DS.Colour.border)
    }
}

private struct SkillAgentSheetLoading: View {
    var body: some View {
        VStack {
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colour.recessed)
    }
}

private struct SkillAgentSheetLoadFailure: View {
    let message: String?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(message ?? OpenTypeL10n.text("读取失败", english: "Failed to load"))
                .font(DS.Text.caption())
                .foregroundStyle(DS.Colour.error)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SkillAgentButton(title: OpenTypeL10n.text("关闭", english: "Close")) { onClose() }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colour.recessed)
    }
}
