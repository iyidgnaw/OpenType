import XCTest
@testable import OpenType

/// Speaking again while a card is still on screen has to continue that
/// conversation.
///
/// It did not: a thread could only be continued by first opening it in the
/// main window, so talking to the overlay — the natural way to follow up on
/// an answer you are looking at — opened a new thread every time and split
/// one conversation into a pile of one-turn ones.
final class VoiceFollowUpTests: XCTestCase {
    func testTheVisibleCardWinsOverTheMainWindowsOpenThread() {
        // Both can be set at once, and where they disagree the surface is the
        // more recent statement of what the user is working on.
        XCTAssertEqual(
            VoiceFollowUp.conversationId(surface: 42, focusedTab: 7),
            42
        )
    }

    func testItFallsBackToTheOpenThreadWhenNothingIsOnScreen() {
        // Opening a thread in the main window and then speaking still
        // continues it — the behaviour that already existed.
        XCTAssertEqual(
            VoiceFollowUp.conversationId(surface: nil, focusedTab: 7),
            7
        )
    }

    func testNoThreadAnywhereStartsAFreshOne() {
        XCTAssertNil(VoiceFollowUp.conversationId(surface: nil, focusedTab: nil))
    }

    func testAFirstTurnIsStillAFollowUpSourceOnceItHasAnId() {
        // The id only exists after the first response, so a first turn
        // dispatches with nil and adopts the id it is told about.
        var panel = AgentProgressPanelState(
            runId: "r", task: "t", steps: [], phase: .running, result: nil
        )
        XCTAssertNil(VoiceFollowUp.conversationId(surface: panel.conversationId, focusedTab: nil))

        panel.conversationId = 11
        XCTAssertEqual(
            VoiceFollowUp.conversationId(surface: panel.conversationId, focusedTab: nil),
            11
        )
    }

    func testDismissingIsWhatEndsTheThread() {
        // Nil panel state IS dismissal (`dismissAgentPanel`/`hideVoiceSurface`
        // clear it), so this is the whole "close the card to start over"
        // contract: an explicit, visible act rather than a hidden timeout.
        let dismissed: AgentProgressPanelState? = nil

        XCTAssertNil(
            VoiceFollowUp.conversationId(surface: dismissed?.conversationId, focusedTab: nil)
        )
    }

    func testAskAndAgentThreadsDoNotBleedIntoEachOther() {
        // The sidecar keys conversations by kind, so each mode must consult
        // only its own surface. Passing the agent's thread to an ask dispatch
        // would append a question to a task thread.
        let ask = AskPanelState(kind: .ask, query: "q", answer: "a", conversationId: 5)
        let agent = AgentProgressPanelState(
            runId: "r", task: "t", steps: [], phase: .succeeded, result: "done", conversationId: 9
        )

        XCTAssertEqual(VoiceFollowUp.conversationId(surface: ask.conversationId, focusedTab: nil), 5)
        XCTAssertEqual(VoiceFollowUp.conversationId(surface: agent.conversationId, focusedTab: nil), 9)
    }
}

/// The overlay should not change size while it is still just a pill.
final class VoiceSurfacePillSizeTests: XCTestCase {
    func testEveryPreResultStateIsTheSameSize() {
        // `.processing` and `.working` render the same view, so a different
        // size for each was dead space in one of them and a visible twitch on
        // the transition between them.
        let listening = VoiceSurfacePanelLayout.size(for: .listening)
        let processing = VoiceSurfacePanelLayout.size(for: .processing)
        let working = VoiceSurfacePanelLayout.size(
            for: .working(.init(kind: .agent, currentStep: "step"))
        )

        XCTAssertEqual(listening, processing)
        XCTAssertEqual(processing, working)
    }

    func testTheCardIsStillLargerThanThePill() {
        // The morph has to remain a real change: the point of holding the
        // pill's size steady is that growing into the card reads as the one
        // deliberate transition.
        let pill = VoiceSurfacePanelLayout.size(for: .listening)
        let card = VoiceSurfacePanelLayout.size(
            for: .result(.init(kind: .agent, query: "q", body: "b", steps: []))
        )

        XCTAssertGreaterThan(card.width, pill.width)
        XCTAssertGreaterThan(card.height, pill.height)
    }
}
