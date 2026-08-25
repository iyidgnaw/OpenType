import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for `VoiceSurfaceFollowUp`, the decision behind
/// the follow-up bug: `OverlayController`'s `onFollowUp`/`onFollowUpByVoice`
/// closures (wired to the composer's submit, the mic button, and the
/// 「展开说说」/「换个说法」 chips — `OverlayController.swift:2780`, `:2782`,
/// `:2799`, `:2850`) are declared but **never assigned** by `AppModel`, so
/// none of the three follow-up entry points on a result card do anything.
///
/// `AppModel.init` has side effects and is not instantiable in tests
/// (`DispatchConfirmationTests` documents the constraint;
/// `AssistantEscalationWiringTests` documents the same fix for §H's
/// escalation button), so the decision `AppModel` needs before it can wire
/// those closures — "what conversation, of what kind, does a follow-up typed
/// or spoken right now continue?" — is factored into `VoiceSurfaceFollowUp.
/// target(for:askConversationId:agentConversationId:)`, a pure function of
/// exactly the state `AppModel` has in scope (the current `VoiceSurfaceState`
/// plus both live panel ids), tested here rather than left inline where
/// nothing can reach it.
///
/// `VoiceSurfaceState.ResultCard` carries no `conversationId` of its own (see
/// `AssistantEscalation`'s doc comment on the same point) — only a `kind`.
/// So the two ids the caller already tracks (`AskPanelState.conversationId`,
/// `AgentProgressPanelState.conversationId`) have to be threaded in
/// separately and picked by the card's own kind, never by "whichever one
/// happens to be live". That is the exact hazard
/// `AssistantEscalationWiringTests.
/// testEscalatingAnAskCardIgnoresAnUnrelatedLiveAgentConversationId` pins for
/// the escalation button, and it recurs here unchanged: an ask card and a
/// completely unrelated live agent run (or vice versa) is an ordinary moment,
/// not an edge case, and picking the wrong id would silently continue a
/// conversation the user never asked to continue.
final class VoiceSurfaceFollowUpTests: XCTestCase {

    // MARK: - Helpers

    private func askCard(
        answer: String,
        conversationId: Int?
    ) -> VoiceSurfaceState {
        VoiceSurfaceState.reduce(
            mode: .ask,
            processing: .idle,
            ask: AskPanelState(
                kind: .ask,
                query: "今天的美元汇率是多少",
                answer: answer,
                conversationId: conversationId
            ),
            agent: nil
        )
    }

    private func agentCard(
        phase: AgentProgressPanelState.Phase,
        result: String?,
        conversationId: Int?
    ) -> VoiceSurfaceState {
        VoiceSurfaceState.reduce(
            mode: .agent,
            processing: .idle,
            ask: nil,
            agent: AgentProgressPanelState(
                runId: "run-1",
                task: "整理一下桌面上的截图",
                steps: [],
                phase: phase,
                result: result,
                conversationId: conversationId,
                question: nil
            )
        )
    }

    // MARK: - Rule 1: a card is required

    /// Every non-card state must refuse to offer a follow-up target. The
    /// composer, mic button, and action chips only exist ON a result card
    /// (`OverlayController.swift`'s `ResultCardView`) — dispatching a
    /// follow-up while the surface is still the listening pill, the
    /// processing dots, a working indicator, or a pending agent question
    /// would have nothing to attach the request to, so this must be provably
    /// `nil` for all five, not just absent from the UI by construction.
    func testOnlyAResultOrFailedCardOffersAFollowUpTarget() {
        let nonCardStates: [(name: String, surface: VoiceSurfaceState)] = [
            (
                "hidden (transcribe mode never uses this surface)",
                VoiceSurfaceState.reduce(mode: .transcribe, processing: .idle, ask: nil, agent: nil)
            ),
            (
                "listening (a new recording wins even over a live ask card)",
                VoiceSurfaceState.reduce(
                    mode: .ask,
                    processing: .listening,
                    ask: AskPanelState(kind: .ask, query: "q", answer: "a", conversationId: 5),
                    agent: nil
                )
            ),
            (
                "processing (ASR in flight, no panel state yet)",
                VoiceSurfaceState.reduce(mode: .ask, processing: .transcribing, ask: nil, agent: nil)
            ),
            (
                "working (ask still thinking, no answer yet)",
                VoiceSurfaceState.reduce(
                    mode: .ask,
                    processing: .idle,
                    ask: AskPanelState(kind: .ask, query: "q", answer: nil, conversationId: nil),
                    agent: nil
                )
            ),
            (
                "asking (agent blocked on a pending question)",
                VoiceSurfaceState.reduce(
                    mode: .agent,
                    processing: .idle,
                    ask: nil,
                    agent: AgentProgressPanelState(
                        runId: "run-1",
                        task: "整理一下桌面上的截图",
                        steps: [],
                        phase: .running,
                        result: nil,
                        conversationId: nil,
                        question: AgentQuestion(
                            id: "q1", question: "哪个文件夹？", detail: nil, options: nil, multiSelect: nil
                        )
                    )
                )
            ),
        ]

        for (name, surface) in nonCardStates {
            let target = VoiceSurfaceFollowUp.target(
                for: surface, askConversationId: 5, agentConversationId: 9
            )
            XCTAssertNil(target, "expected nil follow-up target for \(name)")
        }
    }

    // MARK: - Rule 2: kind and id both come from the matching panel

    func testAnAskResultCardTargetsTheAskConversation() {
        let surface = askCard(answer: "1 USD ≈ 7.21 CNY", conversationId: 5)

        let target = VoiceSurfaceFollowUp.target(
            for: surface, askConversationId: 5, agentConversationId: nil
        )

        XCTAssertEqual(target, VoiceSurfaceFollowUpTarget(kind: .ask, conversationId: 5))
    }

    func testASucceededAgentResultCardTargetsTheAgentConversation() {
        let surface = agentCard(phase: .succeeded, result: "已移动 12 个文件", conversationId: 9)

        let target = VoiceSurfaceFollowUp.target(
            for: surface, askConversationId: nil, agentConversationId: 9
        )

        XCTAssertEqual(target, VoiceSurfaceFollowUpTarget(kind: .agent, conversationId: 9))
    }

    /// A `.failed` card (agent run failed or was cancelled — both render
    /// through `.failed`, see `VoiceSurfaceState.reduce`'s case 3 comment)
    /// must offer a follow-up exactly like a `.result` card does. A run that
    /// failed is exactly when a user is likely to want to say more ("no, I
    /// meant the other file") — refusing the follow-up here would be
    /// refusing it where it matters most.
    func testAFailedAgentCardOffersAFollowUpTargetJustLikeAResultCard() {
        let surface = agentCard(phase: .failed, result: "找不到该文件", conversationId: 9)

        let target = VoiceSurfaceFollowUp.target(
            for: surface, askConversationId: nil, agentConversationId: 9
        )

        XCTAssertEqual(target, VoiceSurfaceFollowUpTarget(kind: .agent, conversationId: 9))
    }

    // MARK: - Cross-contamination: the wrong kind's id must never leak in

    /// Mirrors `AssistantEscalationWiringTests.
    /// testEscalatingAnAskCardIgnoresAnUnrelatedLiveAgentConversationId`. An
    /// unrelated agent run can easily be live at the same moment a finished
    /// ask card is on screen (the user asked a question, then separately
    /// dispatched a task earlier). A follow-up typed or spoken now must
    /// continue the ask thread, never silently attach itself to that
    /// unrelated agent run.
    func testFollowingUpOnAnAskCardIgnoresAnUnrelatedLiveAgentConversationId() {
        let surface = askCard(answer: "1 USD ≈ 7.21 CNY", conversationId: 5)

        let target = VoiceSurfaceFollowUp.target(
            for: surface, askConversationId: 5, agentConversationId: 9
        )

        XCTAssertEqual(target, VoiceSurfaceFollowUpTarget(kind: .ask, conversationId: 5))
    }

    /// The reverse direction of the same hazard: a finished agent card on
    /// screen while an unrelated ask thread is still live must continue the
    /// agent run, never the ask thread.
    func testFollowingUpOnAnAgentCardIgnoresAnUnrelatedLiveAskConversationId() {
        let surface = agentCard(phase: .succeeded, result: "已移动 12 个文件", conversationId: 9)

        let target = VoiceSurfaceFollowUp.target(
            for: surface, askConversationId: 5, agentConversationId: 9
        )

        XCTAssertEqual(target, VoiceSurfaceFollowUpTarget(kind: .agent, conversationId: 9))
    }

    // MARK: - Rule 3: no matching id yet means a fresh thread, not a borrowed one

    /// The failure-path first turn: an ask card can render (with an error
    /// message as its answer text, per `VoiceSurfaceState.reduce`'s
    /// `.ask` branch doc comment) before any conversation id ever came back.
    /// A live agent id sitting right there must not be borrowed — that would
    /// silently continue somebody else's conversation instead of starting
    /// this one fresh.
    func testAnAskCardWithNoConversationIdYetStartsFreshRatherThanBorrowingTheAgentId() {
        let surface = askCard(answer: "请求失败：无法连接到模型服务", conversationId: nil)

        let target = VoiceSurfaceFollowUp.target(
            for: surface, askConversationId: nil, agentConversationId: 9
        )

        XCTAssertEqual(target, VoiceSurfaceFollowUpTarget(kind: .ask, conversationId: nil))
    }

    /// Same hazard, agent side: a `.failed` card can exist before the run's
    /// own conversation id is known. A live, unrelated ask id must not be
    /// borrowed for it.
    func testAFailedAgentCardWithNoConversationIdYetStartsFreshRatherThanBorrowingTheAskId() {
        let surface = agentCard(phase: .failed, result: "找不到该文件", conversationId: nil)

        let target = VoiceSurfaceFollowUp.target(
            for: surface, askConversationId: 5, agentConversationId: nil
        )

        XCTAssertEqual(target, VoiceSurfaceFollowUpTarget(kind: .agent, conversationId: nil))
    }
}
