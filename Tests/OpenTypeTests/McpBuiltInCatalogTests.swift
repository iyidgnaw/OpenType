import XCTest
@testable import OpenType

/// Stage-1 (red) tests for Pipeline D / D1
/// (`docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md`
/// §4): `McpBuiltInCatalog` in `McpServerViews.swift` is hand-transcribed from
/// `sidecar/src/agent/coreTools.ts` and has drifted — it lists 10 tools, the
/// real built-in set (core tools + the two memory tools + `read_history`) is
/// 16. These tests pin the *ground-truth* catalog: the full name set, the two
/// group memberships (本机 / 网络与记忆), and which tools carry the
/// `hasSideEffects` (「有副作用」) badge.
///
/// Ground truth for names comes from `sidecar/src/agent/coreTools.ts`'s
/// `*_TOOL_NAME` constants plus `sidecar/src/agent/readHistoryTool.ts`'s
/// `READ_HISTORY_TOOL_NAME`; `hasSideEffects` follows the doc comment already
/// on `McpBuiltInTool.hasSideEffects` ("could this leave something different
/// behind") extended to the four new file-mutating tools the spec calls out:
/// `write_file`, `edit_file`, `move_file`, `trash`.
///
/// ACCESS-LEVEL NOTE (flagged for the implementer, not guessed at): as of this
/// writing `McpBuiltInTool` and `McpBuiltInCatalog` are both declared
/// `private` in `McpServerViews.swift`, which restricts them to that file even
/// under `@testable import` (`@testable` only upgrades `internal` to visible;
/// it does not cross a `private`/`fileprivate` boundary). This file is written
/// against the *intended* surface — both types accessible at (at least)
/// `internal` — per the task's stage-1 instructions. Until the implementer
/// widens that access, this file will not compile at all (a legitimate red
/// reason distinct from the 10-vs-16 count mismatch); once access is widened,
/// it should compile and fail on content instead.
final class McpBuiltInCatalogTests: XCTestCase {

    /// The complete, current built-in tool surface, namespaced as the catalog
    /// stores names today (fully `opentype__`-prefixed — see
    /// `McpBuiltInTool.name`'s existing entries, e.g. `"opentype__bash"`).
    private let expectedAllNames: Set<String> = [
        "opentype__bash",
        "opentype__python",
        "opentype__open_file",
        "opentype__read_file",
        "opentype__list_dir",
        "opentype__grep",
        "opentype__write_file",
        "opentype__edit_file",
        "opentype__move_file",
        "opentype__trash",
        "opentype__glob",
        "opentype__web_search",
        "opentype__web_fetch",
        "opentype__remember_fact",
        "opentype__consolidate_memory_now",
        "opentype__read_history",
    ]

    private let expectedLocalNames: Set<String> = [
        "opentype__bash",
        "opentype__python",
        "opentype__open_file",
        "opentype__read_file",
        "opentype__list_dir",
        "opentype__grep",
        "opentype__write_file",
        "opentype__edit_file",
        "opentype__move_file",
        "opentype__trash",
        "opentype__glob",
    ]

    private let expectedNetworkAndMemoryNames: Set<String> = [
        "opentype__web_search",
        "opentype__web_fetch",
        "opentype__remember_fact",
        "opentype__consolidate_memory_now",
        "opentype__read_history",
    ]

    private let expectedSideEffectNames: Set<String> = [
        "opentype__bash",
        "opentype__python",
        "opentype__open_file",
        "opentype__remember_fact",
        "opentype__write_file",
        "opentype__edit_file",
        "opentype__move_file",
        "opentype__trash",
    ]

    // MARK: - Full name set (16)

    /// The union of both groups is exactly the 16-tool ground truth — no
    /// tool missing (the four write tools + `glob` + `read_history` this spec
    /// item adds), and nothing stray left over from a hand-transcription typo.
    func testFullNameSetMatchesGroundTruth() {
        let allTools = McpBuiltInCatalog.local + McpBuiltInCatalog.networkAndMemory
        let allNames = Set(allTools.map(\.name))

        XCTAssertEqual(allNames, expectedAllNames)
        XCTAssertEqual(allTools.count, 16, "expected 16 built-in tools total, found \(allTools.count)")
    }

    /// Every name in the catalog is unique — a duplicate between groups would
    /// pass a naive set-equality check on the union while still being wrong.
    func testNoDuplicateNamesAcrossGroups() {
        let allTools = McpBuiltInCatalog.local + McpBuiltInCatalog.networkAndMemory
        let names = allTools.map(\.name)

        XCTAssertEqual(names.count, Set(names).count, "duplicate tool name found across groups")
    }

    // MARK: - Group membership

    /// 本机 (local machine) group: 11 tools, matching
    /// `sidecar/src/agent/coreTools.ts`'s local/file/shell tools.
    func testLocalGroupContainsExactlyTheElevenLocalTools() {
        let names = Set(McpBuiltInCatalog.local.map(\.name))

        XCTAssertEqual(names, expectedLocalNames)
        XCTAssertEqual(McpBuiltInCatalog.local.count, 11)
    }

    /// 网络与记忆 (web + memory) group: 5 tools, matching the two memory
    /// tools plus the two web tools plus `read_history`.
    func testNetworkAndMemoryGroupContainsExactlyTheFiveTools() {
        let names = Set(McpBuiltInCatalog.networkAndMemory.map(\.name))

        XCTAssertEqual(names, expectedNetworkAndMemoryNames)
        XCTAssertEqual(McpBuiltInCatalog.networkAndMemory.count, 5)
    }

    // MARK: - hasSideEffects flags

    /// Exactly 8 tools carry the 「有副作用」 badge: the original 4
    /// (bash/python/open_file/remember_fact) plus the 4 new file-mutating
    /// tools this spec item adds (write_file/edit_file/move_file/trash).
    /// Every other tool — including the newly-added `glob` and
    /// `read_history`, both read-only — must be `false`.
    func testSideEffectFlagsMatchGroundTruthExactly() {
        let allTools = McpBuiltInCatalog.local + McpBuiltInCatalog.networkAndMemory

        let actualSideEffectNames = Set(allTools.filter(\.hasSideEffects).map(\.name))
        XCTAssertEqual(actualSideEffectNames, expectedSideEffectNames)

        let actualNoSideEffectNames = Set(allTools.filter { !$0.hasSideEffects }.map(\.name))
        XCTAssertEqual(actualNoSideEffectNames, expectedAllNames.subtracting(expectedSideEffectNames))
    }

    // MARK: - Count is catalog-derived, not a literal

    /// The "内置工具 · N" / "…只有上面这 N 个内置工具" labels in
    /// `McpServerViews.swift` already read `McpBuiltInCatalog.count` rather
    /// than a hardcoded literal, so fixing the catalog's contents is
    /// sufficient to fix the displayed count too. This assertion pins that
    /// derived count directly, independent of the two group-count assertions
    /// above, so a future refactor that hardcodes the sum elsewhere still gets
    /// caught here.
    func testDerivedCountIsSixteen() {
        XCTAssertEqual(McpBuiltInCatalog.count, 16)
        XCTAssertEqual(McpBuiltInCatalog.count, McpBuiltInCatalog.local.count + McpBuiltInCatalog.networkAndMemory.count)
    }
}
