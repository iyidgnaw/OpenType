import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for `AssistantEscalationWiring`, the one
/// decision `AppModel.presentVoiceSurface()` makes when offering §H's
/// escalation (`docs/superpowers/specs/2026-08-15-product-batch-plan.md`):
/// which of the two live panel ids is *this ask thread's own*.
///
/// `AppModel.init` has side effects and is not instantiable in tests
/// (`DispatchConfirmationTests` documents the same constraint and the same
/// fix), so the decision is factored into `AssistantEscalationWiring.
/// forVoiceSurface`, a pure function of exactly the state
/// `presentVoiceSurface()` has in scope — `askPanelState?.conversationId`
/// and `agentPanelState?.conversationId` — and tested here rather than left
/// inline where nothing can reach it.
///
/// The load-bearing case is `testEscalatingAnAskCardIgnoresAnUnrelatedLive-
/// AgentConversationId`. A stale or unrelated agent run can easily be live at
/// the same moment a finished ask card is on screen — `AppModel` carries one
/// `askPanelState` and one `agentPanelState` side by side, and nothing about
/// a `VoiceSurfaceState.result` case says which one produced it. An
/// implementation that reached for "whichever panel id happens to be around"
/// instead of the ask panel's own would attach the escalation to the WRONG
/// thread, or — worse, if the numbers ever coincided — silently continue a
/// conversation the user never asked to continue. That is the exact
/// "whichever panel is live" hazard `AssistantEscalation`'s own doc comment
/// warns callers about; `AssistantEscalation` itself cannot guard against it,
/// because by the time a caller reaches it, the wrong id already looks like
/// the right shape.
final class AssistantEscalationWiringTests: XCTestCase {

    private func askResult(
        query: String,
        answer: String,
        conversationId: Int?
    ) -> VoiceSurfaceState {
        VoiceSurfaceState.reduce(
            mode: .ask,
            processing: .idle,
            ask: AskPanelState(kind: .ask, query: query, answer: answer, conversationId: conversationId),
            agent: nil
        )
    }

    func testItOffersTheAskThreadsOwnConversation() {
        let surface = askResult(
            query: "今天的美元汇率是多少", answer: "1 USD ≈ 7.21 CNY", conversationId: 5
        )

        let escalation = AssistantEscalationWiring.forVoiceSurface(
            surface, askConversationId: 5, agentConversationId: nil
        )

        XCTAssertEqual(escalation?.conversation, FocusedConversation(id: 5, kind: .ask))
    }

    func testEscalatingAnAskCardIgnoresAnUnrelatedLiveAgentConversationId() {
        // The ask card and a completely different agent run are live at the
        // same time — a perfectly ordinary moment (the user asked a question,
        // then separately dispatched an unrelated task earlier). The
        // escalation must still name the ask thread, never the agent one.
        let surface = askResult(
            query: "今天的美元汇率是多少", answer: "1 USD ≈ 7.21 CNY", conversationId: 5
        )

        let escalation = AssistantEscalationWiring.forVoiceSurface(
            surface, askConversationId: 5, agentConversationId: 9
        )

        XCTAssertEqual(escalation?.conversation, FocusedConversation(id: 5, kind: .ask))
    }

    func testNoAskConversationIdYetEscalatesFreshRatherThanBorrowingTheAgentsId() {
        // The failure-path first turn (`AssistantEscalationThreadTests.
        // testAnAskWithNoThreadYetEscalatesIntoAFreshConversation`'s scenario,
        // reached through this seam): no ask thread was ever created, but a
        // live agent id happens to be sitting right there. Borrowing it would
        // silently post this question into somebody else's conversation.
        let surface = askResult(
            query: "今天的美元汇率是多少", answer: "请求失败：无法连接到模型服务", conversationId: nil
        )

        let escalation = AssistantEscalationWiring.forVoiceSurface(
            surface, askConversationId: nil, agentConversationId: 9
        )

        XCTAssertNotNil(escalation)
        XCTAssertNil(escalation?.conversation)
    }

    func testAnAgentCardOffersNothingRegardlessOfWhichIdsAreLive() {
        let surface = VoiceSurfaceState.reduce(
            mode: .agent,
            processing: .idle,
            ask: nil,
            agent: AgentProgressPanelState(
                runId: "run-1",
                task: "整理一下桌面上的截图",
                steps: [],
                phase: .succeeded,
                result: "已移动 12 个文件",
                conversationId: 9,
                question: nil
            )
        )

        let escalation = AssistantEscalationWiring.forVoiceSurface(
            surface, askConversationId: 5, agentConversationId: 9
        )

        XCTAssertNil(escalation)
    }
}
