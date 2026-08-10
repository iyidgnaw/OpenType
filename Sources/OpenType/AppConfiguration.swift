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
        static let localTranscriptionOnlyAcknowledged = "localTranscriptionOnlyAcknowledged"
    }
}
