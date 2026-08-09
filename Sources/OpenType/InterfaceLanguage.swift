import Foundation

/// Runtime localization for model values that SwiftUI receives as `String`
/// rather than `LocalizedStringKey`. Literal labels are localized by the
/// standard Localizable.strings catalog.
///
/// The interface-language picker was removed before it was ever finished, so
/// the interface is pinned to Chinese instead of following the system locale —
/// otherwise an English system locale would resolve literal labels through
/// `en.lproj` while every string routed through `text(_:english:)` stayed
/// Chinese. The `english:` argument is kept at each call site as the base for
/// the localization work that will eventually replace this bridge.
enum OpenTypeL10n {
    static let locale = Locale(identifier: "zh-Hans")

    static func text(_ chinese: String, english: String) -> String {
        chinese
    }
}
