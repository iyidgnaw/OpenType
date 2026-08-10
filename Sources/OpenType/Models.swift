import Foundation

enum InputMode: String, CaseIterable, Codable, Identifiable {
    case transcribe = "transcribe"
    case ask = "ask"
    case agent = "agent"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcribe: return OpenTypeL10n.text("听写", english: "Transcribe")
        case .ask: return OpenTypeL10n.text("问答", english: "Ask")
        case .agent: return OpenTypeL10n.text("Agent", english: "Agent")
        }
    }

    var shortTitle: String {
        switch self {
        case .transcribe: return OpenTypeL10n.text("按住说话 · 直接转文字", english: "Hold to talk · Direct transcription")
        case .ask: return OpenTypeL10n.text("提出问题 · 弹窗直接回答", english: "Ask a question · Answered in a popup")
        case .agent: return OpenTypeL10n.text("说出任务 · 交给 Agent 完成", english: "Describe a task · Handed to the Agent")
        }
    }

    var symbol: String {
        switch self {
        case .transcribe: return "mic.fill"
        case .ask: return "questionmark.bubble.fill"
        // Was "gearshape.2.fill" - read as a mechanical settings icon, not
        // "an agent doing something for you," and looked flat/generic next
        // to the other two modes' more distinctive glyphs. wand.and.stars
        // reads as "this happens automatically" and stays visually
        // consistent with the other modes' single-concept SF Symbols.
        case .agent: return "wand.and.stars"
        }
    }

    /// No remaining mode requires a pre-existing text selection: the 3-mode
    /// cut (transcribe/ask/agent) dropped the two modes (`sidecarPolish`,
    /// `sidecarXReply`) that used to require one. Kept as a property (always
    /// `false`) rather than removed outright so the selection-guard call
    /// sites in `AppModel` don't need to change shape.
    var requiresSelection: Bool { false }

    var next: InputMode {
        let modes = Self.visibleModes
        guard let index = modes.firstIndex(of: self) else { return modes[0] }
        return modes[(index + 1) % modes.count]
    }

    static let visibleModes: [InputMode] = [
        .transcribe,
        .ask,
        .agent
    ]

    var explanation: String {
        switch self {
        case .transcribe:
            return OpenTypeL10n.text("按住快捷键说话，松开后直接转成文字，不经过任何 AI 处理", english: "Hold the shortcut and speak; release to get the raw transcription with no AI processing at all")
        case .ask:
            return OpenTypeL10n.text("说出一个问题，弹窗里直接显示答案，而不是整理后的原话", english: "Speak a question and see the answer in a popup, not a cleaned-up version of what you said")
        case .agent:
            return OpenTypeL10n.text(
                "说出任务，交给 Agent Runtime 完成；可能比其他模式慢，且可能调用工具",
                english: "Describe a task and hand it to the Agent Runtime; may take longer than other modes and can use tools"
            )
        }
    }

}

/// The two ways `transcribe` mode can deliver its result, chosen in Settings
/// and applied to every `transcribe`-mode recording until changed (not a
/// per-recording toggle — see `docs/superpowers/specs/2026-08-09-current-system-state.md`
/// for the design rationale). `ask`/`agent` are unaffected by this setting.
enum TranscribeVariant: String, CaseIterable, Codable, Identifiable {
    case direct
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return OpenTypeL10n.text("直接模式", english: "Direct")
        case .review: return OpenTypeL10n.text("复核模式", english: "Review")
        }
    }

    var explanation: String {
        switch self {
        case .direct:
            return OpenTypeL10n.text(
                "松开后直接写入光标所在位置",
                english: "Released speech is inserted straight into the focused field"
            )
        case .review:
            return OpenTypeL10n.text(
                "松开后先在预览面板中查看、编辑或用语音修改，确认后再写入",
                english: "Released speech is staged in a review panel to check, edit, or voice-correct before it's inserted"
            )
        }
    }
}

/// Drives the floating Review panel (`ReviewPanelController`), shown after a
/// `transcribe`-mode recording when `TranscribeVariant.review` is active.
/// `AppModel` is the single source of truth: non-nil means the panel is
/// showing a review session in progress. Unlike `AskPanelState`, the
/// in-progress *text* itself is not mirrored here — the panel's own
/// `NSTextView` is the authoritative source for the current (possibly
/// user-edited or voice-corrected) text once the session starts, to avoid a
/// two-way-sync bug between SwiftUI state and free-form text editing (see
/// `ReviewPanelController`'s doc comment).
struct ReviewPanelState: Equatable {
    let sessionId: UUID
    let originalTranscript: String
}

/// Drives the floating "Ask"/"Agent" popup (`AskPanelController`) introduced
/// alongside the 3-mode cut: `nil` means the popup is hidden, non-nil means
/// it's showing, and `answer == nil` means it's still in the "thinking"
/// state. `AppModel.process(audioURL:)` sets this right before issuing the
/// `/oneshot/ask` or `/agent/run` sidecar call, and fills in `answer` once
/// the response arrives.
struct AskPanelState: Equatable {
    enum Kind: Equatable {
        case ask
        case agent
    }

    var kind: Kind
    var query: String
    var answer: String?
}

/// Locale for the ASR pass. Fed to the sidecar's `/asr/transcribe` request
/// isn't language-scoped (MLX-Whisper auto-detects), so this now only drives
/// the Apple on-device live-caption preview's locale
/// (`AppModel.hotKeyPressed`/`beginRecording` -> `LiveSpeechTranscriber.start`)
/// via `appleLocaleIdentifier`.
enum TranscriptionLanguage: String, CaseIterable, Codable, Identifiable {
    case automatic
    case chinese
    case cantonese
    case english
    case japanese
    case korean
    case german
    case french
    case spanish
    case italian
    case portuguese
    case russian
    case arabic
    case hindi
    case indonesian
    case thai
    case turkish
    case vietnamese
    case ukrainian
    case czech
    case danish
    case filipino
    case finnish
    case icelandic
    case malay
    case norwegian
    case polish
    case swedish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return OpenTypeL10n.text("自动识别（支持混合语言）", english: "Auto-detect (mixed languages)")
        case .chinese: return OpenTypeL10n.text("中文", english: "Chinese")
        case .cantonese: return OpenTypeL10n.text("粤语", english: "Cantonese")
        case .english: return OpenTypeL10n.text("英语", english: "English")
        case .japanese: return OpenTypeL10n.text("日语", english: "Japanese")
        case .korean: return OpenTypeL10n.text("韩语", english: "Korean")
        case .german: return OpenTypeL10n.text("德语", english: "German")
        case .french: return OpenTypeL10n.text("法语", english: "French")
        case .spanish: return OpenTypeL10n.text("西班牙语", english: "Spanish")
        case .italian: return OpenTypeL10n.text("意大利语", english: "Italian")
        case .portuguese: return OpenTypeL10n.text("葡萄牙语", english: "Portuguese")
        case .russian: return OpenTypeL10n.text("俄语", english: "Russian")
        case .arabic: return OpenTypeL10n.text("阿拉伯语", english: "Arabic")
        case .hindi: return OpenTypeL10n.text("印地语", english: "Hindi")
        case .indonesian: return OpenTypeL10n.text("印尼语", english: "Indonesian")
        case .thai: return OpenTypeL10n.text("泰语", english: "Thai")
        case .turkish: return OpenTypeL10n.text("土耳其语", english: "Turkish")
        case .vietnamese: return OpenTypeL10n.text("越南语", english: "Vietnamese")
        case .ukrainian: return OpenTypeL10n.text("乌克兰语", english: "Ukrainian")
        case .czech: return OpenTypeL10n.text("捷克语", english: "Czech")
        case .danish: return OpenTypeL10n.text("丹麦语", english: "Danish")
        case .filipino: return OpenTypeL10n.text("菲律宾语", english: "Filipino")
        case .finnish: return OpenTypeL10n.text("芬兰语", english: "Finnish")
        case .icelandic: return OpenTypeL10n.text("冰岛语", english: "Icelandic")
        case .malay: return OpenTypeL10n.text("马来语", english: "Malay")
        case .norwegian: return OpenTypeL10n.text("挪威语", english: "Norwegian")
        case .polish: return OpenTypeL10n.text("波兰语", english: "Polish")
        case .swedish: return OpenTypeL10n.text("瑞典语", english: "Swedish")
        }
    }

    var appleLocaleIdentifier: String {
        switch self {
        case .automatic, .chinese: return "zh-CN"
        case .cantonese: return "yue-Hant-HK"
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .german: return "de-DE"
        case .french: return "fr-FR"
        case .spanish: return "es-ES"
        case .italian: return "it-IT"
        case .portuguese: return "pt-PT"
        case .russian: return "ru-RU"
        case .arabic: return "ar-SA"
        case .hindi: return "hi-IN"
        case .indonesian: return "id-ID"
        case .thai: return "th-TH"
        case .turkish: return "tr-TR"
        case .vietnamese: return "vi-VN"
        case .ukrainian: return "uk-UA"
        case .czech: return "cs-CZ"
        case .danish: return "da-DK"
        case .filipino: return "fil-PH"
        case .finnish: return "fi-FI"
        case .icelandic: return "is-IS"
        case .malay: return "ms-MY"
        case .norwegian: return "nb-NO"
        case .polish: return "pl-PL"
        case .swedish: return "sv-SE"
        }
    }
}

enum FeedbackSoundCue: String, CaseIterable, Identifiable {
    case ready
    case release
    case done
    case issue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ready: return OpenTypeL10n.text("开始说话", english: "Start speaking")
        case .release: return OpenTypeL10n.text("结束录音", english: "Stop recording")
        case .done: return OpenTypeL10n.text("完成写入", english: "Inserted")
        case .issue: return OpenTypeL10n.text("出现问题", english: "Issue")
        }
    }

    var resourceName: String {
        switch self {
        case .ready: return "OpenTypeReady"
        case .release: return "OpenTypeRelease"
        case .done: return "OpenTypeDone"
        case .issue: return "OpenTypeIssue"
        }
    }

    var volume: Float {
        switch self {
        case .ready: return 0.70
        case .release: return 0.64
        case .done: return 0.64
        case .issue: return 0.58
        }
    }

    var fallbackSystemSound: String {
        switch self {
        case .ready: return "Tink"
        case .release: return "Pop"
        case .done: return "Glass"
        case .issue: return "Basso"
        }
    }
}

enum ProcessingState: Equatable {
    case idle
    case modeChanged
    case listening
    case transcribing
    case transforming
    case inserting
    case success
    case copied
    /// A non-blocking acknowledgment that an Agent-mode task was handed off
    /// to the detached `/agent/run` call — distinct from `.success`/`.copied`
    /// because nothing has actually finished yet. See `AppModel.dispatchAgentRun`.
    case dispatched(String)
    case cancelled(String)
    case failure(String)

    var title: String {
        switch self {
        case .idle: return OpenTypeL10n.text("就绪", english: "Ready")
        case .modeChanged: return OpenTypeL10n.text("已切换模式", english: "Mode changed")
        case .listening: return OpenTypeL10n.text("正在听", english: "Listening")
        case .transcribing: return OpenTypeL10n.text("正在识别", english: "Transcribing")
        case .transforming: return OpenTypeL10n.text("正在整理", english: "Refining")
        case .inserting: return OpenTypeL10n.text("正在写入", english: "Inserting")
        case .success: return OpenTypeL10n.text("完成", english: "Done")
        case .copied: return OpenTypeL10n.text("已复制", english: "Copied")
        case .dispatched: return OpenTypeL10n.text("已下发", english: "Dispatched")
        case .cancelled: return OpenTypeL10n.text("未执行", english: "Not run")
        case .failure: return OpenTypeL10n.text("出现问题", english: "Something went wrong")
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "waveform"
        case .modeChanged: return "arrow.triangle.2.circlepath"
        case .listening: return "mic.fill"
        case .transcribing: return "waveform.badge.magnifyingglass"
        case .transforming: return "sparkles"
        case .inserting: return "text.cursor"
        case .success: return "circle.fill"
        case .copied: return "doc.on.clipboard.fill"
        case .dispatched: return "paperplane.fill"
        case .cancelled: return "circle.slash"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    func overlayDetail(for mode: InputMode) -> String {
        switch self {
        case .dispatched(let message):
            return message
        case .cancelled(let message):
            return message
        case .failure(let message):
            return message
        default:
            return mode.title
        }
    }
}

enum OutputDeliveryStrategy: Equatable {
    case automaticInsert
    case clipboard
}

enum OutputDeliveryPolicy {
    static func strategy(
        for mode: InputMode,
        automaticallyInsert: Bool
    ) -> OutputDeliveryStrategy {
        guard automaticallyInsert else { return .clipboard }
        switch mode {
        case .ask:
            // `ask` answers are delivered to the floating popup + clipboard.
            // Auto-pasting a multi-line answer into whatever field happens to
            // be focused (often a chat box) is a high-misfire action, so this
            // mode never auto-inserts regardless of the setting.
            return .clipboard
        case .transcribe, .agent:
            return .automaticInsert
        }
    }

    /// Whether the generated result should be copied to the clipboard.
    ///
    /// Clipboard availability is a product-level guarantee, so the default is
    /// always `true`. The only case that skips the copy is when the user has
    /// explicitly opted out of retaining the clipboard after a *successful*
    /// insert (`retainClipboardAfterInsert == true`) — there the result is
    /// already in the focused field and the user chose to keep their original
    /// clipboard untouched. If the insert did not land, the clipboard copy is
    /// still made so the result is never lost.
    static func retainsClipboardCopy(
        for mode: InputMode,
        insertSucceeded: Bool,
        retainClipboardAfterInsert: Bool
    ) -> Bool {
        !(retainClipboardAfterInsert && insertSucceeded)
    }

    /// Back-compatible entry point: with no opt-out configured, the clipboard
    /// always retains the result. Equivalent to the multi-argument form with
    /// `retainClipboardAfterInsert == false`.
    static func retainsClipboardCopy(for mode: InputMode) -> Bool {
        retainsClipboardCopy(
            for: mode,
            insertSucceeded: false,
            retainClipboardAfterInsert: false
        )
    }

    /// Whether auto-insert should proceed, given the app captured at recording
    /// time versus the app frontmost at delivery time. If focus moved to a
    /// different app after capture, the insert is downgraded to clipboard-only
    /// so the result never lands in the wrong app. A `nil` captured id means the
    /// captured identity is unknown, so the existing allow-insert behavior is
    /// preserved.
    static func shouldInsert(
        capturedBundleId: String?,
        frontmostBundleId: String?
    ) -> Bool {
        guard let capturedBundleId else { return true }
        return capturedBundleId == frontmostBundleId
    }

}

enum PermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied

    var title: String {
        switch self {
        case .notDetermined: return OpenTypeL10n.text("待授权", english: "Permission needed")
        case .granted: return OpenTypeL10n.text("已就绪", english: "Ready")
        case .denied: return OpenTypeL10n.text("未授权", english: "Not allowed")
        }
    }

    var symbol: String {
        switch self {
        case .notDetermined: return "circle.dashed"
        case .granted: return "circle.fill"
        case .denied: return "exclamationmark.circle.fill"
        }
    }
}

enum HotKeyPreset: String, CaseIterable, Codable, Identifiable {
    case leftOption
    case fnKey
    case doubleControl
    case doubleOption
    case doubleShift
    case controlShiftSpace
    case optionSpace
    case controlSpace
    case controlOptionSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftOption: return OpenTypeL10n.text("左 Option", english: "Left Option")
        case .fnKey: return OpenTypeL10n.text("fn（地球键）", english: "fn (Globe)")
        case .doubleControl: return OpenTypeL10n.text("双击 Ctrl", english: "Double-tap Ctrl")
        case .doubleOption: return OpenTypeL10n.text("双击 Option", english: "Double-tap Option")
        case .doubleShift: return OpenTypeL10n.text("双击 Shift", english: "Double-tap Shift")
        case .controlShiftSpace: return "⌃⇧ Space"
        case .optionSpace: return "⌥ Space"
        case .controlSpace: return "⌃ Space"
        case .controlOptionSpace: return "⌃⌥ Space"
        }
    }

    var keys: [String] {
        switch self {
        case .leftOption: return ["左 Option"]
        case .fnKey: return ["fn"]
        case .doubleControl: return ["Ctrl × 2"]
        case .doubleOption: return ["Option × 2"]
        case .doubleShift: return ["Shift × 2"]
        case .controlShiftSpace: return ["⌃", "⇧", "Space"]
        case .optionSpace: return ["⌥", "Space"]
        case .controlSpace: return ["⌃", "Space"]
        case .controlOptionSpace: return ["⌃", "⌥", "Space"]
        }
    }

    var usesDoubleModifierTap: Bool {
        switch self {
        case .doubleControl, .doubleOption, .doubleShift: return true
        default: return false
        }
    }

    var usesModifierOnlyEventTap: Bool {
        self == .leftOption || self == .fnKey || usesDoubleModifierTap
    }

    /// Hold to talk, release to finish — plus double-tap to start hands-free.
    /// Named for left Option, which was the first preset to use it; `fnKey`
    /// runs the identical gesture off the secondary-fn flag instead.
    var usesOptionHybridGesture: Bool {
        self == .leftOption || self == .fnKey
    }

    var note: String {
        switch self {
        case .leftOption:
            return OpenTypeL10n.text("长按说话、松开完成；双击开始，再按任意普通键结束。右 Option 保持空闲。", english: "Hold to talk and release to finish; double-tap to start and press any regular key to stop. Right Option stays free.")
        case .fnKey:
            return OpenTypeL10n.text("长按 fn 说话、松开完成；双击 fn 开始，再按任意普通键结束。若「系统设置 › 键盘 › 按下 🌐 键时」设为听写或输入法切换，建议改为「不执行任何操作」。", english: "Hold fn to talk and release to finish; double-tap fn to start and press any regular key to stop. If System Settings › Keyboard › \"Press 🌐 key to\" is set to Dictation or input switching, change it to \"Do Nothing\".")
        case .doubleControl:
            return OpenTypeL10n.text("推荐。两次轻点任意一侧 Ctrl。", english: "Recommended. Tap either Ctrl key twice.")
        case .doubleOption:
            return OpenTypeL10n.text("可能与部分输入法的 Option 快捷键冲突。", english: "May conflict with Option shortcuts in some input methods.")
        case .doubleShift:
            return OpenTypeL10n.text("适合不常连续使用 Shift 的键盘习惯。", english: "Useful if you rarely tap Shift twice in succession.")
        case .controlShiftSpace:
            return OpenTypeL10n.text("不占用 Option；没有辅助功能权限时可按住说话。", english: "Keeps Option free; hold to talk without Accessibility permission.")
        case .optionSpace, .controlSpace, .controlOptionSpace:
            return OpenTypeL10n.text("按一次开始；授权辅助功能后，按任意普通键结束。", english: "Press once to start; with Accessibility permission, press any regular key to stop.")
        }
    }
}

enum HotKeyBehavior: Equatable {
    case optionHybrid
    case doubleTapThenAnyKey
    case pressThenAnyKey
    case holdToTalk
}

struct CapturedContext {
    var selectedText: String?
    var applicationName: String
    var bundleIdentifier: String?
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let mode: InputMode
    let applicationName: String
    let transcript: String
    let result: String
    let contextPreview: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        mode: InputMode,
        applicationName: String,
        transcript: String,
        result: String,
        contextPreview: String?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.applicationName = applicationName
        self.transcript = transcript
        self.result = result
        self.contextPreview = contextPreview
    }
}

struct AgentTaskMemory: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let request: String
    let outcome: String
    let applicationName: String
    let referencePreview: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        request: String,
        outcome: String,
        applicationName: String,
        referencePreview: String?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.request = request
        self.outcome = outcome
        self.applicationName = applicationName
        self.referencePreview = referencePreview
    }

    var estimatedPromptCharacters: Int {
        min(request.count, 900)
            + min(outcome.count, 2_400)
            + min(referencePreview?.count ?? 0, 600)
            + applicationName.count
            + 120
    }
}

struct MemoryEvent: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let mode: InputMode
    let applicationName: String
    let bundleIdentifier: String?
    let rawTranscript: String
    let effectiveInput: String
    let selectedContext: String?
    let result: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        mode: InputMode,
        applicationName: String,
        bundleIdentifier: String?,
        rawTranscript: String,
        effectiveInput: String,
        selectedContext: String?,
        result: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.rawTranscript = rawTranscript
        self.effectiveInput = effectiveInput
        self.selectedContext = selectedContext
        self.result = result
    }
}

enum ProfileLanguagePreference: String, CaseIterable, Codable, Identifiable {
    case followInput
    case chinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followInput:
            return OpenTypeL10n.text(
                "跟随当前模式与输入",
                english: "Follow the current mode and input"
            )
        case .chinese:
            return OpenTypeL10n.text(
                "中文（仅在未指定时）",
                english: "Chinese (only when unspecified)"
            )
        case .english:
            return OpenTypeL10n.text(
                "English（仅在未指定时）",
                english: "English (only when unspecified)"
            )
        }
    }
}

struct OwnerProfile: Codable, Equatable {
    var identityAndWork: String
    var communicationStyle: String
    var importantTerms: String
    var preferredLanguage: ProfileLanguagePreference
    var updatedAt: Date?

    init(
        identityAndWork: String,
        communicationStyle: String,
        importantTerms: String,
        preferredLanguage: ProfileLanguagePreference = .followInput,
        updatedAt: Date? = nil
    ) {
        self.identityAndWork = identityAndWork
        self.communicationStyle = communicationStyle
        self.importantTerms = importantTerms
        self.preferredLanguage = preferredLanguage
        self.updatedAt = updatedAt
    }

    static let empty = OwnerProfile(
        identityAndWork: "",
        communicationStyle: "",
        importantTerms: "",
        preferredLanguage: .followInput,
        updatedAt: nil
    )

    var isEmpty: Bool {
        let textFieldsAreEmpty = [
            identityAndWork,
            communicationStyle,
            importantTerms
        ].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return textFieldsAreEmpty && preferredLanguage == .followInput
    }
}

struct MemoryInsights: Codable, Equatable {
    let observedTaskCount: Int
    let commonTerms: [String]
    let taskDomains: [String]
    let languagePattern: String?
    let stylePreferences: [String]
    let updatedAt: Date

    static let empty = MemoryInsights(
        observedTaskCount: 0,
        commonTerms: [],
        taskDomains: [],
        languagePattern: nil,
        stylePreferences: [],
        updatedAt: .distantPast
    )

    var isEmpty: Bool {
        commonTerms.isEmpty
            && taskDomains.isEmpty
            && languagePattern == nil
            && stylePreferences.isEmpty
    }
}

struct MemoryProfileContext: Equatable {
    let ownerProfile: OwnerProfile
    let insights: MemoryInsights

    static let empty = MemoryProfileContext(
        ownerProfile: .empty,
        insights: .empty
    )

    var isEmpty: Bool {
        ownerProfile.isEmpty && insights.isEmpty
    }
}

enum OpenTypeError: LocalizedError {
    case missingCredential
    case microphoneDenied
    case recordingFailed(String)
    case emptyRecording
    case invalidResponse
    case service(String)
    case accessibilityRequired
    case selectionRequired(InputMode)
    case missingEditInstruction

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "请先在设置中配置当前选择的语音与文字服务"
        case .microphoneDenied:
            return "需要麦克风权限才能录音"
        case .recordingFailed(let detail):
            return "录音失败：\(detail)"
        case .emptyRecording:
            return "没有听到有效语音"
        case .invalidResponse:
            return "云端返回了无法识别的结果"
        case .service(let detail):
            return detail
        case .accessibilityRequired:
            return "请先开启辅助功能权限，再使用选中文字或自动写入"
        case .selectionRequired:
            // Unreachable with the current 3-mode set (none of
            // transcribe/ask/agent require a selection) but kept for
            // forward compatibility / defensive completeness.
            return "这个模式需要先选中文字"
        case .missingEditInstruction:
            return "没有听到明确的修改指令，选中文字保持不变"
        }
    }
}

enum ErrorMessagePresenter {
    static func message(for error: Error) -> String {
        if let openTypeError = error as? OpenTypeError {
            switch openTypeError {
            case .service(let detail):
                return serviceMessage(detail)
            default:
                return openTypeError.errorDescription ?? "出现了一个问题，请再试一次"
            }
        }

        if let sidecarError = error as? SidecarClientError {
            switch sidecarError {
            case .processFailedToStart:
                return "本地服务未能启动，请重启应用后再试一次"
            case .timedOutWaitingForReadiness:
                return "本地服务启动超时，请重启应用后再试一次"
            case .requestFailed:
                return "无法连接到本地服务，请重启应用后再试一次"
            case .responseDecodingFailed, .emptyResponse:
                return "本地服务响应异常，请再试一次"
            }
        }

        return error.localizedDescription
    }

    private static func serviceMessage(_ detail: String) -> String {
        let normalized = detail.lowercased()
        if normalized.contains("invalidparameter")
            || normalized.contains("does not support this input") {
            return "这段语音没有识别成功，请再说一次"
        }
        if normalized.contains("timeout") || normalized.contains("timed out") {
            return "云端处理超时，请再试一次"
        }
        if normalized.contains("rate limit") || normalized.contains("throttl") {
            return "请求太频繁了，稍等几秒再试"
        }
        if normalized.contains("unauthorized")
            || normalized.contains("invalid api-key")
            || normalized.contains("invalid api key") {
            return "服务商连接已失效，请检查 API key 配置"
        }
        return detail
    }
}

/// One row of the sidecar's `GET /memory/terms` response — the entity
/// dictionary shown read-only in the Settings "Memory" panel. Mirrors (a
/// subset of) `EntityTerm` from `sidecar/src/memory/MemoryStore.ts`.
struct EntityTermSummary: Decodable, Identifiable {
    let canonicalTerm: String
    let aliases: [String]
    let category: String
    let confidence: Double

    var id: String { canonicalTerm }
}

/// One row of the sidecar's `GET /memory/consolidation-runs` response — the
/// consolidation run log shown read-only in the Settings "Memory" panel.
/// Mirrors `ConsolidationRunSummary` from `sidecar/src/memory/MemoryStore.ts`
/// (which deliberately omits `snapshotBeforeJSON`, large internal rollback
/// state not meant for display). `ranAt`/`rolledBackAt` are epoch
/// milliseconds, matching `Date.now()` on the sidecar side.
/// One entry of the sidecar's `POST /agent/run` response `steps` array — the
/// step-by-step log of a single Agent Runtime call, shown read-only in the
/// Task List panel (`AgentTaskLogView`). Mirrors the agent loop's internal
/// step log on the sidecar side (`thinking`/`tool_call`/`tool_result`/
/// `done`/`error`).
struct AgentStepSummary: Decodable, Equatable {
    let type: String
    let detail: String
}

struct ConsolidationRunSummary: Decodable, Identifiable {
    let id: Int
    let ranAt: Int
    let eventsConsidered: Int
    let candidatesProposed: Int
    let candidatesAccepted: Int
    let summary: String
    let rolledBackAt: Int?
}

/// Mirrors the sidecar's `ConsolidationResult` (`sidecar/src/memory/consolidator.ts`),
/// as returned by `POST /memory/consolidate-now`. `reason` is only set when
/// `aborted` is true (the LLM call failed, or its response didn't parse).
struct ConsolidationResultSummary: Decodable {
    let ranRunId: Int?
    let eventsConsidered: Int
    let candidatesProposed: Int
    let candidatesAccepted: Int
    let aborted: Bool
    let reason: String?
}

/// Transient success/failure indicator for the Settings "Memory" panel's
/// manual "Consolidate now" button (`MemoryPanelView`) — cleared on the next
/// trigger, not persisted; the persistent record is `memoryConsolidationRuns`.
enum ConsolidateNowStatus: Equatable {
    case idle
    case running
    case succeeded(String)
    case failed(String)
}

/// Mirrors the sidecar's `Conversation` (`sidecar/src/memory/conversations.ts`)
/// -- one row of `GET /conversations?kind=ask|agent`, the list backing the
/// Q&A and Agent tabs (`Views.swift`). `createdAt`/`updatedAt` are
/// milliseconds-since-epoch, matching `ConsolidationRunSummary.ranAt`'s
/// existing convention for sidecar timestamps.
struct ConversationSummary: Decodable, Identifiable, Equatable {
    let id: Int
    let kind: String
    let title: String
    let createdAt: Int
    let updatedAt: Int
}

/// Mirrors the sidecar's `ConversationMessage`.
struct ConversationMessageSummary: Decodable, Identifiable, Equatable {
    let id: Int
    let conversationId: Int
    let role: String
    let content: String
    let createdAt: Int
}

/// Mirrors the sidecar's `ConversationWithMessages` -- the full thread
/// returned by `GET /conversations/:id`, rendered by the Q&A/Agent tabs'
/// thread view.
struct ConversationDetail: Decodable, Identifiable, Equatable {
    let id: Int
    let kind: String
    let title: String
    let createdAt: Int
    let updatedAt: Int
    let messages: [ConversationMessageSummary]
}

// MARK: - Provider configuration (Whisper / LLM)

/// Which shape a user-configured LLM provider speaks — mirrors the
/// sidecar's `LLMProviderType` (`sidecar/src/provider/types.ts`): either the
/// Anthropic Messages API (`/v1/messages`) or the OpenAI-compatible Chat
/// Completions API (`/chat/completions`), which DeepSeek/OpenAI itself/many
/// self-hosted servers all share. Raw values match the sidecar's JSON
/// literals exactly since they're sent as-is in request bodies.
enum LLMProviderType: String, CaseIterable, Identifiable, Codable {
    case anthropic
    case openaiCompatible = "openai-compatible"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic:
            return "Anthropic"
        case .openaiCompatible:
            return OpenTypeL10n.text("OpenAI 兼容", english: "OpenAI-compatible")
        }
    }

    /// Shown as placeholder text in the base-URL field — a starting point,
    /// not a hardcoded default that's silently submitted.
    var baseUrlPlaceholder: String {
        switch self {
        case .anthropic:
            return "https://api.anthropic.com"
        case .openaiCompatible:
            return "https://api.deepseek.com"
        }
    }
}

/// Mirrors the sidecar's `WhisperMode` (`sidecar/src/provider/configStore.ts`).
enum WhisperMode: String, CaseIterable, Identifiable, Codable {
    case local
    case remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local:
            return OpenTypeL10n.text("本机（MLX-Whisper）", english: "Local (MLX-Whisper)")
        case .remote:
            return OpenTypeL10n.text("远程 API", english: "Remote API")
        }
    }
}

/// Mirrors the sidecar's `GET /config/status` response.
struct ProviderConfigStatus: Decodable, Equatable {
    let llmConfigured: Bool
    let whisperConfigured: Bool
    let ready: Bool
}

/// Mirrors the sidecar's `GET`/`PUT /config/llm` response shape. `type`/
/// `baseUrl`/`model`/`apiKeyMasked` are only present when `configured` is
/// true — the raw API key is never sent back to Swift, only a masked form.
struct LLMConfigSummary: Decodable, Equatable {
    let configured: Bool
    let type: LLMProviderType?
    let baseUrl: String?
    let model: String?
    let apiKeyMasked: String?
}

/// Mirrors the sidecar's `GET`/`PUT /config/whisper` response shape.
struct WhisperConfigSummary: Decodable, Equatable {
    let configured: Bool
    let mode: WhisperMode?
    let baseUrl: String?
    let model: String?
    let apiKeyMasked: String?
}

/// Mirrors the sidecar's `{success, error?}` shape returned by both
/// `POST /config/llm/test` and `POST /config/whisper/test`.
struct ProviderTestResultSummary: Decodable, Equatable {
    let success: Bool
    let error: String?
}

/// Mirrors the sidecar's `POST /config/llm/models` response.
struct ProviderModelListSummary: Decodable, Equatable {
    let models: [String]
    let fallback: Bool
}
