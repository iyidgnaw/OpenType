import Foundation

@MainActor
final class AppConfiguration: ObservableObject {
    @Published var selectedMode: InputMode {
        didSet { defaults.set(selectedMode.rawValue, forKey: Keys.selectedMode) }
    }

    @Published var hotKeyPreset: HotKeyPreset {
        didSet { defaults.set(hotKeyPreset.rawValue, forKey: Keys.hotKeyPreset) }
    }

    @Published var transcriptionLanguage: TranscriptionLanguage {
        didSet {
            defaults.set(
                transcriptionLanguage.rawValue,
                forKey: Keys.transcriptionLanguage
            )
        }
    }

    /// Direct vs. Review, applied to every `transcribe`-mode recording until
    /// changed here — see `TranscribeVariant`'s doc comment. Persisted the
    /// same way every other enum setting on this object is.
    @Published var transcribeVariant: TranscribeVariant {
        didSet {
            defaults.set(transcribeVariant.rawValue, forKey: Keys.transcribeVariant)
        }
    }

    /// The same setting, but able to say 「用户还没选过」 — `nil` when nothing
    /// readable has ever been stored under that key.
    ///
    /// It exists because a per-app rule (`AppRules`) may fill an unmade choice
    /// and may not overrule a made one, and the property above cannot tell the
    /// two apart: it collapses an absent key to `.direct` in `init`, so every
    /// reader sees a value and none of them can see whether anyone picked it.
    /// Comparing against `.direct` instead would be a different rule wearing the
    /// same clothes — it would overrule the user who deliberately chose 直接,
    /// which is the one case where being overruled is least visible.
    ///
    /// Nothing extra is persisted for this. `didSet` does not fire during
    /// `init`, so a fresh install simply never writes the key, and the first
    /// assignment from the UI is what creates it — including an assignment of
    /// `.direct`, which is exactly what makes 「选了直接」 representable.
    var userSelectedTranscribeVariant: TranscribeVariant? {
        Self.storedTranscribeVariant(in: defaults)
    }

    @Published var automaticallyInsert: Bool {
        didSet { defaults.set(automaticallyInsert, forKey: Keys.automaticallyInsert) }
    }

    /// When enabled, a *successful* auto-insert leaves the user's clipboard
    /// untouched instead of overwriting it with the inserted result. Defaults to
    /// `false` to preserve the always-copy guarantee; if the insert fails, the
    /// result is still copied regardless of this setting.
    @Published var retainClipboardAfterInsert: Bool {
        didSet {
            defaults.set(
                retainClipboardAfterInsert,
                forKey: Keys.retainClipboardAfterInsert
            )
        }
    }

    @Published var keepHistory: Bool {
        didSet { defaults.set(keepHistory, forKey: Keys.keepHistory) }
    }

    @Published var playFeedbackSounds: Bool {
        didSet { defaults.set(playFeedbackSounds, forKey: Keys.playFeedbackSounds) }
    }

    @Published var liveCaptionsEnabled: Bool {
        didSet { defaults.set(liveCaptionsEnabled, forKey: Keys.liveCaptionsEnabled) }
    }

    /// What the user last chose for 开机自启, and nothing more.
    ///
    /// **Never read this to decide what the switch shows.** The registration
    /// itself is the source of truth — `LaunchAtLoginController` re-reads
    /// `SMAppService.mainApp.status` for that — because the user can turn our
    /// login item off in System Settings without telling us, and a
    /// UserDefaults-backed switch would go on reading 「开」 afterwards. Nothing
    /// reconciles the two either: re-registering at launch because this says
    /// `true` would undo the change the user just made in System Settings.
    ///
    /// What it is for is the other question — 「用户表过态没有」 — which a later
    /// first-run step wants so it can ask exactly once. Note the `Bool` on its
    /// own does not answer that one either: 「问过，选了不开」 and 「从没问过」
    /// both read `false`, and the only thing separating them is whether the key
    /// exists at all (`defaults.object(forKey: "launchAtLogin") == nil`). Read
    /// it that way when the time comes, or add a flag of its own. Defaults to
    /// `false`, which leaves an existing install's behaviour exactly as it was.
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    /// Whether the app asks GitHub, once a day, whether a newer release exists
    /// (§B). On by default: an install that never learns it is outdated is the
    /// problem this feature exists for, and the check is two requests a day
    /// with no payload of ours attached.
    ///
    /// It is a switch at all because this is a local-first product where every
    /// other outbound request is one the user initiated by speaking. A periodic
    /// one they did not ask for deserves to be refusable — and turning it off
    /// stops the loop rather than hiding its result
    /// (`AppModel.changeUpdateCheckEnabled`).
    @Published var updateCheckEnabled: Bool {
        didSet { defaults.set(updateCheckEnabled, forKey: Keys.updateCheckEnabled) }
    }

    /// The newest version the user has already been shown, in the same
    /// `v`-stripped display form `UpdateCheckOutcome.updateAvailable` carries —
    /// storing a tag's `v1.1.0` here and later comparing it against `1.1.0`
    /// would re-announce the same release forever. `UpdatePromptPolicy`
    /// compares it as a version rather than as text, so the round trip survives
    /// a stored value in any shape.
    ///
    /// `""` (never announced anything) is deliberately the empty-string default
    /// rather than `nil`: it is unparseable, and an unparseable stored value
    /// means 「说」, which is exactly right for a fresh install.
    @Published var lastSeenUpdateVersion: String {
        didSet { defaults.set(lastSeenUpdateVersion, forKey: Keys.lastSeenUpdateVersion) }
    }

    /// Set once the user explicitly chose the first-run "just local
    /// transcription, skip AI setup" path. Persisted so the choice survives
    /// relaunches — `OnboardingPolicy.needsProviderOnboarding` reads it to let a
    /// transcribe-only user past the wizard without ever configuring an LLM.
    @Published var localTranscriptionOnlyAcknowledged: Bool {
        didSet {
            defaults.set(
                localTranscriptionOnlyAcknowledged,
                forKey: Keys.localTranscriptionOnlyAcknowledged
            )
        }
    }

    /// 界面语言（§F）— 跟随系统 / 中文 / English. See `OpenTypeL10n` for how
    /// `.system` resolves and how every `text(_:english:)`/`.locale` call site
    /// consults `OpenTypeL10n.current`, which this keeps in sync: nothing
    /// downstream reads this property directly, so a `didSet` that forgot the
    /// push would leave the setting silently inert.
    @Published var interfaceLanguage: InterfaceLanguage {
        didSet {
            defaults.set(interfaceLanguage.rawValue, forKey: Keys.interfaceLanguage)
            OpenTypeL10n.current = interfaceLanguage
            // Bumped on every change so `.id()` on the root view / popover /
            // floating panels — see those files' `body` — always sees a fresh
            // value and rebuilds the tree, which is what makes a language
            // switch take effect immediately rather than needing a relaunch.
            // A plain `interfaceLanguage` read at those call sites would not
            // be enough on its own: two of the four roots (the overlay panel,
            // the review panel) are not `@ObservedObject` on this object at
            // all, and mirror the token instead — see
            // `OverlayController.languageToken`.
            interfaceLanguageToken += 1
        }
    }

    /// Exists only to give `.id()` something that reliably changes when
    /// `interfaceLanguage` does — see that property's `didSet`. Not itself
    /// persisted: nothing downstream reads its value, only whether it
    /// changed.
    @Published var interfaceLanguageToken: Int = 0

    private let defaults: UserDefaults

    var isMuted: Bool {
        get { !playFeedbackSounds }
        set { playFeedbackSounds = !newValue }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedMode = InputMode(
            rawValue: defaults.string(forKey: Keys.selectedMode) ?? ""
        ) ?? InputMode.visibleModes[0]
        hotKeyPreset = HotKeyPreset(
            rawValue: defaults.string(forKey: Keys.hotKeyPreset) ?? ""
        ) ?? .leftOption
        transcriptionLanguage = TranscriptionLanguage(
            rawValue: defaults.string(forKey: Keys.transcriptionLanguage) ?? ""
        ) ?? .automatic
        // One parse of the stored string, shared with
        // `userSelectedTranscribeVariant`, so 「存的是什么」 and 「用户选过没有」
        // can never be answered by two rules that disagree about the same
        // garbage value.
        transcribeVariant = Self.storedTranscribeVariant(in: defaults)
            ?? AppRules.factoryTranscribeVariant
        automaticallyInsert = defaults.object(forKey: Keys.automaticallyInsert) as? Bool ?? true
        retainClipboardAfterInsert = defaults.object(
            forKey: Keys.retainClipboardAfterInsert
        ) as? Bool ?? false
        keepHistory = defaults.object(forKey: Keys.keepHistory) as? Bool ?? true
        playFeedbackSounds = defaults.object(forKey: Keys.playFeedbackSounds) as? Bool ?? true
        liveCaptionsEnabled = defaults.object(forKey: Keys.liveCaptionsEnabled) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        updateCheckEnabled = defaults.object(forKey: Keys.updateCheckEnabled) as? Bool ?? true
        lastSeenUpdateVersion = defaults.string(forKey: Keys.lastSeenUpdateVersion) ?? ""
        localTranscriptionOnlyAcknowledged = defaults.object(
            forKey: Keys.localTranscriptionOnlyAcknowledged
        ) as? Bool ?? false
        interfaceLanguage = InterfaceLanguage(
            rawValue: defaults.string(forKey: Keys.interfaceLanguage) ?? ""
        ) ?? .system
        // `didSet` does not fire during `init` (same rule as
        // `transcribeVariant` above), so the initial sync to `OpenTypeL10n`
        // has to happen explicitly here — otherwise a fresh process would
        // read a persisted English preference correctly into this property
        // and then render every screen in Chinese anyway, until the first
        // in-process change.
        OpenTypeL10n.current = interfaceLanguage
    }

    /// The stored variant as stored: `nil` for an absent key and `nil` for a
    /// value no `TranscribeVariant` answers to (a setting written by an older
    /// build, say — `polish` was a real case). Unreadable is not a choice, so
    /// both the optional reader and `init`'s fallback treat it as one absence.
    private static func storedTranscribeVariant(
        in defaults: UserDefaults
    ) -> TranscribeVariant? {
        TranscribeVariant(rawValue: defaults.string(forKey: Keys.transcribeVariant) ?? "")
    }

    private enum Keys {
        static let selectedMode = "selectedMode"
        static let hotKeyPreset = "hotKeyPreset"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let transcribeVariant = "transcribeVariant"
        static let automaticallyInsert = "automaticallyInsert"
        static let retainClipboardAfterInsert = "retainClipboardAfterInsert"
        static let keepHistory = "keepHistory"
        static let playFeedbackSounds = "playFeedbackSounds"
        static let liveCaptionsEnabled = "liveCaptionsEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let updateCheckEnabled = "updateCheckEnabled"
        static let lastSeenUpdateVersion = "lastSeenUpdateVersion"
        static let localTranscriptionOnlyAcknowledged = "localTranscriptionOnlyAcknowledged"
        static let interfaceLanguage = "interfaceLanguage"
    }
}
