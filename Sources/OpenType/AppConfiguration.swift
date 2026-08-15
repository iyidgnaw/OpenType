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

    @Published var agentMemoryEnabled: Bool {
        didSet { defaults.set(agentMemoryEnabled, forKey: Keys.agentMemoryEnabled) }
    }

    @Published var automaticOwnerProfileUpdates: Bool {
        didSet {
            defaults.set(
                automaticOwnerProfileUpdates,
                forKey: Keys.automaticOwnerProfileUpdates
            )
        }
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
        transcribeVariant = TranscribeVariant(
            rawValue: defaults.string(forKey: Keys.transcribeVariant) ?? ""
        ) ?? .direct
        automaticallyInsert = defaults.object(forKey: Keys.automaticallyInsert) as? Bool ?? true
        retainClipboardAfterInsert = defaults.object(
            forKey: Keys.retainClipboardAfterInsert
        ) as? Bool ?? false
        keepHistory = defaults.object(forKey: Keys.keepHistory) as? Bool ?? true
        agentMemoryEnabled = defaults.object(forKey: Keys.agentMemoryEnabled) as? Bool ?? true
        automaticOwnerProfileUpdates = defaults.object(
            forKey: Keys.automaticOwnerProfileUpdates
        ) as? Bool ?? true
        playFeedbackSounds = defaults.object(forKey: Keys.playFeedbackSounds) as? Bool ?? true
        liveCaptionsEnabled = defaults.object(forKey: Keys.liveCaptionsEnabled) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        localTranscriptionOnlyAcknowledged = defaults.object(
            forKey: Keys.localTranscriptionOnlyAcknowledged
        ) as? Bool ?? false
    }

    private enum Keys {
        static let selectedMode = "selectedMode"
        static let hotKeyPreset = "hotKeyPreset"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let transcribeVariant = "transcribeVariant"
        static let automaticallyInsert = "automaticallyInsert"
        static let retainClipboardAfterInsert = "retainClipboardAfterInsert"
        static let keepHistory = "keepHistory"
        static let agentMemoryEnabled = "agentMemoryEnabled"
        static let automaticOwnerProfileUpdates = "automaticOwnerProfileUpdates"
        static let playFeedbackSounds = "playFeedbackSounds"
        static let liveCaptionsEnabled = "liveCaptionsEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let localTranscriptionOnlyAcknowledged = "localTranscriptionOnlyAcknowledged"
    }
}
