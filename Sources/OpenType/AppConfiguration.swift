import Foundation

@MainActor
final class AppConfiguration: ObservableObject {
    @Published var selectedMode: InputMode {
        didSet { defaults.set(selectedMode.rawValue, forKey: Keys.selectedMode) }
    }

    @Published var hotKeyPreset: HotKeyPreset {
        didSet { defaults.set(hotKeyPreset.rawValue, forKey: Keys.hotKeyPreset) }
    }

    @Published var interfaceLanguage: InterfaceLanguage {
        didSet {
            defaults.set(interfaceLanguage.rawValue, forKey: Keys.interfaceLanguage)
            OpenTypeL10n.language = interfaceLanguage
        }
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

    @Published var pressEnterCommand: Bool {
        didSet { defaults.set(pressEnterCommand, forKey: Keys.pressEnterCommand) }
    }

    @Published var playFeedbackSounds: Bool {
        didSet { defaults.set(playFeedbackSounds, forKey: Keys.playFeedbackSounds) }
    }

    @Published var liveCaptionsEnabled: Bool {
        didSet { defaults.set(liveCaptionsEnabled, forKey: Keys.liveCaptionsEnabled) }
    }

    @Published var personalDictionaryText: String {
        didSet { defaults.set(personalDictionaryText, forKey: Keys.personalDictionaryText) }
    }

    private let defaults: UserDefaults

    var personalDictionary: [String] {
        personalDictionaryText
            .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

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
        interfaceLanguage = InterfaceLanguage(
            rawValue: defaults.string(forKey: Keys.interfaceLanguage) ?? ""
        ) ?? .chinese
        transcriptionLanguage = TranscriptionLanguage(
            rawValue: defaults.string(forKey: Keys.transcriptionLanguage) ?? ""
        ) ?? .automatic
        transcribeVariant = TranscribeVariant(
            rawValue: defaults.string(forKey: Keys.transcribeVariant) ?? ""
        ) ?? .direct
        automaticallyInsert = defaults.object(forKey: Keys.automaticallyInsert) as? Bool ?? true
        keepHistory = defaults.object(forKey: Keys.keepHistory) as? Bool ?? true
        agentMemoryEnabled = defaults.object(forKey: Keys.agentMemoryEnabled) as? Bool ?? true
        automaticOwnerProfileUpdates = defaults.object(
            forKey: Keys.automaticOwnerProfileUpdates
        ) as? Bool ?? true
        pressEnterCommand = defaults.object(forKey: Keys.pressEnterCommand) as? Bool ?? false
        playFeedbackSounds = defaults.object(forKey: Keys.playFeedbackSounds) as? Bool ?? true
        liveCaptionsEnabled = defaults.object(forKey: Keys.liveCaptionsEnabled) as? Bool ?? true
        personalDictionaryText = defaults.string(forKey: Keys.personalDictionaryText)
            ?? "Rain, OpenType, OpenClaw, Mingle, Clawborn"
        OpenTypeL10n.language = interfaceLanguage
    }

    private enum Keys {
        static let selectedMode = "selectedMode"
        static let hotKeyPreset = "hotKeyPreset"
        static let interfaceLanguage = "interfaceLanguage"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let transcribeVariant = "transcribeVariant"
        static let automaticallyInsert = "automaticallyInsert"
        static let keepHistory = "keepHistory"
        static let agentMemoryEnabled = "agentMemoryEnabled"
        static let automaticOwnerProfileUpdates = "automaticOwnerProfileUpdates"
        static let pressEnterCommand = "pressEnterCommand"
        static let playFeedbackSounds = "playFeedbackSounds"
        static let liveCaptionsEnabled = "liveCaptionsEnabled"
        static let personalDictionaryText = "personalDictionaryText"
    }
}
