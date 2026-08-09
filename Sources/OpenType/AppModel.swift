import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: ProcessingState = .idle
    @Published private(set) var shortcutStatus = "正在注册…"
    @Published private(set) var sidecarStatus = "正在启动…"
    @Published private(set) var shortcutKeys = HotKeyPreset.controlShiftSpace.keys
    @Published private(set) var shortcutBehavior: HotKeyBehavior = .holdToTalk
    @Published private(set) var shortcutReady = false
    @Published private(set) var preferredShortcutActive = false
    @Published private(set) var microphonePermission: PermissionStatus = .notDetermined
    @Published private(set) var speechRecognitionPermission: PermissionStatus = .notDetermined
    @Published private(set) var isPracticeSession = false
    @Published private(set) var lastResultWasPractice = false
    @Published private(set) var lastResult = ""
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastApplication = ""
    @Published private(set) var memoryTerms: [EntityTermSummary] = []
    @Published private(set) var memoryConsolidationRuns: [ConsolidationRunSummary] = []
    /// Backs the Settings "Memory" panel's manual "Consolidate now" button
    /// (`MemoryPanelView`) — a brief, in-place success/failure indicator, not
    /// a persistent log (that's what `memoryConsolidationRuns` is for).
    @Published private(set) var consolidateNowStatus: ConsolidateNowStatus = .idle
    /// Bounded history of recent Agent (`/agent/run`) dispatches, most recent
    /// first — see `AgentRunTracking.swift`. Replaces the old
    /// `lastAgentRunSteps` (singular, overwritten every run) now that Agent
    /// dispatch is non-blocking and multiple runs can be in flight or queued
    /// up in history at once.
    @Published private(set) var agentRuns: [AgentRunRecord] = []
    /// Count of `agentRuns` still `.running` — backs the lightweight menubar
    /// badge (`MenuBarStatusIcon`). Recomputed alongside every `agentRuns`
    /// mutation rather than as a computed property so the menubar icon's
    /// Combine pipeline (`OpenTypeApp.observeStatusPresentation`) has a
    /// `@Published` value of its own to subscribe to.
    @Published private(set) var runningAgentRunCount = 0
    /// Set when a completion notification is tapped (or the Task List's own
    /// "N running" affordance is used) so the app window's Task List panel
    /// can scroll to and briefly highlight that specific run.
    @Published var focusedAgentRunID: UUID?
    @Published var selectedTab: AppTab = .home
    /// Drives the floating Ask/Agent popup (`AskPanelController`). `nil`
    /// hides it; non-nil shows it; `answer == nil` is the "thinking" state.
    /// The `didSet` keeps `askPanel` (an imperative `NSPanel` owner, not an
    /// `ObservableObject` itself — same split as `overlay`/`OverlayController`)
    /// in sync with this single source of truth.
    @Published private(set) var askPanelState: AskPanelState? {
        didSet { syncAskPanel() }
    }

    let configuration: AppConfiguration
    let history: HistoryStore
    let agentMemory: AgentMemoryStore
    private let auditStore = ImmutableAuditStore()

    private let sidecarClient = SidecarClient()
    private let audioRecorder = AudioRecorder()
    private let liveSpeechTranscriber = LiveSpeechTranscriber()
    private let contextBridge = ContextBridge()
    private let hotKey = GlobalHotKey()
    private let overlay = OverlayController()
    private let askPanel = AskPanelController()
    private var customSounds: [String: NSSound] = [:]
    private var activeFeedbackSound: NSSound?
    private var capturedContext = CapturedContext(
        selectedText: nil,
        applicationName: "Unknown app",
        bundleIdentifier: nil
    )
    private var processingTask: Task<Void, Never>?
    private var accessibilityPollTimer: Timer?
    private var activeMode: InputMode?
    private var didStart = false
    private var isHotKeyHeld = false
    private var isStartingRecording = false
    /// Detached, un-awaited units of work for in-flight `/agent/run` calls,
    /// keyed by `AgentRunRecord.id`. Deliberately not awaited by
    /// `process(audioURL:)` — see `dispatchAgentRun(...)` — so a slow Agent
    /// task never keeps the app's general recording pipeline busy. Entries
    /// are removed once their run finishes (success or failure); nothing
    /// currently cancels them early (e.g. on quit), matching the sidecar's
    /// own agent loop continuing server-side regardless of whether the Swift
    /// side is still listening for the HTTP response.
    private var runningAgentTasks: [UUID: Task<Void, Never>] = [:]
    private let agentNotificationDelegate = AgentNotificationDelegate()

    /// Set by `OpenTypeAppDelegate` once the main app window controller
    /// exists (Part A). Lets both the menubar popover's gear button and
    /// `focusAgentRun(_:)` (a tapped Agent-completion notification) open the
    /// same real, resizable window without `AppModel` owning any AppKit
    /// window/view-controller state itself.
    var onOpenMainWindowRequested: (() -> Void)?

    var accessibilityGranted: Bool {
        contextBridge.accessibilityGranted
    }

    var setupReady: Bool {
        microphonePermission == .granted
            && accessibilityGranted
            && (!configuration.liveCaptionsEnabled
                || speechRecognitionPermission == .granted)
            && shortcutReady
            && preferredShortcutActive
    }

    var canTogglePractice: Bool {
        if isPracticeSession, state == .listening { return true }
        return !isBusy && !isStartingRecording
    }

    var canUndo: Bool {
        !lastResult.isEmpty
    }

    init() {
        self.configuration = AppConfiguration()
        self.history = HistoryStore()
        self.agentMemory = AgentMemoryStore()
        self.agentMemory.importHistoryIfNeeded(self.history.entries)
        self.agentMemory.refreshOwnerProfileIfNeeded(
            enabled: self.configuration.agentMemoryEnabled
                && self.configuration.automaticOwnerProfileUpdates,
            personalDictionary: self.configuration.personalDictionary
        )
        self.overlay.updateColorTheme(self.configuration.colorTheme)
        self.overlay.updateInterfaceLanguage(self.configuration.interfaceLanguage)
        self.askPanel.updateColorTheme(self.configuration.colorTheme)
        self.askPanel.updateInterfaceLanguage(self.configuration.interfaceLanguage)
        self.askPanel.onRequestDismiss = { [weak self] in
            self?.askPanelState = nil
        }
        microphonePermission = audioRecorder.permissionStatus
        speechRecognitionPermission = liveSpeechTranscriber.permissionStatus
        liveSpeechTranscriber.onTranscript = { [weak self] text in
            self?.overlay.updateLiveTranscript(text)
        }
        liveSpeechTranscriber.onAudioLevel = { [weak self] level in
            self?.overlay.updateAudioLevel(level)
        }
        agentNotificationDelegate.onAgentRunTapped = { [weak self] runID in
            self?.focusAgentRun(runID)
        }
        UNUserNotificationCenter.current().delegate = agentNotificationDelegate
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in
            // Best-effort: an Agent-completion notification is a convenience
            // on top of the in-app Task List panel and the always-updated
            // menubar badge, not the only way to learn a run finished, so a
            // denied/failed authorization is silently ignored rather than
            // surfaced as an error anywhere.
        }
        start()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sidecarClient.start()
                self.sidecarStatus = OpenTypeL10n.text(
                    "Sidecar 已就绪",
                    english: "Sidecar ready"
                )
            } catch {
                self.sidecarStatus = OpenTypeL10n.text(
                    "Sidecar 启动失败：\(error.localizedDescription)",
                    english: "Sidecar failed to start: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Stops the sidecar child process. Called from the app delegate's
    /// `applicationWillTerminate` so the sidecar doesn't outlive the app.
    func stopSidecar() {
        sidecarClient.stop()
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        hotKey.onPressed = { [weak self] in
            self?.shortcutBehavior = .holdToTalk
            self?.hotKeyPressed()
        }
        hotKey.onReleased = { [weak self] in
            self?.hotKeyReleased()
        }
        hotKey.onToggle = { [weak self] in
            self?.shortcutBehavior = .pressThenAnyKey
            self?.hotKeyToggled()
        }
        hotKey.onStopRequested = { [weak self] in
            self?.hotKeyReleased()
        }
        hotKey.onCycleMode = { [weak self] in
            self?.cycleMode()
        }
        let installed = hotKey.install(preference: configuration.hotKeyPreset)
        updateShortcutPresentation(
            preference: configuration.hotKeyPreset,
            installed: installed
        )
    }

    func hotKeyPressed() {
        guard state != .listening else { return }
        guard !isBusy, !isStartingRecording else { return }

        let context = contextBridge.capture()
        let mode = configuration.selectedMode
        if mode.requiresSelection, !contextBridge.accessibilityGranted {
            fail(OpenTypeError.accessibilityRequired)
            return
        }
        if mode.requiresSelection,
           context.selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty != false {
            fail(OpenTypeError.selectionRequired(mode))
            return
        }

        isHotKeyHeld = true
        beginRecording(context: context, mode: mode, practice: false)
    }

    func togglePracticeDictation() {
        if isPracticeSession, state == .listening {
            isHotKeyHeld = false
            finishRecording()
            return
        }
        guard canTogglePractice else { return }

        isHotKeyHeld = true
        beginRecording(
            context: CapturedContext(
                selectedText: nil,
                applicationName: "OpenType 试用",
                bundleIdentifier: "ai.rain.opentype"
            ),
            mode: .ask,
            practice: true
        )
    }

    private func beginRecording(
        context: CapturedContext,
        mode: InputMode,
        practice: Bool
    ) {
        isStartingRecording = true
        capturedContext = context
        activeMode = mode
        isPracticeSession = practice
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.audioRecorder.start()
                self.microphonePermission = self.audioRecorder.permissionStatus
                self.isStartingRecording = false
                self.setState(.listening)
                if self.configuration.liveCaptionsEnabled,
                   self.speechRecognitionPermission == .granted {
                    try? self.liveSpeechTranscriber.start(
                        localeIdentifier: self.configuration
                            .transcriptionLanguage
                            .appleLocaleIdentifier
                    )
                }
                self.playFeedbackSound(.ready)
                if !self.isHotKeyHeld, !self.isPracticeSession {
                    self.finishRecording()
                }
            } catch {
                self.microphonePermission = self.audioRecorder.permissionStatus
                self.isStartingRecording = false
                self.fail(error)
            }
        }
    }

    func hotKeyReleased() {
        isHotKeyHeld = false
        shortcutBehavior = hotKey.behavior
        guard state == .listening else { return }
        finishRecording()
    }

    func hotKeyToggled() {
        if state == .listening {
            hotKeyReleased()
        } else if !isBusy, !isStartingRecording {
            hotKeyPressed()
        } else {
            shortcutBehavior = hotKey.behavior
        }
    }

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        isHotKeyHeld = false
        isStartingRecording = false
        isPracticeSession = false
        activeMode = nil
        shortcutBehavior = hotKey.behavior
        audioRecorder.cancel()
        liveSpeechTranscriber.stop()
        setState(.idle)
        overlay.hide()
    }

    func selectMode(_ mode: InputMode) {
        configuration.selectedMode = mode
        overlay.show(state: .modeChanged, mode: mode)
    }

    func cycleMode() {
        guard state != .listening, !isBusy, !isStartingRecording else { return }
        selectMode(configuration.selectedMode.next)
    }

    func requestAccessibility() {
        contextBridge.requestAccessibilityPermission()
        contextBridge.openAccessibilitySettings()
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.contextBridge.accessibilityGranted else { return }
                timer.invalidate()
                self.accessibilityPollTimer = nil
                self.refreshPreferredShortcut()
                self.objectWillChange.send()
            }
        }
        objectWillChange.send()
    }

    func requestMicrophonePermission() {
        if microphonePermission == .denied {
            contextBridge.openMicrophoneSettings()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            _ = await self.audioRecorder.requestPermission()
            self.microphonePermission = self.audioRecorder.permissionStatus
        }
    }

    func requestSpeechRecognitionPermission() {
        if speechRecognitionPermission == .denied {
            liveSpeechTranscriber.openPermissionSettings()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            _ = await self.liveSpeechTranscriber.requestPermission()
            self.speechRecognitionPermission = self.liveSpeechTranscriber.permissionStatus
            self.objectWillChange.send()
        }
    }

    func refreshPermissionStatus() {
        microphonePermission = audioRecorder.permissionStatus
        speechRecognitionPermission = liveSpeechTranscriber.permissionStatus
        if contextBridge.accessibilityGranted,
           (!preferredShortcutActive || shortcutBehavior == .holdToTalk) {
            refreshPreferredShortcut()
        }
        objectWillChange.send()
    }

    func changeHotKey(_ preset: HotKeyPreset) {
        guard state != .listening, !isBusy, !isStartingRecording else {
            shortcutStatus = OpenTypeL10n.text("请先结束当前语音输入，再修改快捷键", english: "Finish the current voice input before changing the shortcut")
            persistShortcutStatus()
            return
        }

        let previous = configuration.hotKeyPreset
        let installed = hotKey.reinstall(preference: preset)
        if installed {
            configuration.hotKeyPreset = preset
            updateShortcutPresentation(preference: preset, installed: true)
            return
        }

        let restored = hotKey.reinstall(preference: previous)
        updateShortcutPresentation(preference: previous, installed: restored)
        shortcutStatus = OpenTypeL10n.text(
            "\(preset.title) 已被系统或其他应用占用，已恢复 \(previous.title)",
            english: "\(preset.title) is used by macOS or another app. Restored \(previous.title)."
        )
        persistShortcutStatus()
    }

    func changeColorTheme(_ theme: AppColorTheme) {
        guard configuration.colorTheme != theme else { return }
        configuration.colorTheme = theme
        overlay.updateColorTheme(theme)
        askPanel.updateColorTheme(theme)
    }

    func changeInterfaceLanguage(_ language: InterfaceLanguage) {
        guard configuration.interfaceLanguage != language else { return }
        configuration.interfaceLanguage = language
        overlay.updateInterfaceLanguage(language)
        askPanel.updateInterfaceLanguage(language)
        updateShortcutPresentation(
            preference: configuration.hotKeyPreset,
            installed: shortcutReady
        )
    }

    func changeTranscriptionLanguage(_ language: TranscriptionLanguage) {
        configuration.transcriptionLanguage = language
    }

    func changeAutomaticOwnerProfileUpdates(_ enabled: Bool) {
        configuration.automaticOwnerProfileUpdates = enabled
        guard enabled, configuration.agentMemoryEnabled else { return }
        agentMemory.refreshOwnerProfileIfNeeded(
            enabled: true,
            personalDictionary: configuration.personalDictionary
        )
    }

    func copyLastResult() {
        guard !lastResult.isEmpty else { return }
        contextBridge.copyToClipboard(lastResult)
    }

    func copy(_ text: String) {
        contextBridge.copyToClipboard(text)
    }

    func previewFeedbackSound(_ cue: FeedbackSoundCue) {
        playFeedbackSound(cue)
    }

    func changeMuted(_ muted: Bool) {
        configuration.isMuted = muted
        if muted {
            activeFeedbackSound?.stop()
            activeFeedbackSound = nil
        }
    }

    func resetHistory() {
        history.clear()
    }

    func resetAgentMemory() {
        agentMemory.clear()
    }

    func reuse(_ entry: HistoryEntry) {
        lastResult = entry.result
        lastTranscript = entry.transcript
        lastApplication = entry.applicationName
        lastResultWasPractice = false
        contextBridge.copyToClipboard(entry.result)
    }

    func undo() {
        do {
            try contextBridge.undoLastChange()
        } catch {
            fail(error)
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Opens the real, resizable app window (Part A) — settings, Memory
    /// panel, and Agent history all live there now, not in the menubar
    /// popover. Called from the popover's gear button.
    func openMainWindow() {
        onOpenMainWindowRequested?()
    }

    /// Opens the main app window, switches to the Settings tab (where the
    /// Task List panel lives), and marks `runID` to be scrolled to and
    /// briefly highlighted — the target of a tapped "Agent finished"
    /// notification (`AgentNotificationDelegate.onAgentRunTapped`).
    func focusAgentRun(_ runID: UUID) {
        focusedAgentRunID = runID
        selectedTab = .settings
        openMainWindow()
    }

    /// Explicit dismissal entry point for the Ask/Agent popup, in addition to
    /// the panel's own close button / Escape / click-outside handling.
    func dismissAskPanel() {
        askPanelState = nil
    }

    private func syncAskPanel() {
        if let askPanelState {
            askPanel.show(askPanelState)
        } else {
            askPanel.hide()
        }
    }

    private var isBusy: Bool {
        switch state {
        case .transcribing, .transforming, .inserting:
            return true
        default:
            return false
        }
    }

    private func finishRecording() {
        hotKey.setRecordingActive(false)
        liveSpeechTranscriber.stop()
        do {
            let audioURL = try audioRecorder.stop()
            playFeedbackSound(.release)
            processingTask = Task { [weak self] in
                await self?.process(audioURL: audioURL)
            }
        } catch {
            fail(error)
        }
    }

    private func refreshPreferredShortcut() {
        let preference = configuration.hotKeyPreset
        let installed = hotKey.reinstall(preference: preference)
        updateShortcutPresentation(preference: preference, installed: installed)
    }

    private func updateShortcutPresentation(
        preference: HotKeyPreset,
        installed: Bool
    ) {
        shortcutReady = installed
        preferredShortcutActive = installed && hotKey.isUsingPreferred
        shortcutKeys = installed ? hotKey.shortcutKeys : preference.keys
        shortcutBehavior = installed ? hotKey.behavior : .holdToTalk

        if !installed {
            shortcutStatus = OpenTypeL10n.text("\(preference.title) 无法注册，请换一个快捷键", english: "Could not register \(preference.title). Choose another shortcut.")
        } else if hotKey.isUsingPreferred {
            let interaction: String
            switch hotKey.behavior {
            case .optionHybrid:
                interaction = OpenTypeL10n.text("长按说话 / 双击连续录音", english: "Hold to talk / double-tap for continuous recording")
            case .holdToTalk:
                interaction = OpenTypeL10n.text("按住说话", english: "Hold to talk")
            default:
                interaction = OpenTypeL10n.text("按任意键结束", english: "Press any key to finish")
            }
            shortcutStatus = OpenTypeL10n.text("当前生效：\(preference.title) · \(interaction)", english: "Active: \(preference.title) · \(interaction)")
        } else {
            let actual = hotKey.shortcutKeys.joined(separator: " ")
            shortcutStatus = OpenTypeL10n.text("目标：\(preference.title) · 当前回退：\(actual)（等待辅助功能授权）", english: "Target: \(preference.title) · Fallback: \(actual) (waiting for Accessibility permission)")
        }
        persistShortcutStatus()
    }

    private func persistShortcutStatus() {
        UserDefaults.standard.set(
            shortcutStatus,
            forKey: "lastShortcutRegistrationStatus"
        )
    }

    /// Every mode now routes to the sidecar for its text generation, always
    /// using this fixed model, and ASR always runs locally via the sidecar's
    /// MLX-Whisper process (see `transcribeLocally(audioURL:)` below) --
    /// there is no cloud-provider selection anywhere in the pipeline anymore,
    /// so audit events (`appendAudit` in `process(audioURL:)`) record these
    /// fixed labels directly instead of resolving a configured provider.
    private static let sidecarTextModel = "deepseek-v4-flash"
    private static let sidecarTextProvider = "deepseek"
    private static let sidecarASRProvider = "mlx-whisper"

    /// Request/response bodies for the sidecar's `/asr/transcribe` endpoint
    /// (proxies to the local MLX-Whisper python process -- see
    /// `sidecar/src/asr/whisperClient.ts`), used by `transcribeLocally(audioURL:)`.
    private struct TranscribeRequestBody: Encodable { let audioBase64: String }
    private struct TranscribeResponseBody: Decodable { let text: String }

    /// Request/response bodies for the sidecar's `/oneshot/ask` endpoint,
    /// used by the `ask` mode branch below.
    private struct AskRequestBody: Encodable { let question: String }
    private struct AskResponseBody: Decodable { let result: String }

    /// Request/response bodies for the sidecar's `/agent/run` endpoint, used
    /// by the `agent` mode branch below. This runs a full agent loop
    /// (potentially calling MCP tools) as a single blocking HTTP call and can
    /// take noticeably longer than `/oneshot/ask`; `steps` carries the full
    /// step-by-step log after the fact for display in the Task List panel
    /// (`AgentTaskLogView`).
    private struct AgentRunRequestBody: Encodable { let task: String; let context: String? }
    private struct AgentRunResponseBody: Decodable { let result: String; let steps: [AgentStepSummary] }

    private struct MemoryTermsResponseBody: Decodable { let terms: [EntityTermSummary] }
    private struct MemoryConsolidationRunsResponseBody: Decodable { let runs: [ConsolidationRunSummary] }

    /// Refreshes the read-only Settings "Memory" panel (design doc §4.1: the
    /// human-review surface over the sidecar's entity dictionary and
    /// consolidation run log) by hitting `GET /memory/terms` and
    /// `GET /memory/consolidation-runs`. This backs a convenience display,
    /// not the critical recording/transcription path, so a sidecar hiccup
    /// (not started yet, transient failure) just yields an empty list plus a
    /// logged message rather than throwing.
    func refreshMemoryPanel() async {
        do {
            let response: MemoryTermsResponseBody = try await sidecarClient.request(
                method: "GET",
                path: "/memory/terms"
            )
            memoryTerms = response.terms
        } catch {
            memoryTerms = []
            print("OpenType: failed to refresh memory terms from sidecar: \(error.localizedDescription)")
        }

        do {
            let response: MemoryConsolidationRunsResponseBody = try await sidecarClient.request(
                method: "GET",
                path: "/memory/consolidation-runs"
            )
            memoryConsolidationRuns = response.runs
        } catch {
            memoryConsolidationRuns = []
            print("OpenType: failed to refresh memory consolidation runs from sidecar: \(error.localizedDescription)")
        }
    }

    private struct ConsolidateNowResponseBody: Decodable { let result: ConsolidationResultSummary }

    /// Manual trigger for the Settings "Memory" panel's "Consolidate now"
    /// button: hits `POST /memory/consolidate-now`, which runs the sidecar's
    /// `runConsolidation` immediately, bypassing the normal automatic
    /// time/event-count gate (`shouldConsolidate`) — the same bypass path
    /// the voice-triggered `consolidate_memory_now` agent tool uses. Updates
    /// `consolidateNowStatus` for the button's brief indicator and refreshes
    /// the panel afterward so a newly-accepted term shows up immediately.
    func consolidateMemoryNow() {
        guard consolidateNowStatus != .running else { return }
        consolidateNowStatus = .running
        Task { [weak self] in
            guard let self else { return }
            do {
                let response: ConsolidateNowResponseBody = try await self.sidecarClient.request(
                    method: "POST",
                    path: "/memory/consolidate-now"
                )
                if response.result.aborted {
                    self.consolidateNowStatus = .failed(
                        OpenTypeL10n.text("整理未完成，请稍后重试", english: "Consolidation did not complete")
                    )
                } else {
                    self.consolidateNowStatus = .succeeded(
                        OpenTypeL10n.text(
                            "已整理 \(response.result.eventsConsidered) 条记录，采纳 \(response.result.candidatesAccepted) 条",
                            english: "Reviewed \(response.result.eventsConsidered), accepted \(response.result.candidatesAccepted)"
                        )
                    )
                }
                await self.refreshMemoryPanel()
            } catch {
                self.consolidateNowStatus = .failed(error.localizedDescription)
            }
        }
    }

    /// Local ASR via the sidecar's `/asr/transcribe` endpoint, which proxies
    /// to a persistent MLX-Whisper python process (`sidecar/whisper/serve.py`,
    /// managed by `sidecar/src/asr/whisperClient.ts`) -- the ASR step shared
    /// by all modes, with no credential/provider configuration required.
    private func transcribeLocally(audioURL: URL) async throws -> String {
        let audioData = try Data(contentsOf: audioURL)
        guard !audioData.isEmpty else { throw OpenTypeError.emptyRecording }
        let response: TranscribeResponseBody = try await sidecarClient.request(
            method: "POST",
            path: "/asr/transcribe",
            body: TranscribeRequestBody(audioBase64: audioData.base64EncodedString())
        )
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenTypeError.emptyRecording }
        return text
    }

    private func process(audioURL: URL) async {
        let startingMode = activeMode ?? configuration.selectedMode
        let practice = isPracticeSession
        let auditRequestID = UUID()
        var auditMode = startingMode
        var auditRawTranscript = ""
        var auditEffectiveInput: String?
        var effectiveTextModel: String?

        func appendAudit(
            status: AuditEventStatus,
            result: String? = nil,
            error: String? = nil,
            provider: String? = nil,
            model: String? = nil
        ) {
            try? auditStore.append(
                ImmutableAuditEvent(
                    requestId: auditRequestID,
                    status: status,
                    mode: auditMode,
                    rawTranscript: auditRawTranscript,
                    effectiveInput: auditEffectiveInput,
                    selectedContext: capturedContext.selectedText,
                    result: result,
                    provider: provider,
                    model: model,
                    error: error
                )
            )
        }

        defer {
            try? FileManager.default.removeItem(at: audioURL)
            activeMode = nil
            isPracticeSession = false
        }

        do {
            setState(.transcribing)
            let rawTranscript = try await transcribeLocally(audioURL: audioURL)
            try Task.checkCancellation()
            auditRawTranscript = rawTranscript

            let sendCommand = SendCommandParser.parse(
                rawTranscript,
                enabled: configuration.pressEnterCommand
            )
            let routed = VoiceModeRouter.route(
                sendCommand.text,
                currentMode: startingMode
            )
            let mode = routed.mode
            let transcript = routed.text
            activeMode = mode
            auditMode = mode
            auditEffectiveInput = transcript
            appendAudit(
                status: .recognized,
                provider: Self.sidecarASRProvider
            )

            if mode.requiresSelection,
               !contextBridge.accessibilityGranted {
                throw OpenTypeError.accessibilityRequired
            }
            if mode.requiresSelection,
               capturedContext.selectedText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty != false {
                throw OpenTypeError.selectionRequired(mode)
            }
            lastTranscript = transcript

            setState(.transforming)
            // Optional rather than `String`: the `.agent` branch below never
            // has a result at this point (it dispatches a detached run and
            // returns before anything below this switch runs) — see the
            // `guard let result else { ... return }` immediately after.
            let result: String?
            switch mode {
            case .transcribe:
                // Pure ASR passthrough: no sidecar/LLM call at all, and no
                // Ask popup — the transcript itself is the result.
                result = transcript
            case .ask:
                effectiveTextModel = Self.sidecarTextModel
                askPanelState = AskPanelState(kind: .ask, query: transcript, answer: nil)
                do {
                    let response: AskResponseBody = try await sidecarClient.request(
                        method: "POST",
                        path: "/oneshot/ask",
                        body: AskRequestBody(question: transcript)
                    )
                    result = response.result
                    askPanelState?.answer = result
                } catch {
                    askPanelState = nil
                    throw OpenTypeError.service(
                        "Ask 请求失败：\(error.localizedDescription)"
                    )
                }
            case .agent:
                // Non-blocking dispatch (see `dispatchAgentRun` below): the
                // `/agent/run` call runs as an independent, detached `Task`
                // that is never awaited here, so a slow multi-step Agent
                // loop can't hold the app's general recording pipeline busy.
                // No Ask/Agent popup either — completion is surfaced later
                // via a `UNUserNotification` plus the Task List panel in the
                // main app window (Part A), not a panel the user waits in
                // front of.
                effectiveTextModel = Self.sidecarTextModel
                dispatchAgentRun(
                    transcript: transcript,
                    context: capturedContext,
                    practice: practice,
                    requestID: auditRequestID
                )
                result = nil
            }
            try Task.checkCancellation()

            guard let result else {
                // `.agent` took the dispatch-and-return path above: give a
                // brief, transient "dispatched" acknowledgement (the same
                // sound-cue/overlay pattern every other mode uses for its own
                // completion signal) and let `state` fall back to idle right
                // away, rather than staying "busy" for the run's whole
                // duration. `defer` above still fires normally, so the audio
                // file is cleaned up and `activeMode`/`isPracticeSession`
                // reset exactly as any other completed dispatch would.
                playFeedbackSound(.done)
                let dispatchedState = ProcessingState.dispatched(
                    OpenTypeL10n.text("已下发给 Agent", english: "Dispatched to Agent")
                )
                setState(dispatchedState)
                scheduleIdle(after: dispatchedState)
                return
            }

            lastResult = result
            lastApplication = capturedContext.applicationName
            lastResultWasPractice = practice

            if configuration.agentMemoryEnabled, !practice {
                agentMemory.record(
                    MemoryEvent(
                        mode: mode,
                        applicationName: capturedContext.applicationName,
                        bundleIdentifier: capturedContext.bundleIdentifier,
                        rawTranscript: rawTranscript,
                        effectiveInput: transcript,
                        selectedContext: capturedContext.selectedText,
                        result: result
                    )
                )
                agentMemory.refreshOwnerProfileIfNeeded(
                    enabled: configuration.automaticOwnerProfileUpdates,
                    personalDictionary: configuration.personalDictionary
                )
            }

            if configuration.keepHistory, !practice {
                history.add(
                    HistoryEntry(
                        mode: mode,
                        applicationName: capturedContext.applicationName,
                        transcript: transcript,
                        result: result,
                        contextPreview: capturedContext.selectedText.map {
                            String($0.prefix(240))
                        }
                    )
                )
            }

            var completionState: ProcessingState = .success
            let deliveryStrategy = OutputDeliveryPolicy.strategy(
                for: mode,
                automaticallyInsert: configuration.automaticallyInsert
            )
            if practice {
                // The guided first-run test keeps the result inside OpenType so
                // users can verify the whole voice pipeline before granting
                // system-wide insertion access.
            } else if deliveryStrategy == .automaticInsert {
                setState(.inserting)
                do {
                    try await contextBridge.insert(
                        result,
                        pressEnter: sendCommand.pressEnter
                            && OutputDeliveryPolicy.permitsAutomaticEnter(
                                for: mode
                            )
                    )
                } catch {
                    completionState = .copied
                }
            } else if !practice {
                completionState = .copied
            }

            if OutputDeliveryPolicy.retainsClipboardCopy(for: mode) {
                contextBridge.copyToClipboard(result)
            }

            appendAudit(
                status: .completed,
                result: result,
                // `.transcribe` is a pure ASR passthrough with no sidecar
                // text-generation call (see the `switch mode` above), so it
                // has no text provider/model of its own to record here.
                provider: mode == .transcribe ? nil : Self.sidecarTextProvider,
                model: effectiveTextModel
            )

            playFeedbackSound(.done)
            setState(completionState)
            scheduleIdle(after: completionState)
        } catch is CancellationError {
            appendAudit(
                status: .cancelled,
                error: OpenTypeL10n.text(
                    "处理已取消",
                    english: "Processing was cancelled"
                )
            )
            if state != .copied {
                setState(.idle)
            }
        } catch OpenTypeError.missingEditInstruction {
            let message = OpenTypeL10n.text("没有明确修改指令，原文保持不变", english: "No clear editing instruction was detected. The original text was left unchanged.")
            appendAudit(status: .cancelled, error: message)
            let cancelled = ProcessingState.cancelled(message)
            setState(cancelled)
            scheduleIdle(after: cancelled)
        } catch {
            appendAudit(
                status: .failed,
                error: ErrorMessagePresenter.message(for: error),
                provider: auditRawTranscript.isEmpty
                    ? Self.sidecarASRProvider
                    : Self.sidecarTextProvider,
                model: auditRawTranscript.isEmpty
                    ? nil
                    : (effectiveTextModel ?? Self.sidecarTextModel)
            )
            fail(error)
        }
    }

    /// Kicks off an Agent-mode task as an independent, detached unit of work
    /// and returns immediately — the "non-blocking dispatch" half of the
    /// Agent redesign. Records a `.running` `AgentRunRecord` right away (so
    /// the Task List panel and menubar badge reflect it instantly) and hands
    /// the actual `/agent/run` HTTP call off to `runAgentDispatch`, tracked
    /// in `runningAgentTasks` but never awaited by `process(audioURL:)`.
    /// This is what lets a second recording — including a second Agent task
    /// — start immediately without waiting for this one to finish.
    private func dispatchAgentRun(
        transcript: String,
        context: CapturedContext,
        practice: Bool,
        requestID: UUID
    ) {
        let record = AgentRunRecord(
            task: transcript,
            applicationName: context.applicationName,
            contextPreview: context.selectedText.map { String($0.prefix(240)) }
        )
        agentRuns = AgentRunHistory.inserting(record, into: agentRuns)
        runningAgentRunCount = AgentRunHistory.runningCount(in: agentRuns)

        let runID = record.id
        runningAgentTasks[runID] = Task { [weak self] in
            await self?.runAgentDispatch(
                runID: runID,
                transcript: transcript,
                context: context,
                practice: practice,
                requestID: requestID
            )
        }
    }

    /// The detached unit of work started by `dispatchAgentRun`: issues the
    /// (potentially long-running, multi-step) `/agent/run` call, then updates
    /// `agentRuns` in place, records history/memory, and fires the
    /// completion notification — all independent of whatever `state`/mode
    /// the app has moved on to in the meantime. Deliberately does **not**
    /// call `contextBridge.insert(...)`: by the time a run this long
    /// finishes, the focused text field the user had in mind when they spoke
    /// the task may no longer be focused (or may not even exist anymore), so
    /// auto-typing into "whatever is focused now" would be surprising at
    /// best. The result is always copied to the clipboard and surfaced via
    /// notification + Task List instead, consistent with Agent results being
    /// drafts the user reviews, never something auto-inserted unattended.
    private func runAgentDispatch(
        runID: UUID,
        transcript: String,
        context: CapturedContext,
        practice: Bool,
        requestID: UUID
    ) async {
        defer { runningAgentTasks[runID] = nil }

        do {
            let response: AgentRunResponseBody = try await sidecarClient.request(
                method: "POST",
                path: "/agent/run",
                body: AgentRunRequestBody(
                    task: transcript,
                    context: context.selectedText
                )
            )

            agentRuns = AgentRunHistory.updating(id: runID, in: agentRuns) { record in
                record.steps = response.steps
                record.status = .completed(response.result)
                record.completedAt = Date()
            }
            runningAgentRunCount = AgentRunHistory.runningCount(in: agentRuns)

            try? auditStore.append(
                ImmutableAuditEvent(
                    requestId: requestID,
                    status: .completed,
                    mode: .agent,
                    rawTranscript: transcript,
                    effectiveInput: transcript,
                    selectedContext: context.selectedText,
                    result: response.result,
                    provider: Self.sidecarTextProvider,
                    model: Self.sidecarTextModel,
                    error: nil
                )
            )

            lastResult = response.result
            lastApplication = context.applicationName
            lastResultWasPractice = practice

            if configuration.agentMemoryEnabled, !practice {
                agentMemory.record(
                    MemoryEvent(
                        mode: .agent,
                        applicationName: context.applicationName,
                        bundleIdentifier: context.bundleIdentifier,
                        rawTranscript: transcript,
                        effectiveInput: transcript,
                        selectedContext: context.selectedText,
                        result: response.result
                    )
                )
                agentMemory.refreshOwnerProfileIfNeeded(
                    enabled: configuration.automaticOwnerProfileUpdates,
                    personalDictionary: configuration.personalDictionary
                )
            }
            if configuration.keepHistory, !practice {
                history.add(
                    HistoryEntry(
                        mode: .agent,
                        applicationName: context.applicationName,
                        transcript: transcript,
                        result: response.result,
                        contextPreview: context.selectedText.map {
                            String($0.prefix(240))
                        }
                    )
                )
            }

            contextBridge.copyToClipboard(response.result)
        } catch {
            let message = ErrorMessagePresenter.message(for: error)
            agentRuns = AgentRunHistory.updating(id: runID, in: agentRuns) { record in
                record.status = .failed(message)
                record.completedAt = Date()
            }
            runningAgentRunCount = AgentRunHistory.runningCount(in: agentRuns)

            try? auditStore.append(
                ImmutableAuditEvent(
                    requestId: requestID,
                    status: .failed,
                    mode: .agent,
                    rawTranscript: transcript,
                    effectiveInput: transcript,
                    selectedContext: context.selectedText,
                    result: nil,
                    provider: Self.sidecarTextProvider,
                    model: Self.sidecarTextModel,
                    error: message
                )
            )
        }

        if let record = agentRuns.first(where: { $0.id == runID }) {
            postAgentCompletionNotification(record)
        }
    }

    /// Fires the "Agent finished" `UNUserNotification` for a just-completed
    /// or just-failed run. Tapping it routes through
    /// `AgentNotificationDelegate.onAgentRunTapped` -> `focusAgentRun(_:)`.
    private func postAgentCompletionNotification(_ record: AgentRunRecord) {
        let content = UNMutableNotificationContent()
        switch record.status {
        case .completed(let result):
            content.title = OpenTypeL10n.text("Agent 完成任务", english: "Agent finished the task")
            content.body = String(result.prefix(140))
        case .failed(let message):
            content.title = OpenTypeL10n.text("Agent 任务失败", english: "Agent task failed")
            content.body = String(message.prefix(140))
        case .running:
            return
        }
        content.sound = .default
        content.userInfo = ["agentRunID": record.id.uuidString]

        let request = UNNotificationRequest(
            identifier: record.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func scheduleIdle(after completionState: ProcessingState) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.state == completionState else { return }
            self.state = .idle
        }
    }

    private func setState(_ newState: ProcessingState) {
        state = newState
        hotKey.setRecordingActive(newState == .listening)
        overlay.show(
            state: newState,
            mode: activeMode ?? configuration.selectedMode
        )
    }

    private func fail(_ error: Error) {
        let message = ErrorMessagePresenter.message(for: error)
        let failedMode = activeMode ?? configuration.selectedMode
        isHotKeyHeld = false
        isStartingRecording = false
        isPracticeSession = false
        activeMode = nil
        shortcutBehavior = hotKey.behavior
        hotKey.setRecordingActive(false)
        liveSpeechTranscriber.stop()
        state = .failure(message)
        overlay.show(
            state: .failure(message),
            mode: failedMode
        )
        playFeedbackSound(.issue)
    }

    private func playFeedbackSound(_ cue: FeedbackSoundCue) {
        guard configuration.playFeedbackSounds else { return }

        activeFeedbackSound?.stop()

        if let sound = customSounds[cue.resourceName] {
            sound.currentTime = 0
            activeFeedbackSound = sound
            sound.play()
            return
        }

        if let url = Bundle.main.url(
            forResource: cue.resourceName,
            withExtension: "wav",
            subdirectory: "Sounds"
        ), let sound = NSSound(contentsOf: url, byReference: true) {
            sound.volume = cue.volume
            customSounds[cue.resourceName] = sound
            activeFeedbackSound = sound
            sound.play()
            return
        }

        NSSound(named: NSSound.Name(cue.fallbackSystemSound))?.play()
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return OpenTypeL10n.text("输入", english: "Input")
        case .history: return OpenTypeL10n.text("历史", english: "History")
        case .settings: return OpenTypeL10n.text("设置", english: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "slider.horizontal.3"
        }
    }
}
