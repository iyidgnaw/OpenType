import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for 「交给助理去做」 —— the exit for "I picked the
/// wrong mode" (`docs/superpowers/specs/2026-08-15-product-batch-plan.md` §H,
/// motivated by `docs/reviews/2026-08-15-product-review.md` §6).
///
/// Ask and Agent differ by exactly one thing: the toolset. `/oneshot/ask` runs
/// the same `runAgentLoop` narrowed to `opentype__web_search` +
/// `opentype__web_fetch` (`filterToolSet`, 6 iterations); `/agent/run` gets
/// everything. That line is invisible from outside — 「帮我查一下今天的汇率」 is
/// either one, and "does this need tools?" is an implementation detail the user
/// has no obligation to know before they open their mouth.
///
/// So one button: re-run **this turn** with the full toolset. Not the P1-5
/// merge, which the product owner rejected and which
/// `2026-08-14-product-batch-plan.md` keeps struck through rather than deleted
/// so the decision stays legible.
///
/// Expected shape (Stage 3 creates it; nothing here builds it) —
/// `Sources/OpenType/AssistantEscalation.swift`:
///
///     struct AssistantEscalation: Equatable {
///         /// The user's own words, re-dispatched verbatim.
///         let task: String
///         /// The thread this run continues, and the kind that thread keeps.
///         /// `nil` starts a fresh one.
///         let conversation: FocusedConversation?
///
///         /// Where *this turn* goes. Constant: the toolset is the point.
///         static let dispatchMode: InputMode = .agent
///
///         /// The escalation this surface offers, or `nil` when the button
///         /// must not be drawn at all.
///         static func offered(
///             for surface: VoiceSurfaceState,
///             conversationId: Int?
///         ) -> AssistantEscalation?
///
///         /// The session detail page's copy of the same decision, for one
///         /// assistant turn in an open thread.
///         static func offered(
///             forAssistantMessage message: ConversationMessageSummary,
///             in detail: ConversationDetail
///         ) -> AssistantEscalation?
///     }
///
/// ## Pinned decision 1 — escalation is turn-scoped; the thread's kind is not touched
///
/// This is the load-bearing decision of the whole item, and it is the one that
/// keeps §H from becoming the rejected merge by the back door. The escalated
/// turn is dispatched to `/agent/run`; the conversation stays `kind == "ask"`,
/// so the **next** spoken turn in it still routes to `/oneshot/ask`.
///
/// The sidecar already behaves this way and needs no change:
/// `resolveConversation` (`sidecar/src/oneshot/routes.ts`) only supplies a
/// `kind` when it *creates* a conversation, so `/agent/run` handed an existing
/// ask thread continues it and leaves the `kind` column alone. The hazard is
/// therefore entirely Swift-side, and it is not hypothetical: after the
/// escalated run is dispatched the surface is driven by `agentPanelState`, and
/// the obvious way to answer "which conversation is on screen" — read whichever
/// panel state is live — reports `FocusedConversation(id: 5, kind: .agent)` for
/// what is still an ask thread. `VoiceFollowUp.continuation` then sends the next
/// utterance to `/agent/run`, and one tool-shaped question has silently
/// converted the whole thread. That is why the escalation carries the whole
/// `FocusedConversation`, kind included, instead of just an id.
///
/// One thing these assertions do NOT prove, stated here so Stage 4 does not
/// read more into them than they say: `VoiceFollowUp.continuation` is a pure
/// seam with no production caller yet. `AppModel` still dispatches through the
/// older mode-partitioned `VoiceFollowUp.conversationId(surface:focusedTab:)`
/// — `case .ask` reads `askPanelState?.conversationId`/
/// `focusedAskConversationId`, `case .agent` reads the agent pair — so today
/// the *ambient mode* picks the endpoint and the thread's kind is not consulted
/// at dispatch. (Pre-existing: `focusedConversation` is written by the two list
/// views but not yet read by the dispatcher. Not this item's to fix.) What
/// these tests pin is therefore the escalation's payload — the value a router
/// reads — not the router. The corresponding obligation on Stage 3 is the
/// mirror image and cannot be expressed at this seam: escalating must leave the
/// ask thread reachable *as an ask thread* by the next turn, i.e. it must not
/// clear the thread out of the ask-side state or repoint `focusedConversation`
/// at an agent-kind copy of it.
///
/// ## Pinned decision 2 — the question is re-run, never the answer
///
/// `ResultCard` holds both `query` (what was heard) and `body` (what came
/// back), one field apart. Getting them backwards sends the model its own
/// output as a task, which does not fail loudly — it produces a plausible run
/// against the wrong input. Pinned by equality against `query` *and* by
/// negation against `body`, because a test that only checked "non-empty" would
/// pass either way.
///
/// ## Pinned decision 3 — one-directional
///
/// There is no agent → ask escalation: an agent run that turns out to be a
/// plain question already answered it, at no cost. So an agent card offers
/// nothing — including, specifically, the card the escalated run itself
/// produces. That is also what makes "re-run once" true without any
/// already-escalated bookkeeping: the result of escalating is an agent card,
/// and agent cards have no button.
///
/// ## Pinned decision 4 — offered only for a *finished* ask
///
/// The states are taken from `VoiceSurfaceState.reduce` rather than
/// hand-constructed wherever possible, so every case under test is one the app
/// can actually be in. A run in flight (`.working`, `.asking`, `.processing`)
/// has no result to escalate and no `conversationId` yet; offering a button
/// there would mean dispatching a second run against a thread whose first one
/// has not landed.
final class AssistantEscalationOfferTests: XCTestCase {

    // MARK: - Offered

    func testACompletedAskResultOffersTheEscalation() {
        let surface = askResult(query: "今天的美元汇率是多少", answer: "1 USD ≈ 7.21 CNY")

        XCTAssertNotNil(AssistantEscalation.offered(for: surface, conversationId: 5))
    }

    func testAnEmptyAnswerIsStillAFinishedAskAndStillOffers() {
        // `reduce` splits on `answer == nil`, never on `answer?.isEmpty` — an
        // empty string is an answer that arrived. The button must follow the
        // same split, or it would disappear exactly when a re-run with real
        // tools is most obviously what the user wants.
        let surface = askResult(query: "查一下今天的汇率", answer: "")

        XCTAssertNotNil(AssistantEscalation.offered(for: surface, conversationId: 5))
    }

    func testAnAskThatFailedStillOffersTheEscalation() {
        // An ask failure is delivered *as answer text* (`AskPanelState`'s doc
        // comment), so the surface cannot tell it from a real answer without
        // sniffing strings. Retrying a failed question with the full toolset is
        // the recovery this button exists for, so it stays.
        let surface = askResult(
            query: "查一下今天的汇率",
            answer: "请求失败：无法连接到模型服务"
        )

        XCTAssertNotNil(AssistantEscalation.offered(for: surface, conversationId: 5))
    }

    // MARK: - Not offered: the other mode's results

    func testAnAgentResultOffersNothing() {
        // One-directional. Nothing to escalate to.
        XCTAssertNil(
            AssistantEscalation.offered(
                for: agentResult(task: "整理一下桌面上的截图", result: "已移动 12 个文件", phase: .succeeded),
                conversationId: 9
            )
        )
    }

    func testAFailedAgentRunOffersNothing() {
        XCTAssertNil(
            AssistantEscalation.offered(
                for: agentResult(task: "整理一下桌面上的截图", result: "权限不足", phase: .failed),
                conversationId: 9
            )
        )
    }

    func testAStoppedAgentRunOffersNothing() {
        // `.cancelled` reduces to the same `.failed` card shape; it must not
        // pick up a button that shape does not have.
        XCTAssertNil(
            AssistantEscalation.offered(
                for: agentResult(task: "整理一下桌面上的截图", result: "已停止", phase: .cancelled),
                conversationId: 9
            )
        )
    }

    func testTheEscalatedRunsOwnCardOffersNoFurtherEscalation() {
        // The card the escalation itself produces: an agent run, on the ask
        // thread it was escalated from. This is what makes "re-run once" hold
        // without any already-escalated flag — escalating lands you on a card
        // that has no button.
        let escalatedCard = agentResult(
            task: "今天的美元汇率是多少",
            result: "1 USD ≈ 7.21 CNY（来源：ECB）",
            phase: .succeeded,
            conversationId: 5
        )

        XCTAssertNil(AssistantEscalation.offered(for: escalatedCard, conversationId: 5))
    }

    // MARK: - Not offered: nothing has finished yet

    func testAnAskStillThinkingOffersNothing() {
        let surface = VoiceSurfaceState.reduce(
            mode: .ask,
            processing: .idle,
            ask: AskPanelState(kind: .ask, query: "查一下今天的汇率", answer: nil, conversationId: nil),
            agent: nil
        )
        XCTAssertEqual(surface, .working(.init(kind: .ask, currentStep: nil)))

        XCTAssertNil(AssistantEscalation.offered(for: surface, conversationId: nil))
    }

    func testAnAgentStillRunningOffersNothing() {
        let surface = VoiceSurfaceState.reduce(
            mode: .agent,
            processing: .idle,
            ask: nil,
            agent: agentPanel(task: "整理一下桌面", result: nil, phase: .running, conversationId: 9)
        )

        XCTAssertNil(AssistantEscalation.offered(for: surface, conversationId: 9))
    }

    func testAnAgentWaitingOnAQuestionOffersNothing() {
        var panel = agentPanel(task: "整理一下桌面", result: nil, phase: .running, conversationId: 9)
        panel.question = AgentQuestion(
            id: "q1",
            question: "要包含子目录吗？",
            detail: nil,
            options: nil,
            multiSelect: nil
        )
        let surface = VoiceSurfaceState.reduce(
            mode: .agent, processing: .idle, ask: nil, agent: panel
        )
        XCTAssertEqual(surface.stoppableAgentRun, true, "fixture must be the blocked-run state")

        XCTAssertNil(AssistantEscalation.offered(for: surface, conversationId: 9))
    }

    func testAsrStillInFlightOffersNothing() {
        let surface = VoiceSurfaceState.reduce(
            mode: .ask, processing: .transcribing, ask: nil, agent: nil
        )
        XCTAssertEqual(surface, .processing)

        XCTAssertNil(AssistantEscalation.offered(for: surface, conversationId: nil))
    }

    func testListeningOffersNothing() {
        // A new recording resets the surface to the pill even while an older
        // card's state is still around (`reduce` rule 2). The button goes with
        // the card, not with the state behind it.
        let surface = VoiceSurfaceState.reduce(
            mode: .ask,
            processing: .listening,
            ask: AskPanelState(kind: .ask, query: "旧问题", answer: "旧答案", conversationId: 5),
            agent: nil
        )
        XCTAssertEqual(surface, .listening)

        XCTAssertNil(AssistantEscalation.offered(for: surface, conversationId: 5))
    }

    func testAHiddenSurfaceOffersNothing() {
        XCTAssertNil(AssistantEscalation.offered(for: .hidden, conversationId: 5))
    }

    // MARK: - Not offered: dictation

    func testATranscribeDeliveryOffersNothing() {
        // 听写 never reaches this surface at all (`reduce` rule 1 maps every
        // transcribe state to `.hidden`), and it has no conversation to
        // continue — escalating it would mean handing whatever was pasted into
        // a text field to a tool-using agent.
        for processing in [ProcessingState.idle, .transcribing, .inserting, .copied, .success] {
            let surface = VoiceSurfaceState.reduce(
                mode: .transcribe, processing: processing, ask: nil, agent: nil
            )
            XCTAssertEqual(surface, .hidden)
            XCTAssertNil(AssistantEscalation.offered(for: surface, conversationId: nil))
        }
    }

    func testATranscribeDeliveryOffersNothingEvenWithAStaleAskCardBehindIt() {
        // The stale-state version of the same rule: transcribe wins over a
        // panel state that has not been cleared yet.
        let surface = VoiceSurfaceState.reduce(
            mode: .transcribe,
            processing: .copied,
            ask: AskPanelState(kind: .ask, query: "旧问题", answer: "旧答案", conversationId: 5),
            agent: nil
        )

        XCTAssertNil(AssistantEscalation.offered(for: surface, conversationId: 5))
    }

    // MARK: - Fixtures

    /// Built through `reduce` rather than by hand so every state under test is
    /// one `AppModel` can actually put the surface into.
    private func askResult(query: String, answer: String) -> VoiceSurfaceState {
        VoiceSurfaceState.reduce(
            mode: .ask,
            processing: .idle,
            ask: AskPanelState(kind: .ask, query: query, answer: answer, conversationId: 5),
            agent: nil
        )
    }

    private func agentResult(
        task: String,
        result: String?,
        phase: AgentProgressPanelState.Phase,
        conversationId: Int = 9
    ) -> VoiceSurfaceState {
        VoiceSurfaceState.reduce(
            mode: .agent,
            processing: .idle,
            ask: nil,
            agent: agentPanel(
                task: task, result: result, phase: phase, conversationId: conversationId
            )
        )
    }

    private func agentPanel(
        task: String,
        result: String?,
        phase: AgentProgressPanelState.Phase,
        conversationId: Int
    ) -> AgentProgressPanelState {
        AgentProgressPanelState(
            runId: "run-1",
            task: task,
            steps: [],
            phase: phase,
            result: result,
            conversationId: conversationId,
            question: nil
        )
    }
}

/// The thread: reused, and **not converted**.
///
/// Every assertion in this class exists because the cheap implementation gets
/// it wrong in a way no screenshot shows. Escalating turns the surface into an
/// agent card on an ask thread; anything that infers "which conversation am I
/// in" from what is on screen will start calling that thread an agent thread,
/// and the user's next question — asked in the same breath, at the same card —
/// goes to `/agent/run` with the full toolset. That is the rejected merge,
/// arrived at one thread at a time.
final class AssistantEscalationThreadTests: XCTestCase {

    private let askThread = 5

    func testTheConversationIdIsReusedNotRegenerated() {
        let escalation = escalate(conversationId: askThread)

        XCTAssertEqual(escalation?.conversation?.id, askThread)
    }

    func testTheConversationKeepsItsAskKind() {
        // The single load-bearing assertion of §H. `/agent/run` continuing an
        // existing conversation never rewrites its `kind` column
        // (`resolveConversation` only assigns one on create), so the Swift side
        // must not re-label it locally either.
        let escalation = escalate(conversationId: askThread)

        XCTAssertEqual(escalation?.conversation?.kind, .ask)
        XCTAssertEqual(
            escalation?.conversation,
            FocusedConversation(id: askThread, kind: .ask)
        )
    }

    func testThisTurnGoesToAgentWhileTheNextOneStillGoesToAsk() {
        // The two answers side by side, which is the whole shape of the
        // feature: one turn escalates, the thread does not.
        let escalation = escalate(conversationId: askThread)

        XCTAssertEqual(AssistantEscalation.dispatchMode, .agent)
        XCTAssertEqual(
            VoiceFollowUp.continuation(
                surface: escalation?.conversation,
                focused: nil,
                spoken: .ask
            ),
            SessionContinuation(conversationId: askThread, mode: .ask)
        )
    }

    func testTheNextTurnGoesToAskEvenWhenTheUserIsSittingInAgentMode() {
        // `continuation` lets the thread outrank the ambient mode switch. If
        // the escalation had converted the thread, this is where it would show:
        // the same call would answer `.agent` and never come back.
        XCTAssertEqual(
            VoiceFollowUp.continuation(
                surface: escalate(conversationId: askThread)?.conversation,
                focused: nil,
                spoken: .agent
            ),
            SessionContinuation(conversationId: askThread, mode: .ask)
        )
    }

    func testTheThreadOpenInTheMainWindowIsAlsoStillAnAskThread() {
        // The same conversation reached from the other of the two seams
        // `continuation` arbitrates between. Escalation must not change the
        // answer from either side.
        XCTAssertEqual(
            VoiceFollowUp.continuation(
                surface: nil,
                focused: escalate(conversationId: askThread)?.conversation,
                spoken: .agent
            ),
            SessionContinuation(conversationId: askThread, mode: .ask)
        )
    }

    func testAnAskWithNoThreadYetEscalatesIntoAFreshConversation() {
        // Not a race: `runAskDispatch` sets `answer` and `conversationId`
        // together on success, so a *successful* first-turn card always has an
        // id. The state that reaches here is the failure path, which sets only
        // the answer text (`AppModel.runAskDispatch`'s `catch`) — so this is
        // `testAnAskThatFailedStillOffersTheEscalation`'s first turn, and it is
        // the one case where escalating does produce an agent-kind thread:
        // `/agent/run` with no id calls `resolveConversation(…, "agent", …)`,
        // which creates one. That is the honest outcome rather than the
        // conversion this class guards against — Swift never learned of an ask
        // thread to preserve, because the call that would have created one is
        // the call that failed. Suppressing the button here would remove the
        // retry exactly where it is most wanted.
        let escalation = escalate(conversationId: nil)

        XCTAssertNotNil(escalation)
        XCTAssertNil(escalation?.conversation)
        XCTAssertEqual(
            VoiceFollowUp.continuation(
                surface: escalation?.conversation,
                focused: nil,
                spoken: .ask
            ),
            SessionContinuation(conversationId: nil, mode: .ask)
        )
    }

    private func escalate(conversationId: Int?) -> AssistantEscalation? {
        AssistantEscalation.offered(
            for: VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .idle,
                ask: AskPanelState(
                    kind: .ask,
                    query: "今天的美元汇率是多少",
                    answer: "1 USD ≈ 7.21 CNY",
                    conversationId: conversationId
                ),
                agent: nil
            ),
            conversationId: conversationId
        )
    }
}

/// What gets re-run. `query` and `body` sit one field apart on the same
/// `ResultCard`, and sending the model its own output as a task fails silently:
/// the run succeeds, against the wrong input.
final class AssistantEscalationSourceTests: XCTestCase {

    private let question = "今天的美元兑人民币汇率是多少"
    private let answer = "1 USD ≈ 7.21 CNY，数据截至今天上午。"

    func testTheQuestionIsWhatGetsReRun() {
        XCTAssertEqual(escalation()?.task, question)
    }

    func testTheAnswerIsNotWhatGetsReRun() {
        // Stated as its own negation rather than folded into the equality
        // above: an implementation that concatenated or summarised would still
        // produce a non-empty task, and only this catches it.
        let task = escalation()?.task
        XCTAssertNotEqual(task, answer)
        XCTAssertFalse(task?.contains("7.21") ?? true)
    }

    func testTheQuestionIsCarriedVerbatim() {
        // Not trimmed, not normalised, not re-titled. Whatever ASR produced is
        // exactly what `/oneshot/ask` was given, so it is exactly what
        // `/agent/run` must be given for the two runs to be comparable.
        let spoken = "  帮我查一下 PayPal 的汇率\n再算成人民币  "
        let escalated = AssistantEscalation.offered(
            for: VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .idle,
                ask: AskPanelState(kind: .ask, query: spoken, answer: "…", conversationId: 5),
                agent: nil
            ),
            conversationId: 5
        )

        XCTAssertEqual(escalated?.task, spoken)
    }

    private func escalation() -> AssistantEscalation? {
        AssistantEscalation.offered(
            for: VoiceSurfaceState.reduce(
                mode: .ask,
                processing: .idle,
                ask: AskPanelState(
                    kind: .ask, query: question, answer: answer, conversationId: 5
                ),
                agent: nil
            ),
            conversationId: 5
        )
    }
}

/// §H puts the same button on the session detail page, where the card's two
/// fields become a list of turns. The decision has to be the *same* decision —
/// a second rule grown beside the first is how the two surfaces end up
/// disagreeing about whether a thread is escalatable — so both entry points
/// return the same `AssistantEscalation`, and the detail page's extra work is
/// only finding which question produced the answer being escalated.
final class AssistantEscalationSessionDetailTests: XCTestCase {

    func testAnAssistantTurnInAnAskThreadOffersTheEscalation() {
        let thread = detail(kind: "ask", turns: [("user", "今天的汇率"), ("assistant", "7.21")])

        let escalation = AssistantEscalation.offered(
            forAssistantMessage: thread.messages[1], in: thread
        )

        XCTAssertEqual(escalation?.task, "今天的汇率")
        XCTAssertEqual(escalation?.conversation, FocusedConversation(id: 5, kind: .ask))
    }

    func testItReRunsTheQuestionThatProducedThatAnswerNotTheLatestOne() {
        // Escalating the *first* answer in a three-turn thread. "The last user
        // message" is the plausible wrong implementation and it passes the
        // two-turn case above by luck.
        let thread = detail(kind: "ask", turns: [
            ("user", "今天的汇率"),
            ("assistant", "7.21"),
            ("user", "那欧元呢"),
            ("assistant", "7.85"),
        ])

        XCTAssertEqual(
            AssistantEscalation.offered(forAssistantMessage: thread.messages[1], in: thread)?.task,
            "今天的汇率"
        )
        XCTAssertEqual(
            AssistantEscalation.offered(forAssistantMessage: thread.messages[3], in: thread)?.task,
            "那欧元呢"
        )
    }

    func testAUserTurnOffersNothing() {
        // There is nothing to re-run from a question that has not been answered
        // through this surface yet; the affordance belongs to the answer.
        let thread = detail(kind: "ask", turns: [("user", "今天的汇率"), ("assistant", "7.21")])

        XCTAssertNil(
            AssistantEscalation.offered(forAssistantMessage: thread.messages[0], in: thread)
        )
    }

    func testAnAssistantTurnInAnAgentThreadOffersNothing() {
        let thread = detail(kind: "agent", turns: [("user", "整理桌面"), ("assistant", "已完成")])

        XCTAssertNil(
            AssistantEscalation.offered(forAssistantMessage: thread.messages[1], in: thread)
        )
    }

    func testAnAssistantTurnInAThreadOfAnUnknownKindOffersNothing() {
        // Same rule `SessionFilter` already applies to an unrecognised `kind`:
        // it is a real conversation and stays visible, but no feature that
        // depends on knowing what it is may claim it.
        let thread = detail(kind: "assistant", turns: [("user", "问题"), ("assistant", "答案")])

        XCTAssertNil(
            AssistantEscalation.offered(forAssistantMessage: thread.messages[1], in: thread)
        )
    }

    func testAnAnswerWithNoQuestionBeforeItOffersNothing() {
        // Defensive: an assistant-first thread has no transcript to re-run, and
        // the alternative — falling back to the answer — is exactly the
        // send-the-model-its-own-output bug.
        let thread = detail(kind: "ask", turns: [("assistant", "7.21")])

        XCTAssertNil(
            AssistantEscalation.offered(forAssistantMessage: thread.messages[0], in: thread)
        )
    }

    func testAMessageFromAnotherThreadOffersNothing() {
        // The detail page keeps the previously loaded thread on screen while
        // the next one is fetched, so a click can arrive carrying a message
        // that does not belong to the thread now open. Escalating it would post
        // one conversation's question into another conversation.
        let thread = detail(kind: "ask", turns: [("user", "今天的汇率"), ("assistant", "7.21")])
        let stray = ConversationMessageSummary(
            id: 99, conversationId: 77, role: "assistant", content: "别的答案", createdAt: 1
        )

        XCTAssertNil(AssistantEscalation.offered(forAssistantMessage: stray, in: thread))
    }

    func testTheDetailPageAndTheCardAgreeOnTheThreadTheyContinue() {
        // One decision, two entry points: whichever the user presses, the next
        // turn in that thread must still be an ask turn.
        let thread = detail(kind: "ask", turns: [("user", "今天的汇率"), ("assistant", "7.21")])
        let escalation = AssistantEscalation.offered(
            forAssistantMessage: thread.messages[1], in: thread
        )

        XCTAssertEqual(
            VoiceFollowUp.continuation(
                surface: escalation?.conversation, focused: nil, spoken: .agent
            ),
            SessionContinuation(conversationId: 5, mode: .ask)
        )
    }

    // MARK: - Fixtures

    private func detail(
        kind: String,
        turns: [(String, String)],
        id: Int = 5
    ) -> ConversationDetail {
        ConversationDetail(
            id: id,
            kind: kind,
            title: "对话",
            createdAt: 1_760_000_000_000,
            updatedAt: 1_760_000_000_000,
            messages: turns.enumerated().map { index, turn in
                ConversationMessageSummary(
                    id: index + 1,
                    conversationId: id,
                    role: turn.0,
                    content: turn.1,
                    createdAt: 1_760_000_000_000 + index
                )
            }
        )
    }
}
