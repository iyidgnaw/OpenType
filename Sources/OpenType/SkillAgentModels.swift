import Foundation

/// Pure-logic surface behind the Settings "Skill 与 Agent" page (design §3,
/// `docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md`):
/// DTOs mirroring the sidecar's `/skills*`/`/agent/definitions*` wire shapes
/// (`sidecar/src/skills/skillRoutes.ts`, `sidecar/src/agent/agentDefinitionRoutes.ts`),
/// source bucketing (decision A-2), list-section derivation, name validation
/// mirroring the sidecar's own rules, and the two editor form states.
///
/// Deliberately no `import SwiftUI` — everything here is testable without a
/// view hierarchy (`SkillAgentModelsTests.swift`), and `SkillAgentViews.swift`
/// is the only consumer that needs a rendering layer on top of it.

// MARK: - 1. DTOs

/// `GET /skills`'s per-row shape.
///
/// `active`/`shadowedBy` come from the discovery layer's `listAll()`
/// (design §1.1): `active` is the first-root-wins winner for this name,
/// `shadowedBy` names the root that beat it (absent for the winner itself).
/// `editable` is `root == userRoot`, independent of `active` — a shadowed
/// user copy stays editable (design §1.2's 8A "被覆盖的「我的」条目也要能点开看").
struct SkillSummary: Decodable, Equatable {
    let name: String
    let description: String
    let root: String
    let path: String
    let editable: Bool
    let active: Bool
    let shadowedBy: String?
}

extension SkillSummary: Identifiable {
    /// `name` alone isn't unique across a shadowed pair sharing one name in
    /// different roots — the root is part of the identity.
    var id: String { "\(root)/\(name)" }
}

/// `GET /skills`'s envelope — `{ skills: [...] }`, not a bare array (unlike
/// the agent-definitions list endpoint below; that asymmetry is upstream and
/// deliberate, not a typo here).
struct SkillListEnvelope: Decodable, Equatable {
    let skills: [SkillSummary]
}

/// `GET /skills/:name`, and the response body of `POST`/`PUT /skills(/:name)`.
/// Carries the full markdown `body`, unlike `SkillSummary`. No `active`/
/// `shadowedBy` — a single fetched-by-name-and-root record has no notion of
/// "shadowed by what", only the list does.
struct SkillDetail: Decodable, Equatable {
    let name: String
    let description: String
    let body: String
    let path: String
    let root: String
    let editable: Bool
}

/// `GET /agent/definitions`'s per-row shape — a **bare array**, not wrapped in
/// an envelope (unlike `SkillListEnvelope` above). Rows never carry `editable`
/// at all (only the single-item detail does), which is why `AgentListRow`
/// below has to derive `isReadOnly` from the root bucket instead of an
/// API-supplied flag. No `body` property is declared at all — the list
/// contract never sends one (design §1.3: "列表继续不含 body"), and a stray
/// `body` key in the wire JSON (which should never happen) is simply ignored
/// by `Decodable` rather than causing a decode failure.
struct AgentDefinitionSummary: Decodable, Equatable {
    let name: String
    let description: String
    let displayName: String?
    /// Still the raw comma-separated string (e.g. `"bash, read_file"`), never
    /// pre-split into an array — matches the existing `GET /agent/definitions`
    /// wire convention.
    let tools: String?
    let model: String?
    let root: String
    let path: String
    let active: Bool
    let shadowedBy: String?
}

extension AgentDefinitionSummary: Identifiable {
    var id: String { "\(root)/\(name)" }
}

/// `GET /agent/definitions/:name`, and the response body of
/// `POST`/`PUT /agent/definitions(/:name)`. Carries the full `body` and an
/// `editable` flag, unlike the list row.
struct AgentDefinitionDetail: Decodable, Equatable {
    let name: String
    let displayName: String?
    let description: String
    let body: String
    let path: String
    let root: String
    let tools: String?
    /// Read-only display value (B2): a file's existing `model:` frontmatter
    /// line, parsed but never editable and never sent back on a save.
    let model: String?
    let editable: Bool
}

// MARK: - 2. Source bucketing (decision A-2)

/// Which of the three discovery roots a skill/agent lives under, as far as
/// this page's grouping (8A: 内置 / 我的 / Claude Code) is concerned.
enum SkillAgentSourceBucket: String, Equatable {
    case builtin
    case user
    case claude
}

/// Namespace for `bucket(forRoot:homeDirectory:)` — kept separate from
/// `SkillAgentSourceBucket` itself so the enum stays a plain value type.
enum SkillAgentSource {
    /// Buckets a discovery root by path *prefix* alone (never `FileManager`/
    /// `realpath`, and never touches the real filesystem): `~/.opentype`
    /// (inclusive, `/`-boundary) → `.user`; `~/.claude` (same boundary) →
    /// `.claude`; anything else → `.builtin`, including a packaged app's
    /// bundled Resources root and a dev-checkout root under the sidecar
    /// source tree, both of which are "outside home's dotfiles" but not
    /// necessarily outside home itself.
    ///
    /// The `/`-boundary check is load-bearing: a naive `hasPrefix` would
    /// wrongly bucket `~/.opentypeExtra`/`~/.claudeBackup` as user/claude.
    static func bucket(forRoot root: String, homeDirectory: String) -> SkillAgentSourceBucket {
        let userPrefix = homeDirectory + "/.opentype"
        if root == userPrefix || root.hasPrefix(userPrefix + "/") {
            return .user
        }
        let claudePrefix = homeDirectory + "/.claude"
        if root == claudePrefix || root.hasPrefix(claudePrefix + "/") {
            return .claude
        }
        return .builtin
    }
}

// MARK: - 3. List section derivation

/// One row of the SKILL column (8A), with the view-facing booleans already
/// derived so `SkillAgentViews.swift` never has to re-derive them.
struct SkillListRow: Identifiable, Equatable {
    let skill: SkillSummary
    let bucket: SkillAgentSourceBucket
    /// Straight off the wire's own `editable` flag — the skills list contract
    /// carries one per row, unlike the agent list (see `AgentListRow`).
    let isReadOnly: Bool
    /// The orange "被内置同名覆盖" badge. Only ever true for a user-root,
    /// inactive row — an inactive builtin/claude row isn't a concept this
    /// design has, since the user root is always tried first.
    let showsShadowedBadge: Bool

    var id: String { skill.id }
}

/// One non-empty group in the SKILL column: 内置 / 我的 / Claude Code.
struct SkillListSection: Identifiable, Equatable {
    let bucket: SkillAgentSourceBucket
    let rows: [SkillListRow]

    var count: Int { rows.count }
    var id: String { bucket.rawValue }
}

enum SkillListBuilder {
    /// Groups `skills` into ordered, non-empty sections: 内置 → 我的 → Claude
    /// Code (design §3's 8A mock only shows non-empty groups — an empty
    /// bucket contributes no section at all, not a "内置 · 0" header).
    static func sections(for skills: [SkillSummary], homeDirectory: String) -> [SkillListSection] {
        var byBucket: [SkillAgentSourceBucket: [SkillListRow]] = [:]
        for skill in skills {
            let bucket = SkillAgentSource.bucket(forRoot: skill.root, homeDirectory: homeDirectory)
            let row = SkillListRow(
                skill: skill,
                bucket: bucket,
                isReadOnly: !skill.editable,
                showsShadowedBadge: bucket == .user && !skill.active
            )
            byBucket[bucket, default: []].append(row)
        }
        let order: [SkillAgentSourceBucket] = [.builtin, .user, .claude]
        return order.compactMap { bucket in
            guard let rows = byBucket[bucket], !rows.isEmpty else { return nil }
            return SkillListSection(bucket: bucket, rows: rows)
        }
    }
}

/// One row of the AGENT column (8A). Unlike `SkillListRow`, `isReadOnly` here
/// is derived from the root bucket rather than an API flag — the agent list
/// contract has no `editable` field at all (see `AgentDefinitionSummary`).
struct AgentListRow: Identifiable, Equatable {
    let agent: AgentDefinitionSummary
    let bucket: SkillAgentSourceBucket
    let isReadOnly: Bool
    let showsShadowedBadge: Bool

    var id: String { agent.id }
}

struct AgentListSection: Identifiable, Equatable {
    let bucket: SkillAgentSourceBucket
    let rows: [AgentListRow]

    var count: Int { rows.count }
    var id: String { bucket.rawValue }
}

enum AgentListBuilder {
    static func sections(for agents: [AgentDefinitionSummary], homeDirectory: String) -> [AgentListSection] {
        var byBucket: [SkillAgentSourceBucket: [AgentListRow]] = [:]
        for agent in agents {
            let bucket = SkillAgentSource.bucket(forRoot: agent.root, homeDirectory: homeDirectory)
            let row = AgentListRow(
                agent: agent,
                bucket: bucket,
                isReadOnly: bucket != .user,
                showsShadowedBadge: bucket == .user && !agent.active
            )
            byBucket[bucket, default: []].append(row)
        }
        let order: [SkillAgentSourceBucket] = [.builtin, .user, .claude]
        return order.compactMap { bucket in
            guard let rows = byBucket[bucket], !rows.isEmpty else { return nil }
            return AgentListSection(bucket: bucket, rows: rows)
        }
    }
}

// MARK: - 4. Name validation mirror

/// Which kind of resource a name is being validated for — the only rule that
/// differs between the two is the `readme` reservation (agents only).
enum SkillAgentKind: Equatable {
    case skill
    case agent
}

/// A typed, render-specific reason a name (or a save) is rejected. Distinct
/// cases exist so the UI can show copy specific to the reason rather than one
/// generic "invalid" message.
enum SkillAgentNameError: Equatable {
    case invalidCharset
    case tooLong
    /// `readme` (case-insensitive), agents only.
    case reserved
    /// Same name as a **builtin** entry — blocks unconditionally, regardless
    /// of what else shares the name.
    case conflictsWithBuiltin
    /// Same name already exists in **the user's own root** ("mine") — a
    /// friendlier "already yours" reading than a generic conflict.
    case duplicateInMine
}

/// Mirrors the sidecar's own name validation
/// (`NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]*$/`, `MAX_NAME_LENGTH = 64`) so
/// the editor can show the same rejection before a round trip ever happens.
enum SkillAgentNameValidator {
    private static let namePattern = "^[A-Za-z0-9][A-Za-z0-9-]*$"
    private static let maxNameLength = 64

    /// Charset/emptiness is checked BEFORE length, so a 65-character name made
    /// entirely of valid characters reports `.tooLong` specifically rather
    /// than the generic `.invalidCharset`.
    static func charsetAndLengthError(for name: String) -> SkillAgentNameError? {
        guard name.range(of: namePattern, options: .regularExpression) != nil else {
            return .invalidCharset
        }
        if name.count > maxNameLength {
            return .tooLong
        }
        return nil
    }

    /// `readme` (case-insensitive) is reserved for AGENTS only — a skill's
    /// file is always `SKILL.md` regardless of the skill's own name, while an
    /// agent definition's filename IS `<name>.md`, and the discovery layer
    /// silently skips any `README.md`.
    static func nameError(for name: String, kind: SkillAgentKind) -> SkillAgentNameError? {
        if kind == .agent, name.lowercased() == "readme" {
            return .reserved
        }
        return charsetAndLengthError(for: name)
    }
}

enum SkillAgentNameConflictChecker {
    /// Low-level pure-tuple form: `builtin` collision outranks a `user`
    /// ("mine") duplicate when both exist under the same name — matching the
    /// sidecar's own 409 priority. A same-name `claude`-root entry is
    /// deliberately NOT a conflict at all (E3: the Claude-Code-compat root
    /// never blocks a create, since a user copy already wins that collision
    /// by root ordering). Exact-match, case-sensitive comparison throughout.
    static func conflict(
        forName name: String,
        buckets: [(name: String, bucket: SkillAgentSourceBucket)]
    ) -> SkillAgentNameError? {
        if buckets.contains(where: { $0.name == name && $0.bucket == .builtin }) {
            return .conflictsWithBuiltin
        }
        if buckets.contains(where: { $0.name == name && $0.bucket == .user }) {
            return .duplicateInMine
        }
        return nil
    }

    /// Convenience overload composing bucketing + conflict checking over an
    /// actual fetched `[SkillSummary]` — the shape a caller holding a
    /// freshly-fetched list actually has.
    static func conflict(
        forName name: String,
        amongSkills skills: [SkillSummary],
        homeDirectory: String
    ) -> SkillAgentNameError? {
        conflict(
            forName: name,
            buckets: skills.map { (name: $0.name, bucket: SkillAgentSource.bucket(forRoot: $0.root, homeDirectory: homeDirectory)) }
        )
    }

    /// Same, for a fetched `[AgentDefinitionSummary]`.
    static func conflict(
        forName name: String,
        amongAgents agents: [AgentDefinitionSummary],
        homeDirectory: String
    ) -> SkillAgentNameError? {
        conflict(
            forName: name,
            buckets: agents.map { (name: $0.name, bucket: SkillAgentSource.bucket(forRoot: $0.root, homeDirectory: homeDirectory)) }
        )
    }
}

/// The end-to-end "is this name usable for a new skill/agent" check a create
/// form actually calls: charset/length/reserved first, then conflict.
enum SkillAgentNameValidation {
    static func validateForCreateSkill(
        name: String,
        amongSkills skills: [SkillSummary],
        homeDirectory: String
    ) -> SkillAgentNameError? {
        if let error = SkillAgentNameValidator.nameError(for: name, kind: .skill) {
            return error
        }
        return SkillAgentNameConflictChecker.conflict(forName: name, amongSkills: skills, homeDirectory: homeDirectory)
    }

    static func validateForCreateAgent(
        name: String,
        amongAgents agents: [AgentDefinitionSummary],
        homeDirectory: String
    ) -> SkillAgentNameError? {
        if let error = SkillAgentNameValidator.nameError(for: name, kind: .agent) {
            return error
        }
        return SkillAgentNameConflictChecker.conflict(forName: name, amongAgents: agents, homeDirectory: homeDirectory)
    }
}

// MARK: - 5. Editor form state

/// Shared create/edit mode for both editor form states — E1: the name is
/// editable only in create mode, never in edit (avoids rename semantics).
enum SkillAgentEditorMode: Equatable {
    case create
    case edit
}

/// The `POST /skills` / `PUT /skills/:name` request body. `name` is included
/// only for a create (`PUT` addresses the resource by URL, and the name is
/// immutable anyway per E1) — encoded via the synthesized `encodeIfPresent`,
/// so `nil` simply omits the key.
struct SkillEditorSavePayload: Encodable, Equatable {
    var name: String?
    var description: String
    var body: String
}

/// 8B's form state: name/description/body plus the create-vs-edit mode that
/// decides whether the name field is even enabled.
struct SkillEditorFormState: Equatable {
    var mode: SkillAgentEditorMode
    var name: String
    var description: String
    var body: String

    /// E1: only a create can set the name at all.
    var isNameEditable: Bool { mode == .create }

    static func blankForCreate() -> SkillEditorFormState {
        SkillEditorFormState(mode: .create, name: "", description: "", body: "")
    }

    static func loadForEdit(from detail: SkillDetail) -> SkillEditorFormState {
        SkillEditorFormState(mode: .edit, name: detail.name, description: detail.description, body: detail.body)
    }

    /// E2: "复制到我的 Skill 再改" prefills name/description/body from a
    /// builtin's detail, but the resulting form is a CREATE, not an edit of
    /// the builtin file — saving under the same name is caught by the normal
    /// create-mode `conflictsWithBuiltin` validation, forcing a rename.
    static func copyToMine(from detail: SkillDetail) -> SkillEditorFormState {
        SkillEditorFormState(mode: .create, name: detail.name, description: detail.description, body: detail.body)
    }

    /// `nil` in edit mode — the (immutable) name is never re-validated there.
    func nameError(amongSkills skills: [SkillSummary], homeDirectory: String) -> SkillAgentNameError? {
        guard mode == .create else { return nil }
        return SkillAgentNameValidation.validateForCreateSkill(name: name, amongSkills: skills, homeDirectory: homeDirectory)
    }

    /// In edit mode only description/body emptiness gates Save; in create
    /// mode the name must additionally be non-empty and pass validation.
    func isSaveEnabled(amongSkills skills: [SkillSummary], homeDirectory: String) -> Bool {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty, !trimmedBody.isEmpty else { return false }
        guard mode == .create else { return true }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        return nameError(amongSkills: skills, homeDirectory: homeDirectory) == nil
    }

    /// The body `SkillAgentViews.swift` actually sends: a create carries the
    /// typed name, an edit omits it (the URL already addresses the resource).
    var savePayload: SkillEditorSavePayload {
        SkillEditorSavePayload(
            name: mode == .create ? name : nil,
            description: description,
            body: body
        )
    }
}

/// The `POST /agent/definitions` / `PUT /agent/definitions/:name` request
/// body. Deliberately has NO `model` property at all (B2) — the save payload
/// must be structurally incapable of carrying a model value, even when the
/// loaded form is displaying one read-only.
struct AgentEditorSavePayload: Encodable, Equatable {
    var name: String?
    var displayName: String?
    var description: String
    var body: String
    var tools: [String]?
}

/// 8D's form state.
struct AgentEditorFormState: Equatable {
    var mode: SkillAgentEditorMode
    var name: String
    var displayName: String
    var description: String
    var body: String
    var selectedTools: Set<String>
    /// The file's existing `model:` value, when loaded from a detail that had
    /// one — read-only display only (B2), never sent back on save.
    var existingModel: String?

    var isNameEditable: Bool { mode == .create }

    /// Empty selection means "inherit everything" — serializes to `nil` (no
    /// `tools` key at all), matching the omitted-tools-line contract.
    var toolsPayload: [String]? {
        selectedTools.isEmpty ? nil : Array(selectedTools).sorted()
    }

    static func blankForCreate() -> AgentEditorFormState {
        AgentEditorFormState(
            mode: .create, name: "", displayName: "", description: "", body: "",
            selectedTools: [], existingModel: nil
        )
    }

    static func loadForEdit(from detail: AgentDefinitionDetail) -> AgentEditorFormState {
        AgentEditorFormState(
            mode: .edit,
            name: detail.name,
            displayName: detail.displayName ?? "",
            description: detail.description,
            body: detail.body,
            selectedTools: Self.parseTools(detail.tools),
            existingModel: detail.model
        )
    }

    /// Copy-to-mine creates a brand-new file — there is no existing model
    /// line yet, regardless of what the source builtin's detail carried.
    static func copyToMine(from detail: AgentDefinitionDetail) -> AgentEditorFormState {
        AgentEditorFormState(
            mode: .create,
            name: detail.name,
            displayName: detail.displayName ?? "",
            description: detail.description,
            body: detail.body,
            selectedTools: Self.parseTools(detail.tools),
            existingModel: nil
        )
    }

    private static func parseTools(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    /// `nil` in edit mode — the (immutable) name is never re-validated there.
    func nameError(amongAgents agents: [AgentDefinitionSummary], homeDirectory: String) -> SkillAgentNameError? {
        guard mode == .create else { return nil }
        return SkillAgentNameValidation.validateForCreateAgent(name: name, amongAgents: agents, homeDirectory: homeDirectory)
    }

    /// Description and body are required; `displayName` is always optional.
    func isSaveEnabled(amongAgents agents: [AgentDefinitionSummary], homeDirectory: String) -> Bool {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty, !trimmedBody.isEmpty else { return false }
        guard mode == .create else { return true }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        return nameError(amongAgents: agents, homeDirectory: homeDirectory) == nil
    }

    /// The body `SkillAgentViews.swift` actually sends. `existingModel` never
    /// participates — `AgentEditorSavePayload` has no field for it to go in.
    ///
    /// Create and edit collapse an empty `displayName`/`selectedTools`
    /// differently, and the difference is load-bearing (decision C-1). A
    /// create has no existing file to compare against, so omitting the key
    /// (`nil`) and sending it empty mean the same thing — "no such line" —
    /// and `nil` is the natural choice. An edit's `PUT` instead treats an
    /// OMITTED key as "leave the existing value alone" and only clears a
    /// field when the key is PRESENT with an empty value (see
    /// `agentDefinitionRoutes.ts`'s `PUT` handler): so clearing `displayName`
    /// or deselecting every tool on an EXISTING agent must send `""`/`[]`
    /// (present, non-nil) — collapsing to `nil` there would silently leave
    /// the stale value in place rather than clearing it.
    var savePayload: AgentEditorSavePayload {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .create:
            return AgentEditorSavePayload(
                name: name,
                displayName: trimmedDisplayName.isEmpty ? nil : trimmedDisplayName,
                description: description,
                body: body,
                tools: toolsPayload
            )
        case .edit:
            return AgentEditorSavePayload(
                name: nil,
                displayName: trimmedDisplayName,
                description: description,
                body: body,
                tools: Array(selectedTools).sorted()
            )
        }
    }
}
