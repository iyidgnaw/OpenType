import Foundation

/// 界面语言 (§F of `docs/superpowers/specs/2026-08-15-product-batch-plan.md`).
///
/// 跟随系统 (default), or an explicit override. Persisted on
/// `AppConfiguration.interfaceLanguage`; `Settings ▸ 通用` is the only writer.
enum InterfaceLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return OpenTypeL10n.text("跟随系统", english: "Follow System")
        case .chinese: return OpenTypeL10n.text("中文", english: "Chinese")
        case .english: return OpenTypeL10n.text("English", english: "English")
        }
    }

    var explanation: String {
        switch self {
        case .system:
            return OpenTypeL10n.text(
                "界面语言随 macOS 系统语言变化；系统的麦克风、语音识别等权限弹窗另外跟随系统语言，不受这里影响",
                english: "The interface follows whatever macOS itself is set to; the system's own permission dialogs (microphone, speech recognition) follow the system language separately and are unaffected by this setting"
            )
        case .chinese:
            return OpenTypeL10n.text(
                "界面始终显示中文，不论系统语言是什么",
                english: "The interface always shows Chinese, regardless of the system language"
            )
        case .english:
            return OpenTypeL10n.text(
                "界面始终显示英文，不论系统语言是什么",
                english: "The interface always shows English, regardless of the system language"
            )
        }
    }
}

/// The pure half of §F's locale decision, kept apart from `OpenTypeL10n`'s
/// static state for the same reason `LaunchAtLoginPolicy`/`OnboardingPolicy`
/// keep their decisions apart from `SMAppService`/`AppModel`: a function over
/// plain values is testable without touching the framework it will eventually
/// be fed by (`Locale.preferredLanguages`, here) or depending on the host
/// machine's actual locale to exercise every branch.
enum InterfaceLanguagePolicy {
    /// `setting` overrides the system outright for `.chinese`/`.english`.
    /// `.system` reads only `preferredLanguages.first` — a `zh` prefix (covers
    /// `zh-Hans-US`, `zh-Hant-TW`, `zh-CN`, …, since macOS reports a full
    /// language-region tag, not a bare `zh`) resolves to Chinese, anything
    /// else — a different language, or no preferred language at all —
    /// resolves to English. English is the fallback rather than an unhandled
    /// third state because every string this decision governs is written in
    /// exactly two languages; there is no third rendering to fall back to.
    static func resolvesToChinese(
        setting: InterfaceLanguage,
        preferredLanguages: [String]
    ) -> Bool {
        switch setting {
        case .chinese: return true
        case .english: return false
        case .system: return (preferredLanguages.first ?? "").hasPrefix("zh")
        }
    }
}

/// Runtime localization for model values that SwiftUI receives as `String`
/// rather than `LocalizedStringKey`, plus §F's interface-language decision
/// itself. Literal `LocalizedStringKey` labels (bare `Text("...")` etc.) are
/// localized separately by the standard `Localizable.strings` catalog via
/// `.environment(\.locale, OpenTypeL10n.locale)` on each of the app's four
/// SwiftUI roots (`RootView`, `MenuBarPopoverView`, `OverlayController`'s
/// panel, `ReviewPanelController`'s panel) — the two mechanisms have to agree,
/// which is exactly what `locale` existing as a computed property alongside
/// `text(_:english:)` (rather than a value some other type owns) guarantees.
enum OpenTypeL10n {
    /// What every `text(_:english:)`/`locale` call resolves against.
    /// `AppConfiguration.interfaceLanguage`'s `didSet` is the only production
    /// writer, keeping this in step with the persisted setting from `init`
    /// onward — see that property's doc comment. Defaults to `.system` so a
    /// context that runs before any `AppConfiguration` exists (a preview, a
    /// unit test that never constructs one) still resolves something sane
    /// rather than nothing.
    static var current: InterfaceLanguage = .system

    /// Test seam: production reads the real `Locale.preferredLanguages`;
    /// `InterfaceLanguageTests` injects a fixed list so `.system` resolution
    /// is exercised without depending on — or mutating — the host machine's
    /// actual locale. Reset to this default in `tearDown` there so no test
    /// leaks a stub into the rest of the target.
    static var preferredLanguagesProvider: () -> [String] = { Locale.preferredLanguages }

    /// `zh-Hans` or `en`, matching whatever `text(_:english:)` is about to
    /// return for the same `current`/system state. Date/number formatters
    /// read this directly (`DictationViews.swift`, `SessionsViews.swift`,
    /// `MenuBarPopoverView.swift`, `MemoryViews.swift`) — it must never
    /// disagree with the string content on screen, so it is derived from the
    /// exact same `isChineseResolved` the text lookup uses rather than
    /// computed separately.
    static var locale: Locale {
        isChineseResolved ? Locale(identifier: "zh-Hans") : Locale(identifier: "en")
    }

    static func text(_ chinese: String, english: String) -> String {
        isChineseResolved ? chinese : english
    }

    private static var isChineseResolved: Bool {
        InterfaceLanguagePolicy.resolvesToChinese(
            setting: current,
            preferredLanguages: preferredLanguagesProvider()
        )
    }
}
