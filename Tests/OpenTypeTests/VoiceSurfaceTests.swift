import CoreGraphics
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the unified voice surface — "HUD morph
/// result surface + markdown" (spec:
/// `docs/superpowers/specs/2026-08-13-hud-morph-result-surface-design.md`).
///
/// The spec collapses three floating windows (the bottom-center HUD, the
/// center-screen Ask popup, the top-right Agent progress panel) into ONE
/// bottom-center panel driven by a single state enum, and requires all
/// assistant text to render as Markdown. This file pins the pure, testable
/// seams the spec calls out in §1 ("Pure-logic seams", `OverlayHideBehavior`
/// precedent) plus the Markdown wrapper's existence from §3. Nothing here
/// instantiates an `NSPanel`, starts a timer, or touches the network.
///
/// ============================================================
/// CONTRACT PICKS — stage 3 implements these exactly
/// ============================================================
///
/// **1. `VoiceSurfaceState`** (new, `Models.swift` alongside the other state
/// models), `Equatable`, with exactly the spec's states:
/// ```swift
/// enum VoiceSurfaceState: Equatable {
///     case hidden
///     case listening
///     case processing
///     case working(WorkingDetail)
///     case result(ResultCard)
///     case failed(ResultCard)
/// }
/// ```
/// `WorkingDetail` and `ResultCard` are **nested** inside `VoiceSurfaceState`
/// (`VoiceSurfaceState.WorkingDetail`, `VoiceSurfaceState.ResultCard`),
/// following this repo's existing nesting precedent — `AskPanelState.Kind`,
/// `AgentProgressPanelState.Phase`, `AgentProgressStep.Kind`. Tests below
/// always spell them fully qualified, so the nesting is part of the contract.
///
/// - `WorkingDetail`: `Equatable` struct, memberwise
///   `init(kind:currentStep:)` with `kind: AskPanelState.Kind` and
///   `currentStep: String?` (the agent's live one-liner; always `nil` for
///   ask, which per spec §4 gets a generic indicator with no per-step
///   display).
/// - `ResultCard`: `Equatable` struct, memberwise
///   `init(kind:query:body:steps:)` with `kind: AskPanelState.Kind`,
///   `query: String` (the spoken question/task, rendered as plain user text),
///   `body: String` (**Markdown source** for the answer/result — the card
///   renders it through `AssistantMarkdownView`, it is NOT pre-rendered
///   here), and `steps: [AgentProgressStep]` (the collapsible agent step
///   list; always empty for ask).
///
/// **Why `AskPanelState.Kind` for `kind`** rather than a new enum: it is
/// already exactly `.ask`/`.agent`, and the spec (§2) keeps `AskPanelState`
/// as the ask-side state model feeding the reducer, so reusing its nested
/// `Kind` avoids inventing a parallel two-case enum. `InputMode` is the wrong
/// type here — the surface has no `.transcribe` shape at all. One test below
/// annotates the type explicitly to pin this.
///
/// **2. The reducer** — a pure static on the enum:
/// ```swift
/// static func reduce(
///     mode: InputMode,
///     processing: ProcessingState,
///     ask: AskPanelState?,
///     agent: AgentProgressPanelState?
/// ) -> VoiceSurfaceState
/// ```
/// evaluated in this documented order (each rule is tested):
///
///   1. `mode == .transcribe` → `.hidden`, unconditionally. Transcribe keeps
///      the legacy `OverlayController` HUD, the Review panel, and the toast
///      states (spec §1 "transcribe mode's existing behavior … is
///      unchanged", §4 out of scope); this surface is ask/agent only.
///   2. `processing == .listening` → `.listening`, **even when a panel state
///      is non-nil**. Spec §1: "A new recording resets the surface to
///      `listening`; an in-flight agent run continues in the background."
///      The user is speaking and needs the live-caption pill; the agent run
///      keeps running and keeps its `AgentProgressPanelState` (that state is
///      what drives progress polling, so the reducer must not require
///      AppModel to destroy it just to show the pill). This is the one
///      deliberate carve-out from rule 3's panel-wins precedence, and it is
///      why "listening wins" is tested explicitly below.
///   3. Otherwise the panel state for the current mode **wins over the
///      `ProcessingState`** (the caller's precedence requirement: the run has
///      outlived the recording). Concretely, `AppModel.process(audioURL:)`
///      calls `setState(.transforming)` *before* assigning
///      `askPanelState`/dispatching the agent run, and then drops back to
///      `.idle`/`.dispatched` while the run is still in flight — so a
///      lingering `.transcribing`/`.transforming`/`.idle`/`.dispatched` must
///      never override a live run's surface. Only the panel state for the
///      **active mode** is consulted (ask mode ignores `agent:`, agent mode
///      ignores `ask:`), so a stale panel from the other mode cannot leak in.
///      - `.ask` + `ask.answer == nil` →
///        `.working(.init(kind: .ask, currentStep: nil))`
///      - `.ask` + `ask.answer != nil` →
///        `.result(.init(kind: .ask, query: ask.query, body: answer,
///        steps: []))`
///      - `.agent` + `phase == .running` →
///        `.working(.init(kind: .agent, currentStep: steps.last?.detail))`
///        — the live one-liner ticker of spec §1's `working` row; `nil` when
///        no step has arrived yet.
///      - `.agent` + `phase == .succeeded` →
///        `.result(.init(kind: .agent, query: agent.task,
///        body: agent.result ?? "", steps: agent.steps))`
///      - `.agent` + `phase == .failed` → the same card, wrapped in
///        `.failed` instead of `.result`.
///      `agent.result == nil` maps to an EMPTY body rather than dropping the
///      card, so a malformed completion still shows the task + step list
///      instead of vanishing.
///   4. No panel state for the active mode, and
///      `processing == .transcribing` (the real ASR-in-flight case name in
///      `ProcessingState`) → `.processing`. This is the load-bearing half:
///      `AppModel.process(audioURL:)` sets `.transcribing` and then *awaits*
///      `transcribeLocally(audioURL:)`, so `.transcribing` with no panel state
///      is a long, genuinely-rendered window. `.transforming` maps here too,
///      defensively: `setState(.transforming)` really does run before
///      `askPanelState` is assigned / `dispatchAgentRun` is called (verified
///      in stage 2, see the note at the bottom of this header), but there is
///      no suspension point in between, so ask/agent never actually *render*
///      a panel-less `.transforming`. Mapping the two ASR/hand-off states
///      together keeps the surface from being able to flash off mid-pipeline
///      if that gap ever gains an `await`.
///   5. Everything else → `.hidden` (`.idle`, `.success`, `.copied`,
///      `.dispatched`, `.cancelled`, `.failure`, `.modeChanged`,
///      `.inserting` with no live panel state).
///
/// Two consequences worth stating because they are deliberate, not
/// oversights:
/// - There is no ask-side `.failed`: `AppModel.dispatchAskRun`'s `catch`
///   delivers failures *as the answer text* ("提问失败：…") on
///   `AskPanelState`, so an ask error surfaces as a `.result` card whose body
///   is that message. `.failed` is agent-only (`Phase.failed`).
/// - In `.ask` mode the card's `kind` is derived from the MODE (always
///   `.ask`), not from `AskPanelState.kind` — AppModel only ever constructs
///   `AskPanelState(kind: .ask, …)`, so the `.agent`-flavored `AskPanelState`
///   is unreachable and is not exercised here.
///
/// **3. `VoiceSurfacePanelLayout`** (new): a pure namespace enum — precedent
/// `OutputDeliveryPolicy` / `OnboardingPolicy` — with two static functions:
/// - `frame(for size: CGSize, visibleFrame: CGRect) -> CGRect`:
///   bottom-anchored growth. `origin.x = visibleFrame.midX - size.width / 2`,
///   `origin.y = visibleFrame.minY + 54` (the same 54pt bottom margin
///   `OverlayController.position(_:)` uses today), size passed through. The
///   bottom edge is therefore FIXED across every state and the card grows
///   upward, which is what makes `setFrame(_:display:animate:)` read as the
///   pill morphing into the card (spec §1 `result` row).
/// - `size(for state: VoiceSurfaceState) -> CGSize`, the spec §1 table:
///   `.listening`/`.processing` → 388×96 (today's
///   `OverlayController.listeningSize`), `.working` → 388×120 (the extra
///   room for the step ticker line), `.result`/`.failed` → 620×480,
///   `.hidden` → `.zero`.
///
/// **4. Dismissal policy** — two computed properties on `VoiceSurfaceState`
/// (spec §1 "Transition rules"):
/// - `var allowsClickOutsideDismiss: Bool` — `true` ONLY for `.result` and
///   `.failed`. While `.working` the user must be able to click away and keep
///   working during a long agent run without killing the surface.
/// - `var dismissalEffect: VoiceSurfaceDismissalEffect` — a new `Equatable`
///   enum `{ case cancelAsk, none }`. `.cancelAsk` ONLY for `.working` with
///   kind `.ask` (today's `dismissAskPanel` ghost-answer cancellation);
///   everything else, including `.working` kind `.agent`, is `.none` —
///   dismissing NEVER cancels an agent run.
///
/// **5. `AssistantMarkdownView`** (new, shared wrapper view, spec §3) with
/// `init(markdown: String)`. Its test is deliberately construction-only: it
/// exists to force the MarkdownUI SwiftPM dependency and the shared wrapper
/// into existence, with no rendering/snapshot assertion.
///
/// ============================================================
/// RED STATE / SCOPE
/// ============================================================
/// None of `VoiceSurfaceState`, its nested `WorkingDetail`/`ResultCard`,
/// `VoiceSurfacePanelLayout`, `VoiceSurfaceDismissalEffect`, or
/// `AssistantMarkdownView` exists yet, so this file fails to COMPILE and the
/// whole test target is red. That is the intended red (same shape as
/// `OverlayHideBehaviorTests` / `AgentProgressPanelTests` when they were
/// written); every compile error must reference only the new symbols above.
///
/// Reused unchanged, NOT re-tested here (already covered by
/// `AgentProgressPanelTests`): `AgentProgressPanelState.steps(fromProgressEvents:)`
/// and `AgentProgressPanelState.shouldContinuePolling(for:)`. That file's
/// `AgentProgressPanelController.panelOrigin` top-right geometry tests belong
/// to the presentation layer this spec supersedes; the "Frame math" section
/// below is their replacement coverage. They still reference
/// `AgentProgressPanelController`, so stage 3 must leave that controller in
/// place while making this file green — retiring the top-right window (spec
/// §2) is a separate step that has to retire those two tests with it.
///
/// ============================================================
/// STAGE-2 REVIEW NOTES (verified against the source, 2026-08-13)
/// ============================================================
/// - Rule 2's carve-out is load-bearing, not theoretical:
///   `AppModel.beginRecording(context:mode:practice:)` sets only
///   `isStartingRecording`/`capturedContext`/`activeMode`/`isPracticeSession`
///   and cancels `processingTask` before `setState(.listening)`. It never
///   clears `agentPanelState` (only `dispatchAgentRun` and
///   `dismissAgentPanel` assign it) or `askPanelState`, and it does not
///   cancel `askTask`. So `.listening` genuinely coexists with a non-nil
///   panel state on every re-record, for BOTH kinds.
/// - Rule 4's ordering claim is real: `setState(.transforming)` precedes both
///   `askPanelState = AskPanelState(...)` and `dispatchAgentRun(...)` in
///   `process(audioURL:)`, with only comments and a synchronous
///   `sidecarTextModel` read in between (no `await`) — hence the "defensive,
///   not observable" wording in rule 4 above.
/// - Two discriminating tests were added in review (marked STAGE-2 below):
///   the working-ticker mode gate with BOTH panel states live, and the
///   empty-string ask answer. Without them a reducer that reads the agent
///   ticker regardless of mode, or that splits ask on `answer?.isEmpty`
///   instead of `answer == nil`, would pass the whole file.
@MainActor
final class VoiceSurfaceTests: XCTestCase {

    // MARK: - Fixtures

    private func askState(
        query: String = "北京今天多少度",
        answer: String? = nil
    ) -> AskPanelState {
        AskPanelState(kind: .ask, query: query, answer: answer)
    }

    private func agentState(
        runId: String = "run-1",
        task: String = "帮我整理这份会议纪要",
        steps: [AgentProgressStep] = [],
        phase: AgentProgressPanelState.Phase = .running,
        result: String? = nil
    ) -> AgentProgressPanelState {
        AgentProgressPanelState(
            runId: runId,
            task: task,
            steps: steps,
            phase: phase,
            result: result
        )
    }

    // MARK: - A. VoiceSurfaceState: construction, payloads, equality

    func testWorkingDetailCarriesKindAndCurrentStep() {
        let detail = VoiceSurfaceState.WorkingDetail(
            kind: .agent,
            currentStep: "正在调用 web_search…"
        )

        XCTAssertEqual(detail.kind, .agent)
        XCTAssertEqual(detail.currentStep, "正在调用 web_search…")
    }

    func testWorkingDetailKindIsAskPanelStateKind() {
        // Pins the `kind` type: an explicitly annotated `AskPanelState.Kind`
        // must be accepted, so stage 3 cannot substitute a new enum.
        let kind: AskPanelState.Kind = .ask
        let detail = VoiceSurfaceState.WorkingDetail(kind: kind, currentStep: nil)

        XCTAssertEqual(detail.kind, .ask)
        XCTAssertNil(detail.currentStep)
    }

    func testResultCardCarriesAllFields() {
        let steps = [AgentProgressStep(kind: .toolCall, detail: "Calling a()")]
        let card = VoiceSurfaceState.ResultCard(
            kind: .agent,
            query: "帮我整理这份会议纪要",
            body: "## 纪要\n\n- 第一点",
            steps: steps
        )

        XCTAssertEqual(card.kind, .agent)
        XCTAssertEqual(card.query, "帮我整理这份会议纪要")
        XCTAssertEqual(card.body, "## 纪要\n\n- 第一点")
        XCTAssertEqual(card.steps, steps)
    }

    func testResultCardKindIsAskPanelStateKind() {
        let kind: AskPanelState.Kind = .ask
        let card = VoiceSurfaceState.ResultCard(
            kind: kind,
            query: "q",
            body: "**bold**",
            steps: []
        )

        XCTAssertEqual(card.kind, .ask)
        XCTAssertTrue(card.steps.isEmpty)
    }

    func testIdenticalStatesAreEqual() {
        func makeWorking() -> VoiceSurfaceState {
            .working(
                VoiceSurfaceState.WorkingDetail(kind: .agent, currentStep: "step")
            )
        }
        func makeResult() -> VoiceSurfaceState {
            .result(
                VoiceSurfaceState.ResultCard(
                    kind: .ask,
                    query: "q",
                    body: "a",
                    steps: []
                )
            )
        }

        XCTAssertEqual(VoiceSurfaceState.hidden, .hidden)
        XCTAssertEqual(VoiceSurfaceState.listening, .listening)
        XCTAssertEqual(VoiceSurfaceState.processing, .processing)
        XCTAssertEqual(makeWorking(), makeWorking())
        XCTAssertEqual(makeResult(), makeResult())
    }

    func testDistinctStatesAreNotEqual() {
        XCTAssertNotEqual(VoiceSurfaceState.hidden, .listening)
        XCTAssertNotEqual(VoiceSurfaceState.listening, .processing)
        XCTAssertNotEqual(
            VoiceSurfaceState.processing,
            .working(VoiceSurfaceState.WorkingDetail(kind: .ask, currentStep: nil))
        )
    }

    func testWorkingInequalityWhenKindOrStepDiffers() {
        let ask = VoiceSurfaceState.working(
            VoiceSurfaceState.WorkingDetail(kind: .ask, currentStep: nil)
        )
        let agent = VoiceSurfaceState.working(
            VoiceSurfaceState.WorkingDetail(kind: .agent, currentStep: nil)
        )
        let agentTicking = VoiceSurfaceState.working(
            VoiceSurfaceState.WorkingDetail(kind: .agent, currentStep: "正在调用 web_search…")
        )

        XCTAssertNotEqual(ask, agent)
        XCTAssertNotEqual(agent, agentTicking)
    }

    func testResultAndFailedWithTheSameCardAreNotEqual() {
        // The card payload is identical; only the case differs. A `.failed`
        // run must never compare equal to a succeeded one.
        let card = VoiceSurfaceState.ResultCard(
            kind: .agent,
            query: "任务",
            body: "boom",
            steps: []
        )

        XCTAssertNotEqual(VoiceSurfaceState.result(card), .failed(card))
    }

    func testResultInequalityWhenBodyDiffers() {
        let first = VoiceSurfaceState.result(
            VoiceSurfaceState.ResultCard(kind: .ask, query: "q", body: "42", steps: [])
        )
        let second = VoiceSurfaceState.result(
            VoiceSurfaceState.ResultCard(kind: .ask, query: "q", body: "43", steps: [])
        )

        XCTAssertNotEqual(first, second)
    }

    // MARK: - B. Reducer: transcribe never uses this surface

    func testTranscribeModeIsAlwaysHiddenAcrossProcessingStates() {
        let states: [ProcessingState] = [
            .idle,
            .listening,
            .transcribing,
            .transforming,
            .inserting,
            .success,
            .copied,
            .modeChanged,
            .dispatched("已下发给 Agent"),
            .cancelled("已取消"),
            .failure("出错了")
        ]

        for processing in states {
            XCTAssertEqual(
                VoiceSurfaceState.reduce(
                    mode: .transcribe,
                    processing: processing,
                    ask: nil,
                    agent: nil
                ),
                .hidden,
                "transcribe must keep the legacy HUD for \(processing)"
            )
        }
    }

    func testTranscribeModeStaysHiddenEvenWithLivePanelStates() {
        // A leftover ask answer / running agent run must not drag the surface
        // into view during a transcribe recording.
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .transcribe,
                processing: .transcribing,
                ask: askState(answer: "42"),
                agent: agentState(steps: [
                    AgentProgressStep(kind: .thinking, detail: "Thinking…")
                ])
            ),
            .hidden
        )
    }

    // MARK: - B. Reducer: listening / processing

    func testAskListeningShowsListening() {
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .listening,
                ask: nil,
                agent: nil
            ),
            .listening
        )
    }

    func testAgentListeningShowsListening() {
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .listening,
                ask: nil,
                agent: nil
            ),
            .listening
        )
    }

    func testAskTranscribingShowsProcessing() {
        // `.transcribing` is the real ASR-in-flight case in `ProcessingState`.
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .transcribing,
                ask: nil,
                agent: nil
            ),
            .processing
        )
    }

    func testAgentTranscribingShowsProcessing() {
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .transcribing,
                ask: nil,
                agent: nil
            ),
            .processing
        )
    }

    func testTransformingWithoutPanelStateStaysProcessing() {
        // The hand-off window: `process(audioURL:)` sets `.transforming`
        // BEFORE `askPanelState` is assigned / the agent run is dispatched
        // (verified in stage 2). No `await` sits in that gap today, so this
        // pairs `.transforming` with `.transcribing` defensively rather than
        // to fix an observable flash — see rule 4 in the header.
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .transforming,
                ask: nil,
                agent: nil
            ),
            .processing
        )
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .transforming,
                ask: nil,
                agent: nil
            ),
            .processing
        )
    }

    func testIdleWithoutPanelStateIsHidden() {
        for mode in [InputMode.ask, .agent] {
            XCTAssertEqual(
                VoiceSurfaceState.reduce(
                    mode: mode,
                    processing: .idle,
                    ask: nil,
                    agent: nil
                ),
                .hidden,
                "no run and nothing in flight means nothing to show (\(mode))"
            )
        }
    }

    func testTerminalToastStatesWithoutPanelStateAreHidden() {
        let states: [ProcessingState] = [
            .success,
            .copied,
            .modeChanged,
            .inserting,
            .dispatched("已下发给 Agent"),
            .cancelled("已取消"),
            .failure("出错了")
        ]

        for processing in states {
            XCTAssertEqual(
                VoiceSurfaceState.reduce(
                    mode: .agent,
                    processing: processing,
                    ask: nil,
                    agent: nil
                ),
                .hidden,
                "\(processing) has no surface of its own without a run"
            )
        }
    }

    // MARK: - B. Reducer: ask panel state

    func testAskWithoutAnswerIsWorkingWithNoStepTicker() {
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .idle,
                ask: askState(query: "生命的意义是什么", answer: nil),
                agent: nil
            ),
            .working(
                VoiceSurfaceState.WorkingDetail(kind: .ask, currentStep: nil)
            )
        )
    }

    func testAskWithAnswerIsResultCardCarryingQueryAndBody() {
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .idle,
                ask: askState(query: "生命的意义是什么", answer: "42"),
                agent: nil
            ),
            .result(
                VoiceSurfaceState.ResultCard(
                    kind: .ask,
                    query: "生命的意义是什么",
                    body: "42",
                    steps: []
                )
            )
        )
    }

    // STAGE-2 addition. The ask split is `answer == nil`, not
    // `answer?.isEmpty`: an empty-string answer is still an ANSWER and must
    // resolve the card, otherwise a degenerate `/oneshot/ask` response leaves
    // the user staring at a "thinking…" surface forever. Mirrors the agent
    // side's `result == nil` → empty-body rule.
    func testAskWithAnEmptyAnswerStillResolvesToAResultCard() {
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .idle,
                ask: askState(query: "生命的意义是什么", answer: ""),
                agent: nil
            ),
            .result(
                VoiceSurfaceState.ResultCard(
                    kind: .ask,
                    query: "生命的意义是什么",
                    body: "",
                    steps: []
                )
            )
        )
    }

    func testAskResultCardHasNoSteps() {
        let state = VoiceSurfaceState.reduce(
            mode: .ask,
            processing: .idle,
            ask: askState(answer: "**Markdown** answer"),
            agent: nil
        )

        guard case .result(let card) = state else {
            return XCTFail("expected a result card, got \(state)")
        }
        XCTAssertTrue(card.steps.isEmpty, "ask never has an agent step list")
        XCTAssertEqual(card.body, "**Markdown** answer")
    }

    func testAskModeIgnoresAStaleAgentPanelState() {
        // Only the active mode's panel state is consulted, so a finished agent
        // run cannot hijack an ask-mode surface.
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .idle,
                ask: nil,
                agent: agentState(phase: .succeeded, result: "old result")
            ),
            .hidden
        )
    }

    // MARK: - B. Reducer: agent panel state

    func testAgentRunningUsesTheLastStepAsTheLiveTicker() {
        let steps = [
            AgentProgressStep(kind: .thinking, detail: "Thinking (step 1/10)…"),
            AgentProgressStep(kind: .toolCall, detail: "正在调用 web_search…")
        ]

        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .idle,
                ask: nil,
                agent: agentState(steps: steps, phase: .running)
            ),
            .working(
                VoiceSurfaceState.WorkingDetail(
                    kind: .agent,
                    currentStep: "正在调用 web_search…"
                )
            )
        )
    }

    func testAgentRunningWithNoStepsYetHasNoTicker() {
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .idle,
                ask: nil,
                agent: agentState(steps: [], phase: .running)
            ),
            .working(
                VoiceSurfaceState.WorkingDetail(kind: .agent, currentStep: nil)
            )
        )
    }

    func testAgentSucceededBecomesResultCardCarryingTaskResultAndSteps() {
        let steps = [
            AgentProgressStep(kind: .toolCall, detail: "Calling a()"),
            AgentProgressStep(kind: .toolResult, detail: "ok")
        ]

        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .idle,
                ask: nil,
                agent: agentState(
                    task: "帮我整理这份会议纪要",
                    steps: steps,
                    phase: .succeeded,
                    result: "## 纪要\n\n- 第一点"
                )
            ),
            .result(
                VoiceSurfaceState.ResultCard(
                    kind: .agent,
                    query: "帮我整理这份会议纪要",
                    body: "## 纪要\n\n- 第一点",
                    steps: steps
                )
            )
        )
    }

    func testAgentFailedBecomesFailedCardCarryingTheSameFields() {
        let steps = [AgentProgressStep(kind: .error, detail: "Error calling tool x: boom")]

        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .idle,
                ask: nil,
                agent: agentState(
                    task: "帮我下载这个文件",
                    steps: steps,
                    phase: .failed,
                    result: "Agent failed: boom"
                )
            ),
            .failed(
                VoiceSurfaceState.ResultCard(
                    kind: .agent,
                    query: "帮我下载这个文件",
                    body: "Agent failed: boom",
                    steps: steps
                )
            )
        )
    }

    func testAgentFinishedWithoutAResultStillShowsACardWithAnEmptyBody() {
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .idle,
                ask: nil,
                agent: agentState(task: "任务", steps: [], phase: .succeeded, result: nil)
            ),
            .result(
                VoiceSurfaceState.ResultCard(
                    kind: .agent,
                    query: "任务",
                    body: "",
                    steps: []
                )
            )
        )
    }

    func testAgentModeIgnoresAStaleAskPanelState() {
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .idle,
                ask: askState(answer: "old answer"),
                agent: nil
            ),
            .hidden
        )
    }

    // MARK: - B. Reducer: precedence

    func testLivePanelStateWinsOverALingeringTranscribingState() {
        // The run has outlived the recording's `ProcessingState`.
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .transcribing,
                ask: askState(query: "生命的意义是什么", answer: "42"),
                agent: nil
            ),
            .result(
                VoiceSurfaceState.ResultCard(
                    kind: .ask,
                    query: "生命的意义是什么",
                    body: "42",
                    steps: []
                )
            )
        )

        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .transcribing,
                ask: nil,
                agent: agentState(steps: [], phase: .running)
            ),
            .working(
                VoiceSurfaceState.WorkingDetail(kind: .agent, currentStep: nil)
            )
        )
    }

    func testLivePanelStateWinsOverTransformingAndDispatched() {
        // `.transforming` is set before the panel state exists and
        // `.dispatched`/`.idle` land while the run is still going: neither may
        // override the run's own surface.
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .transforming,
                ask: askState(answer: nil),
                agent: nil
            ),
            .working(
                VoiceSurfaceState.WorkingDetail(kind: .ask, currentStep: nil)
            )
        )

        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .dispatched("已下发给 Agent"),
                ask: nil,
                agent: agentState(
                    steps: [AgentProgressStep(kind: .thinking, detail: "Thinking…")],
                    phase: .running
                )
            ),
            .working(
                VoiceSurfaceState.WorkingDetail(kind: .agent, currentStep: "Thinking…")
            )
        )
    }

    // STAGE-2 addition. The two "ignores a stale X" tests above only ever
    // present ONE panel state, so a reducer that reads the ticker from
    // `agent` unconditionally (`currentStep: agent?.steps.last?.detail`) still
    // passes them — in ask mode `agent` is nil there, so the leak is
    // invisible. This is the realistic collision: a long agent run is still
    // ticking when the user asks a question, and vice versa. The active
    // mode must pick BOTH the branch and the ticker source.
    func testTheActiveModePicksTheTickerWhenBothPanelStatesAreLive() {
        let agentSteps = [AgentProgressStep(kind: .toolCall, detail: "正在调用 web_search…")]

        // Ask mode: agent's ticker must not leak into the ask indicator
        // (spec §4 — ask gets a generic indicator, no per-step display).
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .idle,
                ask: askState(query: "生命的意义是什么", answer: nil),
                agent: agentState(steps: agentSteps, phase: .running)
            ),
            .working(
                VoiceSurfaceState.WorkingDetail(kind: .ask, currentStep: nil)
            )
        )

        // Agent mode: the finished ask card must not win over the live run.
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .idle,
                ask: askState(query: "生命的意义是什么", answer: "42"),
                agent: agentState(steps: agentSteps, phase: .running)
            ),
            .working(
                VoiceSurfaceState.WorkingDetail(
                    kind: .agent,
                    currentStep: "正在调用 web_search…"
                )
            )
        )
    }

    func testANewRecordingResetsTheSurfaceToListeningEvenDuringALiveRun() {
        // Spec §1: "A new recording resets the surface to `listening`; an
        // in-flight agent run continues in the background." The agent state
        // stays non-nil (it drives progress polling) but the pill wins, so the
        // user sees their live caption while speaking.
        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .agent,
                processing: .listening,
                ask: nil,
                agent: agentState(
                    steps: [AgentProgressStep(kind: .toolCall, detail: "Calling a()")],
                    phase: .running
                )
            ),
            .listening
        )

        XCTAssertEqual(
            VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .listening,
                ask: askState(answer: "42"),
                agent: nil
            ),
            .listening
        )
    }

    // MARK: - C. Frame math: bottom-anchored growth

    func testPillAndCardShareTheSameBottomEdgeAndGrowUpward() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let pill = CGSize(width: 388, height: 96)
        let card = CGSize(width: 620, height: 480)

        let pillFrame = VoiceSurfacePanelLayout.frame(
            for: pill,
            visibleFrame: visibleFrame
        )
        let cardFrame = VoiceSurfacePanelLayout.frame(
            for: card,
            visibleFrame: visibleFrame
        )

        // Bottom edge fixed at `visibleFrame.minY + 54` for BOTH sizes.
        XCTAssertEqual(pillFrame.minY, 54)
        XCTAssertEqual(cardFrame.minY, 54)
        XCTAssertEqual(pillFrame.minY, cardFrame.minY)

        // …and the card is taller, i.e. it grew upward, not downward.
        XCTAssertEqual(pillFrame.maxY, 54 + 96)
        XCTAssertEqual(cardFrame.maxY, 54 + 480)
        XCTAssertGreaterThan(cardFrame.maxY, pillFrame.maxY)

        // Both horizontally centered on the same screen.
        XCTAssertEqual(pillFrame.midX, visibleFrame.midX)
        XCTAssertEqual(cardFrame.midX, visibleFrame.midX)
        XCTAssertEqual(pillFrame.minX, 756 - 194)
        XCTAssertEqual(cardFrame.minX, 756 - 310)

        // Size is passed through untouched.
        XCTAssertEqual(pillFrame.size, pill)
        XCTAssertEqual(cardFrame.size, card)
    }

    func testFrameHonorsANonZeroOriginVisibleFrame() {
        // A secondary display (or the dock/menubar inset) does not start at
        // (0, 0): a `width`/`height`-only implementation would place the panel
        // on the wrong screen and at the wrong height.
        let visibleFrame = CGRect(x: 1512, y: 100, width: 1000, height: 800)
        let pill = CGSize(width: 388, height: 96)

        let frame = VoiceSurfacePanelLayout.frame(
            for: pill,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.minY, 154) // 100 + 54
        XCTAssertEqual(frame.midX, 2012) // 1512 + 500
        XCTAssertEqual(frame.minX, 1818) // 2012 - 388/2
        XCTAssertEqual(frame.size, pill)
    }

    func testCardOnANonZeroOriginScreenKeepsTheSameBottomEdgeAsThePill() {
        let visibleFrame = CGRect(x: 1512, y: 100, width: 1000, height: 800)

        let pillFrame = VoiceSurfacePanelLayout.frame(
            for: CGSize(width: 388, height: 96),
            visibleFrame: visibleFrame
        )
        let cardFrame = VoiceSurfacePanelLayout.frame(
            for: CGSize(width: 620, height: 480),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(pillFrame.minY, cardFrame.minY)
        XCTAssertNotEqual(pillFrame.maxY, cardFrame.maxY)
        XCTAssertEqual(cardFrame.midX, visibleFrame.midX)
    }

    // MARK: - C. Per-state size mapping

    func testListeningAndProcessingUseTheExistingPillSize() {
        let pill = CGSize(width: 388, height: 96)

        XCTAssertEqual(VoiceSurfacePanelLayout.size(for: .listening), pill)
        XCTAssertEqual(VoiceSurfacePanelLayout.size(for: .processing), pill)
    }

    func testWorkingIsSlightlyTallerForTheStepTicker() {
        let working = CGSize(width: 388, height: 120)

        XCTAssertEqual(
            VoiceSurfacePanelLayout.size(
                for: .working(
                    VoiceSurfaceState.WorkingDetail(kind: .ask, currentStep: nil)
                )
            ),
            working
        )
        XCTAssertEqual(
            VoiceSurfacePanelLayout.size(
                for: .working(
                    VoiceSurfaceState.WorkingDetail(
                        kind: .agent,
                        currentStep: "正在调用 web_search…"
                    )
                )
            ),
            working
        )
    }

    func testResultAndFailedUseTheCardSize() {
        let card = VoiceSurfaceState.ResultCard(
            kind: .agent,
            query: "任务",
            body: "结果",
            steps: []
        )
        let cardSize = CGSize(width: 620, height: 480)

        XCTAssertEqual(VoiceSurfacePanelLayout.size(for: .result(card)), cardSize)
        XCTAssertEqual(VoiceSurfacePanelLayout.size(for: .failed(card)), cardSize)
    }

    func testHiddenHasZeroSize() {
        XCTAssertEqual(VoiceSurfacePanelLayout.size(for: .hidden), .zero)
    }

    // MARK: - D. Dismissal policy: click-outside

    func testOnlyResultAndFailedAllowClickOutsideDismiss() {
        let card = VoiceSurfaceState.ResultCard(
            kind: .agent,
            query: "任务",
            body: "结果",
            steps: []
        )

        XCTAssertTrue(VoiceSurfaceState.result(card).allowsClickOutsideDismiss)
        XCTAssertTrue(VoiceSurfaceState.failed(card).allowsClickOutsideDismiss)
    }

    func testInFlightStatesDoNotAllowClickOutsideDismiss() {
        // Spec §1: the user must be able to click away and keep working during
        // a long agent run without killing the surface.
        let states: [VoiceSurfaceState] = [
            .hidden,
            .listening,
            .processing,
            .working(VoiceSurfaceState.WorkingDetail(kind: .ask, currentStep: nil)),
            .working(
                VoiceSurfaceState.WorkingDetail(kind: .agent, currentStep: "Calling a()")
            )
        ]

        for state in states {
            XCTAssertFalse(
                state.allowsClickOutsideDismiss,
                "\(state) must survive a click outside"
            )
        }
    }

    // MARK: - D. Dismissal policy: side effect

    func testDismissingAWorkingAskCancelsIt() {
        // Today's `dismissAskPanel` ghost-answer semantics move here.
        XCTAssertEqual(
            VoiceSurfaceState.working(
                VoiceSurfaceState.WorkingDetail(kind: .ask, currentStep: nil)
            ).dismissalEffect,
            VoiceSurfaceDismissalEffect.cancelAsk
        )
    }

    func testDismissingAWorkingAgentNeverCancelsTheRun() {
        XCTAssertEqual(
            VoiceSurfaceState.working(
                VoiceSurfaceState.WorkingDetail(
                    kind: .agent,
                    currentStep: "正在调用 web_search…"
                )
            ).dismissalEffect,
            VoiceSurfaceDismissalEffect.none
        )
    }

    func testEveryOtherStateDismissesWithoutSideEffects() {
        let card = VoiceSurfaceState.ResultCard(
            kind: .ask,
            query: "q",
            body: "a",
            steps: []
        )
        let states: [VoiceSurfaceState] = [
            .hidden,
            .listening,
            .processing,
            .result(card),
            .failed(card)
        ]

        for state in states {
            XCTAssertEqual(
                state.dismissalEffect,
                VoiceSurfaceDismissalEffect.none,
                "\(state) must not cancel anything on dismiss"
            )
        }
    }

    func testDismissalEffectCasesAreDistinct() {
        XCTAssertNotEqual(
            VoiceSurfaceDismissalEffect.cancelAsk,
            VoiceSurfaceDismissalEffect.none
        )
    }

    // MARK: - E. Markdown seam (type existence only)

    func testAssistantMarkdownWrapperExists() {
        // Deliberately construction-only: this test's whole job is to force
        // the MarkdownUI dependency and the shared `AssistantMarkdownView`
        // wrapper (spec §3) into existence. No rendering, no snapshot, no
        // assertion on output — those would be testing MarkdownUI, not us.
        _ = AssistantMarkdownView(markdown: "**bold**")
    }
}
