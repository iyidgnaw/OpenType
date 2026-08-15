import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for §F of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — 界面语言跟随系统.
///
/// The bug, in the file's own doc comment before this batch:
/// `OpenTypeL10n.text(_:english:)` was a one-line `return chinese` — the app
/// was pinned to Chinese no matter what the system, or the user, wanted. The
/// English copy already exists at ~670 call sites (the `english:` argument);
/// what was missing was the locale decision, not the translation.
///
/// Same split this repo uses everywhere a decision has to be testable without
/// touching a framework (`LaunchAtLoginPolicy`, `OnboardingPolicy`,
/// `CorrectionWindow`): `InterfaceLanguagePolicy.resolvesToChinese(setting:
/// preferredLanguages:)` is a pure function over an explicit
/// `preferredLanguages` array rather than `Locale.preferredLanguages` itself,
/// so `.system` resolution is testable without depending on — or mutating —
/// the host machine's actual locale. `OpenTypeL10n` wires that pure function
/// to the real `Locale.preferredLanguages` (via an overridable provider, reset
/// in `tearDown` below so a test never leaks into the rest of this 500+ test
/// target) and to a mutable `static var current`, which is what
/// `AppConfiguration.interfaceLanguage`'s `didSet` keeps in sync in
/// production — see §C below for that half.
///
/// These tests are RED until Stage 3 adds `InterfaceLanguage`,
/// `InterfaceLanguagePolicy`, and rewrites `OpenTypeL10n` in
/// `Sources/OpenType/InterfaceLanguage.swift`, and adds
/// `AppConfiguration.interfaceLanguage` / `.interfaceLanguageToken`. They
/// currently fail to COMPILE because most of those symbols don't exist yet —
/// that is the intended red.
final class InterfaceLanguageTests: XCTestCase {

    override func tearDown() {
        // Static, process-global state: leaving either of these mutated would
        // make every other test in this target that renders a `Text` or reads
        // `OpenTypeL10n.locale` depend on run order. Reset unconditionally,
        // not just for the tests that touch it, so a future test added above
        // this line without its own cleanup can't leak either.
        OpenTypeL10n.current = .system
        OpenTypeL10n.preferredLanguagesProvider = { Locale.preferredLanguages }
        super.tearDown()
    }

    // MARK: - A. `.system` resolution

    func testSystemResolvesSimplifiedChineseToChinese() {
        XCTAssertTrue(
            InterfaceLanguagePolicy.resolvesToChinese(
                setting: .system,
                preferredLanguages: ["zh-Hans-US"]
            )
        )
    }

    func testSystemResolvesTraditionalChineseToChinese() {
        // `zh` is the whole family — Traditional included. §F's rule is a
        // prefix match, not an exact one, precisely so `zh-Hant-TW` doesn't
        // fall through to English.
        XCTAssertTrue(
            InterfaceLanguagePolicy.resolvesToChinese(
                setting: .system,
                preferredLanguages: ["zh-Hant-TW"]
            )
        )
    }

    func testSystemResolvesEnglishToEnglish() {
        XCTAssertFalse(
            InterfaceLanguagePolicy.resolvesToChinese(
                setting: .system,
                preferredLanguages: ["en-US"]
            )
        )
    }

    func testSystemResolvesAThirdLanguageToEnglish() {
        // Not Chinese, not English — the spec's rule is "zh prefix means
        // Chinese, anything else means English", not "anything else passes
        // through unlocalized". French, Japanese, whatever the system reports:
        // all of it lands on the language the copy is actually written in.
        XCTAssertFalse(
            InterfaceLanguagePolicy.resolvesToChinese(
                setting: .system,
                preferredLanguages: ["fr-FR"]
            )
        )
    }

    func testSystemResolvesEmptyPreferredLanguagesToEnglish() {
        // No preferred language at all (a bare/misconfigured environment, or
        // a test harness) must not crash on `.first` and must not default to
        // Chinese — English is the safe fallback an audience `zh` was never
        // meant to cover.
        XCTAssertFalse(
            InterfaceLanguagePolicy.resolvesToChinese(
                setting: .system,
                preferredLanguages: []
            )
        )
    }

    func testOnlyTheFirstPreferredLanguageIsConsulted() {
        // A system with English first and Chinese second is an English
        // system that also understands Chinese, not the reverse — `.first`
        // is deliberate, not an oversight.
        XCTAssertFalse(
            InterfaceLanguagePolicy.resolvesToChinese(
                setting: .system,
                preferredLanguages: ["en-US", "zh-Hans-US"]
            )
        )
    }

    // MARK: - B. Explicit settings override the system

    func testExplicitChineseIgnoresAnEnglishSystem() {
        XCTAssertTrue(
            InterfaceLanguagePolicy.resolvesToChinese(
                setting: .chinese,
                preferredLanguages: ["en-US"]
            )
        )
    }

    func testExplicitEnglishIgnoresAChineseSystem() {
        XCTAssertFalse(
            InterfaceLanguagePolicy.resolvesToChinese(
                setting: .english,
                preferredLanguages: ["zh-Hans-US"]
            )
        )
    }

    // MARK: - C. `OpenTypeL10n.text(_:english:)` under all three settings

    func testTextReturnsChineseWhenCurrentIsChinese() {
        OpenTypeL10n.current = .chinese
        XCTAssertEqual(OpenTypeL10n.text("你好", english: "hello"), "你好")
    }

    func testTextReturnsEnglishWhenCurrentIsEnglish() {
        OpenTypeL10n.current = .english
        XCTAssertEqual(OpenTypeL10n.text("你好", english: "hello"), "hello")
    }

    func testTextFollowsSystemWhenCurrentIsSystem() {
        OpenTypeL10n.current = .system

        OpenTypeL10n.preferredLanguagesProvider = { ["zh-Hans-US"] }
        XCTAssertEqual(OpenTypeL10n.text("你好", english: "hello"), "你好")

        OpenTypeL10n.preferredLanguagesProvider = { ["en-US"] }
        XCTAssertEqual(OpenTypeL10n.text("你好", english: "hello"), "hello")
    }

    // MARK: - D. `locale` agrees with the resolved language

    func testLocaleIsSimplifiedChineseWhenResolvedChinese() {
        OpenTypeL10n.current = .chinese
        XCTAssertEqual(OpenTypeL10n.locale.identifier, "zh-Hans")
    }

    func testLocaleIsEnglishWhenResolvedEnglish() {
        OpenTypeL10n.current = .english
        XCTAssertEqual(OpenTypeL10n.locale.identifier, "en")
    }

    func testLocaleFollowsSystemWhenCurrentIsSystem() {
        OpenTypeL10n.current = .system
        OpenTypeL10n.preferredLanguagesProvider = { ["fr-FR"] }
        // French isn't Chinese, so §F's rule resolves it to English — and
        // `locale` must never disagree with what `text(_:english:)` just
        // returned, since date/number formatters (`DictationViews.swift`,
        // `SessionsViews.swift`, `MenuBarPopoverView.swift`, `MemoryViews.swift`)
        // read this directly and would otherwise format an English sentence
        // with Chinese month names or vice versa.
        XCTAssertEqual(OpenTypeL10n.locale.identifier, "en")
    }

    // MARK: - E. `InterfaceLanguage.allCases` — the Settings picker's source

    func testAllCasesHasExactlyTheThreeDocumentedOptions() {
        XCTAssertEqual(
            Set(InterfaceLanguage.allCases),
            [.system, .chinese, .english]
        )
    }

    func testEveryCaseHasANonEmptyTitle() {
        for language in InterfaceLanguage.allCases {
            XCTAssertFalse(language.title.isEmpty)
        }
    }

    // MARK: - F. `AppConfiguration.interfaceLanguage` — persistence + wiring

    @MainActor
    func testInterfaceLanguageDefaultsToSystem() {
        let suiteName = "OpenTypeTests.InterfaceLanguage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertEqual(configuration.interfaceLanguage, .system)
    }

    @MainActor
    func testInterfaceLanguagePersistsAcrossRelaunch() {
        let suiteName = "OpenTypeTests.InterfaceLanguage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        configuration.interfaceLanguage = .english

        let reloaded = AppConfiguration(defaults: defaults)
        XCTAssertEqual(reloaded.interfaceLanguage, .english)
    }

    @MainActor
    func testSettingInterfaceLanguageUpdatesOpenTypeL10nCurrent() {
        // The production wiring §F depends on: nothing renders through
        // `AppConfiguration` directly, everything goes through
        // `OpenTypeL10n.text`/`.locale`, so a setting that didn't push into
        // `OpenTypeL10n.current` would change nothing on screen.
        let suiteName = "OpenTypeTests.InterfaceLanguage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        configuration.interfaceLanguage = .english
        XCTAssertEqual(OpenTypeL10n.current, .english)

        configuration.interfaceLanguage = .chinese
        XCTAssertEqual(OpenTypeL10n.current, .chinese)
    }

    @MainActor
    func testInterfaceLanguageTokenChangesOnEveryAssignment() {
        // The `.id()` seam §F's live-switch requirement depends on
        // (`RootView`/`MenuBarPopoverView`/the floating panels) needs a value
        // that reliably *changes*, not a value that merely reflects the
        // current setting — see the property's own doc comment for why
        // `interfaceLanguage` itself isn't enough at every call site.
        let suiteName = "OpenTypeTests.InterfaceLanguage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        let initialToken = configuration.interfaceLanguageToken

        configuration.interfaceLanguage = .english
        XCTAssertNotEqual(configuration.interfaceLanguageToken, initialToken)

        let secondToken = configuration.interfaceLanguageToken
        configuration.interfaceLanguage = .chinese
        XCTAssertNotEqual(configuration.interfaceLanguageToken, secondToken)
    }
}
