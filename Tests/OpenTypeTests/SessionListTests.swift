import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the redesign's merged 「会话」 surface
/// (`design_handoff_opentype_redesign_v1/README.md` › "State Management",
/// §1 主屏「会话」).
///
/// The Q&A tab and the Agent tab become one list. That is three separate
/// pieces of state logic, all of them pure and all of them wrong-able in ways
/// a screenshot will not show:
///
/// 1. **The merge** — `askConversations` + `agentConversations` into one
///    `updatedAt`-descending stream, each row still knowing which kind it is.
/// 2. **The filter** — `全部 / Agent / 问答` chips that narrow *the rendered
///    list*, never the two lists the sidecar filled.
/// 3. **The focus** — one `focusedConversationId` in place of the separate
///    `focusedAskConversationId` / `focusedAgentConversationId`, whose `kind`
///    now decides whether the next spoken turn goes to `/oneshot/ask` or
///    `/agent/run`.
///
/// Expected shape (Stage 3 creates it; nothing here builds it):
///
///     enum SessionKind: String, CaseIterable, Identifiable, Equatable {
///         case ask
///         case agent
///         var id: String { rawValue }
///         var title: String            // 问答 / Agent
///     }
///
///     extension ConversationSummary {
///         var sessionKind: SessionKind?   // typed view of the wire `kind`
///     }
///
///     enum SessionFilter: String, CaseIterable, Identifiable, Equatable {
///         case all
///         case agent
///         case ask
///         var id: String { rawValue }
///         var title: String            // 全部 / Agent / 问答
///         func matches(_ conversation: ConversationSummary) -> Bool
///     }
///
///     enum SessionList {
///         static func merged(
///             ask: [ConversationSummary],
///             agent: [ConversationSummary]
///         ) -> [ConversationSummary]
///
///         static func filtered(
///             _ conversations: [ConversationSummary],
///             by filter: SessionFilter
///         ) -> [ConversationSummary]
///     }
///
///     struct FocusedConversation: Equatable {
///         var id: Int
///         var kind: SessionKind
///     }
///
///     struct SessionContinuation: Equatable {
///         var conversationId: Int?
///         var mode: InputMode
///     }
///
///     extension VoiceFollowUp {
///         static func continuation(
///             surface: FocusedConversation?,
///             focused: FocusedConversation?,
///             spoken: InputMode
///         ) -> SessionContinuation
///     }
///
/// ## Pinned decision 1 — the merge sorts, it does not assume
///
/// Both inputs arrive already ordered (`GET /conversations?kind=…` is
/// `ORDER BY updatedAt DESC`), so a two-finger interleave would be enough. It
/// is pinned as a *total* order anyway — descending `updatedAt`, ties broken by
/// descending `id` — because the alternative fails silently: one stale row kept
/// from a failed refresh (`AppModel.mergedRefresh` deliberately keeps the old
/// list on a fetch error) is enough to leave an input out of order, and an
/// interleave over unordered inputs produces a list that is *nearly* sorted,
/// which reads as a bug in the sidecar rather than in the merge.
///
/// The tie-break is `id` descending because ids come from one autoincrement
/// column shared by both kinds (`sidecar/src/memory/conversations.ts` — one
/// `conversations` table with a `kind` column), so the higher id is the newer
/// row. Two conversations updated in the same millisecond is not hypothetical:
/// `updatedAt` is millisecond-resolution and a single dispatch can touch both a
/// thread and its reply.
///
/// ## Pinned decision 2 — an unknown `kind` survives 「全部」 and only that
///
/// `ConversationSummary.kind` is a wire `String`, not an enum, so a kind this
/// build does not know is representable. It is still a real conversation the
/// user had, so 「全部」 keeps it; but it cannot be claimed by either the Agent
/// or the 问答 chip, because guessing wrong there means a chip that says
/// "Agent" listing something that is not one.
///
/// ## Pinned decision 3 — id and kind must come from the same source
///
/// This is the hazard the merge introduces. Today an ask dispatch reads
/// `focusedAskConversationId` and *cannot* see an agent thread; that is what
/// `VoiceFollowUpTests.testAskAndAgentThreadsDoNotBleedIntoEachOther` pins.
/// With one `focusedConversationId` the separation is gone, and the two
/// mechanisms can now disagree: the live card can be showing ask thread #5
/// while the main window has agent thread #9 open. Resolving "which thread"
/// and "which endpoint" independently gives ask thread #5 dispatched to
/// `/agent/run` — the exact bleed the old split prevented.
///
/// So they are resolved together, by one function, from one winner:
/// `surface ?? focused`, keeping `VoiceFollowUp`'s existing precedence (the
/// card you are looking at is the most recent statement of what you are working
/// on). `conversationId` and `mode` in the returned `SessionContinuation`
/// always describe the same conversation.
///
/// ## Pinned decision 4 — 听写 is never hijacked
///
/// A focused conversation redirects `ask`↔`agent`, since those are the two
/// endpoints a conversation can live at. It must not touch `transcribe`:
/// dictation delivers text into whatever field has focus, and a thread left
/// open in a background window turning the user's next dictation into a chat
/// turn would be a data-loss-shaped bug. A `transcribe` dispatch therefore
/// continues nothing — `conversationId` is `nil`, not "the thread we happen to
/// be ignoring".
final class SessionListMergeTests: XCTestCase {

    private let hour = 3_600_000  // updatedAt is milliseconds since epoch
    private let base = 1_760_000_000_000

    // MARK: - Interleaving

    func testTwoSortedListsInterleaveByUpdatedAtDescending() {
        let ask = [
            conversation(id: 101, kind: "ask", updatedAt: base - 1 * hour),
            conversation(id: 102, kind: "ask", updatedAt: base - 5 * hour),
        ]
        let agent = [
            conversation(id: 201, kind: "agent", updatedAt: base - 3 * hour),
            conversation(id: 202, kind: "agent", updatedAt: base - 7 * hour),
        ]

        let merged = SessionList.merged(ask: ask, agent: agent)

        XCTAssertEqual(merged.map(\.id), [101, 201, 102, 202])
    }

    func testTheKindOfEveryRowSurvivesTheMerge() {
        // The whole point of one list is that a row still says what it is: the
        // type dot, the chip filter and the dispatch endpoint all read it.
        let ask = [conversation(id: 101, kind: "ask", updatedAt: base - 1 * hour)]
        let agent = [conversation(id: 201, kind: "agent", updatedAt: base - 2 * hour)]

        let merged = SessionList.merged(ask: ask, agent: agent)

        XCTAssertEqual(merged.map(\.kind), ["ask", "agent"])
        XCTAssertEqual(merged.map(\.sessionKind), [.ask, .agent])
    }

    func testTheWholeRowSurvivesNotJustItsIdentity() {
        // Title and timestamps are what the list row renders; a merge that
        // rebuilt rows from ids would lose them.
        let original = conversation(
            id: 101, kind: "ask", updatedAt: base - 1 * hour, title: "会议纪要"
        )

        let merged = SessionList.merged(ask: [original], agent: [])

        XCTAssertEqual(merged, [original])
    }

    func testATieOnUpdatedAtIsBrokenByTheNewerIdRegardlessOfWhichListItCameFrom() {
        let ask = [conversation(id: 10, kind: "ask", updatedAt: base)]
        let agent = [conversation(id: 11, kind: "agent", updatedAt: base)]

        XCTAssertEqual(
            SessionList.merged(ask: ask, agent: agent).map(\.id),
            [11, 10]
        )
        // …and the answer cannot depend on which side the caller passed first.
        XCTAssertEqual(
            SessionList.merged(ask: agent, agent: ask).map(\.id),
            [11, 10]
        )
    }

    func testAnOutOfOrderInputStillComesOutSorted() {
        // A refresh that failed leaves the previous list in place
        // (`AppModel.mergedRefresh`), so "the sidecar sorted it" is not a
        // guarantee the merge gets to lean on.
        let ask = [
            conversation(id: 101, kind: "ask", updatedAt: base - 9 * hour),
            conversation(id: 102, kind: "ask", updatedAt: base - 1 * hour),
        ]
        let agent = [
            conversation(id: 201, kind: "agent", updatedAt: base - 5 * hour),
        ]

        let merged = SessionList.merged(ask: ask, agent: agent)

        XCTAssertEqual(merged.map(\.id), [102, 201, 101])
    }

    // MARK: - Empty sides

    func testAnEmptyAskListLeavesTheAgentListIntactAndInOrder() {
        let agent = [
            conversation(id: 201, kind: "agent", updatedAt: base - 1 * hour),
            conversation(id: 202, kind: "agent", updatedAt: base - 4 * hour),
        ]

        XCTAssertEqual(
            SessionList.merged(ask: [], agent: agent).map(\.id),
            [201, 202]
        )
    }

    func testAnEmptyAgentListLeavesTheAskListIntactAndInOrder() {
        let ask = [
            conversation(id: 101, kind: "ask", updatedAt: base - 2 * hour),
            conversation(id: 102, kind: "ask", updatedAt: base - 6 * hour),
        ]

        XCTAssertEqual(
            SessionList.merged(ask: ask, agent: []).map(\.id),
            [101, 102]
        )
    }

    func testTwoEmptyListsMergeToNothing() {
        XCTAssertTrue(SessionList.merged(ask: [], agent: []).isEmpty)
    }

    // MARK: - Fixtures

    private func conversation(
        id: Int,
        kind: String,
        updatedAt: Int,
        title: String = "对话"
    ) -> ConversationSummary {
        ConversationSummary(
            id: id,
            kind: kind,
            title: title,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }
}

/// The 全部 / Agent / 问答 chips. They narrow what is drawn and nothing else —
/// `askConversations` / `agentConversations` are what the sidecar filled, and a
/// filter that edited them would turn a UI preference into data loss on the
/// next refresh diff.
final class SessionFilterTests: XCTestCase {

    private let base = 1_760_000_000_000

    private lazy var list: [ConversationSummary] = [
        conversation(id: 101, kind: "ask", updatedAt: base - 1),
        conversation(id: 201, kind: "agent", updatedAt: base - 2),
        conversation(id: 102, kind: "ask", updatedAt: base - 3),
        conversation(id: 202, kind: "agent", updatedAt: base - 4),
    ]

    func testTheChipRowIsExactlyThreeFiltersInDesignOrder() {
        XCTAssertEqual(SessionFilter.allCases, [.all, .agent, .ask])
    }

    func testEachChipCarriesItsDesignedChineseTitle() {
        XCTAssertEqual(SessionFilter.all.title, "全部")
        XCTAssertEqual(SessionFilter.agent.title, "Agent")
        XCTAssertEqual(SessionFilter.ask.title, "问答")
    }

    func testFiltersAreIdentifiableByTheirRawValue() {
        for filter in SessionFilter.allCases {
            XCTAssertEqual(filter.id, filter.rawValue)
        }
        XCTAssertEqual(
            Set(SessionFilter.allCases.map(\.id)).count,
            SessionFilter.allCases.count
        )
    }

    func testAllKeepsEverythingInTheOrderItArrivedIn() {
        XCTAssertEqual(SessionList.filtered(list, by: .all), list)
    }

    func testAgentKeepsOnlyAgentConversationsAndTheirRelativeOrder() {
        XCTAssertEqual(
            SessionList.filtered(list, by: .agent).map(\.id),
            [201, 202]
        )
    }

    func testAskKeepsOnlyAskConversationsAndTheirRelativeOrder() {
        XCTAssertEqual(
            SessionList.filtered(list, by: .ask).map(\.id),
            [101, 102]
        )
    }

    func testFilteringNeverReordersWhatItKeeps() {
        // Pinned separately from the two cases above because a `filter` built
        // out of a sort or a set would pass a two-element example by luck.
        let unsorted = [
            conversation(id: 301, kind: "agent", updatedAt: base - 9),
            conversation(id: 302, kind: "agent", updatedAt: base - 1),
            conversation(id: 303, kind: "agent", updatedAt: base - 5),
        ]

        XCTAssertEqual(
            SessionList.filtered(unsorted, by: .agent).map(\.id),
            [301, 302, 303]
        )
    }

    func testFilteringAnEmptyListIsEmptyForEveryChip() {
        for filter in SessionFilter.allCases {
            XCTAssertTrue(SessionList.filtered([], by: filter).isEmpty)
        }
    }

    func testFilteringDoesNotTouchTheListItWasGiven() {
        // The chip narrows the rendered list, never the data source.
        let source = list
        _ = SessionList.filtered(source, by: .agent)
        XCTAssertEqual(source, list)
    }

    // MARK: - Kinds this build does not know

    func testAConversationOfAnUnknownKindHasNoTypedKind() {
        let legacy = conversation(id: 999, kind: "assistant", updatedAt: base)
        XCTAssertNil(legacy.sessionKind)
    }

    func testAnUnknownKindStaysUnderAllAndIsClaimedByNeitherChip() {
        let legacy = conversation(id: 999, kind: "assistant", updatedAt: base)
        let withLegacy = list + [legacy]

        XCTAssertEqual(SessionList.filtered(withLegacy, by: .all).map(\.id).last, 999)
        XCTAssertFalse(SessionList.filtered(withLegacy, by: .agent).contains(legacy))
        XCTAssertFalse(SessionList.filtered(withLegacy, by: .ask).contains(legacy))
    }

    func testMatchesAgreesWithFiltered() {
        // The per-row predicate is what a list row will call to decide its own
        // visibility; it must not be able to drift from the list-level filter.
        for filter in SessionFilter.allCases {
            XCTAssertEqual(
                SessionList.filtered(list, by: filter),
                list.filter { filter.matches($0) }
            )
        }
    }

    private func conversation(
        id: Int,
        kind: String,
        updatedAt: Int,
        title: String = "对话"
    ) -> ConversationSummary {
        ConversationSummary(
            id: id,
            kind: kind,
            title: title,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }
}

/// One focus for both kinds — and therefore one decision, not two.
///
/// `VoiceFollowUp.conversationId(surface:focusedTab:)` already answers "which
/// thread does the next utterance continue". After the merge it also has to
/// answer "and which endpoint does it go to", because the kind that used to be
/// implied by *which* focus field was read is now carried by the conversation
/// itself. Splitting those two answers across two lookups is how an ask thread
/// ends up dispatched to `/agent/run`.
final class SessionContinuationTests: XCTestCase {

    // MARK: - Routing by the focused conversation's kind

    func testAFocusedAskThreadSendsTheNextTurnToAsk() {
        let continuation = VoiceFollowUp.continuation(
            surface: nil,
            focused: FocusedConversation(id: 5, kind: .ask),
            spoken: .ask
        )

        XCTAssertEqual(continuation, SessionContinuation(conversationId: 5, mode: .ask))
    }

    func testAFocusedAgentThreadSendsTheNextTurnToAgent() {
        let continuation = VoiceFollowUp.continuation(
            surface: nil,
            focused: FocusedConversation(id: 9, kind: .agent),
            spoken: .agent
        )

        XCTAssertEqual(continuation, SessionContinuation(conversationId: 9, mode: .agent))
    }

    func testTheThreadsKindWinsOverTheModeTheUserHappensToBeIn() {
        // 「`kind` 决定新一轮语音走 `/oneshot/ask` 还是 `/agent/run`」. Speaking
        // into an agent thread while the mode switch says 问答 continues the
        // agent task; the alternative is appending a question to a task thread,
        // which is what the two separate focus fields used to prevent.
        XCTAssertEqual(
            VoiceFollowUp.continuation(
                surface: nil,
                focused: FocusedConversation(id: 9, kind: .agent),
                spoken: .ask
            ),
            SessionContinuation(conversationId: 9, mode: .agent)
        )
        XCTAssertEqual(
            VoiceFollowUp.continuation(
                surface: nil,
                focused: FocusedConversation(id: 5, kind: .ask),
                spoken: .agent
            ),
            SessionContinuation(conversationId: 5, mode: .ask)
        )
    }

    func testDictationIsNeverRedirectedIntoAThread() {
        // 听写 writes into whatever field has focus. A thread left open in a
        // background window must not turn the user's next dictation into a chat
        // turn — and a transcribe dispatch continues no conversation at all.
        for kind in SessionKind.allCases {
            XCTAssertEqual(
                VoiceFollowUp.continuation(
                    surface: FocusedConversation(id: 5, kind: kind),
                    focused: FocusedConversation(id: 9, kind: kind),
                    spoken: .transcribe
                ),
                SessionContinuation(conversationId: nil, mode: .transcribe)
            )
        }
    }

    // MARK: - Starting fresh

    func testNoFocusAnywhereStartsAFreshConversationInTheSpokenMode() {
        for mode in InputMode.allCases {
            XCTAssertEqual(
                VoiceFollowUp.continuation(surface: nil, focused: nil, spoken: mode),
                SessionContinuation(conversationId: nil, mode: mode)
            )
        }
    }

    func testClearingTheFocusReturnsToStartingFresh() {
        // 「+」新对话 clears `focusedConversationId`; the next turn must open a
        // new thread rather than silently continue the one just dismissed.
        let focused = VoiceFollowUp.continuation(
            surface: nil,
            focused: FocusedConversation(id: 5, kind: .ask),
            spoken: .ask
        )
        XCTAssertEqual(focused.conversationId, 5)

        let cleared = VoiceFollowUp.continuation(
            surface: nil,
            focused: nil,
            spoken: .ask
        )
        XCTAssertNil(cleared.conversationId)
        XCTAssertEqual(cleared.mode, .ask)
    }

    // MARK: - Surface vs. main window (the disagreement this merge creates)

    func testTheVisibleCardStillWinsOverTheMainWindowsOpenThread() {
        // Same precedence `VoiceFollowUp.conversationId(surface:focusedTab:)`
        // already pins (commit eaa03f3), restated for the pair.
        let continuation = VoiceFollowUp.continuation(
            surface: FocusedConversation(id: 42, kind: .ask),
            focused: FocusedConversation(id: 7, kind: .ask),
            spoken: .ask
        )

        XCTAssertEqual(continuation.conversationId, 42)
        XCTAssertEqual(
            continuation.conversationId,
            VoiceFollowUp.conversationId(surface: 42, focusedTab: 7),
            "the pair must not disagree with the id-only seam it is layered on"
        )
    }

    func testTheThreadAndTheEndpointAlwaysComeFromTheSameConversation() {
        // The bleed this merge makes possible: an ask card on screen while an
        // agent thread is open in the main window. Resolving "which thread" and
        // "which endpoint" separately gives ask thread #5 posted to
        // `/agent/run`.
        let askCardOverAgentTab = VoiceFollowUp.continuation(
            surface: FocusedConversation(id: 5, kind: .ask),
            focused: FocusedConversation(id: 9, kind: .agent),
            spoken: .agent
        )

        XCTAssertEqual(
            askCardOverAgentTab,
            SessionContinuation(conversationId: 5, mode: .ask)
        )

        // …and the mirror image, so neither kind is the accidental default.
        let agentCardOverAskTab = VoiceFollowUp.continuation(
            surface: FocusedConversation(id: 9, kind: .agent),
            focused: FocusedConversation(id: 5, kind: .ask),
            spoken: .ask
        )

        XCTAssertEqual(
            agentCardOverAskTab,
            SessionContinuation(conversationId: 9, mode: .agent)
        )
    }

    func testAFirstTurnHasNoSurfaceThreadYetAndFallsBackToTheOpenOne() {
        // The card exists before its conversation id does (the id arrives with
        // the first response), so "no surface conversation" is the ordinary
        // first-turn state, not an error.
        XCTAssertEqual(
            VoiceFollowUp.continuation(
                surface: nil,
                focused: FocusedConversation(id: 7, kind: .agent),
                spoken: .agent
            ),
            SessionContinuation(conversationId: 7, mode: .agent)
        )
    }

    func testDismissingTheCardAndTheThreadEndsBoth() {
        XCTAssertEqual(
            VoiceFollowUp.continuation(surface: nil, focused: nil, spoken: .agent),
            SessionContinuation(conversationId: nil, mode: .agent)
        )
    }

    // MARK: - The kind vocabulary

    func testSessionKindsRawValuesAreTheSidecarsWireStrings() {
        // `SessionKind(rawValue: summary.kind)` is how a list row types itself,
        // and `GET /conversations?kind=…` is how the lists are fetched.
        XCTAssertEqual(SessionKind.ask.rawValue, "ask")
        XCTAssertEqual(SessionKind.agent.rawValue, "agent")
        XCTAssertEqual(SessionKind.allCases, [.ask, .agent])
    }

    func testSessionKindsCarryTheirDesignedChineseTitles() {
        XCTAssertEqual(SessionKind.ask.title, "问答")
        XCTAssertEqual(SessionKind.agent.title, "Agent")
    }
}
