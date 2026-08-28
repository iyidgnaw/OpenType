import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for Pipeline B §2's Swift half
/// (docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md
/// §2, the "Swift" bullet). The sidecar half already ships on `main`:
/// `GET /conversations/:id` now returns each message's persisted `steps`
/// (`ConversationStepRecord[]`, shape `{type: string; detail: string}` --
/// `sidecar/src/memory/conversations.ts`), present for an assistant message
/// whose run recorded them, `null`/absent otherwise. This file pins the Swift
/// side of that: decoding, rendering the persisted log for historical
/// threads, and not double-rendering against the ACTIVE run's live in-memory
/// state, which still wins for the turn that has not been written down yet.
///
/// It also corrects the stale premise behind the comment at
/// `SessionsViews.swift` ~500-506 ("Steps are not persisted with the
/// conversation ... so a thread from a previous launch has no log to show")
/// -- that comment predates this batch and stage 3 must update it alongside
/// the implementation.
///
/// ## New/changed symbols stage 3 must add for this file to compile (red now,
/// green once implemented) -- every compile error below should trace to one
/// of these four:
///
/// 1. `Models.swift` -- `ConversationMessageSummary` gains
///    `var steps: [AgentStepSummary]? = nil`. **Reuses the existing
///    `AgentStepSummary` decode model** (`{type: String, detail: String}`),
///    which already matches the sidecar's `ConversationStepRecord` shape
///    exactly -- no new decode type needed. Defaulted to `nil` (the same
///    pattern `ConversationSummary.preview` already uses) so every existing
///    memberwise construction of this type across the test target (see
///    `AssistantEscalationTests.swift`, `HistoryExportTests.swift`,
///    `HistorySearchTests.swift`) keeps compiling unchanged.
///
/// 2. `SessionsViews.swift` -- `StepLogEntry` (currently `private struct`,
///    ~SessionsViews.swift:777) widens to `struct StepLogEntry` (plain
///    internal access; no other change). This is the ONLY change item 2
///    below needs: `StepLogEntry.init(step:)` already exists and already
///    degrades an unrecognized `type` gracefully (its `switch`'s `default:`
///    branch), it is simply unreachable from `@testable import` today
///    because `private` stays file-scoped even under `@testable`.
///
/// 3 & 4. `SessionsViews.swift` (or a new small file -- placement is stage
///    3's call) -- a new pure type, **`SessionStepLogResolver`**, the merge
///    seam neither persisted-only nor live-only code needs today:
///
///        enum SessionStepLogResolver {
///            struct LiveRun: Equatable {
///                var conversationId: Int
///                var steps: [AgentStepSummary]
///                /// Mirrors `AgentProgressPanelState.phase == .running` --
///                /// the same condition `stepLog(for:)`/`isWorking(_:)`
///                /// already gate on today (SessionsViews.swift:513-521,
///                /// 546-557). This is what tells the resolver "the run this
///                /// live record describes has not finished" as opposed to
///                /// "this is a leftover record for a run that already
///                /// completed or failed."
///                var isActivelyRunning: Bool
///            }
///
///            /// Same rule as the existing private
///            /// `SessionsListDetailColumn.stepLogAnchor(in:)` -- the last
///            /// non-user message in a thread. Recommended (not
///            /// test-enforced, since the existing method is a private
///            /// instance method unreachable from a test target): make
///            /// `stepLogAnchor(in:)` delegate to this so the rule has one
///            /// definition instead of two copies drifting apart.
///            static func anchorIndex(in messages: [ConversationMessageSummary]) -> Int?
///
///            /// Which steps (if any) `messages[index]` should render.
///            static func steps(
///                forMessageAt index: Int,
///                in messages: [ConversationMessageSummary],
///                conversationId: Int,
///                liveRun: LiveRun?
///            ) -> [AgentStepSummary]?
///        }
///
///    **Pinned semantics (corrected 2026-08-29 after stage-2 review; see
///    below for what the first draft got wrong):**
///    - A message's own persisted `steps`, when present and non-empty, is
///      what it shows at every NON-anchor index -- a live run anywhere in
///      the conversation must never reach back and change an
///      already-settled turn's own log.
///    - At `anchorIndex(in: messages)`, a matching, **actively running**
///      live record (`liveRun.conversationId == conversationId &&
///      liveRun.isActivelyRunning`) wins **unconditionally** -- even over an
///      anchor message that already has its own non-empty persisted steps.
///      This is the case the first draft of this file got backwards: in a
///      multi-turn thread, a follow-up run's assistant message does not
///      exist yet while the run is in flight, so the anchor stays pinned to
///      the PREVIOUS (already-persisted) message for the run's **entire
///      duration**, not just for one race-y instant. Making persisted win
///      there, as this file originally did, would have hidden that
///      follow-up's whole live step feed the whole time it runs --
///      contradicting spec §2's "活跃 run 仍以内存态优先" ("the active run's
///      in-memory state still wins"), which is a sustained-duration
///      guarantee, not a one-tick tiebreaker.
///    - Only once a matching live record is **not** actively running
///      (`isActivelyRunning == false` -- the run already finished or failed,
///      and this is a still-lingering record) does the anchor's own
///      persisted value get to preempt it: persisted first if present, the
///      trailing live record only as a fallback if the anchor genuinely has
///      no persisted value yet. That remaining live-but-not-running case is
///      the true one-tick race this file's first draft mistook for the
///      general rule: the blocking `/agent/run` call has returned and the
///      assistant message got persisted, but the panel/poller has not yet
///      flipped away from showing that now-stale record.
///    - `[]` (an explicitly-empty array, persisted or live) is normalised to
///      "no steps" throughout -- never a `0`-row collapsible block.
///    - **Known limitation carried over from the current design, not
///      introduced by it**: a run in flight for a conversation that has NO
///      prior assistant message at all (a first-ever turn) has no message
///      index to attach to (`anchorIndex` is `nil` until a message exists),
///      so this resolver renders nothing for it -- matching
///      `stepLog(for:)`'s existing behavior today (it too is only ever
///      invoked at `stepLogAnchor(in: detail)`, which is `nil` in exactly
///      this case). Not exercised here since it produces no observable
///      difference (`nil` in, `nil` out) worth asserting beyond
///      `testAnchorIsNilWhenNoAssistantMessageExistsYet`.
///    - **Stage-3 wiring note**: the caller (`SessionsListDetailColumn`)
///      builds `LiveRun` from `model.agentPanelState` with
///      `isActivelyRunning: panel.phase == .running` -- the exact condition
///      `isWorking(_:)` already tests at SessionsViews.swift:548-549.
final class ConversationMessageStepsDecodingTests: XCTestCase {

    // MARK: - With steps

    func testDecodesMessageWithStepsIntoTypedNonNilArray() throws {
        let json = """
        {"id":2,"conversationId":7,"role":"assistant","content":"Here is the answer.",
         "createdAt":1760000000001,
         "steps":[{"type":"thinking","detail":"Let me check."},
                  {"type":"tool_call","detail":"Calling opentype__web_search({\\"query\\":\\"x\\"})"}]}
        """

        let message: ConversationMessageSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        let steps = try XCTUnwrap(message.steps)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].type, "thinking")
        XCTAssertEqual(steps[0].detail, "Let me check.")
        XCTAssertEqual(steps[1].type, "tool_call")
        XCTAssertEqual(steps[1].detail, "Calling opentype__web_search({\"query\":\"x\"})")
    }

    /// Backward compatibility: the fields that existed before this batch
    /// decode identically whether or not `steps` is present.
    func testExistingFieldsDecodeIdenticallyAlongsideSteps() throws {
        let json = """
        {"id":2,"conversationId":7,"role":"assistant","content":"Here is the answer.",
         "createdAt":1760000000001,
         "steps":[{"type":"done","detail":"Here is the answer."}]}
        """

        let message: ConversationMessageSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertEqual(message.id, 2)
        XCTAssertEqual(message.conversationId, 7)
        XCTAssertEqual(message.role, "assistant")
        XCTAssertEqual(message.content, "Here is the answer.")
        XCTAssertEqual(message.createdAt, 1_760_000_000_001)
    }

    // MARK: - Without steps

    func testStepsKeyAbsentDecodesToNil() throws {
        let json = """
        {"id":1,"conversationId":7,"role":"user","content":"search something","createdAt":1760000000000}
        """

        let message: ConversationMessageSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertNil(message.steps)
        // Still decodes everything else -- a pre-batch row is not otherwise
        // affected by the new field's absence.
        XCTAssertEqual(message.role, "user")
        XCTAssertEqual(message.content, "search something")
    }

    func testExplicitNullStepsDecodesToNil() throws {
        let json = """
        {"id":4,"conversationId":7,"role":"assistant","content":"4","createdAt":1760000000002,"steps":null}
        """

        let message: ConversationMessageSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertNil(message.steps)
    }

    /// The default value on the new property is what keeps every existing
    /// memberwise construction of this type (elsewhere in the test target)
    /// compiling without having to name `steps:` at all.
    func testMemberwiseConstructionWithoutStepsDefaultsToNil() {
        let message = ConversationMessageSummary(
            id: 1, conversationId: 7, role: "user", content: "hi", createdAt: 1
        )
        XCTAssertNil(message.steps)
    }

    // MARK: - Full thread, mixing messages with and without steps

    /// Mirrors `sidecar/test/memory/conversationRoutesSteps.test.ts`'s third
    /// case exactly: two turns, only the first assistant message carries
    /// steps.
    func testConversationDetailDecodesMixedStepsAcrossMessages() throws {
        let json = """
        {"id":7,"kind":"agent","title":"task one","createdAt":1,"updatedAt":4,
         "messages":[
           {"id":1,"conversationId":7,"role":"user","content":"task one","createdAt":1},
           {"id":2,"conversationId":7,"role":"assistant","content":"done one","createdAt":2,
            "steps":[{"type":"tool_call","detail":"Calling opentype__web_search({...})"},
                     {"type":"tool_result","detail":"1. Atlantis wins the final"},
                     {"type":"done","detail":"Here is the answer."}]},
           {"id":3,"conversationId":7,"role":"user","content":"task two","createdAt":3},
           {"id":4,"conversationId":7,"role":"assistant","content":"done two","createdAt":4}
         ]}
        """

        let detail: ConversationDetail = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertEqual(detail.messages.count, 4)
        XCTAssertNil(detail.messages[0].steps)
        XCTAssertEqual(detail.messages[1].steps?.count, 3)
        XCTAssertEqual(detail.messages[1].steps?.first?.type, "tool_call")
        XCTAssertNil(detail.messages[2].steps)
        XCTAssertNil(detail.messages[3].steps)
    }
}

// MARK: - Item 2: mapping a persisted step record to the render row

final class StepLogEntryPersistedStepMappingTests: XCTestCase {

    func testKnownToolCallTypeParsesNameAndArguments() {
        let entry = StepLogEntry(step: AgentStepSummary(
            type: "tool_call",
            detail: "Calling opentype__web_search({\"query\":\"x\"})"
        ))

        XCTAssertEqual(entry.label, "web_search")
        XCTAssertEqual(entry.detail, "{\"query\":\"x\"}")
    }

    func testKnownToolResultTypeCarriesDetailThrough() {
        let entry = StepLogEntry(step: AgentStepSummary(
            type: "tool_result", detail: "1. Atlantis wins the final"
        ))

        XCTAssertEqual(entry.detail, "1. Atlantis wins the final")
    }

    func testKnownDoneTypeCarriesDetailThrough() {
        let entry = StepLogEntry(step: AgentStepSummary(type: "done", detail: "Here is the answer."))

        XCTAssertEqual(entry.detail, "Here is the answer.")
    }

    func testKnownErrorTypeCarriesDetailThrough() {
        let entry = StepLogEntry(step: AgentStepSummary(type: "error", detail: "boom"))

        XCTAssertEqual(entry.detail, "boom")
    }

    /// The sidecar's step `type` is an open string (`ConversationStepRecord`
    /// in `sidecar/src/memory/conversations.ts` is `{ type: string; ... }`,
    /// not a closed union) -- a persisted historical thread can carry a type
    /// this build has never seen (e.g. a newer sidecar added a step kind
    /// after this app version shipped). It must still render as a row --
    /// generic label, detail passed through -- never be silently dropped
    /// from the log or trap.
    func testUnknownTypeDegradesGracefullyInsteadOfDroppingOrCrashing() {
        let entry = StepLogEntry(step: AgentStepSummary(type: "some_future_step_type", detail: "abc"))

        XCTAssertEqual(entry.label, "some_future_step_type")
        XCTAssertEqual(entry.detail, "abc")
    }
}

// MARK: - Items 3 & 4: which steps a message renders (anchor + merge + empty)

final class SessionStepLogResolverTests: XCTestCase {

    private let sampleSteps: [AgentStepSummary] = [
        AgentStepSummary(type: "tool_call", detail: "Calling opentype__web_search({...})"),
        AgentStepSummary(type: "done", detail: "Here is the answer."),
    ]

    // MARK: Anchor

    func testAnchorIsTheLastNonUserMessage() {
        let messages = [
            message(id: 1, role: "user"),
            message(id: 2, role: "assistant"),
            message(id: 3, role: "user"),
        ]

        XCTAssertEqual(SessionStepLogResolver.anchorIndex(in: messages), 1)
    }

    func testAnchorIsNilWhenNoAssistantMessageExistsYet() {
        let messages = [message(id: 1, role: "user")]

        XCTAssertNil(SessionStepLogResolver.anchorIndex(in: messages))
    }

    // MARK: Historical thread -- no live run

    func testHistoricalThreadShowsEachMessagesOwnPersistedSteps() {
        let messages = [
            message(id: 1, role: "user"),
            message(id: 2, role: "assistant", steps: sampleSteps),
        ]

        XCTAssertEqual(
            SessionStepLogResolver.steps(forMessageAt: 1, in: messages, conversationId: 7, liveRun: nil),
            sampleSteps
        )
    }

    func testHistoricalMessageWithNoPersistedStepsShowsNothing() {
        // A pre-batch row, or a non-agent assistant turn -- `steps` absent.
        let messages = [
            message(id: 1, role: "user"),
            message(id: 2, role: "assistant"),
        ]

        XCTAssertNil(
            SessionStepLogResolver.steps(forMessageAt: 1, in: messages, conversationId: 7, liveRun: nil)
        )
    }

    func testNonAnchorMessageShowsItsOwnPersistedStepsRegardlessOfALiveRunElsewhere() {
        // Two completed turns; a live run is now actively in flight for a
        // THIRD turn that has no message row of its own yet (so the anchor
        // is still index 3, the second assistant message). The FIRST turn's
        // own log must keep showing exactly as before -- a live run anywhere
        // in the conversation must never reach back and blank out an
        // earlier, already-settled turn's persisted log.
        let earlierSteps = [AgentStepSummary(type: "thinking", detail: "turn one")]
        let messages = [
            message(id: 1, role: "user"),
            message(id: 2, role: "assistant", steps: earlierSteps),
            message(id: 3, role: "user"),
            message(id: 4, role: "assistant", steps: sampleSteps),
        ]
        let live = SessionStepLogResolver.LiveRun(
            conversationId: 7,
            steps: [AgentStepSummary(type: "thinking", detail: "live, in flight")],
            isActivelyRunning: true
        )

        XCTAssertEqual(
            SessionStepLogResolver.steps(forMessageAt: 1, in: messages, conversationId: 7, liveRun: live),
            earlierSteps
        )
    }

    /// The counterpart to the test above, same fixture: at the ANCHOR
    /// (index 3, `message[3]`), an actively-running live run wins even
    /// though that message already has its own persisted `sampleSteps` --
    /// this is the sustained, whole-run-duration case spec §2's "活跃 run
    /// 仍以内存态优先" describes, not a one-tick race. Getting this backwards
    /// (persisted always wins at the anchor) would hide a genuine follow-up
    /// run's live step feed for its entire duration, since the anchor stays
    /// pinned to the previous message the whole time the new run has no
    /// message row of its own.
    func testLiveStepsOverridePreviousTurnsPersistedStepsAtTheAnchorWhileActivelyRunning() {
        let earlierSteps = [AgentStepSummary(type: "thinking", detail: "turn one")]
        let messages = [
            message(id: 1, role: "user"),
            message(id: 2, role: "assistant", steps: earlierSteps),
            message(id: 3, role: "user"),
            message(id: 4, role: "assistant", steps: sampleSteps), // anchor; already has persisted steps
        ]
        let liveSteps = [AgentStepSummary(type: "thinking", detail: "the NEW run, still going")]
        let live = SessionStepLogResolver.LiveRun(
            conversationId: 7, steps: liveSteps, isActivelyRunning: true
        )

        XCTAssertEqual(
            SessionStepLogResolver.steps(forMessageAt: 3, in: messages, conversationId: 7, liveRun: live),
            liveSteps
        )
    }

    // MARK: Active run -- anchor precedence

    func testLiveStepsShowAtTheAnchorWhenTheAnchorHasNoPersistedSteps() {
        let messages = [
            message(id: 1, role: "user"),
            message(id: 2, role: "assistant"), // anchor; not yet persisted with steps
        ]
        let live = SessionStepLogResolver.LiveRun(conversationId: 7, steps: sampleSteps, isActivelyRunning: true)

        XCTAssertEqual(
            SessionStepLogResolver.steps(forMessageAt: 1, in: messages, conversationId: 7, liveRun: live),
            sampleSteps
        )
    }

    /// The genuine one-tick race, correctly scoped: the live run is no
    /// longer actively running (`isActivelyRunning: false` -- the blocking
    /// `/agent/run` call already returned and this turn's steps got
    /// persisted) but its record has not been torn down yet. Once
    /// `isActivelyRunning` is false, the anchor's own persisted value
    /// preempts that trailing record -- unlike the sustained "still running"
    /// case above, where live always wins regardless of persisted content.
    func testPersistedStepsAtTheAnchorWinOverAStaleNoLongerRunningLiveRecord() {
        let persisted = [AgentStepSummary(type: "done", detail: "the real, final answer")]
        let messages = [
            message(id: 1, role: "user"),
            message(id: 2, role: "assistant", steps: persisted), // anchor, already written down
        ]
        let stale = SessionStepLogResolver.LiveRun(
            conversationId: 7,
            steps: [AgentStepSummary(type: "thinking", detail: "still thinking (stale)")],
            isActivelyRunning: false
        )

        XCTAssertEqual(
            SessionStepLogResolver.steps(forMessageAt: 1, in: messages, conversationId: 7, liveRun: stale),
            persisted
        )
    }

    /// The fallback half of the not-actively-running branch: if the anchor
    /// genuinely has no persisted value yet (e.g. persistence itself is
    /// still in flight a beat after the panel already flipped away from
    /// `.running`), the trailing live record is shown rather than nothing --
    /// `nil` would be a worse answer than a record known to be stale-ish but
    /// still the most recent information available.
    func testNoLongerRunningLiveStepsFillInWhenAnchorHasNoPersistedStepsYet() {
        let messages = [
            message(id: 1, role: "user"),
            message(id: 2, role: "assistant"), // anchor, no persisted value yet
        ]
        let trailing = SessionStepLogResolver.LiveRun(
            conversationId: 7, steps: sampleSteps, isActivelyRunning: false
        )

        XCTAssertEqual(
            SessionStepLogResolver.steps(forMessageAt: 1, in: messages, conversationId: 7, liveRun: trailing),
            sampleSteps
        )
    }

    func testLiveRunForADifferentConversationNeverApplies() {
        let messages = [
            message(id: 1, role: "user"),
            message(id: 2, role: "assistant"),
        ]
        let otherConversationsLiveRun = SessionStepLogResolver.LiveRun(
            conversationId: 999, steps: sampleSteps, isActivelyRunning: true
        )

        XCTAssertNil(
            SessionStepLogResolver.steps(
                forMessageAt: 1, in: messages, conversationId: 7, liveRun: otherConversationsLiveRun
            )
        )
    }

    /// No double-render: the seam returns a single optional array, never a
    /// pair or a concatenation. Scoped to the not-actively-running branch
    /// (see the two tests above for the actively-running branch, where live
    /// alone wins): when both a persisted value and a no-longer-running live
    /// record exist for the anchor, the result is exactly the persisted
    /// value, not "both".
    func testAnchorResultIsExactlyOneSourceNeverBoth() {
        let persisted = [AgentStepSummary(type: "done", detail: "persisted")]
        let live = SessionStepLogResolver.LiveRun(
            conversationId: 7,
            steps: [AgentStepSummary(type: "thinking", detail: "live")],
            isActivelyRunning: false
        )
        let messages = [message(id: 1, role: "assistant", steps: persisted)]

        let result = SessionStepLogResolver.steps(forMessageAt: 0, in: messages, conversationId: 7, liveRun: live)

        XCTAssertEqual(result, persisted)
        XCTAssertEqual(result?.count, 1)
    }

    // MARK: Empty-steps edge (item 4)

    func testEmptyPersistedStepsArrayRendersAsNoStepLog() {
        let messages = [
            message(id: 1, role: "user"),
            message(id: 2, role: "assistant", steps: []),
        ]

        XCTAssertNil(
            SessionStepLogResolver.steps(forMessageAt: 1, in: messages, conversationId: 7, liveRun: nil)
        )
    }

    func testEmptyLiveStepsArrayAtTheAnchorRendersAsNoStepLog() {
        let messages = [
            message(id: 1, role: "user"),
            message(id: 2, role: "assistant"),
        ]
        let live = SessionStepLogResolver.LiveRun(conversationId: 7, steps: [], isActivelyRunning: true)

        XCTAssertNil(
            SessionStepLogResolver.steps(forMessageAt: 1, in: messages, conversationId: 7, liveRun: live)
        )
    }

    func testEmptyPersistedStepsAtTheAnchorFallsThroughToLiveRatherThanSuppressingIt() {
        // `[]` and `nil` are equivalent as "nothing persisted yet" -- an
        // anchor explicitly written with zero steps must still defer to a
        // live run in flight for the same conversation, exactly like `nil`
        // would.
        let messages = [
            message(id: 1, role: "user"),
            message(id: 2, role: "assistant", steps: []),
        ]
        let live = SessionStepLogResolver.LiveRun(conversationId: 7, steps: sampleSteps, isActivelyRunning: true)

        XCTAssertEqual(
            SessionStepLogResolver.steps(forMessageAt: 1, in: messages, conversationId: 7, liveRun: live),
            sampleSteps
        )
    }

    // MARK: - Fixture

    private func message(
        id: Int,
        conversationId: Int = 7,
        role: String,
        content: String = "x",
        steps: [AgentStepSummary]? = nil
    ) -> ConversationMessageSummary {
        ConversationMessageSummary(
            id: id, conversationId: conversationId, role: role, content: content, createdAt: id, steps: steps
        )
    }
}
