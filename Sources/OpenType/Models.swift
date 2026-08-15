import CoreGraphics
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

    /// True for the modes that make an actual LLM/text-generation call
    /// (`ask` → `/oneshot/ask`, `agent` → `/agent/run`). `transcribe` is pure
    /// ASR passthrough and never needs an LLM, which is why a transcribe-only
    /// user can skip provider setup entirely — see `OnboardingPolicy`. Used to
    /// surface a "configure an AI model first" nudge when one of these modes is
    /// selected but no LLM is configured yet.
    var requiresLLM: Bool {
        switch self {
        case .transcribe: return false
        case .ask, .agent: return true
        }
    }

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

/// The three ways `transcribe` mode can deliver its result, chosen in Settings
/// and applied to every `transcribe`-mode recording until changed (not a
/// per-recording toggle — see `docs/superpowers/specs/2026-08-09-current-system-state.md`
/// for the design rationale). `ask`/`agent` are unaffected by this setting.
///
/// All three stay inside `transcribe`'s promise that dictation never reaches a
/// model: `tidy` cleans by fixed local rules, so the axis is *how much
/// deterministic processing happens before delivery*, never *whether an LLM
/// sees the text*.
enum TranscribeVariant: String, CaseIterable, Codable, Identifiable {
    case direct
    /// Deterministic local cleanup — **never an LLM call**. See
    /// `TidyTranscript`. Ordered between `direct` and `review` because the
    /// three form a ladder of increasing intervention (raw ⇢ rules ⇢ human),
    /// and `allCases` is what Settings' picker renders.
    case tidy
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return OpenTypeL10n.text("直接模式", english: "Direct")
        case .tidy: return OpenTypeL10n.text("轻整理", english: "Tidy")
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
        case .tidy:
            return OpenTypeL10n.text(
                "松开后按固定规则去掉口癖、整理标点再写入，不经过任何 AI 模型",
                english: "Released speech has fillers dropped and punctuation normalised by fixed rules before it's inserted — no AI model involved"
            )
        case .review:
            return OpenTypeL10n.text(
                "松开后先在预览面板中查看、编辑或用语音修改，确认后再写入",
                english: "Released speech is staged in a review panel to check, edit, or voice-correct before it's inserted"
            )
        }
    }

    /// What this variant hands to the delivery path, or `nil` when it delivers
    /// nothing yet.
    ///
    /// The routing seam for the whole variant axis, kept here rather than
    /// inline in `AppModel.process` so it is testable without instantiating the
    /// model, and so adding a variant is one exhaustive `switch` the compiler
    /// checks rather than a chain of `== .review` comparisons scattered across
    /// the pipeline.
    ///
    /// `nil` means "dispatched, don't deliver yet" — today only `review`, which
    /// stages the transcript in its panel and delivers on commit. `tidy`
    /// deliberately does **not** join it: cleanup is instant and deterministic,
    /// so making the user confirm it would buy nothing and cost the whole
    /// point of a tier that sits between "unchanged" and "reviewed".
    func deliverableText(for transcript: String) -> String? {
        switch self {
        case .direct: return transcript
        case .tidy: return TidyTranscript.tidy(transcript)
        case .review: return nil
        }
    }

    /// Whether a finished recording in this variant lands text in the app the
    /// user was looking at — the condition the post-delivery correction window
    /// (`CorrectionWindow`) is built on, since there is nothing to fix in place
    /// until something has actually been pasted.
    ///
    /// The mirror image of `deliverableText(for:)`'s `nil`, stated as its own
    /// exhaustive `switch` rather than as `!= .review` so that a fourth variant
    /// has to answer both questions here, in one place, instead of silently
    /// inheriting an answer from a comparison somewhere down the pipeline.
    var deliversIntoTargetApp: Bool {
        switch self {
        case .direct, .tidy: return true
        case .review: return false
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

/// The ask side of the unified voice surface (`VoiceSurfaceState`), which is
/// derived from it: `nil` means no live ask, non-nil means one is on screen,
/// and `answer == nil` means it's still in the "thinking" state.
/// `AppModel.process(audioURL:)` sets this right before issuing the
/// `/oneshot/ask` sidecar call, and fills in `answer` once the response
/// arrives (including an error, delivered as answer text). `Kind` is also the
/// surface's own ask/agent discriminator — see `VoiceSurfaceState`.
///
/// Was originally the model behind a separate center-screen popup
/// (`AskPanelController`); that window is gone, but the state stayed, because
/// it is what `runAskDispatch` guards its late-answer delivery on.
struct AskPanelState: Equatable {
    enum Kind: Equatable {
        case ask
        case agent
    }

    var kind: Kind
    var query: String
    var answer: String?
    /// The sidecar conversation this exchange belongs to, once known.
    ///
    /// Carried on the SURFACE, not just on the tab, because the surface is
    /// what the user is looking at when they speak again: as long as the card
    /// is still up, the next utterance continues this thread rather than
    /// starting another one. See `VoiceFollowUp`.
    var conversationId: Int?
}

/// One step of the Agent progress panel's live feed — the display-side
/// mapping of a sidecar progress event (`SidecarAgentProgressEvent`). The
/// sidecar's `"done"` event type deliberately has no `Kind` here: the final
/// answer is shown via `AgentProgressPanelState.result`, not as a feed step.
struct AgentProgressStep: Equatable {
    enum Kind: Equatable {
        case thinking
        case toolCall
        case toolResult
        case error
    }

    var kind: Kind
    var detail: String
}

/// One choice offered by an agent question (T5), mirroring the sidecar's
/// `AskUserOption`. `label` is both the button text and the answer value, so
/// a richer UI later returns the same encoding a plain list does.
struct AgentQuestionOption: Decodable, Equatable {
    let label: String
    let description: String?
}

/// One question the agent is waiting on, from `GET /agent/question/:runId`.
struct AgentQuestion: Decodable, Equatable {
    let id: String
    let question: String
    let detail: String?
    let options: [AgentQuestionOption]?
    let multiSelect: Bool?
}

/// The pending-question payload for one run; `questions` is empty when the
/// run is not waiting on anything.
struct AgentQuestionPrompt: Decodable, Equatable {
    let runId: String
    let questions: [AgentQuestion]
}

/// One answer sent back through `POST /agent/answer/:runId`.
struct AgentQuestionAnswerItem: Encodable, Equatable {
    let id: String
    let selected: [String]
    let custom: String?
}

/// The wire shape of one entry from the sidecar's
/// `GET /agent/progress/:runId` response (`{ status, events }`) — what
/// `SidecarClient.agentProgress(runId:)` decodes each `events` element into.
struct SidecarAgentProgressEvent: Decodable, Equatable {
    let type: String
    let detail: String
}

/// The agent side of the unified voice surface: live feedback for an
/// in-flight `/agent/run` (spec:
/// docs/superpowers/specs/2026-08-13-agent-progress-panel-design.md for the
/// transport/state half, which the HUD-morph spec explicitly retains; that
/// spec's separate top-right window is gone). `AppModel` is the single source
/// of truth (`agentPanelState`; `nil` means nothing to show), and
/// `VoiceSurfaceState.reduce(...)` derives what the panel renders from it.
/// The surface always shows the most recently dispatched run — a newer
/// dispatch replaces this state wholesale.
struct AgentProgressPanelState: Equatable {
    enum Phase: Equatable {
        case running
        case succeeded
        case failed
        /// The user stopped the run (T1). Kept apart from `.failed` so the
        /// card can say "stopped" rather than accusing the run of breaking.
        case cancelled
    }

    /// The client-generated run id sent in the `/agent/run` body — the key
    /// both for progress polling and for guarding late updates (a poller or
    /// completion for an older run must not touch a newer run's panel).
    var runId: String
    var task: String
    var steps: [AgentProgressStep]
    var phase: Phase
    /// The final answer once the run succeeds, or the error text once it
    /// fails; `nil` while `phase == .running`.
    var result: String?
    /// The sidecar conversation this run belongs to, once known. Same role as
    /// `AskPanelState.conversationId`: it makes the visible surface the thing
    /// that decides what a follow-up follows. See `VoiceFollowUp`.
    var conversationId: Int?
    /// The question this run is currently waiting on (T5), or `nil`. Set from
    /// the same ~0.7s poll that drives `steps`, so asking needs no second
    /// polling loop.
    var question: AgentQuestion?

    /// Maps polled sidecar progress events to displayable feed steps:
    /// `"thinking"`/`"tool_call"`/`"tool_result"`/`"error"` map to the
    /// matching kinds with details preserved, `"done"` events are dropped
    /// (the `result` field covers them), unknown type strings are dropped,
    /// and relative order is preserved.
    static func steps(
        fromProgressEvents events: [SidecarAgentProgressEvent]
    ) -> [AgentProgressStep] {
        events.compactMap { event in
            let kind: AgentProgressStep.Kind?
            switch event.type {
            case "thinking": kind = .thinking
            case "tool_call": kind = .toolCall
            case "tool_result": kind = .toolResult
            case "error": kind = .error
            default: kind = nil
            }
            return kind.map { AgentProgressStep(kind: $0, detail: event.detail) }
        }
    }

    /// Pure polling decision: keep polling `/agent/progress/:runId` only
    /// while the displayed run is still `.running`.
    static func shouldContinuePolling(for phase: Phase) -> Bool {
        phase == .running
    }
}

/// Which conversation the next voice dispatch continues.
///
/// Before this existed, a thread could only be continued by opening it in the
/// main window first; speaking again at the overlay always opened a new one.
/// That split what was obviously one conversation into a pile of one-turn
/// threads, because the natural way to follow up on an answer you are looking
/// at is to keep talking, not to go find it in a list.
///
/// The rule is the surface's own lifetime: **while a card is still on screen,
/// the next thing you say continues it.** Dismissing the card ends the
/// thread — an explicit, visible act, rather than a hidden timeout.
enum VoiceFollowUp {
    /// - Parameters:
    ///   - surface: the conversation the live overlay is showing, if any.
    ///   - focusedTab: the thread opened in the main window, if any.
    /// - Returns: the conversation to continue, or `nil` to start a new one.
    static func conversationId(surface: Int?, focusedTab: Int?) -> Int? {
        // The surface wins. Both can be set at once — opening a thread in the
        // main window and then speaking leaves the surface showing that same
        // thread — but where they differ, the surface is the more recent
        // statement of what the user is working on.
        surface ?? focusedTab
    }
}

// MARK: - Unified voice surface

/// The single state machine behind the unified voice surface — the one
/// bottom-center `NSPanel` (`OverlayController`) that now covers the whole
/// ask/agent lifecycle, from the live-caption pill through "thinking" to the
/// result card it morphs into (spec:
/// `docs/superpowers/specs/2026-08-13-hud-morph-result-surface-design.md` §1).
/// It replaced the center-screen Ask popup and the top-right Agent progress
/// panel, both of which are gone.
///
/// This type is pure state: `AppModel` derives it from what it already owns
/// (`reduce(mode:processing:ask:agent:)`) and hands it to the controller,
/// which never decides anything itself. `transcribe` mode is deliberately
/// outside this machine — it keeps the legacy HUD/toast path and the Review
/// panel — so the reducer maps it to `.hidden` unconditionally.
enum VoiceSurfaceState: Equatable {
    /// Nothing for this surface to show; the legacy HUD/toast path owns the
    /// panel (all of transcribe mode, plus ask/agent with no live run).
    case hidden
    /// The existing live-caption pill, unchanged.
    case listening
    /// ASR in flight: the pill stays, with breathing dots in place of the
    /// waveform.
    case processing
    /// The LLM/agent is working: dots continue, plus (agent only) a one-line
    /// live step ticker.
    case working(WorkingDetail)
    /// The agent is waiting on the user's answer (T5).
    case asking(AskingDetail)
    /// The panel has grown into the result card.
    case result(ResultCard)
    /// The same card, showing a failed agent run.
    case failed(ResultCard)

    /// Payload of `.working`. `currentStep` is the agent's live one-liner
    /// (the last step that arrived, `nil` before the first one); it is always
    /// `nil` for ask, which per spec §4 gets a generic indicator with no
    /// per-step display.
    struct WorkingDetail: Equatable {
        var kind: AskPanelState.Kind
        var currentStep: String?
    }

    /// Payload of `.result`/`.failed`. `body` is **Markdown source** — the
    /// card renders it through `AssistantMarkdownView`, nothing is
    /// pre-rendered here. `steps` backs the collapsible agent step list and
    /// is always empty for ask.
    struct ResultCard: Equatable {
        var kind: AskPanelState.Kind
        var query: String
        var body: String
        var steps: [AgentProgressStep]
    }

    /// Payload of `.asking`: the run to answer and the question to render.
    struct AskingDetail: Equatable {
        var runId: String
        var question: AgentQuestion
    }

    /// Derives the surface from what `AppModel` already owns. Evaluated in a
    /// documented order:
    ///
    /// 1. `transcribe` → `.hidden`, unconditionally (it keeps the legacy HUD,
    ///    the Review panel, and the toast states).
    /// 2. `.listening` → `.listening`, **even with a live panel state**: a new
    ///    recording resets the surface to the pill while an in-flight agent
    ///    run keeps running in the background (its `AgentProgressPanelState`
    ///    must survive, since that state is what drives progress polling).
    /// 3. Otherwise the panel state **for the active mode** wins over
    ///    `ProcessingState` — the run has outlived the recording, and
    ///    `process(audioURL:)` drops back to `.idle`/`.dispatched` while the
    ///    run is still in flight. Only the active mode's panel state is
    ///    consulted, so a stale panel from the other mode can't leak in.
    /// 4. No panel state for the active mode + `.transcribing`/`.transforming`
    ///    → `.processing` (ASR in flight, plus the hand-off window,
    ///    defensively).
    /// 5. Everything else → `.hidden`.
    static func reduce(
        mode: InputMode,
        processing: ProcessingState,
        ask: AskPanelState?,
        agent: AgentProgressPanelState?
    ) -> VoiceSurfaceState {
        // 1. transcribe never uses this surface.
        guard mode != .transcribe else { return .hidden }

        // 2. A new recording always wins: the user is speaking and needs the
        //    live-caption pill, even if a previous run is still live.
        if processing == .listening { return .listening }

        // 3. The active mode's run outranks a lingering ProcessingState.
        switch mode {
        case .transcribe:
            return .hidden
        case .ask:
            if let ask {
                guard let answer = ask.answer else {
                    return .working(WorkingDetail(kind: .ask, currentStep: nil))
                }
                // An empty-string answer is still an answer (and an ask
                // failure arrives as answer text), so the split is
                // `answer == nil`, never `answer?.isEmpty`.
                return .result(
                    ResultCard(kind: .ask, query: ask.query, body: answer, steps: [])
                )
            }
        case .agent:
            if let agent {
                let card = ResultCard(
                    kind: .agent,
                    query: agent.task,
                    // A malformed completion still shows the task + step list
                    // instead of vanishing.
                    body: agent.result ?? "",
                    steps: agent.steps
                )
                switch agent.phase {
                case .running:
                    // A pending question outranks the step ticker: the run is
                    // blocked on the user, so showing "working…" would ask
                    // them to wait for something that is waiting for them.
                    if let question = agent.question {
                        return .asking(
                            AskingDetail(runId: agent.runId, question: question)
                        )
                    }
                    return .working(
                        WorkingDetail(kind: .agent, currentStep: agent.steps.last?.detail)
                    )
                case .succeeded:
                    return .result(card)
                case .failed, .cancelled:
                    // Both render the same card shape; the body text carries
                    // the difference, so the surface needs no fourth case.
                    return .failed(card)
                }
            }
        }

        // 4/5. No live run for this mode: only the genuinely in-flight
        //      ASR/hand-off states render anything.
        switch processing {
        case .transcribing, .transforming:
            return .processing
        default:
            return .hidden
        }
    }

    /// Clicking outside dismisses only a finished card. While `.working` the
    /// user must be able to click away and keep working during a long agent
    /// run without killing the surface.
    var allowsClickOutsideDismiss: Bool {
        switch self {
        case .result, .failed:
            return true
        // A question that a stray click dismisses is not a question. It stays
        // until answered, cancelled, or timed out.
        case .hidden, .listening, .processing, .working, .asking:
            return false
        }
    }

    /// The run this surface can stop, when it is showing a stoppable one
    /// (T1). Deliberately NOT folded into `dismissalEffect`: closing the
    /// panel and stopping the run are different intentions, and the documented
    /// rule that dismissing an agent run never cancels it stays intact.
    ///
    /// Only `.working` for an agent qualifies. An ask has no run id to address
    /// and is already cancelled by dismissal; a finished card has nothing left
    /// to stop.
    var stoppableAgentRun: Bool {
        switch self {
        case .working(let detail):
            return detail.kind == .agent
        // A blocked run is still a run: stopping must stay reachable while a
        // question is on screen.
        case .asking:
            return true
        case .hidden, .listening, .processing, .result, .failed:
            return false
        }
    }

    /// What dismissing this state must do beyond hiding the panel. Only a
    /// still-thinking ask is cancelled (today's `dismissAskPanel`
    /// ghost-answer semantics); dismissing an agent run NEVER cancels it.
    var dismissalEffect: VoiceSurfaceDismissalEffect {
        switch self {
        case .working(let detail) where detail.kind == .ask:
            return .cancelAsk
        case .hidden, .listening, .processing, .working, .asking, .result, .failed:
            return .none
        }
    }
}

/// The side effect of dismissing a `VoiceSurfaceState` — see
/// `VoiceSurfaceState.dismissalEffect`.
enum VoiceSurfaceDismissalEffect: Equatable {
    /// Abort the in-flight `/oneshot/ask` so a late "ghost answer" can't
    /// clobber the clipboard after the user moved on.
    case cancelAsk
    /// Just hide. Notably the agent case: the run, its clipboard delivery,
    /// its completion notification, its audit events, and its Agent-tab entry
    /// all continue untouched.
    case none
}

/// Bottom-center-anchored geometry for the unified voice surface's single
/// panel. Pure namespace enum (precedent: `OutputDeliveryPolicy`,
/// `OnboardingPolicy`) so the frame math is unit-testable without a screen.
///
/// The bottom edge is FIXED across every state and the card grows upward,
/// which is what makes `setFrame(_:display:animate:)` read as the pill
/// morphing into the card rather than as a new window appearing.
enum VoiceSurfacePanelLayout {
    /// The same 54pt bottom margin the HUD has always used.
    static let bottomMargin: CGFloat = 54

    static func frame(for size: CGSize, visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + bottomMargin,
            width: size.width,
            height: size.height
        )
    }

    /// The panel's size for a state.
    ///
    /// Forwards to `VoiceSurfacePanelMetrics` (`OverlayController.swift`)
    /// rather than carrying its own numbers. It used to hold a second copy of
    /// the table, which is how the 2026-08-14 redesign found the panel using
    /// six different widths: two tables, each locally reasonable, drifting
    /// apart one state at a time. One table, one place to change it.
    static func size(for state: VoiceSurfaceState) -> CGSize {
        switch state {
        case .hidden:
            return .zero
        case .listening, .processing, .working:
            return CGSize(
                width: VoiceSurfacePanelMetrics.pill.width,
                height: VoiceSurfacePanelMetrics.pill.height
            )
        case .asking(let detail):
            let size = VoiceSurfacePanelMetrics.asking(
                optionCount: detail.question.options?.count ?? 0
            )
            return CGSize(width: size.width, height: size.height)
        case .result, .failed:
            return CGSize(
                width: VoiceSurfacePanelMetrics.card.width,
                height: VoiceSurfacePanelMetrics.card.height
            )
        }
    }
}

/// The user's chosen language for the ASR pass, expressed in two unrelated
/// vocabularies because two different recognizers consume it:
///
///  - `appleLocaleIdentifier` — a BCP-47 locale for the Apple on-device
///    live-caption *preview* (`AppModel.hotKeyPressed`/`beginRecording` ->
///    `LiveSpeechTranscriber.start`).
///  - `whisperCode` — an ISO-639-1 code for the backend that produces the
///    transcript the user actually keeps, sent on `/asr/transcribe` and
///    honoured by both the local MLX-Whisper process and a configured remote
///    OpenAI-shaped provider.
///
/// The second one is the whole point of the setting and was missing until the
/// 2026-08-15 batch (§C): the picker offered 27 languages and reached only the
/// preview, so choosing "English" and still getting Chinese punctuation read as
/// the product being broken. Do not derive either code from the other — see
/// `whisperCode` for the three entries where that shortcut produces a wrong or
/// nonexistent language.
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

    /// The language code Whisper expects, or `nil` for "let it detect".
    ///
    /// These are keys of Whisper's own `LANGUAGES` table (ISO-639-1), **not**
    /// the BCP-47 identifiers above, and not something to compute from them:
    /// `String(appleLocaleIdentifier.prefix(2))` yields `"fi"` (Finnish) for
    /// Filipino and `"nb"` for Norwegian, which is not in Whisper's table at
    /// all. Whisper rejects a code outside that table outright, so a wrong one
    /// is an outage rather than a degradation.
    ///
    /// Deliberately an exhaustive `switch` with no `default:` — a `default:`
    /// returning `nil` would let a 28th language compile and ship as a picker
    /// entry that silently does nothing, which is exactly the bug this property
    /// exists to fix. `TranscriptionLanguageWhisperCodeTests` pins the same
    /// obligation from the test side.
    var whisperCode: String? {
        switch self {
        // Not a language: the absence of one. Anything but nil here would turn
        // the default setting into a forced language.
        case .automatic: return nil
        case .chinese: return "zh"
        // Measured 2026-08-15 against the model `whisper/serve.py` ships
        // (`DEFAULT_MODEL = mlx-community/whisper-small-mlx`, mlx_whisper
        // 0.4.3), through the same `mlx_whisper.transcribe` call it makes:
        // `language="yue"` raises `ValueError: tuple.index(x): x not in tuple`
        // from the tokenizer, while `language="zh"` returns normally. The cause
        // is structural, not a version fluke — `yue` is the 100th and last key
        // of Whisper's LANGUAGES table (added with large-v3), whisper-small's
        // checkpoint reports `n_vocab == 51865` so `num_languages == 99`, and
        // the tokenizer truncates the table to the first 99 keys before the
        // lookup. Since `serve.py` answers HTTP 500 on any exception, mapping
        // 粤语 to `"yue"` would fail *every* Cantonese transcription: worse
        // than the setting doing nothing. The mapping is static while the model
        // is not (`OPENTYPE_WHISPER_MODEL`, and the coming model picker) — on
        // large-v3 `yue` works, so re-measure this first if the default changes.
        case .cantonese: return "zh"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .german: return "de"
        case .french: return "fr"
        case .spanish: return "es"
        case .italian: return "it"
        case .portuguese: return "pt"
        case .russian: return "ru"
        case .arabic: return "ar"
        case .hindi: return "hi"
        case .indonesian: return "id"
        case .thai: return "th"
        case .turkish: return "tr"
        case .vietnamese: return "vi"
        case .ukrainian: return "uk"
        case .czech: return "cs"
        case .danish: return "da"
        // Whisper's table has Tagalog and no `fil`/`ph` entry at all; note the
        // app's `fil-PH` locale opens with the letters that spell Finnish.
        case .filipino: return "tl"
        case .finnish: return "fi"
        case .icelandic: return "is"
        case .malay: return "ms"
        // The macrolanguage key, which is what Whisper's table uses. Bokmål
        // (`nb`, the app's live-caption locale) is not in it.
        case .norwegian: return "no"
        case .polish: return "pl"
        case .swedish: return "sv"
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

    /// The recording gesture in as few characters as fit under a mode name.
    ///
    /// Distinct from `note` (a full paragraph) and from `modeSwitchHint` (about
    /// Tab). The sidebar's mode card answers "how do I start talking", which is
    /// the one thing someone looking at that card wants.
    var holdHint: String {
        switch self {
        case .leftOption: return OpenTypeL10n.text("按住 ⌥ 说话", english: "Hold ⌥ to talk")
        case .fnKey: return OpenTypeL10n.text("按住 fn 说话", english: "Hold fn to talk")
        case .doubleControl: return OpenTypeL10n.text("双击 ⌃ 开始", english: "Double-tap ⌃")
        case .doubleOption: return OpenTypeL10n.text("双击 ⌥ 开始", english: "Double-tap ⌥")
        case .doubleShift: return OpenTypeL10n.text("双击 ⇧ 开始", english: "Double-tap ⇧")
        case .controlShiftSpace: return OpenTypeL10n.text("⌃⇧Space 开始", english: "⌃⇧Space")
        case .optionSpace: return OpenTypeL10n.text("⌥Space 开始", english: "⌥Space")
        case .controlSpace: return OpenTypeL10n.text("⌃Space 开始", english: "⌃Space")
        case .controlOptionSpace: return OpenTypeL10n.text("⌃⌥Space 开始", english: "⌃⌥Space")
        }
    }

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

    /// The mode-cycle chord's one-line hint, derived from the preset rather
    /// than hardcoded in the UI, so it always names the key the user is
    /// actually holding — telling an `fn` user to hold left Option was the
    /// copy-side half of the same hardcoding bug the Tab gate had.
    ///
    /// `nil` for the Space-chord presets: they register a Carbon hot key
    /// instead of the modifier-only event tap, so there is no Tab handling
    /// there at all and nothing to advertise. Presence tracks
    /// `usesModifierOnlyEventTap` exactly.
    ///
    /// The old Shift half of the chord ("按住时点 Shift 或 Tab") is gone — Tab
    /// is the only mode-switch key now — so no hint tells the user to *tap*
    /// Shift; `.doubleShift` names Shift only as the key it asks them to hold.
    var modeSwitchHint: String? {
        switch self {
        case .leftOption:
            return OpenTypeL10n.text(
                "按住左 Option 时点 Tab 切换模式",
                english: "While holding left Option, tap Tab to switch modes"
            )
        case .fnKey:
            return OpenTypeL10n.text(
                "按住 fn 时点 Tab 切换模式",
                english: "While holding fn, tap Tab to switch modes"
            )
        case .doubleControl:
            return OpenTypeL10n.text(
                "按住 Ctrl 时点 Tab 切换模式",
                english: "While holding Ctrl, tap Tab to switch modes"
            )
        case .doubleOption:
            return OpenTypeL10n.text(
                "按住 Option 时点 Tab 切换模式",
                english: "While holding Option, tap Tab to switch modes"
            )
        case .doubleShift:
            return OpenTypeL10n.text(
                "按住 Shift 时点 Tab 切换模式",
                english: "While holding Shift, tap Tab to switch modes"
            )
        case .controlShiftSpace, .optionSpace, .controlSpace, .controlOptionSpace:
            return nil
        }
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

/// What one mode-cycle leaves behind: the mode the *next* recording will use,
/// and the mode the recording currently in flight is being processed as (`nil`
/// when there is none).
struct ModeCycleOutcome: Equatable {
    let selectedMode: InputMode
    let activeMode: InputMode?
}

/// The mode-cycle chord's decisions, factored out of `AppModel.cycleMode()` so
/// both halves are pure and testable (see `ModeSwitchChordTests`).
///
/// The chord is "hold the recording modifier, then tap Tab" — and holding the
/// recording modifier is *what starts a recording*. So `.listening` is not an
/// edge case the guard should reject, it is the state the user is in every time
/// they use the gesture; rejecting it (which is what `cycleMode()` used to do)
/// made mode switching dead past the 300ms long-press threshold. Cycling
/// while listening therefore also **retargets the in-flight recording** rather
/// than only moving the next-recording default — retargeting mid-flight is an
/// established capability here, not a new concept (`VoiceModeRouter` already
/// reassigns `activeMode` after transcription).
enum ModeCyclePolicy {
    /// The mid-pipeline states are the ones that stay closed: once the audio is
    /// being recognized/transformed/inserted, the mode this run is processed as
    /// has been committed and moving it would rewrite a decision already acted
    /// on. `isBusy`/`isStartingRecording` keep refusing in every state.
    static func allows(
        state: ProcessingState,
        isBusy: Bool,
        isStartingRecording: Bool
    ) -> Bool {
        guard !isBusy, !isStartingRecording else { return false }
        switch state {
        case .transcribing, .transforming, .inserting:
            return false
        case .idle, .modeChanged, .listening, .success, .copied,
             .dispatched, .cancelled, .failure:
            return true
        }
    }

    /// While listening, the mode being advanced is the one the recording locked
    /// in (`activeMode`) — which is also what the voice surface is showing
    /// (`AppModel.voiceSurfaceMode`) — and both it and the selected default land
    /// on the new mode. Otherwise nothing is in flight, so only the default
    /// moves; a finished run keeps the mode it ran as.
    static func cycle(
        selectedMode: InputMode,
        activeMode: InputMode?,
        state: ProcessingState
    ) -> ModeCycleOutcome {
        guard state == .listening, let inFlight = activeMode else {
            return ModeCycleOutcome(
                selectedMode: selectedMode.next,
                activeMode: activeMode
            )
        }
        let next = inFlight.next
        return ModeCycleOutcome(selectedMode: next, activeMode: next)
    }
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
/// dictionary the Settings "Memory" panel shows and (since P0-4) edits.
/// Mirrors (a subset of) `EntityTerm` from `sidecar/src/memory/MemoryStore.ts`.
///
/// `id` is the sidecar's real `entity_terms.id`, not a value synthesized from
/// `canonicalTerm`: it is what `PUT`/`DELETE /memory/terms/:id` address, and a
/// canonical-term key could not survive a rename — which is precisely the edit
/// the panel exists for. `origin` is optional because older payloads (and test
/// fixtures) may omit it; the panel reads `nil` as unknown provenance.
struct EntityTermSummary: Decodable, Identifiable {
    let id: Int
    let canonicalTerm: String
    let aliases: [String]
    let category: String
    let confidence: Double
    let origin: String?
}

/// One row of the sidecar's `GET /memory/owner-facts` response — the free-text
/// owner facts (`OwnerFact` in `sidecar/src/memory/MemoryStore.ts`), listed for
/// every origin so a user can find and delete one the agent planted from
/// untrusted context (P1-12). `createdAt` is epoch milliseconds.
struct OwnerFactSummary: Decodable, Identifiable {
    let id: Int
    let content: String
    let createdAt: Int
    let origin: String?
}

/// Body for `POST /memory/terms` — a term the user typed into the dictionary
/// panel. Deliberately carries no `confidence`/`origin`: the sidecar pins an
/// owner-created term at confidence 1.0 / origin "owner", and a client-claimed
/// provenance would make the `origin` badge worthless.
struct MemoryTermCreateRequest: Encodable {
    let canonicalTerm: String
    let aliases: [String]
}

/// Body for `PUT /memory/terms/:id` — a *patch*. A field the user did not touch
/// must be absent from the JSON rather than encoded as `null`: the sidecar
/// reads a present key as "set this field", so a null `canonicalTerm` would be
/// a 400 and a null `aliases` would silently wipe every alias. Synthesized
/// `Encodable` already omits a nil optional; this spells the `encodeIfPresent`
/// calls out by hand so the patch semantics survive someone later adding a
/// field or a custom `CodingKeys`, rather than resting on synthesis.
struct MemoryTermUpdateRequest: Encodable {
    let canonicalTerm: String?
    let aliases: [String]?
    let confidence: Double?

    private enum CodingKeys: String, CodingKey {
        case canonicalTerm, aliases, confidence
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(canonicalTerm, forKey: .canonicalTerm)
        try container.encodeIfPresent(aliases, forKey: .aliases)
        try container.encodeIfPresent(confidence, forKey: .confidence)
    }
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
    /// The newest message in the thread, for the row's second line.
    ///
    /// Optional because a conversation can exist with no messages yet, and
    /// because older sidecars do not send it — an absent preview draws a
    /// single-line row rather than an empty second line.
    ///
    /// Defaulted so the many existing constructions of this type, none of
    /// which are about previews, do not have to state one.
    var preview: String? = nil
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

/// Pure, testable decision for whether the first-run provider-setup wizard must
/// take over the main window (P1-19). The sidecar's `ready` flag requires BOTH
/// Whisper and an LLM to be configured, which traps a user who only wants local
/// transcription (`transcribe` mode makes no LLM call at all) into configuring
/// an LLM just to reach the app. This seam changes the truth table so that
/// speech recognition being ready — or the user explicitly choosing the "just
/// local transcription, skip AI setup" path — is enough to enter the app; LLM
/// configuration is deferred to when an `ask`/`agent` mode actually needs it.
///
/// Rule: onboarding is required iff neither the local-only path was
/// acknowledged nor Whisper is configured. `llmConfigured` is intentionally not
/// a factor — an LLM alone can't capture speech, so it never lets the user in,
/// and its absence never keeps a transcribe-ready user out.
enum OnboardingPolicy {
    static func needsProviderOnboarding(
        whisperConfigured: Bool,
        llmConfigured: Bool,
        localTranscriptionOnlyAcknowledged: Bool
    ) -> Bool {
        !(localTranscriptionOnlyAcknowledged || whisperConfigured)
    }
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

// MARK: - MCP servers (P2-13)
//
// Wire models for the sidecar's `/config/mcp*` routes
// (`sidecar/src/agent/mcpConfigRoutes.ts`), which back the Settings
// "MCP 服务器" panel. Same shape of split the provider models above use: a
// `*Summary` for what comes back (secrets masked) and a `*Request` for what
// goes out (secrets real).

/// The two kinds of MCP server the sidecar can attach to Agent mode: a local
/// child process spoken to over stdio, or a remote HTTP endpoint. The choice
/// decides which half of a server record is meaningful — `command`/`args`/`env`
/// for stdio, `url`/`headers` for http — and the sidecar drops the other half
/// at normalization time (`normalizeMcpServer`), so a switched server can't
/// keep credentials it no longer has any use for.
enum McpTransport: String, Codable, CaseIterable, Identifiable, Equatable {
    case stdio
    case http

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stdio:
            return OpenTypeL10n.text("本地命令（stdio）", english: "Local command (stdio)")
        case .http:
            return OpenTypeL10n.text("远程 HTTP", english: "Remote HTTP")
        }
    }
}

/// Which of the sidecar's two config sources actually supplied the servers in a
/// `GET /config/mcp` response. `saved` is the user's own persisted list;
/// `env` is the `OPENTYPE_MCP_SERVERS` zero-config dev fallback, which is shown
/// but never presented as the user's configuration — same "configured is
/// explicit, never ambient" stance `ProviderConfigStatus` takes.
enum McpConfigSource: String, Decodable, Equatable {
    case saved
    case env
}

/// Why a server was skipped when the voice service last started.
///
/// The two cases are kept apart because the fix is different, and the row has
/// one line to say which: a timeout means the server is unreachable or too slow
/// and was given up on, while a failure means the configuration itself is wrong
/// (`spawn npx ENOENT`) and the server's own message is the useful thing to
/// show. Collapsing them into "didn't start" would send a user with a typo off
/// to check their network.
enum McpStartupFailure: Equatable {
    /// The server never finished its handshake inside the connect budget.
    case timedOut
    /// The connection failed outright, carrying the sidecar's recorded message.
    case failed(String)
}

/// One MCP server as the sidecar reports it.
///
/// Secrets arrive **only** as `envMasked`/`headersMasked`. There is
/// deliberately no `env`/`headers` property to decode into, so a real token
/// cannot reach Swift (and therefore cannot reach a text field, a log line, or
/// the pasteboard) even if a future sidecar change started sending one. Map
/// *keys* are not masked: the user needs to see that `GITHUB_TOKEN` is set,
/// just not what it is set to.
struct McpServerSummary: Decodable, Identifiable, Equatable {
    let name: String
    let transport: McpTransport
    let command: String?
    let args: [String]?
    let url: String?
    let envMasked: [String: String]?
    let headersMasked: [String: String]?
    /// Absent reads as enabled — the value every config written before this
    /// field existed implies, and the same default `normalizeMcpServer` applies
    /// on the other side of the wire.
    let enabled: Bool?
    /// Why the last voice-service start skipped this server, when it did.
    ///
    /// `GET /config/mcp` alone carries it — it is a runtime verdict, so the
    /// write routes (which answer with a server that has not booted yet) leave
    /// it out, and so does a server that connected, is still connecting, or was
    /// disabled and therefore never started. Optional in every sense: absent
    /// means "nothing to report", never "fine".
    let lastStartupError: String?

    /// The name is what `PUT`/`DELETE /config/mcp/:name` address, so it is also
    /// the row identity — there is no separate id to key on.
    var id: String { name }

    var isEnabled: Bool { enabled ?? true }

    /// Marker the sidecar stamps on the timeout kind of `lastStartupError`
    /// (`MCP_STARTUP_TIMEOUT_PREFIX` in `sidecar/src/agent/mcpConfigRoutes.ts`).
    /// The field is one string on purpose — it is what a row renders — so the
    /// kind travels inside it, and these two constants must move together.
    private static let startupTimeoutMarker = "Startup timed out:"

    /// `lastStartupError` classified into something a row can render.
    var startupFailure: McpStartupFailure? {
        guard
            let text = lastStartupError?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return nil
        }
        if text.hasPrefix(Self.startupTimeoutMarker) {
            return .timedOut
        }
        return .failed(text)
    }
}

/// Mirrors `GET /config/mcp`.
struct McpConfigSummary: Decodable, Equatable {
    let configured: Bool
    let source: McpConfigSource
    let servers: [McpServerSummary]
}

/// The `POST /config/mcp`, `PUT /config/mcp/:name` and `POST /config/mcp/test`
/// request body — the one direction secrets travel in the clear, over the local
/// Unix socket.
///
/// Every optional is encoded with `encodeIfPresent` (the synthesized default),
/// which is load-bearing in two places:
///
///  * `nil` leaves the key out of the JSON entirely rather than sending `null`.
///    A null `url`/`command` reads on the sidecar side as "supplied but empty"
///    and 400s a perfectly valid server of the other transport.
///  * an *empty* `env`/`args` still goes out as `{}`/`[]`, which is how
///    "delete every entry" is expressed — the write is a replace, not a patch.
///
/// A value equal to the mask the sidecar previously reported for that same
/// server *and* the same key means "unchanged" and is resolved back to the
/// stored secret server-side. `McpServerEditor` (`Views.swift`) relies on that
/// round-trip, so masks are passed through verbatim here rather than being
/// filtered out on the way.
struct McpServerRequest: Encodable, Equatable {
    let name: String
    let transport: McpTransport
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let url: String?
    let headers: [String: String]?
    /// `nil` omits the key, letting the sidecar apply its own `true` default —
    /// so every existing call site keeps behaving exactly as it did. Sent as
    /// `false` by 停用并保存, which is the whole reason this is expressible: a
    /// server whose test failed can be kept without being handed to the next
    /// start.
    ///
    /// Defaulted rather than required: a caller with no opinion about whether a
    /// server should boot is exactly the caller that should not have to state
    /// one, and requiring it would have meant editing call sites — including a
    /// test — that have nothing to do with this field.
    var enabled: Bool? = nil
}

/// One tool an MCP server exposes, as reported by `POST /config/mcp/test`.
struct McpToolSummary: Decodable, Identifiable, Equatable {
    let name: String
    /// MCP servers are not required to describe their tools.
    let description: String?

    var id: String { name }
}

/// Mirrors `POST /config/mcp/test`. `success == true` with an empty `tools` is a
/// server that connected but exposes nothing — distinct both from a failure and
/// from `tools` being absent.
struct McpTestResultSummary: Decodable, Equatable {
    let success: Bool
    let error: String?
    let tools: [McpToolSummary]?
}
