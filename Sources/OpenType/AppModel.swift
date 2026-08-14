import AppKit
import Foundation
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    /// Pure merge seam for a list refresh: `incoming == nil` signals a *failed*
    /// fetch (keep whatever is already on screen), while `incoming == some`
    /// signals a *successful* fetch whose result — even a genuinely empty array —
    /// is authoritative and replaces `previous`. This is what stops a transient
    /// sidecar hiccup from flashing an already-populated list to empty.
    nonisolated static func mergedRefresh<T>(previous: [T], incoming: [T]?) -> [T] {
        incoming ?? previous
    }

    @Published private(set) var state: ProcessingState = .idle
    @Published private(set) var shortcutStatus = "正在注册…"
    /// The sidecar child process's lifecycle state, the single source of truth
    /// the displayed `sidecarStatusText` derives from. Was previously a bare
    /// `String` set exactly once at startup — so a crash left it stuck reading
    /// "ready" forever (P1-4); now it moves to `.degraded`/`.failed` on
    /// unexpected termination and drives the UI's error/restart affordance.
    @Published private(set) var sidecarStatus: SidecarStatus = .starting
    /// Extra detail for a `.failed` status (e.g. a startup error description),
    /// folded into `sidecarStatusText`. `nil` when there's nothing to add.
    @Published private(set) var sidecarErrorDetail: String?
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
    /// A brief, transient note about the most recent delivery when it deviated
    /// from the user's expectation — e.g. an auto-insert that was downgraded to
    /// clipboard-only because focus moved to a different app after capture.
    /// `nil` when there is nothing noteworthy to surface.
    @Published private(set) var lastDeliveryNotice: String?
    @Published private(set) var memoryTerms: [EntityTermSummary] = []
    @Published private(set) var memoryConsolidationRuns: [ConsolidationRunSummary] = []
    /// Free-text owner facts (`GET /memory/owner-facts`, every origin), shown
    /// alongside the entity dictionary in the Settings "Memory" panel so a
    /// planted (non-owner) fact is findable and deletable (P1-12).
    @Published private(set) var memoryOwnerFacts: [OwnerFactSummary] = []
    /// Last failure from a dictionary-panel edit (add/edit/delete), shown
    /// in-place in that panel and cleared by the next successful edit. Editing
    /// is a deliberate user action, so a failed one must say so rather than
    /// look like nothing happened.
    @Published private(set) var memoryEditError: String?
    /// Set when an append to the immutable audit trail throws. The audit log is
    /// the app's local "source of truth"; a failed write must not be silent, so
    /// this surfaces a small warning in the Home / menubar status area. It stays
    /// set until something explicitly clears it (a subsequent successful append).
    @Published private(set) var auditWriteFailed = false
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
    @Published var selectedTab: AppTab = .sessions
    /// Past Ask/Agent conversations (`GET /conversations?kind=...`), backing
    /// the Q&A and Agent tabs (`Views.swift`) -- refreshed on tab appear and
    /// after each dispatch completes. The sidecar-persisted list, not
    /// `agentRuns`/`AgentRunHistory`, is the durable source of truth for
    /// past runs; it survives relaunch, the in-memory list does not.
    @Published private(set) var askConversations: [ConversationSummary] = []
    @Published private(set) var agentConversations: [ConversationSummary] = []
    /// The currently-open thread in the Q&A/Agent tab, if any -- fetched by
    /// `openAskConversation(_:)`/`openAgentConversation(_:)`.
    @Published private(set) var askConversationDetail: ConversationDetail?
    @Published private(set) var agentConversationDetail: ConversationDetail?
    /// The conversation a new Ask/Agent-mode voice dispatch should continue,
    /// if any. Set by opening a past conversation in the Q&A/Agent tab (or by
    /// a tapped Agent-completion notification, via `focusAgentRun(_:)`);
    /// cleared by leaving the thread view or the tab's explicit "new
    /// conversation" affordance (`startNewAskConversation()`/
    /// `startNewAgentConversation()`). `nil` means the next dispatch starts a
    /// fresh conversation, same as today's one-shot behavior.
    @Published var focusedAskConversationId: Int?
    @Published var focusedAgentConversationId: Int?
    /// The ask side of the unified voice surface. `nil` means no live ask;
    /// non-nil with `answer == nil` is the "thinking" state, and an answer
    /// resolves it into the result card. Still a first-class source of truth
    /// (not folded into `VoiceSurfaceState`) because it is what
    /// `runAskDispatch` guards its late-answer delivery on; the surface is
    /// *derived* from it by `VoiceSurfaceState.reduce(...)`, which the
    /// `didSet` re-runs through `presentVoiceSurface()`.
    @Published private(set) var askPanelState: AskPanelState? {
        didSet { presentVoiceSurface() }
    }
    /// Drives the floating Review panel (`ReviewPanelController`) — see
    /// `ReviewPanelState`'s doc comment. `nil` hides it; non-nil shows it.
    /// Same imperative-controller-sync split as `askPanelState`/`askPanel`.
    @Published private(set) var reviewPanelState: ReviewPanelState? {
        didSet { syncReviewPanel() }
    }
    /// The agent side of the unified voice surface — see
    /// `AgentProgressPanelState`'s doc comment. `nil` means no run is being
    /// shown; non-nil is set the moment a run is dispatched and replaced
    /// wholesale by a newer dispatch. It also drives progress polling, which
    /// is why the reducer never requires it to be cleared. Same derived-view
    /// split as `askPanelState`.
    @Published private(set) var agentPanelState: AgentProgressPanelState? {
        didSet { presentVoiceSurface() }
    }
    /// The sidecar's `/config/status` view of whether the user has
    /// explicitly finished configuring a Whisper backend and an LLM
    /// provider through the new provider-config system (see
    /// `ProviderConfigStore` on the sidecar side for the precise
    /// "configured" definition -- an ambient `DEEPSEEK_API_KEY` env var
    /// alone never counts). `nil` until the first successful fetch (right
    /// after the sidecar becomes ready).
    @Published private(set) var providerConfigStatus: ProviderConfigStatus?
    /// True exactly when `providerConfigStatus` has loaded and `ready` is
    /// false -- gates whether `RootView` shows the first-run setup wizard
    /// instead of the normal Home tab. Explicit `Bool?` rather than a
    /// derived computed property so a not-yet-loaded status doesn't
    /// momentarily flash the wizard before the real answer is known.
    var needsProviderOnboarding: Bool {
        providerConfigStatus.map {
            OnboardingPolicy.needsProviderOnboarding(
                whisperConfigured: $0.whisperConfigured,
                llmConfigured: $0.llmConfigured,
                localTranscriptionOnlyAcknowledged: configuration.localTranscriptionOnlyAcknowledged
            )
        } ?? false
    }
    /// True when the currently-selected mode needs an LLM (`ask`/`agent`) but
    /// none is configured yet — the case a transcribe-only user hits after
    /// taking the "skip AI setup" path and later switching to Ask/Agent. Drives
    /// a lightweight inline nudge (with a jump to Settings' AI-model section)
    /// rather than blocking the mode switch; `transcribe` is never gated. `nil`
    /// provider status (not yet loaded) suppresses the nudge so it can't flash.
    var needsLLMForSelectedMode: Bool {
        guard configuration.selectedMode.requiresLLM else { return false }
        guard let status = providerConfigStatus else { return false }
        return !status.llmConfigured
    }
    @Published private(set) var llmConfigSummary: LLMConfigSummary?
    @Published private(set) var whisperConfigSummary: WhisperConfigSummary?

    let configuration: AppConfiguration
    let history: HistoryStore
    let agentMemory: AgentMemoryStore
    private let auditStore = ImmutableAuditStore()

    /// Central append point for the immutable audit trail. The audit log is the
    /// app's local source of truth, so a failed write must be visible rather than
    /// silently swallowed by `try?`: on failure it flips `auditWriteFailed`, which
    /// the Home / menubar status area surfaces as a small warning. A subsequent
    /// successful append clears the flag.
    private func recordAuditEvent(_ event: ImmutableAuditEvent) {
        do {
            try auditStore.append(event)
            if auditWriteFailed { auditWriteFailed = false }
        } catch {
            auditWriteFailed = true
            print("OpenType: failed to append audit event: \(error.localizedDescription)")
        }
    }

    /// This week's figures for the statistics panel (P2-12).
    ///
    /// Derived, never accumulated: `refreshUsageStats()` recomputes it from the
    /// audit trail on demand, so there is no counter to drift out of step with
    /// the log and nothing extra to persist. Starts empty, which is also what a
    /// user with no deliveries this week correctly sees.
    @Published private(set) var usageSummary: UsageStats.Summary = .empty

    /// Recomputes `usageSummary` from `audit-events.v1.jsonl`.
    ///
    /// The read and the decode happen off the main actor: the trail is
    /// append-only and never trimmed, so for a heavy user it is the one file in
    /// this app large enough that parsing it on the main thread would be felt
    /// as a hitch when the tab opens. Only the `URL` and the finished `Summary`
    /// cross the boundary, both value types.
    func refreshUsageStats() {
        let url = auditStore.fileURL
        let now = Date()
        Task.detached(priority: .utility) {
            let summary = UsageStats.summarizeLog(at: url, now: now)
            await MainActor.run { [weak self] in
                self?.usageSummary = summary
            }
        }
    }

    private let sidecarClient = SidecarClient()
    private let audioRecorder = AudioRecorder()
    private let liveSpeechTranscriber = LiveSpeechTranscriber()
    private let contextBridge = ContextBridge()
    private let hotKey = GlobalHotKey()
    /// The one floating bottom-center panel: transcribe's HUD/toasts *and*
    /// the unified ask/agent voice surface (`VoiceSurfaceState`). The
    /// center-screen Ask popup and the top-right Agent progress panel it
    /// replaced are gone.
    private let overlay = OverlayController()
    private let reviewPanel = ReviewPanelController()
    private var customSounds: [String: NSSound] = [:]
    private var activeFeedbackSound: NSSound?
    private var capturedContext = CapturedContext(
        selectedText: nil,
        applicationName: "Unknown app",
        bundleIdentifier: nil
    )
    private var processingTask: Task<Void, Never>?
    /// The detached, non-blocking `/oneshot/ask` request (see `dispatchAskRun`).
    /// Tracked separately from `processingTask` so an in-flight Ask answer does
    /// not hold the recording pipeline busy, and so dismissing a still-thinking
    /// ask (`dismissAskPanel`) can abort just this request without touching an
    /// unrelated recording/processing task.
    private var askTask: Task<Void, Never>?
    /// The ~0.7s `GET /agent/progress/:runId` polling loop feeding the voice
    /// surface's live step ticker (see `startAgentProgressPolling`).
    /// There is at most one: it always serves the most recently dispatched
    /// run (the one `agentPanelState` shows), and a newer dispatch replaces
    /// it. Cancelling it never cancels the run itself — the detached
    /// `/agent/run` task in `runningAgentTasks` is deliberately untouched by
    /// panel dismissal.
    private var agentProgressPollTask: Task<Void, Never>?
    private var accessibilityPollTimer: Timer?
    /// The half-second tick that drives the pill's elapsed-time readout and the
    /// two/five-minute limits (P2-10, `RecordingLimits`). Runs for exactly as
    /// long as one recording does — see `startRecordingClock()`.
    private var recordingClockTimer: Timer?
    /// When the recording currently being timed started. `nil` when none is.
    private var recordingStartedAt: Date?
    /// The one bit of history `RecordingLimits.action(...)` needs to make the
    /// warning fire once. Owned by the session and cleared when one starts, so
    /// a long recording gets one warning rather than one every half-second.
    private var didWarnAboutRecordingLength = false
    private var activeMode: InputMode?
    private var didStart = false
    /// One-shot guard for the first-run provider-setup wizard auto-open —
    /// see the `refreshProviderConfigStatus()` call site in `init()`.
    private var didPromptProviderOnboarding = false
    private var isHotKeyHeld = false
    private var isStartingRecording = false
    /// Set for the duration of a hotkey press/release that's a Review-mode
    /// voice *correction* (spoken while the Review panel is open, targeting
    /// its current text selection) rather than a brand-new Direct/Review
    /// dictation. `hotKeyPressed()` decides which this is based on whether
    /// `reviewPanelState` is non-nil at press time; `finishRecording()`
    /// branches on this flag to route the resulting audio to
    /// `processCorrection(audioURL:)` instead of `process(audioURL:)`.
    private var isCorrectionRecording = false
    /// Non-nil for the duration of an open Review panel — the audit-chain
    /// bookkeeping (`requestId` grouping every event in one session,
    /// `lastEventId` for `supersedesEventId` chaining) and the originally
    /// captured target-app context the eventual commit inserts into. Kept
    /// separate from `reviewPanelState` (which only tracks *visibility* for
    /// SwiftUI) since this is `AppModel`-internal bookkeeping the panel
    /// itself has no need to see.
    private var reviewSession: ReviewSession?
    /// The open post-delivery correction window (P0-3), or `nil` when the
    /// hotkey has its ordinary meaning. Holds the pure
    /// `CorrectionWindow.State` plus the audit anchors a correction round
    /// needs — see `CorrectionWindowSession`. Only ever written through
    /// `armCorrectionWindow`/`updateCorrectionWindow`/`reArmCorrectionWindow`,
    /// which keep `overlay.correctionWindowArmed` in step with it: a window
    /// the user cannot see is, per the spec, no window at all.
    private var correctionWindowSession: CorrectionWindowSession?
    /// Non-nil for the duration of one in-place correction round: what
    /// `processCorrection(audioURL:)` needs to route the audio to the Direct
    /// path rather than the Review panel's. Set at hotkey-press time so the
    /// selection being corrected is the one that was live *then*, not whatever
    /// the user happens to have selected when the recording ends.
    private var inPlaceCorrection: InPlaceCorrectionSession?
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

    /// The pre-dispatch confirmation currently on screen (P1-6), or `nil` when
    /// no task is waiting to go out. Its presence is also what gives Esc its
    /// temporary second meaning — see `cancelActiveVoiceSession()`.
    private var pendingDispatch: DispatchConfirmation.Pending?
    /// When Esc landed during that window. Kept as a timestamp rather than a
    /// bool so the seam can judge it against the window's own bounds instead of
    /// trusting whoever set it.
    private var pendingDispatchEscapePressedAt: Date?

    /// Consecutive unexpected-sidecar-termination count driving the bounded
    /// auto-restart backoff (`SidecarSupervisor.restartDecision`). Reset to 0 on
    /// a successful restart and on a manual restart.
    private var sidecarFailureCount = 0
    /// The pending delayed auto-restart, if one is scheduled. Cancelled when a
    /// newer restart (auto or manual) supersedes it.
    private var sidecarRestartTask: Task<Void, Never>?

    /// True while an `attemptSidecarRestart()` is mid-flight. `sidecarClient.start()`
    /// is not cancellation-aware, so cancelling `sidecarRestartTask` cannot stop a
    /// start already in progress. This guard serializes the auto and manual restart
    /// paths so a manual "restart service" tap during an in-flight auto-restart can't
    /// spawn a second overlapping `start()` (which would orphan a sidecar process
    /// whose armed terminationHandler could then fire a spurious restart).
    private var isRestartingSidecar = false

    /// Set by `OpenTypeAppDelegate` once the main app window controller
    /// exists (Part A). Lets both the menubar popover's gear button and
    /// `focusAgentRun(_:)` (a tapped Agent-completion notification) open the
    /// same real, resizable window without `AppModel` owning any AppKit
    /// window/view-controller state itself.
    var onOpenMainWindowRequested: (() -> Void)?

    var accessibilityGranted: Bool {
        contextBridge.accessibilityGranted
    }

    /// Human-readable, localized rendering of `sidecarStatus` for the UI.
    var sidecarStatusText: String {
        switch sidecarStatus {
        case .starting:
            return OpenTypeL10n.text("正在启动…", english: "Starting…")
        case .ready:
            return OpenTypeL10n.text("Sidecar 已就绪", english: "Sidecar ready")
        case .degraded:
            return OpenTypeL10n.text(
                "Sidecar 已断开，正在自动重启…",
                english: "Sidecar disconnected — restarting…"
            )
        case .failed:
            if let detail = sidecarErrorDetail {
                return OpenTypeL10n.text(
                    "Sidecar 启动失败：\(detail)",
                    english: "Sidecar failed to start: \(detail)"
                )
            }
            return OpenTypeL10n.text(
                "Sidecar 已停止，请手动重启",
                english: "Sidecar stopped — restart needed"
            )
        }
    }

    /// True when the sidecar is in a non-ready state the UI should surface with
    /// a manual "restart service" affordance (auto-restarting or given up).
    var sidecarNeedsAttention: Bool {
        switch sidecarStatus {
        case .degraded, .failed:
            return true
        case .starting, .ready:
            return false
        }
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

    init() {
        self.configuration = AppConfiguration()
        self.history = HistoryStore()
        self.agentMemory = AgentMemoryStore()
        self.agentMemory.importHistoryIfNeeded(self.history.entries)
        self.agentMemory.refreshOwnerProfileIfNeeded(
            enabled: self.configuration.agentMemoryEnabled
                && self.configuration.automaticOwnerProfileUpdates
        )
        self.overlay.onRequestDismiss = { [weak self] in
            self?.dismissVoiceSurface()
        }
        self.overlay.onCopyResult = { [weak self] text in
            self?.copy(text)
        }
        self.overlay.onOpenMainWindow = { [weak self] in
            self?.openMainWindowFromVoiceSurface()
        }
        // The surface's 停止 stops the run it is showing, and nothing else:
        // the panel stays until the run settles into its cancelled state, so
        // the user sees their stop take effect rather than the window simply
        // vanishing.
        // Answering clears the card optimistically: the run resumes the moment
        // the sidecar has the answer, and leaving the question on screen while
        // it does would invite a second, unwanted answer.
        self.overlay.onAnswerAgentQuestion = { [weak self] runId, answer in
            guard let self else { return }
            self.updateAgentPanel(runId: runId) { state in state.question = nil }
            Task { [weak self] in
                guard let self else { return }
                // Delivery is best-effort: the run's own timeout is the
                // backstop if the answer never lands, so there is nothing
                // useful to do with a failure here.
                _ = try? await self.sidecarClient.answerAgentQuestion(
                    runId: runId,
                    answers: [answer]
                )
            }
        }
        self.overlay.onStopAgentRun = { [weak self] in
            guard let state = self?.agentPanelState,
                  let runID = UUID(uuidString: state.runId) else { return }
            self?.cancelAgentRun(runID)
        }
        // P1-6: Esc while the pre-dispatch confirmation is up. Recorded rather
        // than acted on — `DispatchConfirmation.decision` judges the timestamp
        // against the window, so a keypress that arrives a hair late reads as
        // "too late" instead of stopping a task that already went out.
        self.overlay.onCancelPendingDispatch = { [weak self] in
            self?.recordPendingDispatchEscape()
        }
        self.reviewPanel.onCommit = { [weak self] in self?.commitReview() }
        self.reviewPanel.onCancel = { [weak self] in self?.cancelReview() }
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
        sidecarClient.onUnexpectedTermination = { [weak self] in
            self?.handleSidecarUnexpectedTermination()
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
                self.sidecarErrorDetail = nil
                self.sidecarStatus = .ready
                await self.refreshProviderConfigStatus()
                // First-run setup wizard trigger (spec: "if the user hasn't
                // configured Whisper or LLM yet, opening the app should
                // enter a setup wizard"): the popover shows unconditionally
                // right after launch (see `OpenTypeAppDelegate`), but the
                // wizard itself lives in the real app window alongside
                // Settings, so surface that window automatically the first
                // time we learn the user isn't configured yet. Guarded by
                // `didPromptProviderOnboarding` so this fires once per
                // launch, not every time `providerConfigStatus` happens to
                // refresh (e.g. after the wizard itself saves progress).
                if self.needsProviderOnboarding, !self.didPromptProviderOnboarding {
                    self.didPromptProviderOnboarding = true
                    self.onOpenMainWindowRequested?()
                }
            } catch {
                self.sidecarErrorDetail = error.localizedDescription
                self.sidecarStatus = .failed
            }
        }
    }

    /// Stops the sidecar child process. Called from the app delegate's
    /// `applicationWillTerminate` so the sidecar doesn't outlive the app.
    func stopSidecar() {
        // Cancel any pending auto-restart so an intentional quit isn't chased by
        // a resurrection attempt.
        sidecarRestartTask?.cancel()
        sidecarRestartTask = nil
        sidecarClient.stop()
    }

    /// Called (on the main actor) by `SidecarClient` when the sidecar dies
    /// unexpectedly — moves the status to a visible non-ready state and kicks
    /// off the bounded auto-restart loop (P1-4). The intentional-stop path in
    /// `SidecarClient.stop()`/failed-startup teardown never reaches here.
    private func handleSidecarUnexpectedTermination() {
        sidecarStatus = SidecarSupervisor.status(for: .unexpectedTermination)
        scheduleSidecarRestart()
    }

    /// Increments the consecutive-failure counter and, per
    /// `SidecarSupervisor.restartDecision`, either schedules a delayed restart
    /// (bounded backoff) or gives up and surfaces the terminal failure state
    /// for a manual restart.
    private func scheduleSidecarRestart() {
        sidecarFailureCount += 1
        let decision = SidecarSupervisor.restartDecision(
            consecutiveFailureCount: sidecarFailureCount
        )
        switch decision {
        case .giveUp:
            sidecarErrorDetail = nil
            sidecarStatus = SidecarSupervisor.status(for: .gaveUp)
        case .restart(let afterSeconds):
            sidecarStatus = SidecarSupervisor.status(for: .unexpectedTermination)
            sidecarRestartTask?.cancel()
            sidecarRestartTask = Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(max(0, afterSeconds) * 1_000_000_000)
                )
                if Task.isCancelled { return }
                await self?.attemptSidecarRestart()
            }
        }
    }

    /// Attempts to (re)start the sidecar. On success, resets the failure
    /// counter and returns to `.ready`; on failure, feeds back into
    /// `scheduleSidecarRestart()` for the next backoff step / eventual give-up.
    private func attemptSidecarRestart() async {
        // Coalesce overlapping restarts: if one is already in flight, let it be
        // the authoritative attempt (the caller has already reset the failure
        // counter / status if it wanted to). Prevents a double `start()`.
        guard !isRestartingSidecar else { return }
        isRestartingSidecar = true
        defer { isRestartingSidecar = false }
        do {
            try await sidecarClient.start()
            sidecarFailureCount = 0
            sidecarErrorDetail = nil
            sidecarStatus = SidecarSupervisor.status(for: .restartSucceeded)
            await refreshProviderConfigStatus()
        } catch {
            sidecarErrorDetail = error.localizedDescription
            scheduleSidecarRestart()
        }
    }

    /// User-triggered "restart service" action (Home view / menubar popover):
    /// resets the failure counter so the bounded backoff starts fresh, then
    /// attempts a restart immediately.
    func restartSidecarManually() {
        sidecarRestartTask?.cancel()
        sidecarRestartTask = nil
        sidecarFailureCount = 0
        sidecarErrorDetail = nil
        sidecarStatus = .starting
        sidecarRestartTask = Task { [weak self] in
            await self?.attemptSidecarRestart()
        }
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
        hotKey.onCancelRequested = { [weak self] in
            self?.cancelActiveVoiceSession()
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

        // While the Review panel is open, the hotkey means "speak a
        // correction for the panel's current text selection," not "start a
        // brand-new Direct/Review dictation" — the panel's open+selection
        // state is what disambiguates the two, per the feature design (no
        // separate chord). Validated *before* recording starts so an
        // empty-selection mistake gets immediate feedback rather than
        // wasting a recording round-trip.
        if reviewPanelState != nil {
            guard reviewPanel.currentSelection() != nil else {
                let message = OpenTypeL10n.text(
                    "请先在复核面板中选中要修改的文字",
                    english: "Select text in the Review panel first"
                )
                let cancelled = ProcessingState.cancelled(message)
                setState(cancelled)
                scheduleIdle(after: cancelled)
                return
            }
            beginCorrectionRecording()
            return
        }

        let context = contextBridge.capture()
        let mode = configuration.selectedMode

        // P0-3: inside the post-delivery correction window, with something
        // selected in the app that delivery landed in, the hotkey means "fix
        // this selection" instead of "start a new dictation". Everything that
        // decides which is which lives in `CorrectionWindow.intent` —
        // including the deliberate rule that an empty selection does *not*
        // steal the hotkey from someone who just wants to keep talking.
        if let session = correctionWindowSession,
           let selectedText = context.selectedText,
           CorrectionWindow.intent(
               lastDeliveryAt: session.window.deliveredAt,
               now: Date(),
               selectedText: selectedText,
               capturedBundleId: session.window.capturedBundleId,
               frontmostBundleId: context.bundleIdentifier,
               mode: mode,
               variant: configuration.transcribeVariant
           ) == .correctSelection {
            beginInPlaceCorrectionRecording(
                selectedText: selectedText,
                context: context,
                session: session
            )
            return
        }

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
        // The single choke point for "a NEW dictation began" — which is what
        // closes a correction window (P0-3). Deliberately not in
        // `beginCorrectionRecording`, whose round has to survive long enough
        // to re-arm the window it belongs to.
        updateCorrectionWindow(on: .recordingStarted)
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

    /// The Review-panel-open counterpart of `beginRecording(...)` above: no
    /// context re-capture (the panel's own text selection is what this
    /// recording targets, not the currently-focused app), and no mode
    /// selection — `finishRecording()` routes the result to
    /// `processCorrection(audioURL:)` based on `isCorrectionRecording` alone.
    private func beginCorrectionRecording() {
        isHotKeyHeld = true
        isCorrectionRecording = true
        isStartingRecording = true
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.audioRecorder.start()
                self.microphonePermission = self.audioRecorder.permissionStatus
                self.isStartingRecording = false
                self.setState(.listening)
                self.playFeedbackSound(.ready)
            } catch {
                self.microphonePermission = self.audioRecorder.permissionStatus
                self.isStartingRecording = false
                self.isCorrectionRecording = false
                self.inPlaceCorrection = nil
                self.fail(error)
            }
        }
    }

    /// The Direct-mode counterpart (P0-3): the same correction recording, but
    /// targeting a selection in the *target app* rather than in the Review
    /// panel. Recording is identical either way — only the bookkeeping set up
    /// here differs, which is what `processCorrection(audioURL:)` branches on.
    ///
    /// The selection is captured now, at press time: it is what the user was
    /// pointing at when they decided to correct, and it is what gets sent as
    /// `fullText`. It is *also* re-read at write time — not to retarget the
    /// paste, but to refuse it if the selection has moved out from under the
    /// round trip (see `processInPlaceCorrection`).
    private func beginInPlaceCorrectionRecording(
        selectedText: String,
        context: CapturedContext,
        session: CorrectionWindowSession
    ) {
        inPlaceCorrection = InPlaceCorrectionSession(
            requestId: session.requestId,
            selectedText: selectedText,
            context: context,
            supersedesEventId: session.supersedesEventId
        )
        beginCorrectionRecording()
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
        isCorrectionRecording = false
        inPlaceCorrection = nil
        activeMode = nil
        shortcutBehavior = hotKey.behavior
        hotKey.setRecordingActive(false)
        audioRecorder.cancel()
        liveSpeechTranscriber.stop()
        // `setState(.idle)` re-runs the reducer, which hides the HUD outright
        // when nothing is live and keeps a still-running agent's surface up
        // when one is — so no explicit `overlay.hide()` here, which would
        // otherwise tear down a surface the run still owns.
        setState(.idle)
    }

    /// Discards whatever voice activity is currently in flight, wired to the
    /// hotkey's Esc-while-armed cancel (P1-10) and any overlay/processing
    /// cancel control. During a recording this stops + deletes the partial
    /// audio with no transcription; during processing it cancels the in-flight
    /// `processingTask` (our curl transport propagates Task cancellation) and
    /// resets to idle. Safe to call at any time — a no-op when nothing is
    /// active. The `AudioRecorder.stop()` hand-off (currentURL cleared once a
    /// recording ends) guarantees `audioRecorder.cancel()` here can never
    /// delete a file that transcription is still reading.
    func cancelActiveVoiceSession() {
        // While a task is waiting to go out (P1-6) Esc means exactly one thing:
        // don't send that. The recording is already over and the transcript is
        // already in hand, so there is nothing to tear down — recording the
        // keypress and letting the window resolve on its own terms is both
        // narrower and the only reading that produces the 「未下发」 the user
        // is asking for rather than a generic 「已取消」.
        if pendingDispatch != nil {
            recordPendingDispatchEscape()
            return
        }

        let wasActive = state == .listening
            || isStartingRecording
            || isCorrectionRecording
            || isBusy
        guard wasActive else {
            // Nothing is in flight, but Esc still means "done with this" for
            // an open correction window (P0-3): close it and take the hint
            // toast down. Silently, with no 「已取消」 — after a *successful*
            // delivery that message would read as if the text had been
            // un-delivered, which it has not.
            if correctionWindowSession != nil {
                updateCorrectionWindow(on: .cancelled)
                setState(.idle)
            }
            return
        }

        updateCorrectionWindow(on: .cancelled)
        cancel()

        let message = OpenTypeL10n.text("已取消", english: "Cancelled")
        let cancelled = ProcessingState.cancelled(message)
        setState(cancelled)
        scheduleIdle(after: cancelled)
    }

    func selectMode(_ mode: InputMode) {
        // The surface is derived from the mode, so a switch has to re-derive
        // it. A *settled* card is retired outright rather than left live but
        // invisible: it belongs to an interaction the user has moved on from,
        // and leaving it would both pop it back the next time they returned to
        // its mode and leave the panel showing a card the reducer no longer
        // agrees is there (which is what would make it undismissable —
        // dismissal routes through the reducer too). A still-working run keeps
        // its state, its polling, and its surface.
        switch currentVoiceSurfaceState() {
        case .result, .failed:
            hideVoiceSurface()
        case .hidden, .listening, .processing, .working, .asking:
            break
        }
        configuration.selectedMode = mode
        presentVoiceSurface()
        // Preempts a still-working run's pill for its 1.2s and restores it
        // afterwards, so switching modes mid-run still confirms the switch.
        overlay.show(state: .modeChanged, mode: mode)
    }

    /// The mode-switch chord's landing point (hold the recording modifier, tap
    /// Tab). `.listening` used to be refused here, which made the gesture dead:
    /// holding the recording modifier is *what starts a recording*, so past the
    /// 300ms long-press threshold every cycle was rejected. Now it is the
    /// gesture's main case, and it **retargets the recording being captured**
    /// rather than only the next-recording default — see `ModeCyclePolicy`.
    func cycleMode() {
        guard ModeCyclePolicy.allows(
            state: state,
            isBusy: isBusy,
            isStartingRecording: isStartingRecording
        ) else { return }

        let outcome = ModeCyclePolicy.cycle(
            selectedMode: configuration.selectedMode,
            activeMode: activeMode,
            state: state
        )

        guard state == .listening else {
            selectMode(outcome.selectedMode)
            return
        }

        // Deliberately not `selectMode(_:)`: its `.modeChanged` toast preempts
        // the panel for 1.2s, which here would cover the live pill of the
        // recording the user is still speaking into. Retargeting `activeMode`
        // moves `voiceSurfaceMode`, so re-deriving the surface makes the pill
        // itself show the new mode — the confirmation the toast would give,
        // without taking the pill away to give it.
        activeMode = outcome.activeMode
        configuration.selectedMode = outcome.selectedMode
        presentVoiceSurface()
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

    func changeTranscriptionLanguage(_ language: TranscriptionLanguage) {
        configuration.transcriptionLanguage = language
    }

    func changeTranscribeVariant(_ variant: TranscribeVariant) {
        configuration.transcribeVariant = variant
    }

    func changeAutomaticOwnerProfileUpdates(_ enabled: Bool) {
        configuration.automaticOwnerProfileUpdates = enabled
        guard enabled, configuration.agentMemoryEnabled else { return }
        agentMemory.refreshOwnerProfileIfNeeded(enabled: true)
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

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Opens the real, resizable app window (Part A) — settings, Memory
    /// panel, and Agent history all live there now, not in the menubar
    /// popover. Called from the popover's gear button.
    func openMainWindow() {
        onOpenMainWindowRequested?()
    }

    /// Opens the main app window, switches to the Agent tab, and opens the
    /// specific run's conversation thread there — the target of a tapped
    /// "Agent finished" notification
    /// (`AgentNotificationDelegate.onAgentRunTapped`). Also marks `runID` so
    /// the Agent tab's "running now" strip can scroll to and briefly
    /// highlight it, same as before, for runs that are still in flight when
    /// tapped (e.g. the "N running" affordance rather than a completion
    /// notification, which only fires once a run finishes).
    func focusAgentRun(_ runID: UUID) {
        focusedAgentRunID = runID
        if let record = agentRuns.first(where: { $0.id == runID }),
           let conversationId = record.conversationId {
            openAgentConversation(conversationId)
        }
        selectedTab = .sessions
        openMainWindow()
    }

    /// Refreshes the Q&A tab's conversation list (`GET /conversations?kind=ask`).
    func refreshAskConversations() async {
        await refreshConversations(
            kind: "ask",
            current: { [weak self] in self?.askConversations ?? [] },
            assign: { [weak self] in self?.askConversations = $0 }
        )
    }

    /// Refreshes the Agent tab's conversation list (`GET /conversations?kind=agent`).
    func refreshAgentConversations() async {
        await refreshConversations(
            kind: "agent",
            current: { [weak self] in self?.agentConversations ?? [] },
            assign: { [weak self] in self?.agentConversations = $0 }
        )
    }

    private struct ConversationsListResponseBody: Decodable { let conversations: [ConversationSummary] }

    private func refreshConversations(
        kind: String,
        current: () -> [ConversationSummary],
        assign: ([ConversationSummary]) -> Void
    ) async {
        let previous = current()
        do {
            let response: ConversationsListResponseBody = try await sidecarClient.request(
                method: "GET",
                path: "/conversations?kind=\(kind)"
            )
            // Successful decode is authoritative, even a real empty [].
            assign(AppModel.mergedRefresh(previous: previous, incoming: response.conversations))
        } catch {
            // Failed fetch: keep whatever is on screen rather than clobber to [].
            assign(AppModel.mergedRefresh(previous: previous, incoming: nil))
            print("OpenType: failed to refresh \(kind) conversations from sidecar: \(error.localizedDescription)")
        }
    }

    private struct ConversationDetailResponseBody: Decodable { let conversation: ConversationDetail }

    /// Opens a past Ask conversation as the Q&A tab's focused thread: fetches
    /// its full message history and marks it as the conversation a new
    /// Ask-mode dispatch should continue (`focusedAskConversationId`).
    func openAskConversation(_ id: Int) {
        focusedAskConversationId = id
        Task { [weak self] in
            await self?.loadConversationDetail(id: id) { [weak self] in self?.askConversationDetail = $0 }
        }
    }

    /// Opens a past Agent conversation as the Agent tab's focused thread,
    /// same as `openAskConversation(_:)` but for `focusedAgentConversationId`.
    func openAgentConversation(_ id: Int) {
        focusedAgentConversationId = id
        Task { [weak self] in
            await self?.loadConversationDetail(id: id) { [weak self] in self?.agentConversationDetail = $0 }
        }
    }

    private func loadConversationDetail(
        id: Int,
        assign: @escaping (ConversationDetail?) -> Void
    ) async {
        do {
            let response: ConversationDetailResponseBody = try await sidecarClient.request(
                method: "GET",
                path: "/conversations/\(id)"
            )
            assign(response.conversation)
        } catch {
            assign(nil)
            print("OpenType: failed to load conversation \(id) from sidecar: \(error.localizedDescription)")
        }
    }

    /// Clears the Q&A tab's focused conversation, either because the user
    /// left the thread view or tapped the tab's explicit "new conversation"
    /// affordance — the next Ask-mode dispatch starts a fresh conversation.
    func startNewAskConversation() {
        focusedAskConversationId = nil
        askConversationDetail = nil
    }

    /// Agent-tab counterpart to `startNewAskConversation()`.
    func startNewAgentConversation() {
        focusedAgentConversationId = nil
        agentConversationDetail = nil
    }

    /// Explicit dismissal entry point for a live Ask, in addition to the
    /// voice surface's own close button / Escape / click-outside handling.
    func dismissAskPanel() {
        // Abort any in-flight Ask request so a late answer can't overwrite the
        // clipboard or re-populate a surface the user just closed (P1-10
        // "ghost answer"). The SidecarClient transport propagates this
        // cancellation down to the underlying curl process.
        askTask?.cancel()
        askTask = nil
        askPanelState = nil
    }

    /// Takes the Agent run off the voice surface and stops progress polling.
    /// Deliberately does NOT cancel the run itself: the detached `/agent/run`
    /// task keeps going, and every existing delivery path (clipboard +
    /// completion notification + audit trail + Agent tab/conversation) is
    /// untouched — the surface is a view over the run, not its owner.
    func dismissAgentPanel() {
        agentProgressPollTask?.cancel()
        agentProgressPollTask = nil
        agentPanelState = nil
    }

    // MARK: - Unified voice surface

    /// The mode the surface is currently speaking for: the mode locked in by
    /// the active recording if there is one, otherwise the mode of the run
    /// that is still on the surface, otherwise the selected mode.
    private var voiceSurfaceMode: InputMode {
        activeMode ?? surfaceRunMode ?? configuration.selectedMode
    }

    /// The mode of the run currently occupying the surface, when that is
    /// unambiguous. A dispatched run outlives `activeMode` (cleared by
    /// `process(audioURL:)`'s `defer`) and need not match `selectedMode` at
    /// all: `VoiceModeRouter` can route a recording into `.agent` from any
    /// mode, and the practice flow forces `.ask`. Without this the surface
    /// would be re-derived for a mode that owns nothing the moment the
    /// recording ends — a voice-routed Agent run's ticker and result card
    /// would vanish on the next poll tick. When both sides are live the
    /// selected mode arbitrates, which is the same "the active mode picks"
    /// rule the reducer itself applies.
    private var surfaceRunMode: InputMode? {
        switch (askPanelState, agentPanelState) {
        case (.some, nil): return .ask
        case (nil, .some): return .agent
        case (.some, .some), (nil, nil): return nil
        }
    }

    /// The surface state as the reducer sees it right now — the single
    /// derivation used both for rendering and for deciding what a dismissal
    /// must do.
    private func currentVoiceSurfaceState() -> VoiceSurfaceState {
        VoiceSurfaceState.reduce(
            mode: voiceSurfaceMode,
            processing: state,
            ask: askPanelState,
            agent: agentPanelState
        )
    }

    /// Pushes the freshly-reduced surface to the one floating panel. Called
    /// after anything that can change it: a `ProcessingState` transition, an
    /// ask answer landing, a polled agent step, a run settling, a dismissal.
    /// A `.hidden` result hands the panel back to the legacy transcribe
    /// HUD/toast path inside `OverlayController`.
    private func presentVoiceSurface() {
        overlay.apply(
            currentVoiceSurfaceState(),
            state: state,
            mode: voiceSurfaceMode
        )
    }

    /// Escape, the 关闭 button, or a click outside a finished card. Routes
    /// through `VoiceSurfaceState.dismissalEffect`, so only a still-thinking
    /// ask is cancelled — dismissing an agent run never cancels it.
    func dismissVoiceSurface() {
        switch currentVoiceSurfaceState().dismissalEffect {
        case .cancelAsk:
            dismissAskPanel()
        case .none:
            hideVoiceSurface()
        }
    }

    /// Clears whichever panel state is feeding the surface for the active
    /// mode, without cancelling anything. Mirrors the reducer's
    /// active-mode-only rule so dismissing an ask card can't also take down a
    /// long agent run still ticking in the background.
    private func hideVoiceSurface() {
        switch voiceSurfaceMode {
        case .ask:
            askPanelState = nil
        case .agent:
            dismissAgentPanel()
        case .transcribe:
            break
        }
    }

    /// The 打开主窗口 button. For agent it routes through the same
    /// open-main-window-to-Agent-tab path a tapped completion notification
    /// uses (`focusAgentRun(_:)` — the surface's `runId` is the
    /// `AgentRunRecord.id` it was dispatched with); for ask it opens the Q&A
    /// tab. Either way the surface then goes away.
    private func openMainWindowFromVoiceSurface() {
        switch voiceSurfaceMode {
        case .agent:
            if let state = agentPanelState, let runID = UUID(uuidString: state.runId) {
                focusAgentRun(runID)
            } else {
                selectedTab = .sessions
                openMainWindow()
            }
        case .ask, .transcribe:
            // One list now, so both kinds land in the same place. The row's
            // type dot is what tells them apart, not which tab you are on.
            selectedTab = .sessions
            openMainWindow()
        }
        hideVoiceSurface()
    }

    private func syncReviewPanel() {
        if let reviewPanelState {
            reviewPanel.show(originalTranscript: reviewPanelState.originalTranscript)
        } else {
            reviewPanel.hide()
        }
    }

    /// Starts a Review session: records the bookkeeping needed to keep
    /// appending linked audit events for this session
    /// (`reviewSession`/`ReviewSession`) and shows the panel
    /// (`reviewPanelState`). Called from `process(audioURL:)`'s `.transcribe`
    /// branch once the original dictation has been transcribed and its
    /// `.recognized` audit event appended — `recognizedEventId` is that
    /// event's id, the first link in this session's `supersedesEventId`
    /// chain.
    private func beginReviewSession(
        transcript: String,
        requestID: UUID,
        recognizedEventId: UUID
    ) {
        reviewSession = ReviewSession(
            requestId: requestID,
            capturedContext: capturedContext,
            lastEventId: recognizedEventId
        )
        reviewPanelState = ReviewPanelState(
            sessionId: requestID,
            originalTranscript: transcript
        )
    }

    /// Handles the audio from a Review-panel voice *correction* (routed here
    /// by `finishRecording()` when `isCorrectionRecording` is set): ASR only
    /// (no `VoiceModeRouter`/mode routing — the spoken text is always taken
    /// as a correction instruction, never a mode-switch command), then
    /// `POST /transcribe/correct` with the panel's current full text and
    /// selection, then splices the replacement back into the panel in place.
    /// Records one `.corrected` audit event chained to the previous event in
    /// this session via `supersedesEventId`.
    private func processCorrection(audioURL: URL) async {
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            isCorrectionRecording = false
        }

        // Two correction paths share this recording, and which one this is was
        // decided back at hotkey-press time (`hotKeyPressed`): the Review
        // panel's, or Direct mode's in-place one (P0-3).
        if let session = inPlaceCorrection {
            await processInPlaceCorrection(audioURL: audioURL, session: session)
            return
        }

        guard let session = reviewSession else {
            setState(.idle)
            return
        }
        guard let selection = reviewPanel.currentSelection() else {
            let message = OpenTypeL10n.text(
                "请先在复核面板中选中要修改的文字",
                english: "Select text in the Review panel first"
            )
            let cancelled = ProcessingState.cancelled(message)
            setState(cancelled)
            scheduleIdle(after: cancelled)
            return
        }

        do {
            setState(.transcribing)
            let instruction = try await transcribeLocally(audioURL: audioURL)
            try Task.checkCancellation()

            setState(.transforming)
            reviewPanel.beginCorrecting()
            let fullText = reviewPanel.currentText()

            let response: CorrectionResponseBody
            do {
                response = try await requestCorrection(
                    fullText: fullText,
                    range: selection.range,
                    instruction: instruction
                )
            } catch {
                reviewPanel.endCorrecting()
                throw OpenTypeError.service(
                    "修改请求失败：\(error.localizedDescription)"
                )
            }
            try Task.checkCancellation()

            let updatedText = reviewPanel.applyCorrection(
                response.replacement,
                in: selection.range
            )
            reviewPanel.endCorrecting()

            let eventId = UUID()
            recordAuditEvent(
                ImmutableAuditEvent(
                    id: eventId,
                    requestId: session.requestId,
                    status: .corrected,
                    mode: .transcribe,
                    rawTranscript: instruction,
                    effectiveInput: response.replacement,
                    selectedContext: selection.substring,
                    result: updatedText,
                    provider: sidecarTextProvider,
                    model: sidecarTextModel,
                    error: nil,
                    supersedesEventId: session.lastEventId
                )
            )
            reviewSession?.lastEventId = eventId

            playFeedbackSound(.done)
            setState(.idle)
        } catch is CancellationError {
            reviewPanel.endCorrecting()
            setState(.idle)
        } catch {
            reviewPanel.endCorrecting()
            reviewPanel.showHint(ErrorMessagePresenter.message(for: error))
            setState(.idle)
        }
    }

    private struct CorrectionRequestBody: Encodable {
        let fullText: String
        let selectionStart: Int
        let selectionEnd: Int
        let instruction: String
    }

    private struct CorrectionResponseBody: Decodable {
        let replacement: String
        /// What this correction also taught the entity dictionary, when it
        /// qualified (P0-2 — the sidecar omits the key entirely rather than
        /// sending null). Decoded so the response is read as the shape it
        /// actually has; the 「已记住」 affordance that will surface it is a
        /// separate piece of work, so nothing reads this yet.
        let learned: LearnedTerm?

        struct LearnedTerm: Decodable {
            let canonicalTerm: String
            let alias: String
        }
    }

    /// The one `POST /transcribe/correct` call, shared by both correction
    /// paths — the Review panel's and Direct mode's in-place one. `range` is
    /// UTF-16 code units, which is what the sidecar's JS string slicing means
    /// by the same integers (see `TextSpanCorrection`).
    private func requestCorrection(
        fullText: String,
        range: NSRange,
        instruction: String
    ) async throws -> CorrectionResponseBody {
        try await sidecarClient.request(
            method: "POST",
            path: "/transcribe/correct",
            body: CorrectionRequestBody(
                fullText: fullText,
                selectionStart: range.location,
                selectionEnd: range.location + range.length,
                instruction: instruction
            )
        )
    }

    /// One in-place correction round (P0-3): ASR only (never `VoiceModeRouter`
    /// — the spoken text is always an instruction, never a mode-switch
    /// command, exactly as in the Review path), then `/transcribe/correct`
    /// with the selection as the *whole* document, then Cmd+V over the still-
    /// live selection.
    ///
    /// The span is `0..<selectedText.utf16.count` because there is no
    /// surrounding document: the user pointed at the text to fix, so that text
    /// is both the context and the target. The replacement then lands via the
    /// ordinary `ContextBridge.insert` — Cmd+V natively replaces a selection —
    /// and is copied to the clipboard like every other result, so the always-
    /// copy invariant holds here too.
    private func processInPlaceCorrection(
        audioURL: URL,
        session: InPlaceCorrectionSession
    ) async {
        defer { inPlaceCorrection = nil }

        do {
            setState(.transcribing)
            let instruction = try await transcribeLocally(audioURL: audioURL)
            try Task.checkCancellation()

            setState(.transforming)
            let selected = session.selectedText
            let response: CorrectionResponseBody
            do {
                response = try await requestCorrection(
                    fullText: selected,
                    range: NSRange(
                        location: 0,
                        length: (selected as NSString).length
                    ),
                    instruction: instruction
                )
            } catch {
                throw OpenTypeError.service(
                    "修改请求失败：\(error.localizedDescription)"
                )
            }
            try Task.checkCancellation()

            let replacement = response.replacement
            var completionState: ProcessingState = .success

            // The selection was read at hotkey-press time, but this write
            // happens an ASR + `/transcribe/correct` round trip later — a
            // second or more — and `insert` is Cmd+V, which replaces whatever
            // is selected *now*. So the target is re-read here and the paste
            // is refused unless it is still the same selection in the same
            // app. The delivery path guards its own write at write time for
            // the same reason (`OutputDeliveryPolicy.shouldInsert` against a
            // freshly read frontmost app); this path needs the stricter of the
            // two checks, because a replacement derived from one span pasted
            // over a *different* span destroys text the user never pointed at,
            // which is worse than landing dictated text in the wrong window.
            // Downgrading costs nothing: the replacement is copied either way.
            lastDeliveryNotice = nil
            let target = contextBridge.capture()
            let stillTheSameSelection = OutputDeliveryPolicy.shouldInsert(
                capturedBundleId: session.context.bundleIdentifier,
                frontmostBundleId: target.bundleIdentifier
            ) && target.selectedText == session.selectedText

            if stillTheSameSelection {
                setState(.inserting)
                do {
                    try await contextBridge.insert(replacement)
                } catch {
                    completionState = .copied
                }
            } else {
                completionState = .copied
                lastDeliveryNotice = OpenTypeL10n.text(
                    "选区已改变，纠正结果已复制到剪贴板",
                    english: "The selection changed, so the correction was copied to the clipboard instead of pasted."
                )
            }
            contextBridge.copyToClipboard(replacement)

            lastResult = replacement
            lastTranscript = instruction
            lastApplication = session.context.applicationName
            lastResultWasPractice = false

            let eventId = UUID()
            recordAuditEvent(
                ImmutableAuditEvent(
                    id: eventId,
                    requestId: session.requestId,
                    status: .corrected,
                    mode: .transcribe,
                    rawTranscript: instruction,
                    effectiveInput: replacement,
                    selectedContext: selected,
                    result: replacement,
                    provider: sidecarTextProvider,
                    model: sidecarTextModel,
                    error: nil,
                    supersedesEventId: session.supersedesEventId
                )
            )

            // Re-arm rather than end: fixing two words in a row is common, and
            // the second fix should not cost a re-dictation.
            reArmCorrectionWindow(after: eventId)

            playFeedbackSound(.done)
            setState(completionState)
            scheduleIdle(after: completionState, delay: correctionWindowIdleDelay)
        } catch is CancellationError {
            // Whatever cancelled this round has already closed the window
            // itself — Esc through `cancelActiveVoiceSession`, a superseding
            // dictation through `beginRecording` — so there is nothing left
            // here to close.
            setState(.idle)
        } catch {
            // The window keeps running on its original clock (see
            // `CorrectionWindow.Event.correctionFailed`) — the failure toast
            // covers the hint while it is up, and whatever seconds are left
            // are still the user's to retry in.
            updateCorrectionWindow(on: .correctionFailed)
            fail(error)
        }
    }

    // MARK: - Post-delivery correction window (P0-3)

    /// How long the delivery toast stays up, and therefore how long `state`
    /// must keep saying so: while a window is open the toast *is* the
    /// affordance, so letting `state` fall back to idle after the usual second
    /// would let the next surface push tear the hint down early.
    private var correctionWindowIdleDelay: TimeInterval {
        correctionWindowSession == nil ? 1 : CorrectionWindow.windowSeconds
    }

    /// Opens (or replaces) the window after a delivery. The event carries the
    /// mode and variant so `CorrectionWindow.reduce` — not this call site —
    /// decides whether a window exists at all; an ask/agent or Review delivery
    /// closes any window a previous Direct delivery had opened.
    private func armCorrectionWindow(
        mode: InputMode,
        variant: TranscribeVariant,
        context: CapturedContext,
        requestId: UUID,
        completedEventId: UUID,
        at now: Date = Date()
    ) {
        let window = CorrectionWindow.reduce(
            correctionWindowSession?.window,
            on: .delivered(
                at: now,
                capturedBundleId: context.bundleIdentifier,
                mode: mode,
                variant: variant
            )
        )
        correctionWindowSession = window.map {
            CorrectionWindowSession(
                window: $0,
                requestId: requestId,
                supersedesEventId: completedEventId
            )
        }
        syncCorrectionWindowAffordance()
    }

    /// Restarts the clock after a correction landed, chaining the next
    /// round's `supersedesEventId` to the `.corrected` event just written.
    private func reArmCorrectionWindow(after eventId: UUID, at now: Date = Date()) {
        guard let session = correctionWindowSession,
              let window = CorrectionWindow.reduce(
                session.window,
                on: .correctionSucceeded(at: now)
              )
        else {
            correctionWindowSession = nil
            syncCorrectionWindowAffordance()
            return
        }
        correctionWindowSession = CorrectionWindowSession(
            window: window,
            requestId: session.requestId,
            supersedesEventId: eventId
        )
        syncCorrectionWindowAffordance()
    }

    /// Every other window transition (`.recordingStarted`, `.cancelled`,
    /// `.correctionFailed`), routed through the same reducer so this side
    /// holds no opinion of its own about which ones close it.
    private func updateCorrectionWindow(on event: CorrectionWindow.Event) {
        guard let session = correctionWindowSession else { return }
        if let window = CorrectionWindow.reduce(session.window, on: event) {
            correctionWindowSession?.window = window
        } else {
            correctionWindowSession = nil
        }
        syncCorrectionWindowAffordance()
    }

    /// Keeps the HUD's knowledge of the window in step with the window. Per
    /// the spec, a window the user cannot see does not exist as a feature, so
    /// these two must never disagree.
    private func syncCorrectionWindowAffordance() {
        overlay.correctionWindowArmed = correctionWindowSession != nil
    }

    /// Commits the current Review-panel text (Enter button / Cmd+Return) —
    /// inserts it via the same `ContextBridge.insert` delivery path Direct
    /// mode uses, into the app that was focused when the Review dictation
    /// started (the panel is a `.nonactivatingPanel`, so that app has stayed
    /// frontmost this whole time — see `ReviewPanelController`'s doc
    /// comment), always keeps the clipboard copy, records history, and
    /// appends the session's final `.completed` audit event.
    private func commitReview() {
        guard let session = reviewSession,
              let panelState = reviewPanelState else {
            reviewPanelState = nil
            reviewSession = nil
            return
        }

        let finalText = reviewPanel.currentText()
        reviewPanelState = nil
        reviewSession = nil

        lastResult = finalText
        lastTranscript = panelState.originalTranscript
        lastApplication = session.capturedContext.applicationName
        lastResultWasPractice = false

        Task { [weak self] in
            guard let self else { return }
            var completionState: ProcessingState = .success
            do {
                try await self.contextBridge.insert(finalText)
            } catch {
                completionState = .copied
            }
            self.contextBridge.copyToClipboard(finalText)

            if self.configuration.keepHistory {
                self.history.add(
                    HistoryEntry(
                        mode: .transcribe,
                        applicationName: session.capturedContext.applicationName,
                        transcript: panelState.originalTranscript,
                        result: finalText,
                        contextPreview: session.capturedContext.selectedText.map {
                            String($0.prefix(240))
                        }
                    )
                )
            }

            self.recordAuditEvent(
                ImmutableAuditEvent(
                    requestId: session.requestId,
                    status: .completed,
                    mode: .transcribe,
                    rawTranscript: panelState.originalTranscript,
                    effectiveInput: finalText,
                    selectedContext: session.capturedContext.selectedText,
                    result: finalText,
                    provider: nil,
                    model: nil,
                    error: nil,
                    supersedesEventId: session.lastEventId
                )
            )

            self.playFeedbackSound(.done)
            self.setState(completionState)
            self.scheduleIdle(after: completionState)
        }
    }

    /// Discards the Review session (Cancel button / Escape / click outside)
    /// — nothing is inserted or copied. Records the session's final
    /// `.cancelled` audit event so the discard itself is part of the durable
    /// record, not silently dropped.
    private func cancelReview() {
        guard let session = reviewSession else {
            reviewPanelState = nil
            return
        }
        let panelState = reviewPanelState
        let currentText = reviewPanel.currentText()
        reviewPanelState = nil
        reviewSession = nil

        let message = OpenTypeL10n.text(
            "已取消，未写入任何内容",
            english: "Cancelled — nothing was inserted"
        )
        recordAuditEvent(
            ImmutableAuditEvent(
                requestId: session.requestId,
                status: .cancelled,
                mode: .transcribe,
                rawTranscript: panelState?.originalTranscript ?? "",
                effectiveInput: currentText,
                selectedContext: session.capturedContext.selectedText,
                result: nil,
                provider: nil,
                model: nil,
                error: message,
                supersedesEventId: session.lastEventId
            )
        )

        let cancelled = ProcessingState.cancelled(message)
        setState(cancelled)
        scheduleIdle(after: cancelled)
    }

    private var isBusy: Bool {
        switch state {
        case .transcribing, .transforming, .inserting:
            return true
        default:
            return false
        }
    }

    // MARK: - Recording clock and duration limits (P2-10)

    /// Starts timing the recording that just began: the pill's `m:ss` readout,
    /// the two-minute warning, and the five-minute auto-stop
    /// (`RecordingClock`/`RecordingLimits`).
    ///
    /// Half-second ticks: fast enough that neither threshold can be stepped
    /// over, slow enough to cost nothing. The readout is pushed immediately so
    /// the pill reads `0:00` from the first frame rather than appearing a
    /// second later and jogging the layout sideways.
    private func startRecordingClock() {
        stopRecordingClock()
        recordingStartedAt = Date()
        didWarnAboutRecordingLength = false
        overlay.updateRecordingElapsed(RecordingClock.elapsedText(seconds: 0))
        recordingClockTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickRecordingClock()
            }
        }
    }

    private func stopRecordingClock() {
        guard recordingClockTimer != nil || recordingStartedAt != nil else { return }
        recordingClockTimer?.invalidate()
        recordingClockTimer = nil
        recordingStartedAt = nil
        didWarnAboutRecordingLength = false
        overlay.clearRecordingElapsed()
    }

    /// One tick: ask `RecordingLimits` what this instant means, act on it, and
    /// otherwise just move the readout along.
    ///
    /// `isHotKeyHeld` is passed through and makes no difference by design — a
    /// stuck or repeating modifier is indistinguishable from a held key here,
    /// and is exactly the case the cap exists for. See `RecordingLimits.action`.
    private func tickRecordingClock() {
        guard state == .listening, let startedAt = recordingStartedAt else {
            stopRecordingClock()
            return
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        let action = RecordingLimits.action(
            elapsed: elapsed,
            alreadyWarned: didWarnAboutRecordingLength,
            hotKeyHeld: isHotKeyHeld
        )

        if action == .warn {
            didWarnAboutRecordingLength = true
            overlay.showRecordingWarning(RecordingLimits.warningText)
        }

        guard let termination = RecordingLimits.termination(for: action) else {
            overlay.updateRecordingElapsed(
                RecordingClock.elapsedText(seconds: elapsed)
            )
            return
        }

        switch termination {
        case .finishAndDeliver:
            finishRecordingAtDurationLimit()
        case .discard:
            // Unreachable: `RecordingLimits.termination(for:)` only ever
            // returns `.finishAndDeliver`, and `RecordingLimitsTests` sweeps
            // the whole input space to keep it that way. Handled the same way
            // on purpose — this call site is deliberately not capable of
            // throwing away a recording, because the file the user has spent
            // five minutes filling is the one thing the safety net must not
            // destroy. Making the auto-stop able to discard means changing this
            // branch, in the open, rather than inheriting it by accident.
            finishRecordingAtDurationLimit()
        }
    }

    /// The five-minute cap firing.
    ///
    /// Goes through `hotKeyReleased()` — the *exact* path letting go of the
    /// hotkey takes — and pointedly not through `cancel()` /
    /// `cancelActiveVoiceSession()`, which call `audioRecorder.cancel()` and
    /// delete the audio file. 「5 分钟自动停止并正常交付（不是丢弃）」: losing
    /// five minutes of someone's dictation to the safety net meant to protect
    /// them is the worst outcome this feature can produce, so the recording is
    /// stopped, transcribed and delivered exactly as if the user had released
    /// the key themselves.
    ///
    /// The clock is stopped first: `hotKeyReleased()` can decline to finish
    /// (its `guard state == .listening`), and a tick that stopped nothing would
    /// come round again half a second later and try to stop a recording that is
    /// already being transcribed.
    ///
    /// Clearing `isHotKeyHeld` is what `hotKeyReleased()` does anyway; the
    /// physical modifier may well still be down, and the real release that
    /// follows lands on the same `guard` and does nothing.
    private func finishRecordingAtDurationLimit() {
        stopRecordingClock()
        hotKeyReleased()
    }

    private func finishRecording() {
        hotKey.setRecordingActive(false)
        liveSpeechTranscriber.stop()
        do {
            let audioURL = try audioRecorder.stop()
            // The instant the recording stopped, which is the instant the user
            // started waiting. Stamped here rather than derived later because
            // nothing downstream can reconstruct it: the `.recognized` event is
            // written *after* ASR returns, so a timestamp taken there has
            // already lost the recording and the decode. `recordingStartedAt`
            // is the other end of the same recording, not this one, and the
            // clock that owns it has already been stopped by `setState`.
            let recordingEndedAt = Date()
            playFeedbackSound(.release)
            if isCorrectionRecording {
                processingTask = Task { [weak self] in
                    await self?.processCorrection(audioURL: audioURL)
                }
            } else {
                processingTask = Task { [weak self] in
                    await self?.process(
                        audioURL: audioURL,
                        recordingEndedAt: recordingEndedAt
                    )
                }
            }
        } catch {
            isCorrectionRecording = false
            inPlaceCorrection = nil
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

    /// Audit labels (`ImmutableAuditStore`) for whichever provider actually
    /// served the request. Reflects the user-configured provider (Settings'
    /// "AI 模型"/"语音识别" sections, `ProviderSetupViews.swift`) once one has
    /// been explicitly saved via the provider-config system, falling back to
    /// the always-available env-based DeepSeek default / local MLX-Whisper
    /// otherwise -- the same "explicit config wins, otherwise env fallback"
    /// precedence the sidecar itself applies (`sidecar/src/server.ts`'s
    /// `resolveChat`/`resolveTranscribe`). `llmConfigSummary`/
    /// `whisperConfigSummary` are refreshed on sidecar-ready and after every
    /// successful save (see `refreshProviderConfigStatus()` and friends), so
    /// this stays in sync without a dedicated audit-time round trip.
    private var sidecarTextModel: String {
        llmConfigSummary?.model ?? "deepseek-v4-flash"
    }
    private var sidecarTextProvider: String {
        llmConfigSummary?.type?.rawValue ?? "deepseek"
    }
    private var sidecarASRProvider: String {
        whisperConfigSummary?.mode == .remote ? "remote-whisper" : "mlx-whisper"
    }

    /// Request/response bodies for the sidecar's `/asr/transcribe` endpoint
    /// (proxies to the local MLX-Whisper python process -- see
    /// `sidecar/src/asr/whisperClient.ts`), used by `transcribeLocally(audioURL:)`.
    private struct TranscribeRequestBody: Encodable { let audioBase64: String }
    private struct TranscribeResponseBody: Decodable { let text: String }

    /// Request/response bodies for the sidecar's `/oneshot/ask` endpoint,
    /// used by the `ask` mode branch below. `conversationId` continues an
    /// existing conversation when set (the Q&A tab's focused thread);
    /// `nil` starts a fresh one, same as the original one-shot behavior.
    private struct AskRequestBody: Encodable { let question: String; let conversationId: Int? }
    private struct AskResponseBody: Decodable { let result: String; let conversationId: Int }

    /// Request/response bodies for the sidecar's `/agent/run` endpoint, used
    /// by the `agent` mode branch below. This runs a full agent loop
    /// (potentially calling MCP tools) as a single blocking HTTP call and can
    /// take noticeably longer than `/oneshot/ask`; `steps` carries the full
    /// step-by-step log after the fact for display in the Agent tab's
    /// "running now" strip. `conversationId` works the same as
    /// `AskRequestBody`'s, keyed off the Agent tab's focused thread instead.
    /// `runId` is the client-generated id (the `AgentRunRecord.id`'s UUID
    /// string) that keys the sidecar's live progress registry, so the
    /// Swift side can poll `GET /agent/progress/:runId` while this
    /// blocking call is still running.
    private struct AgentRunRequestBody: Encodable { let task: String; let context: String?; let conversationId: Int?; let runId: String? }
    private struct AgentRunResponseBody: Decodable {
        let result: String
        let steps: [AgentStepSummary]
        let conversationId: Int
    }

    private struct MemoryTermsResponseBody: Decodable { let terms: [EntityTermSummary] }
    private struct MemoryConsolidationRunsResponseBody: Decodable { let runs: [ConsolidationRunSummary] }
    private struct MemoryOwnerFactsResponseBody: Decodable { let ownerFacts: [OwnerFactSummary] }

    /// Reloads the Settings "Memory" panel (design doc §4.1: the human-review
    /// surface over the sidecar's entity dictionary, owner facts and
    /// consolidation run log) from `GET /memory/terms`,
    /// `/memory/consolidation-runs` and `/memory/owner-facts`. Read half only —
    /// the panel's edits go through the mutation methods below, which reconcile
    /// their own row rather than refetching. This backs a convenience display,
    /// not the critical recording/transcription path, so a sidecar hiccup
    /// (not started yet, transient failure) just yields an empty list plus a
    /// logged message rather than throwing.
    func refreshMemoryPanel() async {
        let previousTerms = memoryTerms
        do {
            let response: MemoryTermsResponseBody = try await sidecarClient.request(
                method: "GET",
                path: "/memory/terms"
            )
            memoryTerms = AppModel.mergedRefresh(previous: previousTerms, incoming: response.terms)
        } catch {
            memoryTerms = AppModel.mergedRefresh(previous: previousTerms, incoming: nil)
            print("OpenType: failed to refresh memory terms from sidecar: \(error.localizedDescription)")
        }

        let previousRuns = memoryConsolidationRuns
        do {
            let response: MemoryConsolidationRunsResponseBody = try await sidecarClient.request(
                method: "GET",
                path: "/memory/consolidation-runs"
            )
            memoryConsolidationRuns = AppModel.mergedRefresh(previous: previousRuns, incoming: response.runs)
        } catch {
            memoryConsolidationRuns = AppModel.mergedRefresh(previous: previousRuns, incoming: nil)
            print("OpenType: failed to refresh memory consolidation runs from sidecar: \(error.localizedDescription)")
        }

        let previousFacts = memoryOwnerFacts
        do {
            let response: MemoryOwnerFactsResponseBody = try await sidecarClient.request(
                method: "GET",
                path: "/memory/owner-facts"
            )
            memoryOwnerFacts = AppModel.mergedRefresh(previous: previousFacts, incoming: response.ownerFacts)
        } catch {
            memoryOwnerFacts = AppModel.mergedRefresh(previous: previousFacts, incoming: nil)
            print("OpenType: failed to refresh memory owner facts from sidecar: \(error.localizedDescription)")
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

    // MARK: - Memory dictionary management (P0-4)
    //
    // The write half of the Settings "Memory" panel: the entity dictionary
    // stopped being a read-only list and became an editable table, so a user
    // can fix a term the machine mis-learned (or delete one the agent planted
    // from untrusted context, P1-12) instead of only watching it be wrong.
    // Thin wrappers around `POST/PUT/DELETE /memory/terms` and
    // `DELETE /memory/owner-facts/:id`, in the same shape as the provider
    // section below: call the sidecar, then reconcile local state.

    private struct MemoryTermMutationResponseBody: Decodable { let term: EntityTermSummary }

    /// Creates a term from what the user typed into the dictionary panel.
    /// Deliberately sends no confidence/origin — the sidecar pins an
    /// owner-typed term at confidence 1.0 / origin "owner".
    ///
    /// The sidecar merges by canonical-or-alias match, so the response may be
    /// an *existing* row rather than a new one; the reconcile below is keyed on
    /// its id precisely for that case, since blindly appending would render a
    /// merged term twice.
    @discardableResult
    func createMemoryTerm(canonicalTerm: String, aliases: [String]) async -> Bool {
        do {
            let response: MemoryTermMutationResponseBody = try await sidecarClient.request(
                method: "POST",
                path: "/memory/terms",
                body: MemoryTermCreateRequest(canonicalTerm: canonicalTerm, aliases: aliases)
            )
            applyMemoryTerm(response.term)
            memoryEditError = nil
            return true
        } catch {
            recordMemoryEditFailure("create", error)
            return false
        }
    }

    /// Applies an inline edit to one term. Every argument is a patch field:
    /// `nil` means "leave it alone", which `MemoryTermUpdateRequest` encodes by
    /// omitting the key rather than sending null.
    @discardableResult
    func updateMemoryTerm(
        id: Int,
        canonicalTerm: String? = nil,
        aliases: [String]? = nil,
        confidence: Double? = nil
    ) async -> Bool {
        do {
            let response: MemoryTermMutationResponseBody = try await sidecarClient.request(
                method: "PUT",
                path: "/memory/terms/\(id)",
                body: MemoryTermUpdateRequest(
                    canonicalTerm: canonicalTerm,
                    aliases: aliases,
                    confidence: confidence
                )
            )
            applyMemoryTerm(response.term)
            memoryEditError = nil
            return true
        } catch {
            recordMemoryEditFailure("update", error)
            return false
        }
    }

    @discardableResult
    func deleteMemoryTerm(id: Int) async -> Bool {
        do {
            let _: MemoryDeletionResponseBody = try await sidecarClient.request(
                method: "DELETE",
                path: "/memory/terms/\(id)"
            )
            memoryTerms.removeAll { $0.id == id }
            memoryEditError = nil
            return true
        } catch {
            recordMemoryEditFailure("delete", error)
            return false
        }
    }

    /// Deletes one free-text owner fact. The endpoint has existed since the
    /// memory-poisoning close (P1-12) with no UI in front of it; the dictionary
    /// panel is where a user actually goes looking for a planted fact, so the
    /// delete lives there.
    @discardableResult
    func deleteMemoryOwnerFact(id: Int) async -> Bool {
        do {
            let _: MemoryDeletionResponseBody = try await sidecarClient.request(
                method: "DELETE",
                path: "/memory/owner-facts/\(id)"
            )
            memoryOwnerFacts.removeAll { $0.id == id }
            memoryEditError = nil
            return true
        } catch {
            recordMemoryEditFailure("owner-fact delete", error)
            return false
        }
    }

    private struct MemoryDeletionResponseBody: Decodable { let deleted: Bool }

    /// Records a failed dictionary edit: a readable line for the panel (via the
    /// same `ErrorMessagePresenter` every other user-facing failure goes
    /// through — a raw `SidecarClientError` description is English developer
    /// text with the response body inlined), and the untranslated detail on the
    /// console, which is the only place it is still diagnosable.
    private func recordMemoryEditFailure(_ operation: String, _ error: Error) {
        memoryEditError = ErrorMessagePresenter.message(for: error)
        print("OpenType: memory dictionary \(operation) failed: \(error.localizedDescription)")
    }

    /// Folds a mutation's resulting term into `memoryTerms` by id — replacing
    /// the row if it is already on screen (an edit, or a create that merged
    /// into an existing term), appending it otherwise.
    private func applyMemoryTerm(_ term: EntityTermSummary) {
        if let index = memoryTerms.firstIndex(where: { $0.id == term.id }) {
            memoryTerms[index] = term
        } else {
            memoryTerms.append(term)
        }
    }

    // MARK: - MCP server configuration (P2-13)
    //
    // Thin wrappers around the sidecar's `/config/mcp*` endpoints
    // (`sidecar/src/agent/mcpConfigRoutes.ts`), in the same shape as the
    // provider section below: call the sidecar, then reconcile local state.
    // Until this panel existed, `OPENTYPE_MCP_SERVERS` was the only way to
    // attach MCP tools to Agent mode -- and a packaged `.app` user has no way
    // to set an env var, so the capability was unreachable outside a dev
    // checkout.
    //
    // Everything MCP-related on this type lives inside this block, state
    // included, so it stays one clearly delimited section.

    /// Last `GET /config/mcp`. `nil` means "not fetched yet" (the panel shows a
    /// loading-ish empty state) as distinct from "fetched, no servers".
    @Published private(set) var mcpConfig: McpConfigSummary?
    /// Last failure from an MCP panel edit (add/edit/delete/test), shown
    /// in-place and cleared by the next successful one -- same contract as
    /// `memoryEditError`.
    @Published private(set) var mcpEditError: String?

    /// Hands a failure over to whichever surface is better placed to show it.
    /// `McpServerEditor` calls this after a failed save: it renders the message
    /// beside its own Save button (the provider panels' idiom), and the
    /// panel-level banner would otherwise repeat the same sentence at the far
    /// end of the section.
    func clearMcpEditError() {
        mcpEditError = nil
    }

    private struct McpServerMutationResponseBody: Decodable { let server: McpServerSummary }
    private struct McpDeletionResponseBody: Decodable { let deleted: Bool }
    /// The `{ error }` envelope every `/config/mcp*` route answers a 400/404
    /// with. Worth decoding rather than falling back to a generic message: the
    /// sidecar's validation errors here ("An MCP server named ... already
    /// exists", "name must contain only letters, digits ...") name exactly the
    /// field the user has to fix.
    private struct McpErrorEnvelope: Decodable { let error: String }

    /// Refreshes the Settings "MCP 服务器" panel. Like the memory panel, this
    /// backs a convenience display rather than the recording path, so a
    /// sidecar hiccup leaves the last-known list on screen and logs, instead of
    /// throwing or blanking the panel.
    func refreshMcpServers() async {
        do {
            mcpConfig = try await sidecarClient.request(method: "GET", path: "/config/mcp")
        } catch {
            print("OpenType: failed to fetch MCP servers from sidecar: \(error.localizedDescription)")
        }
    }

    /// `POST /config/mcp`. The response carries the stored (masked) server, so
    /// the row is folded in immediately; the follow-up refresh is what picks up
    /// `configured`/`source` flipping from the env fallback to the user's own
    /// saved list on the very first save.
    @discardableResult
    func createMcpServer(_ request: McpServerRequest) async -> Bool {
        do {
            let response: McpServerMutationResponseBody = try await sidecarClient.request(
                method: "POST",
                path: "/config/mcp",
                body: request
            )
            applyMcpServer(response.server, replacing: nil)
            mcpEditError = nil
            await refreshMcpServers()
            return true
        } catch {
            recordMcpEditFailure("create", error)
            return false
        }
    }

    /// `PUT /config/mcp/:name` -- a **replace**, not a patch: whatever the
    /// request omits is gone afterwards. `name` is the server's current name
    /// (the one the URL addresses); `request.name` may differ, which is how a
    /// rename is expressed, so the local fold is keyed on the old name.
    @discardableResult
    func updateMcpServer(name: String, _ request: McpServerRequest) async -> Bool {
        do {
            let response: McpServerMutationResponseBody = try await sidecarClient.request(
                method: "PUT",
                path: "/config/mcp/\(Self.mcpPathComponent(name))",
                body: request
            )
            applyMcpServer(response.server, replacing: name)
            mcpEditError = nil
            await refreshMcpServers()
            return true
        } catch {
            recordMcpEditFailure("update", error)
            return false
        }
    }

    @discardableResult
    func deleteMcpServer(name: String) async -> Bool {
        do {
            let _: McpDeletionResponseBody = try await sidecarClient.request(
                method: "DELETE",
                path: "/config/mcp/\(Self.mcpPathComponent(name))"
            )
            mcpEditError = nil
            await refreshMcpServers()
            return true
        } catch {
            recordMcpEditFailure("delete", error)
            return false
        }
    }

    /// `POST /config/mcp/test` -- connects to the candidate and reports which
    /// tools it would hand the agent. Never throws: a probe failure comes back
    /// as `.success == false` with the server's own error, and a transport
    /// failure is folded into the same shape, so the panel has one code path
    /// (same contract as `testLLMConnection`).
    ///
    /// Sending an unchanged secret as its mask is fine here for the same reason
    /// it is fine on a write: the sidecar resolves a submitted value against
    /// the *saved server of the same name* before probing, so testing an
    /// already-saved server exercises its real credentials rather than failing
    /// with an auth error about the mask.
    func testMcpServer(_ request: McpServerRequest) async -> McpTestResultSummary {
        do {
            return try await sidecarClient.request(
                method: "POST",
                path: "/config/mcp/test",
                body: request
            )
        } catch {
            return McpTestResultSummary(
                success: false,
                error: Self.mcpFailureMessage(error),
                tools: nil
            )
        }
    }

    /// Folds a mutation's resulting server into `mcpConfig.servers`, replacing
    /// the row previously called `replacing` (so a rename updates in place
    /// rather than duplicating) and appending when there was none.
    private func applyMcpServer(_ server: McpServerSummary, replacing previousName: String?) {
        guard let current = mcpConfig else { return }
        var servers = current.servers
        if let index = servers.firstIndex(where: { $0.name == (previousName ?? server.name) }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        mcpConfig = McpConfigSummary(
            configured: current.configured,
            source: current.source,
            servers: servers
        )
    }

    private func recordMcpEditFailure(_ operation: String, _ error: Error) {
        mcpEditError = Self.mcpFailureMessage(error)
        print("OpenType: MCP server \(operation) failed: \(error.localizedDescription)")
    }

    /// The user-facing message for a failed `/config/mcp*` call. A 400/404
    /// answers `{ error }`, which doesn't decode as the expected response and
    /// so arrives as a decoding failure carrying the raw body -- that body's
    /// `error` is the actionable sentence, and `ErrorMessagePresenter`'s
    /// generic "本地服务响应异常" would throw it away.
    nonisolated static func mcpFailureMessage(_ error: Error) -> String {
        if case SidecarClientError.responseDecodingFailed(_, _, let body) = error,
           let data = body.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(McpErrorEnvelope.self, from: data) {
            return envelope.error
        }
        return ErrorMessagePresenter.message(for: error)
    }

    /// Percent-encodes a server name for the `:name` path segment. Saved names
    /// are constrained to `[A-Za-z0-9_-]` sidecar-side, but a name typed into
    /// the panel reaches this before that validation does.
    nonisolated private static func mcpPathComponent(_ name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    // MARK: - Provider configuration (Whisper / LLM)
    //
    // Thin wrappers around the sidecar's `/config/*` endpoints
    // (`sidecar/src/provider/routes.ts`) -- the single source of truth both
    // the Settings provider sections and the first-run onboarding wizard
    // call through (`ProviderSetupView` in `Views.swift`), so there is
    // exactly one place that knows how to test/save/list provider config,
    // not a parallel wizard-only implementation.

    private struct LLMConfigTestRequestBody: Encodable {
        let type: String
        let baseUrl: String
        let apiKey: String
    }
    private struct LLMConfigSaveRequestBody: Encodable {
        let type: String
        let baseUrl: String
        let apiKey: String
        let model: String
    }
    private struct WhisperConfigSaveRequestBody: Encodable {
        let mode: String
        let baseUrl: String?
        let apiKey: String?
        let model: String?
    }
    private struct WhisperConfigTestRequestBody: Encodable {
        let baseUrl: String
        let apiKey: String
    }

    /// Refreshes `providerConfigStatus` (and therefore
    /// `needsProviderOnboarding`) from `GET /config/status`. Called once
    /// right after the sidecar becomes ready, and again after every
    /// successful `saveLLMConfig`/`saveWhisperConfig` so the wizard/Settings
    /// screen can tell the moment both sides are configured.
    ///
    /// Also opportunistically refreshes `llmConfigSummary`/
    /// `whisperConfigSummary` themselves (not just the booleans) so the
    /// audit-label computed properties above (`sidecarTextProvider` etc.)
    /// reflect the real configured provider from the moment the sidecar is
    /// ready, even in a session where the user never opens Settings or the
    /// wizard to trigger those views' own `.task` refreshes.
    func refreshProviderConfigStatus() async {
        do {
            let status: ProviderConfigStatus = try await sidecarClient.request(
                method: "GET",
                path: "/config/status"
            )
            providerConfigStatus = status
            if status.llmConfigured {
                await refreshLLMConfigSummary()
            }
            if status.whisperConfigured {
                await refreshWhisperConfigSummary()
            }
        } catch {
            print("OpenType: failed to fetch provider config status from sidecar: \(error.localizedDescription)")
        }
    }

    /// Refreshes the Settings "AI 模型" section's display of the currently
    /// saved LLM provider (masked API key only -- see `LLMConfigSummary`).
    func refreshLLMConfigSummary() async {
        do {
            llmConfigSummary = try await sidecarClient.request(method: "GET", path: "/config/llm")
        } catch {
            print("OpenType: failed to fetch LLM config from sidecar: \(error.localizedDescription)")
        }
    }

    /// Refreshes the Settings "语音识别" section's display of the currently
    /// saved Whisper mode.
    func refreshWhisperConfigSummary() async {
        do {
            whisperConfigSummary = try await sidecarClient.request(method: "GET", path: "/config/whisper")
        } catch {
            print("OpenType: failed to fetch Whisper config from sidecar: \(error.localizedDescription)")
        }
    }

    /// `POST /config/llm/test` -- verifies `baseUrl`/`apiKey` actually work
    /// against the given provider `type` before the user commits to saving
    /// them. Never throws: sidecar-level connectivity/auth failures come
    /// back as `.success == false` with a real provider error message
    /// (`ProviderTestResultSummary.error`), and a genuine transport failure
    /// (sidecar not reachable at all) is folded into the same shape so
    /// callers only need one code path.
    func testLLMConnection(
        type: LLMProviderType,
        baseUrl: String,
        apiKey: String
    ) async -> ProviderTestResultSummary {
        do {
            return try await sidecarClient.request(
                method: "POST",
                path: "/config/llm/test",
                body: LLMConfigTestRequestBody(type: type.rawValue, baseUrl: baseUrl, apiKey: apiKey)
            )
        } catch {
            return ProviderTestResultSummary(success: false, error: error.localizedDescription)
        }
    }

    /// `POST /config/llm/models` -- lists models for the given provider
    /// config, or the sidecar's hardcoded fallback list
    /// (`fallback == true`) when live listing isn't supported/fails. Only
    /// meaningful to call after `testLLMConnection` has reported success.
    func listLLMModels(
        type: LLMProviderType,
        baseUrl: String,
        apiKey: String
    ) async throws -> ProviderModelListSummary {
        try await sidecarClient.request(
            method: "POST",
            path: "/config/llm/models",
            body: LLMConfigTestRequestBody(type: type.rawValue, baseUrl: baseUrl, apiKey: apiKey)
        )
    }

    /// `PUT /config/llm` -- persists the chosen provider config sidecar-side
    /// and marks it `llmConfigured`. This is the one action that actually
    /// takes the new provider live for `/oneshot/ask`/`/agent/run`; Test
    /// Connection and model listing above are read-only previews.
    @discardableResult
    func saveLLMConfig(
        type: LLMProviderType,
        baseUrl: String,
        apiKey: String,
        model: String
    ) async throws -> LLMConfigSummary {
        let summary: LLMConfigSummary = try await sidecarClient.request(
            method: "PUT",
            path: "/config/llm",
            body: LLMConfigSaveRequestBody(type: type.rawValue, baseUrl: baseUrl, apiKey: apiKey, model: model)
        )
        llmConfigSummary = summary
        await refreshProviderConfigStatus()
        return summary
    }

    /// `POST /config/whisper/test` -- remote-mode connectivity check
    /// (local mode never needs testing, it has no credentials).
    func testWhisperConnection(baseUrl: String, apiKey: String) async -> ProviderTestResultSummary {
        do {
            return try await sidecarClient.request(
                method: "POST",
                path: "/config/whisper/test",
                body: WhisperConfigTestRequestBody(baseUrl: baseUrl, apiKey: apiKey)
            )
        } catch {
            return ProviderTestResultSummary(success: false, error: error.localizedDescription)
        }
    }

    /// `PUT /config/whisper` -- persists the chosen Whisper mode (and, for
    /// remote, its base URL/API key/model) and marks it `whisperConfigured`.
    /// An explicit save is required even for `local` -- see
    /// `ProviderConfigStore`'s doc comment on the sidecar side for why an
    /// unconfigured default doesn't silently count.
    @discardableResult
    func saveWhisperConfig(
        mode: WhisperMode,
        baseUrl: String? = nil,
        apiKey: String? = nil,
        model: String? = nil
    ) async throws -> WhisperConfigSummary {
        let summary: WhisperConfigSummary = try await sidecarClient.request(
            method: "PUT",
            path: "/config/whisper",
            body: WhisperConfigSaveRequestBody(mode: mode.rawValue, baseUrl: baseUrl, apiKey: apiKey, model: model)
        )
        whisperConfigSummary = summary
        await refreshProviderConfigStatus()
        return summary
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

    /// - Parameter recordingEndedAt: When the recording this audio came from
    ///   stopped (`finishRecording()`). Recorded on the `.recognized` event so
    ///   the statistics panel can measure the span the user actually waits
    ///   through — see `UsageStats` and `ImmutableAuditEvent.recordingEndedAt`.
    private func process(audioURL: URL, recordingEndedAt: Date? = nil) async {
        let startingMode = activeMode ?? configuration.selectedMode
        let practice = isPracticeSession
        let auditRequestID = UUID()
        var auditMode = startingMode
        var auditRawTranscript = ""
        var auditEffectiveInput: String?
        var effectiveTextModel: String?

        // Returns the event's id (rather than being purely `Void`) so a
        // Review session starting from this recording can capture the
        // `.recognized` event's id as the first link in its
        // `supersedesEventId` correction chain — see `beginReviewSession`.
        @discardableResult
        func appendAudit(
            status: AuditEventStatus,
            result: String? = nil,
            error: String? = nil,
            provider: String? = nil,
            model: String? = nil,
            recordingEndedAt: Date? = nil
        ) -> UUID {
            let eventId = UUID()
            recordAuditEvent(
                ImmutableAuditEvent(
                    id: eventId,
                    requestId: auditRequestID,
                    status: status,
                    mode: auditMode,
                    rawTranscript: auditRawTranscript,
                    effectiveInput: auditEffectiveInput,
                    selectedContext: capturedContext.selectedText,
                    result: result,
                    provider: provider,
                    model: model,
                    error: error,
                    recordingEndedAt: recordingEndedAt
                )
            )
            return eventId
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

            let routed = VoiceModeRouter.route(
                rawTranscript,
                currentMode: startingMode
            )
            let mode = routed.mode
            let transcript = routed.text
            activeMode = mode
            auditMode = mode
            auditEffectiveInput = transcript
            // The only event that carries it: it describes the recording, and
            // the recording happens once per session.
            let recognizedEventId = appendAudit(
                status: .recognized,
                provider: sidecarASRProvider,
                recordingEndedAt: recordingEndedAt
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
                // The whole variant axis decides here and nowhere else
                // (`TranscribeVariant.deliverableText(for:)`): Direct hands
                // the transcript back untouched, Tidy hands back
                // `TidyTranscript`'s deterministic cleanup, and Review hands
                // back nothing because it stages instead of delivering. No
                // sidecar/LLM call and no voice surface in any of the three —
                // whatever comes back *is* the result.
                if let deliverable = configuration.transcribeVariant
                    .deliverableText(for: transcript) {
                    // Note what is deliberately *not* happening here:
                    // `auditEffectiveInput` keeps the transcript as spoken.
                    // Under Tidy the delivered text differs from it, and both
                    // halves have to stay readable — `rawTranscript` is what
                    // ASR heard, `effectiveInput` what the user said once
                    // mode-routing was applied, and the `.completed` event's
                    // `result` below is what was actually pasted. Overwriting
                    // `effectiveInput` with the tidied form would make the
                    // audit chain claim the user spoke the cleaned-up
                    // sentence, and would contradict the `.recognized` event
                    // already written above under the same `requestId`.
                    result = deliverable
                } else {
                    // Stash the transcript in the Review panel instead of
                    // delivering it — nothing is inserted/copied yet. The
                    // rest of this session (corrections, commit/cancel) is
                    // driven by `processCorrection(audioURL:)`,
                    // `commitReview()`, and `cancelReview()`, all outside
                    // this function. `result = nil` routes through the same
                    // "dispatched, don't wait" early-return path `.agent`
                    // uses below.
                    beginReviewSession(
                        transcript: transcript,
                        requestID: auditRequestID,
                        recognizedEventId: recognizedEventId
                    )
                    result = nil
                }
            case .ask:
                // Non-blocking dispatch, mirroring `.agent`/`dispatchAgentRun`
                // below: assigning `askPanelState` puts the unified voice
                // surface into its "thinking" state immediately, then the
                // `/oneshot/ask` call is handed off to a detached task
                // (`dispatchAskRun`) that is never awaited here, so a slow LLM
                // answer can't hold the whole recording pipeline busy — the
                // user can start a new recording while an answer is in flight.
                // The answer is delivered to the surface's result card +
                // clipboard when it returns; dismissing a still-thinking ask
                // cancels the task so no "ghost answer" can arrive after the
                // user moved on.
                effectiveTextModel = sidecarTextModel
                // Read the thread off the CURRENT panel before replacing it:
                // the card still on screen is what the user is following up
                // on, and overwriting the state first would lose it.
                let askThread = VoiceFollowUp.conversationId(
                    surface: askPanelState?.conversationId,
                    focusedTab: focusedAskConversationId
                )
                askPanelState = AskPanelState(
                    kind: .ask,
                    query: transcript,
                    answer: nil,
                    conversationId: askThread
                )
                dispatchAskRun(
                    transcript: transcript,
                    context: capturedContext,
                    practice: practice,
                    requestID: auditRequestID,
                    conversationId: askThread,
                    model: sidecarTextModel
                )
                result = nil
            case .agent:
                // Non-blocking dispatch (see `dispatchAgentRun` below): the
                // `/agent/run` call runs as an independent, detached `Task`
                // that is never awaited here, so a slow multi-step Agent
                // loop can't hold the app's general recording pipeline busy.
                // Live feedback comes from the unified voice surface
                // (`agentPanelState` -> `VoiceSurfaceState`), put into its
                // working state by `dispatchAgentRun` the moment the task is
                // handed off and fed by polling `GET /agent/progress/:runId`;
                // completion is additionally surfaced via a
                // `UNUserNotification` plus the Agent tab, and dismissing
                // the surface never cancels the run.
                effectiveTextModel = sidecarTextModel
                // P1-6: show what was heard for ~1.5s first. Not a modal —
                // doing nothing dispatches; only Esc inside the window stops
                // it. This is the one mode with real hands, so a mishear here
                // is not a bad answer, it is an executed one.
                let confirmed = await confirmDispatch(transcript: transcript, mode: mode)
                try Task.checkCancellation()
                guard let confirmedTask = confirmed else {
                    appendAudit(
                        status: .cancelled,
                        error: OpenTypeL10n.text(
                            "下发前已撤销",
                            english: "Cancelled before dispatch"
                        )
                    )
                    let cancelledState = ProcessingState.cancelled(
                        OpenTypeL10n.text("未下发", english: "Not dispatched")
                    )
                    setState(cancelledState)
                    scheduleIdle(after: cancelledState)
                    return
                }
                dispatchAgentRun(
                    transcript: confirmedTask,
                    context: capturedContext,
                    practice: practice,
                    requestID: auditRequestID,
                    conversationId: VoiceFollowUp.conversationId(
                        surface: agentPanelState?.conversationId,
                        focusedTab: focusedAgentConversationId
                    )
                )
                result = nil
            }
            try Task.checkCancellation()

            guard let result else {
                // `.agent` and `.transcribe`+Review both took a
                // dispatch-and-return path above (`dispatchAgentRun`/
                // `beginReviewSession`): give a brief, transient
                // acknowledgement (the same sound-cue/overlay pattern every
                // other mode uses for its own completion signal) and let
                // `state` fall back to idle right away, rather than staying
                // "busy" for the rest of that flow's duration. `defer` above
                // still fires normally, so the audio file is cleaned up and
                // `activeMode`/`isPracticeSession` reset exactly as any other
                // completed dispatch would.
                playFeedbackSound(.done)
                let message: String
                switch mode {
                case .agent:
                    message = OpenTypeL10n.text("已下发给 Agent", english: "Dispatched to Agent")
                case .ask:
                    message = OpenTypeL10n.text("正在思考…", english: "Thinking…")
                default:
                    message = OpenTypeL10n.text("待复核", english: "Ready to review")
                }
                let dispatchedState = ProcessingState.dispatched(message)
                setState(dispatchedState)
                scheduleIdle(after: dispatchedState)
                return
            }

            lastResult = result
            lastApplication = capturedContext.applicationName
            lastResultWasPractice = practice
            lastDeliveryNotice = nil

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
                    enabled: configuration.automaticOwnerProfileUpdates
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
            var insertSucceeded = false
            let deliveryStrategy = OutputDeliveryPolicy.strategy(
                for: mode,
                automaticallyInsert: configuration.automaticallyInsert
            )
            if practice {
                // The guided first-run test keeps the result inside OpenType so
                // users can verify the whole voice pipeline before granting
                // system-wide insertion access.
            } else if deliveryStrategy == .automaticInsert {
                // Only insert if focus is still on the app captured at recording
                // time; if the user switched apps mid-transcription, downgrade to
                // clipboard-only so the result never lands in the wrong app.
                let frontmostBundleId = NSWorkspace.shared
                    .frontmostApplication?.bundleIdentifier
                if OutputDeliveryPolicy.shouldInsert(
                    capturedBundleId: capturedContext.bundleIdentifier,
                    frontmostBundleId: frontmostBundleId
                ) {
                    setState(.inserting)
                    do {
                        try await contextBridge.insert(result)
                        insertSucceeded = true
                    } catch {
                        completionState = .copied
                    }
                } else {
                    // Focus changed after capture: keep it on the clipboard and
                    // let the user know why it was not pasted for them.
                    completionState = .copied
                    lastDeliveryNotice = OpenTypeL10n.text(
                        "焦点已切换，结果已复制到剪贴板",
                        english: "Focus changed, so the result was copied to the clipboard instead of inserted."
                    )
                }
            } else if !practice {
                completionState = .copied
            }

            if OutputDeliveryPolicy.retainsClipboardCopy(
                for: mode,
                insertSucceeded: insertSucceeded,
                retainClipboardAfterInsert: configuration.retainClipboardAfterInsert
            ) {
                contextBridge.copyToClipboard(result)
            }

            let completedEventId = appendAudit(
                status: .completed,
                result: result,
                // `.transcribe` reaches no text provider in any of its three
                // variants (see the `switch mode` above) — Tidy's rewriting is
                // local, deterministic rules — so there is no text
                // provider/model of its own to record here. `nil` states that
                // no model was involved, which for Tidy is the product
                // promise, not merely a missing field.
                provider: mode == .transcribe ? nil : sidecarTextProvider,
                model: effectiveTextModel
            )

            // P0-3: the text is delivered and the user is looking at it — for
            // the next few seconds the hotkey offers to fix it in place.
            // Armed *before* the state push below, because that push is what
            // turns the success toast into the window's visible affordance.
            armCorrectionWindow(
                mode: mode,
                variant: configuration.transcribeVariant,
                context: capturedContext,
                requestId: auditRequestID,
                completedEventId: completedEventId
            )

            playFeedbackSound(.done)
            setState(completionState)
            scheduleIdle(after: completionState, delay: correctionWindowIdleDelay)
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
                    ? sidecarASRProvider
                    : sidecarTextProvider,
                model: auditRawTranscript.isEmpty
                    ? nil
                    : (effectiveTextModel ?? sidecarTextModel)
            )
            fail(error)
        }
    }

    /// Kicks off an Ask-mode question as an independent, detached unit of work
    /// and returns immediately — the Ask-mode counterpart of `dispatchAgentRun`
    /// (P1-11). The `/oneshot/ask` call is tracked in `askTask` (never awaited
    /// by `process(audioURL:)`), so a slow answer can't hold the recording
    /// pipeline busy and dismissing the surface can abort it cleanly.
    private func dispatchAskRun(
        transcript: String,
        context: CapturedContext,
        practice: Bool,
        requestID: UUID,
        conversationId: Int?,
        model: String?
    ) {
        // Supersede any still-pending Ask request (e.g. the user asked again
        // before the previous answer arrived) so only the latest one delivers.
        askTask?.cancel()
        askTask = Task { [weak self] in
            await self?.runAskDispatch(
                transcript: transcript,
                context: context,
                practice: practice,
                requestID: requestID,
                conversationId: conversationId,
                model: model
            )
        }
    }

    /// The detached unit of work started by `dispatchAskRun`: issues the
    /// `/oneshot/ask` call, then delivers the answer to the voice surface +
    /// clipboard and records history/memory/audit — all independent of whatever
    /// `state` the app has moved on to. A cancellation (surface dismissed, or superseded
    /// by a newer Ask) drops silently without touching the clipboard, so a
    /// late "ghost answer" can never overwrite what the user is doing now.
    private func runAskDispatch(
        transcript: String,
        context: CapturedContext,
        practice: Bool,
        requestID: UUID,
        conversationId: Int?,
        model: String?
    ) async {
        // Only clear the shared slot if THIS task still owns it. A superseded or
        // dismissed Ask is always cancelled (via `askTask?.cancel()`), so it must
        // leave the slot alone — otherwise its cleanup would null out the live
        // task, and `dismissAskPanel` could no longer cancel it, letting a late
        // "ghost answer" clobber the clipboard after dismissal.
        defer { if !Task.isCancelled { askTask = nil } }

        do {
            // Continues the Q&A tab's focused thread when one is open
            // (`focusedAskConversationId`), otherwise starts a fresh
            // conversation -- see `openAskConversation(_:)`/
            // `startNewAskConversation()`.
            let response: AskResponseBody = try await sidecarClient.request(
                method: "POST",
                path: "/oneshot/ask",
                body: AskRequestBody(
                    question: transcript,
                    conversationId: conversationId
                )
            )
            try Task.checkCancellation()
            let result = response.result

            // Only deliver into the surface if it's still showing this same
            // question awaiting an answer — the user may have dismissed it or
            // moved on to another Ask in the meantime.
            if var current = askPanelState,
               current.kind == .ask,
               current.query == transcript,
               current.answer == nil {
                current.answer = result
                current.conversationId = response.conversationId
                askPanelState = current
            }
            await refreshAskConversations()
            if focusedAskConversationId == response.conversationId {
                openAskConversation(response.conversationId)
            }

            recordAuditEvent(
                ImmutableAuditEvent(
                    requestId: requestID,
                    status: .completed,
                    mode: .ask,
                    rawTranscript: transcript,
                    effectiveInput: transcript,
                    selectedContext: context.selectedText,
                    result: result,
                    provider: sidecarTextProvider,
                    model: model,
                    error: nil
                )
            )

            lastResult = result
            lastApplication = context.applicationName
            lastResultWasPractice = practice
            lastDeliveryNotice = nil

            if configuration.agentMemoryEnabled, !practice {
                agentMemory.record(
                    MemoryEvent(
                        mode: .ask,
                        applicationName: context.applicationName,
                        bundleIdentifier: context.bundleIdentifier,
                        rawTranscript: transcript,
                        effectiveInput: transcript,
                        selectedContext: context.selectedText,
                        result: result
                    )
                )
                agentMemory.refreshOwnerProfileIfNeeded(
                    enabled: configuration.automaticOwnerProfileUpdates
                )
            }
            if configuration.keepHistory, !practice {
                history.add(
                    HistoryEntry(
                        mode: .ask,
                        applicationName: context.applicationName,
                        transcript: transcript,
                        result: result,
                        contextPreview: context.selectedText.map {
                            String($0.prefix(240))
                        }
                    )
                )
            }

            // Ask answers are clipboard-only (never auto-inserted — see
            // `OutputDeliveryPolicy.strategy(for: .ask, ...)`).
            contextBridge.copyToClipboard(result)
        } catch is CancellationError {
            // Popup dismissed or superseded: leave the clipboard/app state
            // untouched and record the abort for the audit trail.
            recordAuditEvent(
                ImmutableAuditEvent(
                    requestId: requestID,
                    status: .cancelled,
                    mode: .ask,
                    rawTranscript: transcript,
                    effectiveInput: transcript,
                    selectedContext: context.selectedText,
                    result: nil,
                    provider: sidecarTextProvider,
                    model: model,
                    error: OpenTypeL10n.text(
                        "提问已取消",
                        english: "Ask was cancelled"
                    )
                )
            )
        } catch {
            let message = ErrorMessagePresenter.message(for: error)
            // Deliver the failure as the answer text, so the surface resolves
            // into a result card instead of leaving the user staring at a
            // "thinking…" indicator forever. (This is why the reducer has no
            // ask-side `.failed` case — see `VoiceSurfaceState`.)
            if var current = askPanelState,
               current.kind == .ask,
               current.query == transcript,
               current.answer == nil {
                current.answer = OpenTypeL10n.text(
                    "提问失败：\(message)",
                    english: "Ask failed: \(message)"
                )
                askPanelState = current
            }
            recordAuditEvent(
                ImmutableAuditEvent(
                    requestId: requestID,
                    status: .failed,
                    mode: .ask,
                    rawTranscript: transcript,
                    effectiveInput: transcript,
                    selectedContext: context.selectedText,
                    result: nil,
                    provider: sidecarTextProvider,
                    model: model,
                    error: message
                )
            )
        }
    }

    /// Holds a task on screen for `DispatchConfirmation.windowSeconds` before
    /// it goes out (P1-6), and returns the text to dispatch — or `nil` if the
    /// user took it back with Esc.
    ///
    /// The whole window costs 1.5 seconds of latency, once, on the one mode
    /// that can change the user's disk. Modes with no window (`arm` returns
    /// `nil`) get their transcript back untouched and pay nothing.
    ///
    /// The wait is a poll rather than a single sleep so Esc ends it early: at
    /// this frequency, a user who spots the mishear immediately should not have
    /// to watch the rest of the bar drain before anything happens.
    private func confirmDispatch(transcript: String, mode: InputMode) async -> String? {
        guard let pending = DispatchConfirmation.arm(
            transcript: transcript,
            mode: mode,
            at: Date()
        ) else { return transcript }

        pendingDispatch = pending
        pendingDispatchEscapePressedAt = nil
        overlay.showPendingDispatch(
            transcript: pending.transcript,
            seconds: DispatchConfirmation.windowSeconds
        )
        defer {
            // Take down *this* window, not whatever is on screen. A superseded
            // recording cancels this task and starts its own confirmation, and
            // a defer that cleared unconditionally would hide the newer card
            // and leave its Esc unheard (`recordPendingDispatchEscape` needs
            // `pendingDispatch` to be non-nil).
            if pendingDispatch == pending {
                pendingDispatch = nil
                overlay.hidePendingDispatch()
            }
        }

        while !Task.isCancelled,
              pendingDispatchEscapePressedAt == nil,
              !pending.isExpired(at: Date()) {
            // `try?`, because a cancelled sleep throws — and the loop condition
            // above is what actually ends this, not the throw.
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        switch DispatchConfirmation.decision(
            for: pending,
            escapePressedAt: pendingDispatchEscapePressedAt
        ) {
        case .dispatch(let text):
            return text
        case .cancelled:
            return nil
        }
    }

    /// Esc arrived while a task was waiting to go out (P1-6). Records *when*
    /// and lets `confirmDispatch`'s next tick ask the seam whether that was in
    /// time; a keypress after the window closed leaves the dispatched run alone
    /// (stopping one that already started is `/agent/cancel`'s job).
    private func recordPendingDispatchEscape() {
        // First press wins. Two things reach here — the overlay's own key
        // monitors and `cancelActiveVoiceSession()` — so a single Esc can
        // arrive twice, and a second timestamp is never new information. It
        // could, however, be *worse* information: a repeat press landing after
        // the deadline but before the loop's next 30ms tick would overwrite an
        // in-time cancellation with an out-of-window one, turning "cancelled"
        // into "dispatched" for a user who pressed Esc twice.
        guard pendingDispatch != nil, pendingDispatchEscapePressedAt == nil else { return }
        pendingDispatchEscapePressedAt = Date()
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
        requestID: UUID,
        conversationId: Int?
    ) {
        let record = AgentRunRecord(
            task: transcript,
            applicationName: context.applicationName,
            contextPreview: context.selectedText.map { String($0.prefix(240)) }
        )
        agentRuns = AgentRunHistory.inserting(record, into: agentRuns)
        runningAgentRunCount = AgentRunHistory.runningCount(in: agentRuns)

        let runID = record.id

        // Put the voice surface into its working state immediately — before
        // the call is even issued — so the user gets live feedback the moment
        // the task is dispatched. It always shows the most recently dispatched
        // run: this assignment replaces whatever older run it was showing
        // (that run keeps going and stays visible in the Agent tab), and the
        // restarted poller below guards on `runId` so the old run's poller
        // and completion can no longer touch the panel.
        agentPanelState = AgentProgressPanelState(
            runId: runID.uuidString,
            task: transcript,
            steps: [],
            phase: .running,
            result: nil,
            // Carried forward so a THIRD utterance continues the same thread:
            // the id is known before the run finishes only when this is
            // already a follow-up.
            conversationId: conversationId
        )
        startAgentProgressPolling(runId: runID.uuidString)

        runningAgentTasks[runID] = Task { [weak self] in
            await self?.runAgentDispatch(
                runID: runID,
                transcript: transcript,
                context: context,
                practice: practice,
                requestID: requestID,
                conversationId: conversationId
            )
        }
    }

    /// Starts (replacing any previous) the ~0.7s polling loop that feeds the
    /// voice surface's live step ticker from `GET /agent/progress/:runId`.
    /// Each tick re-checks that `runId` is still the run the surface shows and
    /// that its phase still says to poll (`shouldContinuePolling`) — so the
    /// loop winds down by itself when the blocking `/agent/run` call
    /// completes, when a newer dispatch replaces the panel, or when the user
    /// dismisses it (which also cancels the task outright).
    private func startAgentProgressPolling(runId: String) {
        agentProgressPollTask?.cancel()
        agentProgressPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, let self else { return }
                guard let current = self.agentPanelState,
                      current.runId == runId,
                      AgentProgressPanelState.shouldContinuePolling(for: current.phase)
                else { return }

                guard let snapshot = try? await self.sidecarClient.agentProgress(runId: runId)
                else { continue } // Transient poll failure: just try again next tick.

                // Re-check after the await: the blocking response (terminal
                // phase, authoritative steps) or a newer dispatch may have
                // landed while this poll request was in flight — never let a
                // stale snapshot overwrite either.
                guard var updated = self.agentPanelState,
                      updated.runId == runId,
                      AgentProgressPanelState.shouldContinuePolling(for: updated.phase)
                else { return }
                updated.steps = AgentProgressPanelState.steps(fromProgressEvents: snapshot.events)
                // Same tick, no second loop (T5): a pending question is part
                // of "what is this run doing right now", exactly like steps.
                // A failed question poll leaves the previous value alone --
                // clearing it on a transient error would blink the card away
                // while the agent is still waiting.
                if let prompt = try? await self.sidecarClient.agentQuestion(runId: runId) {
                    updated.question = prompt.questions.first
                }
                guard self.agentPanelState?.runId == runId else { return }
                self.agentPanelState = updated
            }
        }
    }

    /// Applies `transform` to the panel state only if it is still showing
    /// `runId` — the guard that keeps an older run's completion (or a late
    /// poll) from clobbering a newer run's panel, or resurrecting a panel the
    /// user already dismissed.
    private func updateAgentPanel(
        runId: String,
        _ transform: (inout AgentProgressPanelState) -> Void
    ) {
        guard var state = agentPanelState, state.runId == runId else { return }
        transform(&state)
        agentPanelState = state
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
        requestID: UUID,
        conversationId: Int?
    ) async {
        defer { runningAgentTasks[runID] = nil }

        do {
            // Continues the Agent tab's focused thread when one was open at
            // dispatch time, otherwise starts a fresh conversation -- see
            // `openAgentConversation(_:)`/`startNewAgentConversation()`.
            let response: AgentRunResponseBody = try await sidecarClient.request(
                method: "POST",
                path: "/agent/run",
                body: AgentRunRequestBody(
                    task: transcript,
                    context: context.selectedText,
                    conversationId: conversationId,
                    runId: runID.uuidString
                )
            )

            agentRuns = AgentRunHistory.updating(id: runID, in: agentRuns) { record in
                record.steps = response.steps
                record.status = .completed(response.result)
                record.completedAt = Date()
                record.conversationId = response.conversationId
            }
            runningAgentRunCount = AgentRunHistory.runningCount(in: agentRuns)

            // Settle the surface's agent state (if it's still showing this run):
            // final phase + result, and the response's own durable step log —
            // untruncated and complete, so always at least as rich as the
            // polled display feed — replaces the polled steps. The poller
            // sees the non-running phase on its next tick and stops.
            updateAgentPanel(runId: runID.uuidString) { state in
                state.phase = .succeeded
                state.result = response.result
                state.conversationId = response.conversationId
                let finalSteps = AgentProgressPanelState.steps(
                    fromProgressEvents: response.steps.map {
                        SidecarAgentProgressEvent(type: $0.type, detail: $0.detail)
                    }
                )
                if !finalSteps.isEmpty {
                    state.steps = finalSteps
                }
            }
            await refreshAgentConversations()
            if focusedAgentConversationId == response.conversationId {
                openAgentConversation(response.conversationId)
            }

            recordAuditEvent(
                ImmutableAuditEvent(
                    requestId: requestID,
                    status: .completed,
                    mode: .agent,
                    rawTranscript: transcript,
                    effectiveInput: transcript,
                    selectedContext: context.selectedText,
                    result: response.result,
                    provider: sidecarTextProvider,
                    model: sidecarTextModel,
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
                    enabled: configuration.automaticOwnerProfileUpdates
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
            // The sidecar answers a cancelled run with 499 (T1). That is the
            // ONE terminal state that is not a failure: the user stopped it
            // on purpose, so it gets its own status, its own audit event, and
            // no "task failed" notification.
            let wasCancelled = Self.isCancellationStatus(error)
            let message = wasCancelled
                ? OpenTypeL10n.text("已停止", english: "Stopped")
                : ErrorMessagePresenter.message(for: error)
            agentRuns = AgentRunHistory.updating(id: runID, in: agentRuns) { record in
                record.status = wasCancelled ? .cancelled(message) : .failed(message)
                record.completedAt = Date()
            }
            runningAgentRunCount = AgentRunHistory.runningCount(in: agentRuns)

            // Settle the surface's agent state (if it's still showing this
            // run); the message doubles as the result area's content. The
            // poller stops on its next tick.
            updateAgentPanel(runId: runID.uuidString) { state in
                state.phase = wasCancelled ? .cancelled : .failed
                state.result = message
            }

            recordAuditEvent(
                ImmutableAuditEvent(
                    requestId: requestID,
                    status: wasCancelled ? .cancelled : .failed,
                    mode: .agent,
                    rawTranscript: transcript,
                    effectiveInput: transcript,
                    selectedContext: context.selectedText,
                    result: nil,
                    provider: sidecarTextProvider,
                    model: sidecarTextModel,
                    error: message
                )
            )
        }

        if let record = agentRuns.first(where: { $0.id == runID }) {
            postAgentCompletionNotification(record)
        }
    }

    /// Whether a `/agent/run` failure is really the sidecar reporting that the
    /// run was cancelled. The sidecar answers 499 with `{ error }`, which does
    /// not decode as the expected response, so it surfaces as a decoding
    /// failure carrying the status — the status is the discriminator.
    nonisolated static func isCancellationStatus(_ error: Error) -> Bool {
        if case SidecarClientError.responseDecodingFailed(let status, _, _) = error {
            return status == 499
        }
        return false
    }

    /// Stops one in-flight Agent run (T1). Fire-and-forget by design: the
    /// blocked `/agent/run` task observes the 499 and owns the terminal state,
    /// so a lost or failed cancel response cannot leave the record claiming an
    /// outcome the run did not reach.
    func cancelAgentRun(_ id: UUID) {
        guard agentRuns.first(where: { $0.id == id })?.status.isRunning == true else { return }
        Task { [weak self] in
            guard let client = self?.sidecarClient else { return }
            _ = try? await client.cancelAgentRun(runId: id.uuidString)
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
        case .running, .cancelled:
            // A run the user stopped themselves needs no notification: they
            // were looking at it when they stopped it.
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

    /// Lets a settled state fall back to `.idle` once its toast has had its
    /// time. `delay` is only ever non-default for the correction window
    /// (P0-3), whose toast outlives the usual second — see
    /// `correctionWindowIdleDelay`.
    private func scheduleIdle(
        after completionState: ProcessingState,
        delay: TimeInterval = 1
    ) {
        Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(max(0, delay) * 1_000_000_000)
            )
            guard let self, self.state == completionState else { return }
            self.state = .idle
        }
    }

    private func setState(_ newState: ProcessingState) {
        let wasListening = state == .listening
        state = newState
        hotKey.setRecordingActive(newState == .listening)
        // One entry point: the reducer decides whether this is a voice-surface
        // moment (ask/agent) or a legacy HUD/toast moment (transcribe, and
        // ask/agent with no live run).
        presentVoiceSurface()
        // P2-10: the recording clock lives exactly as long as a recording does.
        // Hung off the one state transition every recording path goes through
        // rather than off each `beginRecording`/`finishRecording` pair, so no
        // exit — hotkey release, Esc, a failed start, an auto-stop — can leave
        // a timer running behind it. Started *after* `presentVoiceSurface()`,
        // since the pill only accepts an elapsed readout once it knows it is
        // listening.
        if newState == .listening {
            if !wasListening { startRecordingClock() }
        } else {
            stopRecordingClock()
        }
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
        // Assigns `state` directly rather than going through `setState`, so the
        // recording clock has to be stopped by hand here (P2-10).
        stopRecordingClock()
        state = .failure(message)
        // Same reducer-first routing as `setState`, but with the mode this
        // recording actually ran as (`activeMode` has just been cleared) and
        // with the failure toast shown *over* whatever the surface reduces to:
        // a previous run's card or ticker must not swallow the one signal that
        // this recording failed, and must not be torn down by it either — see
        // `OverlayController.applyWithToast`.
        overlay.applyWithToast(
            VoiceSurfaceState.reduce(
                mode: failedMode,
                processing: state,
                ask: askPanelState,
                agent: agentPanelState
            ),
            state: state,
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

/// `AppModel`-internal bookkeeping for one open Review session — see
/// `AppModel.reviewSession`'s doc comment.
private struct ReviewSession {
    let requestId: UUID
    let capturedContext: CapturedContext
    var lastEventId: UUID
}

/// An open correction window (P0-3) plus the audit bookkeeping a correction
/// round appends against. The window itself is pure policy
/// (`CorrectionWindow.State`); these two fields are what make the `.corrected`
/// event a *link in the delivery's chain* rather than an orphan — the same
/// `requestId` grouping and `supersedesEventId` chaining a Review session uses
/// (§8 of `docs/superpowers/specs/2026-08-09-current-system-state.md`).
private struct CorrectionWindowSession {
    var window: CorrectionWindow.State
    let requestId: UUID
    /// The event this window's text came from: the delivery's `.completed`
    /// event, or the previous correction's `.corrected` event once one has
    /// landed.
    var supersedesEventId: UUID
}

/// One in-place correction round — see `AppModel.inPlaceCorrection`.
private struct InPlaceCorrectionSession {
    let requestId: UUID
    /// The whole of what the user selected in the target app. It is both the
    /// `fullText` sent to `/transcribe/correct` and the span being corrected
    /// (0..<its UTF-16 length): there is no surrounding document to send,
    /// because the correction is scoped to exactly what the user pointed at.
    let selectedText: String
    let context: CapturedContext
    let supersedesEventId: UUID
}

/// The sidebar's four destinations (2026-08 redesign).
///
/// Down from five bottom tabs, and the reduction is the point rather than a
/// side effect. `home` is gone entirely — it existed to pick a mode and show
/// the last result, and the redesign moves mode selection back to the menu-bar
/// popover and the sidebar's own mode card, where it does not cost a
/// first-class destination. `qa` and `agent` merge into `sessions`: they were
/// never two kinds of place, only two kinds of row in one list, and keeping
/// them apart meant a user who asked a question and then gave a task had to
/// remember which tab it landed in.
///
/// Note what this merge is **not**: the two *modes* stay separate. A session's
/// `kind` still decides whether its next turn goes to `/oneshot/ask` or
/// `/agent/run`. This is one list of conversations, not one kind of
/// conversation.
enum AppTab: String, CaseIterable, Identifiable {
    case sessions
    case dictation
    case memory
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: return OpenTypeL10n.text("会话", english: "Sessions")
        case .dictation: return OpenTypeL10n.text("听写", english: "Dictation")
        case .memory: return OpenTypeL10n.text("记忆", english: "Memory")
        case .settings: return OpenTypeL10n.text("设置", english: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .sessions: return "bubble.left.and.bubble.right.fill"
        case .dictation: return "clock.arrow.circlepath"
        case .memory: return "brain"
        case .settings: return "slider.horizontal.3"
        }
    }
}
