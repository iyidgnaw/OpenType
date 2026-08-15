import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the redesign's navigation shape
/// (`design_handoff_opentype_redesign_v1/README.md` › "State Management",
/// "Implementation Map").
///
/// The main window's five equal-weight bottom tabs (输入 / 历史 / 问答 / Agent /
/// 设置) become a four-item sidebar: **会话 / 听写 / 记忆 / 设置**. That is three
/// separate edits to one enum, and each one can silently half-land:
///
/// - `home` is *deleted*, not renamed — the 输入 tab dissolves entirely (mode
///   selection moves to the menubar popover and the sidebar's mode card), so
///   there must be no case left that a stale `.home` reference resolves to.
/// - `qa` + `agent` *merge* into one `sessions` case. Two tabs collapsing into
///   one is the change most likely to be done by renaming one and forgetting
///   the other, leaving five cases with two of them showing the same list.
/// - `history` is *renamed* `dictation`. A rename that keeps the old raw value
///   is how "we renamed it" quietly becomes "we renamed half of it".
///
/// Expected shape (Stage 3 creates it; nothing here builds it):
///
///     enum AppTab: String, CaseIterable, Identifiable {
///         case sessions
///         case dictation
///         case memory
///         case settings
///     }
///
/// ## Pinned decision — raw values follow the case names
///
/// `AppTab` is **not persisted**: it is not `Codable`, and nothing writes it to
/// `UserDefaults`/`@AppStorage` (the only `UserDefaults` key `AppModel` owns is
/// `lastShortcutRegistrationStatus`). `selectedTab` starts at a fixed default
/// on every launch. So the raw values are free to follow the new case names,
/// and this suite pins them that way rather than preserving `"history"` for a
/// compatibility that does not exist.
///
/// What the raw values still have to be is *stable and distinct*: `id` is
/// `rawValue`, and `AppTab.allCases` drives the sidebar's `ForEach`, so a
/// duplicate raw value is a SwiftUI identity collision rather than a
/// compile error.
final class AppTabTests: XCTestCase {

    /// §F made `OpenTypeL10n.text(_:english:)` depend on
    /// `OpenTypeL10n.current` rather than unconditionally returning Chinese —
    /// pinned here so `testEachTabCarriesItsDesignedChineseTitle`'s assertion
    /// about the Chinese copy itself doesn't depend on whatever locale the
    /// test runner's process happens to report.
    override func setUp() {
        super.setUp()
        OpenTypeL10n.current = .chinese
    }

    override func tearDown() {
        OpenTypeL10n.current = .system
        super.tearDown()
    }

    // MARK: - The case set

    func testTheSidebarHasExactlyFourTabsInDesignOrder() {
        // Order is load-bearing: `allCases` is what the sidebar renders, and
        // the design fixes the order top-to-bottom as 会话 / 听写 / 记忆 / 设置.
        XCTAssertEqual(AppTab.allCases, [.sessions, .dictation, .memory, .settings])
    }

    func testEveryRemovedCaseIsGoneRatherThanRenamedInPlace() {
        // A stale raw value must not resolve to a *different* tab. The four
        // strings below are the five old cases minus `settings`, which
        // survives unchanged.
        XCTAssertNil(AppTab(rawValue: "home"), "the 输入 tab is deleted, not renamed")
        XCTAssertNil(AppTab(rawValue: "history"), "renamed to `dictation`")
        XCTAssertNil(AppTab(rawValue: "qa"), "merged into `sessions`")
        XCTAssertNil(AppTab(rawValue: "agent"), "merged into `sessions`")
    }

    func testRawValuesAreTheNewCaseNames() {
        XCTAssertEqual(AppTab.sessions.rawValue, "sessions")
        XCTAssertEqual(AppTab.dictation.rawValue, "dictation")
        XCTAssertEqual(AppTab.memory.rawValue, "memory")
        XCTAssertEqual(AppTab.settings.rawValue, "settings")
    }

    func testEveryTabRoundTripsThroughItsRawValue() {
        for tab in AppTab.allCases {
            XCTAssertEqual(AppTab(rawValue: tab.rawValue), tab)
        }
    }

    func testIdentityIsTheRawValueAndIsUniquePerTab() {
        // `id` feeds the sidebar's `ForEach`; two tabs sharing one would
        // render as a single row rather than fail to build.
        for tab in AppTab.allCases {
            XCTAssertEqual(tab.id, tab.rawValue)
        }
        XCTAssertEqual(Set(AppTab.allCases.map(\.id)).count, AppTab.allCases.count)
    }

    // MARK: - Labels

    func testEachTabCarriesItsDesignedChineseTitle() {
        // `OpenTypeL10n.text(_:english:)` returns the Chinese string, and the
        // handoff states the Chinese copy is final, not placeholder.
        XCTAssertEqual(AppTab.sessions.title, "会话")
        XCTAssertEqual(AppTab.dictation.title, "听写")
        XCTAssertEqual(AppTab.memory.title, "记忆")
        XCTAssertEqual(AppTab.settings.title, "设置")
    }

    // MARK: - Icons

    func testEachTabCarriesItsSFSymbolFromTheAssetsTable() {
        // The handoff's Assets table maps the design's Material placeholders to
        // SF Symbols; these four are the sidebar's. `waveform` is deliberately
        // absent — it moves to the brand mark now that the 输入 tab is gone.
        XCTAssertEqual(AppTab.sessions.symbol, "bubble.left.and.bubble.right.fill")
        XCTAssertEqual(AppTab.dictation.symbol, "clock.arrow.circlepath")
        XCTAssertEqual(AppTab.memory.symbol, "brain")
        XCTAssertEqual(AppTab.settings.symbol, "slider.horizontal.3")
    }

    func testNoTwoTabsShareAnIcon() {
        XCTAssertEqual(
            Set(AppTab.allCases.map(\.symbol)).count,
            AppTab.allCases.count
        )
    }
}
