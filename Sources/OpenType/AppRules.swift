import Foundation

/// What OpenType does differently in one named application.
///
/// Both fields are optional and both mean the same thing when they are `nil`:
/// *this row has no opinion, leave that decision where it already was*. A row
/// that says nothing at all is a bug rather than a no-op — see
/// `AppRulesTests.testEveryRuleExpressesAtLeastOneOpinion` — because the point
/// of the table is that having a row and not having one are different states.
struct AppRule: Equatable {
    /// The identity `ContextBridge.capture` reads off the frontmost
    /// application, matched exactly. No prefix or wildcard matching: a rule
    /// that fires on `com.apple.` would cover every Apple app ever shipped,
    /// and the whole table is small enough to name what it means.
    let bundleIdentifier: String

    /// The name the app calls itself, for Settings' read-only table. It lives
    /// on the row rather than in the view so the table on screen cannot drift
    /// from the table in force — the two would be a hand-maintained pair of
    /// lists otherwise, and the one people read is the one that would go stale.
    let displayName: String

    /// `false` keeps the result on the clipboard even when 自动写入 is on.
    /// `nil` leaves delivery to the global setting.
    ///
    /// `true` is representable and must never be used: a rule may **restrict**
    /// delivery, never grant it. `AppRulesTests.testNoRuleEverEnablesAutoInsert`
    /// is what holds that line for rows added later.
    var autoInsert: Bool? = nil

    /// The variant this app gets when the user has never chosen one. `nil`
    /// leaves the choice entirely to the global setting.
    ///
    /// Note the asymmetry with `autoInsert`, which is the rule the whole table
    /// is built on: a row may restrict delivery on safety grounds even against
    /// an explicit `automaticallyInsert = true` (strictly less happens than was
    /// asked for, and the text is still on the clipboard), but it may never
    /// substitute one transcript style for another the user picked on purpose —
    /// there the user would have no way to notice, because the text is simply
    /// already in the field.
    var transcribeVariant: TranscribeVariant? = nil
}

/// The built-in per-app behaviour table (§J of the 2026-08-15 product batch).
///
/// `bundleIdentifier` has been captured end to end since long before this —
/// `ContextBridge.capture` reads it, `CapturedContext` carries it, and
/// `OutputDeliveryPolicy.shouldInsert` compares it against the frontmost app at
/// delivery time — but it was only ever consulted to *downgrade* a delivery
/// whose target moved, never to say anything about the target itself. This is
/// that missing table, and nothing more: a fixed list, no per-row editing, no
/// matching language, no user-authored rules. Review §14's judgement is that a
/// rules engine is the wrong shape to reach for before knowing whether the
/// defaults are even right.
///
/// Everything here is a pure lookup with no state of its own, so the two
/// decisions that read it (`OutputDeliveryPolicy.shouldInsert`'s overload below
/// and `transcribeVariant(for:userSelected:perAppRulesEnabled:)`) stay testable
/// without a running app.
enum AppRules {

    /// What `TranscribeVariant` a user who has never opened that setting gets.
    ///
    /// Stated once, here, because two things need it and they must not be able
    /// to disagree: `AppConfiguration`'s initializer, which collapses an absent
    /// key to it, and the resolution below, which falls back to it whenever
    /// neither the user nor the table has an opinion.
    static let factoryTranscribeVariant: TranscribeVariant = .direct

    /// The table.
    ///
    /// Three groups, and only the first one is about safety:
    ///
    /// - **Terminals** do not receive an automatic insert. `ContextBridge.insert`
    ///   is a clipboard write plus ⌘V, so a dictated sentence containing a
    ///   newline is a command the shell runs the instant it lands. That is a
    ///   reachable destructive path in the shipping configuration, and it is
    ///   *less* supervised than anything the agent does — `opentype__bash` at
    ///   least passes through `classifyCommandRisk` first. They carry no variant
    ///   opinion: they are a delivery rule, and quietly changing what reaches the
    ///   clipboard for a destination we already decided not to deliver into would
    ///   be a second, unasked-for behaviour change riding along with a safety one.
    /// - **Messaging and notes** get `tidy`. This is prose written to a person;
    ///   the 嗯/那个 and the restarted sentence are noise in it.
    /// - **Code editors** get `direct`. They receive identifiers, paths and
    ///   code, where normalising punctuation is corruption rather than cleanup.
    ///   The row is not redundant with the factory default even though it names
    ///   the same value: it states the intent, and it is what keeps a future
    ///   change to `factoryTranscribeVariant` from silently reaching Xcode.
    ///
    /// JetBrains ships one bundle identifier per IDE rather than one for the
    /// family, so IntelliJ is here and its siblings are additions rather than
    /// a pattern.
    ///
    /// Computed rather than stored because two of the display names go through
    /// `OpenTypeL10n`, and a `static let` would resolve them once at first
    /// touch — which is exactly the shape that goes stale the day the interface
    /// language stops being a compile-time constant (§F). Twelve rows rebuilt
    /// per lookup costs nothing next to the ASR round trip that precedes it.
    static var defaults: [AppRule] {[
        AppRule(
            bundleIdentifier: "com.apple.Terminal",
            displayName: "Terminal",
            autoInsert: false
        ),
        AppRule(
            bundleIdentifier: "com.googlecode.iterm2",
            displayName: "iTerm2",
            autoInsert: false
        ),
        AppRule(
            bundleIdentifier: "dev.warp.Warp-Stable",
            displayName: "Warp",
            autoInsert: false
        ),
        AppRule(
            bundleIdentifier: "net.kovidgoyal.kitty",
            displayName: "kitty",
            autoInsert: false
        ),
        AppRule(
            bundleIdentifier: "com.github.wez.wezterm",
            displayName: "WezTerm",
            autoInsert: false
        ),
        AppRule(
            bundleIdentifier: "com.tencent.xinWeChat",
            displayName: OpenTypeL10n.text("微信", english: "WeChat"),
            transcribeVariant: .tidy
        ),
        AppRule(
            bundleIdentifier: "com.apple.Notes",
            displayName: OpenTypeL10n.text("备忘录", english: "Notes"),
            transcribeVariant: .tidy
        ),
        AppRule(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            displayName: "Slack",
            transcribeVariant: .tidy
        ),
        AppRule(
            bundleIdentifier: "notion.id",
            displayName: "Notion",
            transcribeVariant: .tidy
        ),
        AppRule(
            bundleIdentifier: "com.apple.dt.Xcode",
            displayName: "Xcode",
            transcribeVariant: .direct
        ),
        AppRule(
            bundleIdentifier: "com.microsoft.VSCode",
            displayName: "VS Code",
            transcribeVariant: .direct
        ),
        AppRule(
            bundleIdentifier: "com.jetbrains.intellij",
            displayName: "IntelliJ IDEA",
            transcribeVariant: .direct
        ),
    ]}

    /// The row for an app, or `nil` when the table has nothing to say about it.
    ///
    /// `nil` rather than an empty `AppRule` on purpose: "no opinion" has to be
    /// distinguishable at the type level from "an opinion that happens to match
    /// today's default", because only the first one is guaranteed to leave an
    /// unlisted app's behaviour untouched however the defaults move later. A
    /// `nil` identifier — no frontmost application, or one without a bundle id —
    /// is the same answer for the same reason: there is no identity to match.
    static func rule(for bundleIdentifier: String?) -> AppRule? {
        guard let bundleIdentifier else { return nil }
        return defaults.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Which `TranscribeVariant` a recording captured in `bundleIdentifier`
    /// actually runs under.
    ///
    /// The order is the pinned decision of §J. An explicit user choice comes
    /// first and is never outranked: someone who went into Settings and chose
    /// 复核 did it because they want to see every transcript before it lands,
    /// and delivering straight into 备忘录 because a built-in table prefers
    /// `tidy` there is exactly the surprise they set that switch to prevent.
    ///
    /// - Parameter userSelected: `nil` means *the user has never chosen*, which
    ///   is the only state a row may fill. It is deliberately not "the current
    ///   value differs from the default": someone who deliberately picked 直接
    ///   chose as explicitly as someone who picked 复核, and comparing values
    ///   instead of asking whether a choice was made would silently overrule
    ///   them. `AppConfiguration.userSelectedTranscribeVariant` is what makes
    ///   the distinction available at the call site.
    static func transcribeVariant(
        for bundleIdentifier: String?,
        userSelected: TranscribeVariant?,
        perAppRulesEnabled: Bool
    ) -> TranscribeVariant {
        if let userSelected { return userSelected }
        guard perAppRulesEnabled else { return factoryTranscribeVariant }
        return rule(for: bundleIdentifier)?.transcribeVariant ?? factoryTranscribeVariant
    }
}

extension AppRule {
    /// What this row changes, in one phrase — the right-hand column of
    /// Settings' read-only table, and what that table groups its rows by.
    ///
    /// Derived from the two fields rather than written out beside them, so a
    /// row added later cannot appear in Settings describing something it does
    /// not do. It is also why the `true` branch exists at all for a value the
    /// table never uses: an unreachable-today case that renders as a blank cell
    /// the first time someone reaches it is worse than one sentence here.
    var effectSummary: String {
        var parts: [String] = []
        switch autoInsert {
        case .some(false):
            parts.append(OpenTypeL10n.text("不自动写入", english: "No auto-insert"))
        case .some(true):
            parts.append(OpenTypeL10n.text("自动写入", english: "Auto-insert"))
        case .none:
            break
        }
        if let transcribeVariant {
            parts.append(transcribeVariant.title)
        }
        return parts.joined(separator: " · ")
    }
}

extension OutputDeliveryPolicy {
    /// `shouldInsert(capturedBundleId:frontmostBundleId:)` with the per-app
    /// table consulted.
    ///
    /// The composition order is the whole of this function and it is not
    /// negotiable: the existing safety guard runs **first**, and a rule is only
    /// ever asked about a delivery the guard has already agreed to. A rule may
    /// take an insert away; it can never give one back. An implementation that
    /// looked the row up first and returned its `autoInsert` would satisfy every
    /// terminal case and would happily paste into an app the user had since
    /// switched away from.
    ///
    /// The master switch is read here rather than at the call site so "rules
    /// off" cannot be half-honoured by one caller and observed by another, and
    /// so that off is a total bypass: with `perAppRulesEnabled == false` this
    /// answers exactly what the two-argument form answers, for every pair of
    /// identifiers.
    ///
    /// `perAppRulesEnabled` has no default value on purpose. A defaulted third
    /// parameter beside the existing two-parameter function is how the current
    /// call sites would silently pick up a new behaviour they never asked for.
    static func shouldInsert(
        capturedBundleId: String?,
        frontmostBundleId: String?,
        perAppRulesEnabled: Bool
    ) -> Bool {
        guard shouldInsert(
            capturedBundleId: capturedBundleId,
            frontmostBundleId: frontmostBundleId
        ) else { return false }
        guard perAppRulesEnabled else { return true }
        return AppRules.rule(for: capturedBundleId)?.autoInsert ?? true
    }
}
