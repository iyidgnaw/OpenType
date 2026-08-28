import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for Pipeline C
/// (`docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md`
/// §3): the pure-logic Swift surface behind the new Settings "Skill 与 Agent"
/// page (design §3, screens 8A–8D). Nothing under test exists yet — this
/// whole file fails to COMPILE until Stage 3 creates
/// `Sources/OpenType/SkillAgentModels.swift`. That is the intended red class,
/// same as `AppTabTests`/`McpBuiltInCatalogTests` in this same batch: missing
/// symbols, not a syntax error in this file.
///
/// The JSON fixtures below are copied byte-faithful (field names, casing,
/// optional-vs-absent) from the two ALREADY-REVIEWED sidecar contract tests
/// that pin the HTTP wire shape this page talks to:
/// `sidecar/test/skills/skillRoutes.test.ts` and
/// `sidecar/test/agent/agentDefinitionRoutes.test.ts`. In particular:
/// `GET /skills` returns `{ skills: [...] }` with each row carrying
/// `editable`; `GET /agent/definitions` returns a BARE ARRAY whose rows never
/// carry `editable` at all (only the single-item `GET /agent/definitions/:name`
/// detail does) — that asymmetry is deliberate upstream, not a typo here, and
/// it is why `AgentListRow.isReadOnly` below has to be derived from the root
/// bucket instead of an API-supplied flag, while `SkillListRow.isReadOnly`
/// just reads `skill.editable` straight off the wire.
///
/// CONTRACT DECISIONS this stage is making on Stage 3's behalf (flagged, not
/// silently guessed — see the final report for the full list):
///
/// - New file `Sources/OpenType/SkillAgentModels.swift`, pure logic only (no
///   SwiftUI import), consumed later by `SkillAgentViews.swift`.
/// - Source bucketing (decision A-2) takes `homeDirectory` as an explicit
///   parameter rather than reading `NSHomeDirectory()`, so it is testable
///   with fabricated paths and never touches the real filesystem.
/// - `SkillAgentSourceBucket`/`SkillAgentSource.bucket(forRoot:homeDirectory:)`
///   only ever look at path *prefixes*: `~/.opentype` (with a `/` boundary, so
///   `~/.opentypeExtra` does NOT collide) → `.user`; `~/.claude` (same
///   boundary) → `.claude`; anything else → `.builtin`. This is a pure string
///   operation, never `FileManager`/`realpath`.
/// - The name-conflict checker (item 4) is exposed at two layers: a low-level
///   pure-tuple form, `SkillAgentNameConflictChecker.conflict(forName:buckets:)`,
///   and two convenience overloads that take the actual fetched list
///   (`amongSkills:`/`amongAgents:`) plus `homeDirectory` directly, since
///   that is the shape a caller holding a freshly-fetched
///   `[SkillSummary]`/`[AgentDefinitionSummary]` actually has. Conflict
///   priority is builtin-collision over mine-duplicate (matching the backend's
///   409 priority: builtin blocks unconditionally, "mine" gets a friendlier
///   "already yours" reading), and a same-name CLAUDE-root entry is
///   deliberately NOT a conflict at all (E3).
/// - Name-charset validation checks charset/emptiness first, THEN length —
///   so a 65-char name made entirely of valid characters reports `.tooLong`
///   specifically, not the generic `.invalidCharset`, matching item 4's ask
///   for a reason specific enough to render distinct copy.
/// - `readme` (case-insensitive) is reserved for AGENTS ONLY — skills have no
///   such rule, since a skill's file is always `SKILL.md` regardless of the
///   skill's own name, while an agent definition's filename IS `<name>.md`.
/// - Editor "copy to mine" (E2) never carries over an existing `model` value
///   into the new create-mode form (`existingModel == nil`): there is no file
///   yet to have "an existing model line" — flagged as an inference, not
///   something design §3/§0 states explicitly either way.
/// - List-section derivation omits empty buckets entirely (design §3's 8A
///   mock shows only non-empty groups with counts) rather than rendering a
///   "内置 · 0" header.
final class SkillAgentModelsTests: XCTestCase {

    // MARK: - 1. DTO decoding

    func testSkillSummaryListEnvelopeDecodesActiveRowWithNoShadowedBy() throws {
        let json = """
        {
          "skills": [
            {
              "name": "dictate",
              "description": "builtin desc",
              "root": "/tmp/opentype-skillroutes-builtin",
              "path": "/tmp/opentype-skillroutes-builtin/dictate/SKILL.md",
              "editable": false,
              "active": true
            }
          ]
        }
        """
        let envelope = try JSONDecoder().decode(SkillListEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.skills.count, 1)
        let row = envelope.skills[0]
        XCTAssertEqual(row.name, "dictate")
        XCTAssertEqual(row.description, "builtin desc")
        XCTAssertEqual(row.root, "/tmp/opentype-skillroutes-builtin")
        XCTAssertEqual(row.path, "/tmp/opentype-skillroutes-builtin/dictate/SKILL.md")
        XCTAssertFalse(row.editable)
        XCTAssertTrue(row.active)
        XCTAssertNil(row.shadowedBy)
    }

    func testSkillSummaryDecodesShadowedRowWithShadowedByPresent() throws {
        let json = """
        {
          "skills": [
            {
              "name": "dictate",
              "description": "user desc",
              "root": "/Users/tester/.opentype/skills",
              "path": "/Users/tester/.opentype/skills/dictate/SKILL.md",
              "editable": true,
              "active": false,
              "shadowedBy": "/Applications/OpenType.app/Contents/Resources/skills"
            }
          ]
        }
        """
        let envelope = try JSONDecoder().decode(SkillListEnvelope.self, from: Data(json.utf8))
        let row = envelope.skills[0]
        XCTAssertTrue(row.editable)
        XCTAssertFalse(row.active)
        XCTAssertEqual(row.shadowedBy, "/Applications/OpenType.app/Contents/Resources/skills")
    }

    func testSkillDetailDecodesWithBody() throws {
        let json = """
        {
          "name": "dictate",
          "description": "builtin desc",
          "body": "BUILTIN BODY",
          "path": "/tmp/builtin/dictate/SKILL.md",
          "root": "/tmp/builtin",
          "editable": false
        }
        """
        let detail = try JSONDecoder().decode(SkillDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.name, "dictate")
        XCTAssertEqual(detail.body, "BUILTIN BODY")
        XCTAssertEqual(detail.root, "/tmp/builtin")
        XCTAssertFalse(detail.editable)
    }

    func testAgentDefinitionSummaryListIsABareArrayWithOptionalFieldsAbsent() throws {
        let json = """
        [
          {
            "name": "helper",
            "description": "builtin helper",
            "root": "/tmp/builtin",
            "path": "/tmp/builtin/helper.md",
            "active": true
          }
        ]
        """
        let rows = try JSONDecoder().decode([AgentDefinitionSummary].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.name, "helper")
        XCTAssertEqual(row.description, "builtin helper")
        XCTAssertNil(row.displayName)
        XCTAssertNil(row.model)
        XCTAssertNil(row.tools)
        XCTAssertNil(row.shadowedBy)
        XCTAssertTrue(row.active)
    }

    func testAgentDefinitionSummaryDecodesWithAllOptionalFieldsPresentAndToolsAsRawString() throws {
        let json = """
        [
          {
            "name": "writer",
            "description": "Writes emails",
            "displayName": "写作助手",
            "tools": "bash, read_file",
            "model": "opus",
            "root": "/Users/tester/.opentype/agents",
            "path": "/Users/tester/.opentype/agents/writer.md",
            "active": false,
            "shadowedBy": "/tmp/builtin"
          }
        ]
        """
        let rows = try JSONDecoder().decode([AgentDefinitionSummary].self, from: Data(json.utf8))
        let row = rows[0]
        XCTAssertEqual(row.displayName, "写作助手")
        // Still the raw comma-separated string, NOT pre-split into an array —
        // matches the existing GET /agent/definitions convention pinned by
        // agentDefinitionRoutes.test.ts.
        XCTAssertEqual(row.tools, "bash, read_file")
        XCTAssertEqual(row.model, "opus")
        XCTAssertFalse(row.active)
        XCTAssertEqual(row.shadowedBy, "/tmp/builtin")
    }

    /// The list endpoint's own contract test asserts every row's `body` key
    /// is `undefined`; `AgentDefinitionSummary` mirrors that by not declaring
    /// a `body` property at all, so a `body` key present in the wire JSON
    /// (which should never happen, but decoding must not choke if it does)
    /// is simply ignored by `Decodable`.
    func testAgentDefinitionSummaryIgnoresAnUnexpectedBodyKey() throws {
        let json = """
        [
          {
            "name": "helper",
            "description": "d",
            "root": "/tmp/builtin",
            "path": "/tmp/builtin/helper.md",
            "active": true,
            "body": "this should never be sent, but must not break decoding"
          }
        ]
        """
        let rows = try JSONDecoder().decode([AgentDefinitionSummary].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].name, "helper")
    }

    func testAgentDefinitionDetailDecodesWithOptionalFieldsAbsent() throws {
        let json = """
        {
          "name": "helper",
          "description": "d",
          "body": "BUILTIN BODY",
          "path": "/tmp/builtin/helper.md",
          "root": "/tmp/builtin",
          "editable": false
        }
        """
        let detail = try JSONDecoder().decode(AgentDefinitionDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.name, "helper")
        XCTAssertEqual(detail.body, "BUILTIN BODY")
        XCTAssertFalse(detail.editable)
        XCTAssertNil(detail.displayName)
        XCTAssertNil(detail.tools)
        XCTAssertNil(detail.model)
    }

    /// Pins the round-trip PUT case from `agentDefinitionRoutes.test.ts`
    /// ("preserves an unmanaged frontmatter key"): an existing `model` value
    /// must decode and be readable, purely for read-only display (B2).
    func testAgentDefinitionDetailDecodesWithModelDisplayNameAndToolsPresent() throws {
        let json = """
        {
          "name": "mine",
          "displayName": "我的助手",
          "description": "new desc",
          "body": "new body",
          "path": "/Users/tester/.opentype/agents/mine.md",
          "root": "/Users/tester/.opentype/agents",
          "tools": "bash",
          "model": "opus",
          "editable": true
        }
        """
        let detail = try JSONDecoder().decode(AgentDefinitionDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.displayName, "我的助手")
        XCTAssertEqual(detail.tools, "bash")
        XCTAssertEqual(detail.model, "opus")
        XCTAssertTrue(detail.editable)
    }

    // MARK: - 2. Source bucketing (decision A-2)

    func testBucketForOpenTypeUserRootIsUser() {
        let bucket = SkillAgentSource.bucket(
            forRoot: "/Users/tester/.opentype/skills",
            homeDirectory: "/Users/tester"
        )
        XCTAssertEqual(bucket, .user)
    }

    func testBucketForClaudeRootIsClaude() {
        let bucket = SkillAgentSource.bucket(
            forRoot: "/Users/tester/.claude/agents",
            homeDirectory: "/Users/tester"
        )
        XCTAssertEqual(bucket, .claude)
    }

    /// A packaged app's bundled resources root, and a dev-checkout root under
    /// the sidecar source tree — neither is under the user's home `.opentype`
    /// or `.claude`, so both fall to builtin by elimination, exactly as A-2
    /// specifies ("其余 → 内置"). The dev-checkout example additionally proves
    /// this isn't just "outside home" — it IS still under the home directory
    /// tree, just not under either recognized dotfile root.
    func testBucketForBundleAndDevCheckoutPathsIsBuiltin() {
        XCTAssertEqual(
            SkillAgentSource.bucket(
                forRoot: "/Applications/OpenType.app/Contents/Resources/skills",
                homeDirectory: "/Users/tester"
            ),
            .builtin
        )
        XCTAssertEqual(
            SkillAgentSource.bucket(
                forRoot: "/Users/tester/hackathon/OpenType/sidecar/skills",
                homeDirectory: "/Users/tester"
            ),
            .builtin
        )
    }

    /// Boundary case: a root that merely starts with the same characters as
    /// `~/.opentype`/`~/.claude` but is actually a different directory must
    /// NOT be misclassified as user/claude. A naive `hasPrefix` without a `/`
    /// boundary check would wrongly bucket `.opentypeExtra`/`.claudeBackup` as
    /// user/claude.
    func testPrefixCollisionDoesNotFalsePositive() {
        XCTAssertEqual(
            SkillAgentSource.bucket(forRoot: "/Users/tester/.opentypeExtra/skills", homeDirectory: "/Users/tester"),
            .builtin
        )
        XCTAssertEqual(
            SkillAgentSource.bucket(forRoot: "/Users/tester/.claudeBackup/agents", homeDirectory: "/Users/tester"),
            .builtin
        )
    }

    /// The root pointing exactly at `~/.opentype` (or `~/.claude`) itself,
    /// with no further path component, is still that bucket — an inclusive
    /// boundary, not just its subdirectories.
    func testExactHomeDotDirectoryRootIsAlsoBucketed() {
        XCTAssertEqual(
            SkillAgentSource.bucket(forRoot: "/Users/tester/.opentype", homeDirectory: "/Users/tester"),
            .user
        )
        XCTAssertEqual(
            SkillAgentSource.bucket(forRoot: "/Users/tester/.claude", homeDirectory: "/Users/tester"),
            .claude
        )
    }

    /// Two different users' home directories must not cross-classify — this
    /// is what makes `homeDirectory` a required parameter rather than a
    /// hardcoded constant.
    func testBucketingIsRelativeToTheInjectedHomeDirectoryOnly() {
        XCTAssertEqual(
            SkillAgentSource.bucket(forRoot: "/Users/alice/.opentype/skills", homeDirectory: "/Users/bob"),
            .builtin
        )
        XCTAssertEqual(
            SkillAgentSource.bucket(forRoot: "/Users/alice/.opentype/skills", homeDirectory: "/Users/alice"),
            .user
        )
    }

    // MARK: - 3. List section derivation

    private func makeSkill(
        name: String,
        root: String,
        editable: Bool,
        active: Bool,
        shadowedBy: String? = nil
    ) -> SkillSummary {
        let json = """
        {
          "name": "\(name)",
          "description": "d",
          "root": "\(root)",
          "path": "\(root)/\(name)/SKILL.md",
          "editable": \(editable),
          "active": \(active)\(shadowedBy.map { ",\n  \"shadowedBy\": \"\($0)\"" } ?? "")
        }
        """
        return try! JSONDecoder().decode(SkillSummary.self, from: Data(json.utf8))
    }

    private func makeAgent(
        name: String,
        root: String,
        active: Bool,
        shadowedBy: String? = nil
    ) -> AgentDefinitionSummary {
        let json = """
        {
          "name": "\(name)",
          "description": "d",
          "root": "\(root)",
          "path": "\(root)/\(name).md",
          "active": \(active)\(shadowedBy.map { ",\n  \"shadowedBy\": \"\($0)\"" } ?? "")
        }
        """
        return try! JSONDecoder().decode(AgentDefinitionSummary.self, from: Data(json.utf8))
    }

    private let home = "/Users/tester"
    private let builtinRoot = "/Applications/OpenType.app/Contents/Resources/skills"
    private let builtinAgentRoot = "/Applications/OpenType.app/Contents/Resources/agents"
    private var userSkillRoot: String { "\(home)/.opentype/skills" }
    private var userAgentRoot: String { "\(home)/.opentype/agents" }
    private var claudeSkillRoot: String { "\(home)/.claude/skills" }
    private var claudeAgentRoot: String { "\(home)/.claude/agents" }

    func testSkillSectionsAreOrderedBuiltinThenUserThenClaudeWithCounts() {
        let skills = [
            makeSkill(name: "b1", root: builtinRoot, editable: false, active: true),
            makeSkill(name: "b2", root: builtinRoot, editable: false, active: true),
            makeSkill(name: "u1", root: userSkillRoot, editable: true, active: true),
            makeSkill(name: "c1", root: claudeSkillRoot, editable: false, active: true),
        ]

        let sections = SkillListBuilder.sections(for: skills, homeDirectory: home)

        XCTAssertEqual(sections.map(\.bucket), [.builtin, .user, .claude])
        XCTAssertEqual(sections.map(\.count), [2, 1, 1])
    }

    /// Design §3's 8A mock only shows non-empty groups — an empty bucket
    /// contributes no section at all, not a "· 0" header.
    func testEmptySkillSectionsAreOmitted() {
        let skills = [makeSkill(name: "u1", root: userSkillRoot, editable: true, active: true)]

        let sections = SkillListBuilder.sections(for: skills, homeDirectory: home)

        XCTAssertEqual(sections.map(\.bucket), [.user])
    }

    /// A user-root skill that is shadowed by a same-named builtin: greyed
    /// name (view concern, not tested here) + the orange "被内置同名覆盖"
    /// badge — `showsShadowedBadge` is the pure boolean that badge is gated
    /// on. The badge only ever appears for a USER-root, INACTIVE row: an
    /// inactive builtin/claude row is not a concept the design has (only user
    /// copies can be shadowed, since user root is tried first).
    func testShadowedUserSkillShowsBadgeAndStaysNotReadOnly() {
        let skills = [
            makeSkill(name: "dictate", root: builtinRoot, editable: false, active: true),
            makeSkill(name: "dictate", root: userSkillRoot, editable: true, active: false, shadowedBy: builtinRoot),
        ]

        let sections = SkillListBuilder.sections(for: skills, homeDirectory: home)
        let allRows = sections.flatMap(\.rows)
        let activeRow = allRows.first { $0.bucket == .builtin }!
        let shadowedRow = allRows.first { $0.bucket == .user }!

        XCTAssertFalse(activeRow.showsShadowedBadge)
        XCTAssertTrue(shadowedRow.showsShadowedBadge)
        // Still editable/not-read-only despite being shadowed (E3-adjacent:
        // the user's own copy is never locked just because it's inactive).
        XCTAssertFalse(shadowedRow.isReadOnly)
        XCTAssertTrue(activeRow.isReadOnly)
    }

    /// `SkillListRow.isReadOnly` reads the API-supplied `editable` flag
    /// directly (the skills list contract carries one per row) rather than
    /// re-deriving it from the root bucket.
    func testSkillRowIsReadOnlyFollowsEditableFlagDirectly() {
        let skills = [
            makeSkill(name: "b", root: builtinRoot, editable: false, active: true),
            makeSkill(name: "u", root: userSkillRoot, editable: true, active: true),
            makeSkill(name: "c", root: claudeSkillRoot, editable: false, active: true),
        ]
        let rows = SkillListBuilder.sections(for: skills, homeDirectory: home).flatMap(\.rows)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.skill.name, $0) })

        XCTAssertTrue(byName["b"]!.isReadOnly)
        XCTAssertFalse(byName["u"]!.isReadOnly)
        XCTAssertTrue(byName["c"]!.isReadOnly)
    }

    func testAgentSectionsAreOrderedBuiltinThenUserThenClaudeWithCounts() {
        let agents = [
            makeAgent(name: "helper", root: builtinAgentRoot, active: true),
            makeAgent(name: "writer", root: userAgentRoot, active: true),
            makeAgent(name: "reader", root: userAgentRoot, active: true),
            makeAgent(name: "reviewer", root: claudeAgentRoot, active: true),
        ]

        let sections = AgentListBuilder.sections(for: agents, homeDirectory: home)

        XCTAssertEqual(sections.map(\.bucket), [.builtin, .user, .claude])
        XCTAssertEqual(sections.map(\.count), [1, 2, 1])
    }

    func testEmptyAgentSectionsAreOmitted() {
        let agents = [makeAgent(name: "helper", root: builtinAgentRoot, active: true)]

        let sections = AgentListBuilder.sections(for: agents, homeDirectory: home)

        XCTAssertEqual(sections.map(\.bucket), [.builtin])
    }

    /// Mirrors the skill case, but proves the AGENT-specific derivation path:
    /// since the agent list contract has no `editable` field at all,
    /// `isReadOnly` here MUST come from the root bucket, not from a
    /// (nonexistent) flag on `AgentDefinitionSummary`.
    func testShadowedUserAgentShowsBadgeAndIsReadOnlyDerivedFromBucket() {
        let agents = [
            makeAgent(name: "writer", root: builtinAgentRoot, active: true),
            makeAgent(name: "writer", root: userAgentRoot, active: false, shadowedBy: builtinAgentRoot),
        ]

        let sections = AgentListBuilder.sections(for: agents, homeDirectory: home)
        let allRows = sections.flatMap(\.rows)
        let activeRow = allRows.first { $0.bucket == .builtin }!
        let shadowedRow = allRows.first { $0.bucket == .user }!

        XCTAssertFalse(activeRow.showsShadowedBadge)
        XCTAssertTrue(shadowedRow.showsShadowedBadge)
        XCTAssertFalse(shadowedRow.isReadOnly)
        XCTAssertTrue(activeRow.isReadOnly)
    }

    func testAgentRowIsReadOnlyForBuiltinAndClaudeButNotUser() {
        let agents = [
            makeAgent(name: "b", root: builtinAgentRoot, active: true),
            makeAgent(name: "u", root: userAgentRoot, active: true),
            makeAgent(name: "c", root: claudeAgentRoot, active: true),
        ]
        let rows = AgentListBuilder.sections(for: agents, homeDirectory: home).flatMap(\.rows)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.agent.name, $0) })

        XCTAssertTrue(byName["b"]!.isReadOnly)
        XCTAssertFalse(byName["u"]!.isReadOnly)
        XCTAssertTrue(byName["c"]!.isReadOnly)
    }

    // MARK: - 4. Name validation mirror

    func testValidNamesPassCharsetAndLengthCheck() {
        XCTAssertNil(SkillAgentNameValidator.charsetAndLengthError(for: "my-skill"))
        XCTAssertNil(SkillAgentNameValidator.charsetAndLengthError(for: "a1"))
        XCTAssertNil(SkillAgentNameValidator.charsetAndLengthError(for: String(repeating: "a", count: 64)))
    }

    /// The exact invalid-name list pinned by both sidecar contract tests
    /// (`skillRoutes.test.ts`/`agentDefinitionRoutes.test.ts`): path
    /// traversal, a space, a leading hyphen, and empty. All of these are
    /// charset failures, not length failures.
    func testPinnedInvalidNamesAreRejectedAsInvalidCharset() {
        for name in ["../x", "a b", "-x", ""] {
            XCTAssertEqual(
                SkillAgentNameValidator.charsetAndLengthError(for: name),
                .invalidCharset,
                "expected \(name.debugDescription) to be invalidCharset"
            )
        }
    }

    /// Non-ASCII input (not in the pinned list, but consistent with the same
    /// charset rule) is also an invalid-charset rejection.
    func testNonAsciiNameIsInvalidCharset() {
        XCTAssertEqual(SkillAgentNameValidator.charsetAndLengthError(for: "中文名"), .invalidCharset)
    }

    /// A 65-character name made ENTIRELY of valid characters must report the
    /// more specific `.tooLong`, not `.invalidCharset` — this is what makes
    /// the typed-reason enum worth having instead of one generic "invalid".
    func testTooLongValidCharsetNameReportsTooLongSpecifically() {
        let name = String(repeating: "a", count: 65)
        XCTAssertEqual(SkillAgentNameValidator.charsetAndLengthError(for: name), .tooLong)
    }

    func testBoundarySixtyFourCharacterNameIsValid() {
        XCTAssertNil(SkillAgentNameValidator.charsetAndLengthError(for: String(repeating: "a", count: 64)))
    }

    /// "readme" is reserved for AGENTS only (design §1.4), case-insensitively.
    func testReadmeIsReservedForAgentsCaseInsensitively() {
        for name in ["readme", "README", "ReadMe"] {
            XCTAssertEqual(SkillAgentNameValidator.nameError(for: name, kind: .agent), .reserved)
        }
    }

    /// Skills have NO "readme" restriction — a skill's file is always
    /// `SKILL.md` regardless of the skill's own name.
    func testReadmeIsNotReservedForSkills() {
        XCTAssertNil(SkillAgentNameValidator.nameError(for: "readme", kind: .skill))
    }

    /// The kind-aware entry point still enforces the shared charset/length
    /// rule underneath the reserved-name check.
    func testKindAwareNameErrorStillEnforcesCharsetForAgents() {
        XCTAssertEqual(SkillAgentNameValidator.nameError(for: "a b", kind: .agent), .invalidCharset)
        XCTAssertEqual(SkillAgentNameValidator.nameError(for: String(repeating: "a", count: 65), kind: .agent), .tooLong)
    }

    func testConflictCheckerLowLevelTupleForm() {
        XCTAssertEqual(
            SkillAgentNameConflictChecker.conflict(
                forName: "dictate",
                buckets: [(name: "dictate", bucket: .builtin)]
            ),
            .conflictsWithBuiltin
        )
        XCTAssertEqual(
            SkillAgentNameConflictChecker.conflict(
                forName: "mine",
                buckets: [(name: "mine", bucket: .user)]
            ),
            .duplicateInMine
        )
        // E3: a same-name CLAUDE-root entry is never a conflict.
        XCTAssertNil(
            SkillAgentNameConflictChecker.conflict(
                forName: "shared-name",
                buckets: [(name: "shared-name", bucket: .claude)]
            )
        )
        XCTAssertNil(
            SkillAgentNameConflictChecker.conflict(forName: "new-name", buckets: [])
        )
    }

    /// Builtin collision outranks a mine-duplicate when (hypothetically) both
    /// exist under the same name — matches the backend's own precedence,
    /// where a builtin conflict is checked before "already exists in mine".
    func testConflictCheckerPrefersBuiltinOverMineWhenBothMatch() {
        let result = SkillAgentNameConflictChecker.conflict(
            forName: "dictate",
            buckets: [(name: "dictate", bucket: .builtin), (name: "dictate", bucket: .user)]
        )
        XCTAssertEqual(result, .conflictsWithBuiltin)
    }

    /// Exact-match only: this stage assumes case-sensitive name comparison
    /// (filesystem-identifier semantics), since the sidecar contract tests
    /// never exercise a case-insensitive collision. Flagged as an assumption.
    func testConflictCheckerIsCaseSensitive() {
        XCTAssertNil(
            SkillAgentNameConflictChecker.conflict(
                forName: "Dictate",
                buckets: [(name: "dictate", bucket: .builtin)]
            )
        )
    }

    /// The convenience overloads that take the actual fetched DTO list plus
    /// `homeDirectory`, composing bucketing + conflict checking end to end —
    /// this is the shape a view actually calls.
    func testConflictCheckerOverloadOnFetchedSkillList() {
        let skills = [makeSkill(name: "dictate", root: builtinRoot, editable: false, active: true)]
        XCTAssertEqual(
            SkillAgentNameConflictChecker.conflict(forName: "dictate", amongSkills: skills, homeDirectory: home),
            .conflictsWithBuiltin
        )
        XCTAssertNil(
            SkillAgentNameConflictChecker.conflict(forName: "brand-new", amongSkills: skills, homeDirectory: home)
        )
    }

    func testConflictCheckerOverloadOnFetchedAgentList() {
        let agents = [makeAgent(name: "helper", root: userAgentRoot, active: true)]
        XCTAssertEqual(
            SkillAgentNameConflictChecker.conflict(forName: "helper", amongAgents: agents, homeDirectory: home),
            .duplicateInMine
        )
    }

    func testValidateForCreateSkillComposesCharsetAndConflict() {
        let skills = [makeSkill(name: "dictate", root: builtinRoot, editable: false, active: true)]

        XCTAssertEqual(
            SkillAgentNameValidation.validateForCreateSkill(name: "-bad", amongSkills: skills, homeDirectory: home),
            .invalidCharset
        )
        XCTAssertEqual(
            SkillAgentNameValidation.validateForCreateSkill(name: "dictate", amongSkills: skills, homeDirectory: home),
            .conflictsWithBuiltin
        )
        XCTAssertNil(
            SkillAgentNameValidation.validateForCreateSkill(name: "brand-new", amongSkills: skills, homeDirectory: home)
        )
    }

    func testValidateForCreateAgentComposesReadmeCharsetAndConflict() {
        let agents = [makeAgent(name: "helper", root: builtinAgentRoot, active: true)]

        XCTAssertEqual(
            SkillAgentNameValidation.validateForCreateAgent(name: "README", amongAgents: agents, homeDirectory: home),
            .reserved
        )
        XCTAssertEqual(
            SkillAgentNameValidation.validateForCreateAgent(name: "helper", amongAgents: agents, homeDirectory: home),
            .conflictsWithBuiltin
        )
        XCTAssertNil(
            SkillAgentNameValidation.validateForCreateAgent(name: "researcher", amongAgents: agents, homeDirectory: home)
        )
    }

    // MARK: - 5. Editor form state

    func testSkillEditorCreateModeNameIsEditable() {
        let state = SkillEditorFormState.blankForCreate()
        XCTAssertEqual(state.mode, .create)
        XCTAssertTrue(state.isNameEditable)
    }

    func testSkillEditorEditModeNameIsNotEditable() {
        let detail = SkillDetail(name: "mine", description: "d", body: "b", path: "/x", root: userSkillRoot, editable: true)
        let state = SkillEditorFormState.loadForEdit(from: detail)
        XCTAssertEqual(state.mode, .edit)
        XCTAssertFalse(state.isNameEditable)
        XCTAssertEqual(state.name, "mine")
    }

    /// In edit mode the (immutable) name is never re-validated — only
    /// description/body emptiness gates Save.
    func testSkillEditorEditModeIgnoresNameValidationEntirely() {
        var state = SkillEditorFormState.loadForEdit(
            from: SkillDetail(name: "mine", description: "d", body: "b", path: "/x", root: userSkillRoot, editable: true)
        )
        state.description = "updated description"
        state.body = "updated body"
        XCTAssertNil(state.nameError(amongSkills: [], homeDirectory: home))
        XCTAssertTrue(state.isSaveEnabled(amongSkills: [], homeDirectory: home))
    }

    func testSkillEditorCreateModeSaveDisabledUntilAllThreeFieldsAreValidAndNonempty() {
        var state = SkillEditorFormState.blankForCreate()
        XCTAssertFalse(state.isSaveEnabled(amongSkills: [], homeDirectory: home))

        state.name = "my-new-skill"
        XCTAssertFalse(state.isSaveEnabled(amongSkills: [], homeDirectory: home), "description/body still empty")

        state.description = "Does a thing"
        XCTAssertFalse(state.isSaveEnabled(amongSkills: [], homeDirectory: home), "body still empty")

        state.body = "Step 1. Step 2."
        XCTAssertTrue(state.isSaveEnabled(amongSkills: [], homeDirectory: home))
    }

    func testSkillEditorCreateModeSaveDisabledWhenNameConflictsWithBuiltin() {
        let skills = [makeSkill(name: "dictate", root: builtinRoot, editable: false, active: true)]
        let state = SkillEditorFormState(mode: .create, name: "dictate", description: "d", body: "b")

        XCTAssertEqual(state.nameError(amongSkills: skills, homeDirectory: home), .conflictsWithBuiltin)
        XCTAssertFalse(state.isSaveEnabled(amongSkills: skills, homeDirectory: home))
    }

    /// E2: "复制到我的 Skill 再改" prefills name/description/body from a
    /// builtin's detail, but the resulting form is a CREATE, not an edit of
    /// the builtin file.
    func testSkillEditorCopyToMinePrefillsAndIsCreateMode() {
        let detail = SkillDetail(
            name: "dictate", description: "builtin desc", body: "BUILTIN BODY",
            path: "\(builtinRoot)/dictate/SKILL.md", root: builtinRoot, editable: false
        )
        let state = SkillEditorFormState.copyToMine(from: detail)

        XCTAssertEqual(state.mode, .create)
        XCTAssertTrue(state.isNameEditable)
        XCTAssertEqual(state.name, "dictate")
        XCTAssertEqual(state.description, "builtin desc")
        XCTAssertEqual(state.body, "BUILTIN BODY")
    }

    func testAgentEditorCreateModeNameIsEditableAndEditModeIsNot() {
        XCTAssertTrue(AgentEditorFormState.blankForCreate().isNameEditable)

        let detail = AgentDefinitionDetail(
            name: "mine", displayName: nil, description: "d", body: "b",
            path: "/x", root: userAgentRoot, tools: nil, model: nil, editable: true
        )
        XCTAssertFalse(AgentEditorFormState.loadForEdit(from: detail).isNameEditable)
    }

    func testAgentEditorSaveEnabledRequiresDescriptionAndBodyOnlyDisplayNameOptional() {
        var state = AgentEditorFormState.blankForCreate()
        state.name = "researcher"
        XCTAssertFalse(state.isSaveEnabled(amongAgents: [], homeDirectory: home))

        state.description = "Looks things up"
        state.body = "You research things carefully."
        // displayName was never set (still "") -- must not block save.
        XCTAssertEqual(state.displayName, "")
        XCTAssertTrue(state.isSaveEnabled(amongAgents: [], homeDirectory: home))
    }

    /// Empty tools selection means "inherit everything" -- serializes to
    /// `nil` (no `tools` key at all), matching the omitted-tools-line
    /// contract pinned by `agentDefinitionRoutes.test.ts`.
    func testAgentEditorEmptyToolsSelectionSerializesToNil() {
        var state = AgentEditorFormState.blankForCreate()
        state.selectedTools = []
        XCTAssertNil(state.toolsPayload)
        XCTAssertNil(state.savePayload.tools)
    }

    func testAgentEditorNonemptyToolsSelectionSerializesToArray() {
        var state = AgentEditorFormState.blankForCreate()
        state.selectedTools = ["bash", "web_search"]
        XCTAssertEqual(Set(state.toolsPayload ?? []), ["bash", "web_search"])
        XCTAssertEqual(Set(state.savePayload.tools ?? []), ["bash", "web_search"])
    }

    /// B2, the load-bearing invariant: the save payload must be structurally
    /// incapable of carrying a `model` value, even when the loaded detail had
    /// one and the form is exposing it read-only. Checked via reflection
    /// (`Mirror`) rather than a JSON round-trip, since the property simply
    /// must not exist on the type -- mirroring how the sidecar's own stage-1
    /// test (A-3) pins this as a carrying-capacity invariant, not a status
    /// code.
    func testAgentSavePayloadStructurallyCannotCarryModel() {
        var state = AgentEditorFormState.blankForCreate()
        state.existingModel = "opus"
        state.description = "d"
        state.body = "b"

        let payload = state.savePayload
        let fieldNames = Mirror(reflecting: payload).children.compactMap(\.label)
        XCTAssertFalse(fieldNames.contains("model"))
    }

    /// The model value already on disk is still exposed for READ-ONLY
    /// display in the editor.
    func testAgentEditorExposesExistingModelReadOnlyFromLoadedDetail() {
        let detail = AgentDefinitionDetail(
            name: "mine", displayName: nil, description: "d", body: "b",
            path: "/x", root: userAgentRoot, tools: nil, model: "opus", editable: true
        )
        let state = AgentEditorFormState.loadForEdit(from: detail)
        XCTAssertEqual(state.existingModel, "opus")
    }

    /// Copy-to-mine creates a brand-new file -- there is no existing model
    /// line yet, regardless of what the source builtin's detail carried.
    func testAgentEditorCopyToMineNeverCarriesOverModel() {
        let builtinDetail = AgentDefinitionDetail(
            name: "helper", displayName: "助手", description: "d", body: "b",
            path: "/builtin/helper.md", root: builtinAgentRoot, tools: "bash", model: "opus", editable: false
        )
        let state = AgentEditorFormState.copyToMine(from: builtinDetail)

        XCTAssertEqual(state.mode, .create)
        XCTAssertEqual(state.name, "helper")
        XCTAssertEqual(state.displayName, "助手")
        XCTAssertEqual(state.selectedTools, ["bash"])
        XCTAssertNil(state.existingModel)
    }

    func testAgentEditorCreateModeSaveDisabledOnReservedName() {
        var state = AgentEditorFormState.blankForCreate()
        state.name = "readme"
        state.description = "d"
        state.body = "b"

        XCTAssertEqual(state.nameError(amongAgents: [], homeDirectory: home), .reserved)
        XCTAssertFalse(state.isSaveEnabled(amongAgents: [], homeDirectory: home))
    }

    func testAgentEditorCreateModeSaveDisabledOnBuiltinConflict() {
        let agents = [makeAgent(name: "helper", root: builtinAgentRoot, active: true)]
        var state = AgentEditorFormState.blankForCreate()
        state.name = "helper"
        state.description = "d"
        state.body = "b"

        XCTAssertEqual(state.nameError(amongAgents: agents, homeDirectory: home), .conflictsWithBuiltin)
        XCTAssertFalse(state.isSaveEnabled(amongAgents: agents, homeDirectory: home))
    }

    // MARK: - 5b. Regression (decision C-1): edit-mode save payload must not
    // silently drop a clear.
    //
    // Stage-4 review found that `savePayload` collapsed an EMPTY
    // displayName/selectedTools to `nil` in BOTH modes. That collapse is
    // correct for CREATE (omitting the key on a brand-new file means "no such
    // line" -- inherit every tool / no display name, exactly what an empty
    // field on a create should produce). It is WRONG for EDIT: the sidecar's
    // PUT treats an OMITTED key as "leave the existing value alone," and only
    // clears a field when the key is PRESENT with an empty value. So clearing
    // a displayName or deselecting every tool on an EXISTING agent must send
    // `""`/`[]` (present, non-nil) in edit mode -- otherwise the clear
    // silently does nothing server-side and the stale value survives the
    // save. Create-mode behaviour (including the existing
    // `testAgentEditorEmptyToolsSelectionSerializesToNil`) is unchanged.

    /// Regression (C-1): clearing displayName on an EXISTING (edit-mode)
    /// agent must send an explicit empty string, not omit the key.
    func testAgentEditorEditModeClearedDisplayNameSendsEmptyStringNotNil() {
        let detail = AgentDefinitionDetail(
            name: "mine", displayName: "我的助手", description: "d", body: "b",
            path: "/x", root: userAgentRoot, tools: nil, model: nil, editable: true
        )
        var state = AgentEditorFormState.loadForEdit(from: detail)
        XCTAssertEqual(state.displayName, "我的助手")

        state.displayName = ""

        XCTAssertEqual(state.savePayload.displayName, "")
    }

    /// Regression (C-1): deselecting every tool on an EXISTING (edit-mode)
    /// agent must send an explicit empty array, not omit the `tools` key --
    /// an omitted key means "leave whatever tools it already had," the
    /// opposite of what deselecting everything asked for.
    func testAgentEditorEditModeEmptiedToolsSendsEmptyArrayNotNil() {
        let detail = AgentDefinitionDetail(
            name: "mine", displayName: nil, description: "d", body: "b",
            path: "/x", root: userAgentRoot, tools: "bash", model: nil, editable: true
        )
        var state = AgentEditorFormState.loadForEdit(from: detail)
        XCTAssertEqual(state.selectedTools, ["bash"])

        state.selectedTools = []

        XCTAssertEqual(state.savePayload.tools, [])
    }

    /// Sanity companion to the two regressions above: edit mode with
    /// NON-empty values still sends them as before -- the fix must only
    /// change the empty case, never stop sending a real edit.
    func testAgentEditorEditModeWithValuesPresentStillSendsThem() {
        let detail = AgentDefinitionDetail(
            name: "mine", displayName: "旧名字", description: "d", body: "b",
            path: "/x", root: userAgentRoot, tools: "bash", model: nil, editable: true
        )
        var state = AgentEditorFormState.loadForEdit(from: detail)
        state.displayName = "新名字"
        state.selectedTools = ["bash", "web_search"]

        XCTAssertEqual(state.savePayload.displayName, "新名字")
        XCTAssertEqual(Set(state.savePayload.tools ?? []), ["bash", "web_search"])
    }

    /// Contrast case for the two regressions above: CREATE mode keeps the
    /// existing nil-collapse behaviour unchanged -- omitting `displayName` on
    /// a brand-new file means "no such line," which is exactly what an empty
    /// field on a create should mean. Only EDIT mode needed the fix.
    func testAgentEditorCreateModeEmptyDisplayNameStillSendsNil() {
        var state = AgentEditorFormState.blankForCreate()
        state.name = "researcher"
        state.description = "d"
        state.body = "b"

        XCTAssertEqual(state.displayName, "")
        XCTAssertNil(state.savePayload.displayName)
    }
}

/// Stage-1 (TDD red) coverage for item 6: the new `SettingsRoute` case for
/// the "Skill 与 Agent" page. Entry placement (设置·引擎组, Agent 工具行下方)
/// is a view-wiring concern for Stage 4's manual walkthrough, not something a
/// pure enum test can pin — this only pins that the case and its title exist.
final class SkillAgentSettingsRouteTests: XCTestCase {

    /// `AppTabTests`/`McpServerStatusWordingTests` establish this pattern:
    /// force `.chinese` so the Chinese copy pinned by the design doc doesn't
    /// depend on the test runner process's actual locale.
    override func setUp() {
        super.setUp()
        OpenTypeL10n.current = .chinese
    }

    override func tearDown() {
        OpenTypeL10n.current = .system
        super.tearDown()
    }

    func testSkillsAndAgentsRouteHasTheDesignedTitle() {
        XCTAssertEqual(SettingsRoute.skillsAndAgents.title, "Skill 与 Agent")
    }

    /// `id` is `rawValue` for every other `SettingsRoute` case (see
    /// `Sources/OpenType/SessionList.swift`); the new case must follow the
    /// same identity scheme rather than special-casing itself.
    func testSkillsAndAgentsRouteIdIsItsRawValue() {
        XCTAssertEqual(SettingsRoute.skillsAndAgents.id, SettingsRoute.skillsAndAgents.rawValue)
    }
}
