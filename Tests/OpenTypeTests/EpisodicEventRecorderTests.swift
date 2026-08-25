import XCTest
@testable import OpenType

/// Stage-1 (red) tests for Task 5 of
/// `docs/superpowers/plans/2026-08-25-unified-memory-and-recent-context.md`
/// ("Swift 单写入点"): `EpisodicEventRecorder`, the pure type that turns one
/// completed delivery into the body of `POST /memory/events`.
///
/// Why this moves to Swift at all: today three sidecar routes each write their
/// own episodic event from only the half of the truth they can see —
/// `/asr/transcribe` doesn't know the real mode or the app; `/oneshot/ask` and
/// `/agent/run` hardcode a placeholder `applicationName`; and none of the
/// three can see a Review-mode edit or a `tidy` rewrite, both of which happen
/// to the transcript *after* the sidecar has already answered. Swift is the
/// only place all of that is known at once, and only at the moment delivery
/// actually completes — see `AppModel.swift`'s three `recordAuditEvent(...
/// status: .completed ...)` call sites (the Direct/Tidy transcribe branch
/// around line 3886, `runAskDispatch`'s success branch around line 4226, and
/// `runAgentDispatch`'s success branch around line 4585), each paired with a
/// best-effort `POST /memory/events` in the design.
///
/// `EpisodicEventRecorder` and `EpisodicEventBody` do not exist yet
/// (`Sources/OpenType/EpisodicEventRecorder.swift` is stage 3's job) — every
/// test below is expected to fail to *compile* until that file exists, which
/// is the right kind of red for a brand-new pure type.
///
/// ## `correctedTranscript` (added after team-lead review of the first pass)
///
/// `body(...)` takes **three** text-shaped inputs, not two:
/// `rawTranscript` (what Whisper heard), `correctedTranscript` (after the
/// entity dictionary rewrote aliases — sidecar's `POST /asr/transcribe` grows
/// this as its new `rawText`/`text` pair per Task 4), and `deliveredText`
/// (what actually reached the user's field, after `tidy` or a Review edit).
/// Consolidation mines `rawTranscript`/`correctedTranscript` as a pair to find
/// mishearings (`sidecar/src/memory/consolidator.ts`), and
/// `recentActivity.ts` renders `correctedTranscript` — not `rawTranscript` —
/// into the injected `input` field, so collapsing the two loses something a
/// live consumer reads. `sidecar/src/memory/routes.ts` defaults a missing
/// `correctedTranscript` to `rawTranscript` (`body.correctedTranscript ??
/// body.rawTranscript`) — that is a safety net for a caller that omits the
/// field, not a statement that Swift should rely on it; a `transcribe`
/// delivery that never went through dictionary rewrite would silently record
/// an unrewritten `correctedTranscript` for consolidation to mine as if it
/// were rewritten.
///
/// This does mean `LearningLoop.swift`'s `TranscribeResponse` (currently
/// `{ text, replacements }`) needs a `rawText` field to give `AppModel`
/// something to pass as `rawTranscript` once Task 4 lands — that is a plain
/// required-`String` `Decodable` addition (Task 4's own contract test already
/// says `rawText` is always present, no absent-key/back-compat case the way
/// `replacements` has one), so there is no interesting decoding *behavior* to
/// pin beyond "it decodes" — no test added for it here; left to stage 3 per
/// the team lead's steer.
final class EpisodicEventRecorderTests: XCTestCase {

    // MARK: - Pin 1: transcribe records the DELIVERED text, not the ASR output

    /// The whole reason the write moved to Swift: `tidy` runs locally, after
    /// recognition, and a Review edit lands later still, so the sidecar never
    /// saw what actually reached the user's text field. `rawTranscript` must
    /// keep the ASR-stage string (fillers and all) while `result` carries only
    /// what was actually delivered.
    func testTranscribeRecordsDeliveredTextAsResultAndOwnerOrigin() {
        let body = EpisodicEventRecorder.body(
            mode: .transcribe,
            rawTranscript: "呃这个明天开会",
            correctedTranscript: "呃这个明天开会",
            deliveredText: "明天开会",
            selectedContext: nil,
            applicationName: "WeChat",
            conversationId: nil
        )

        // 交付出去的是轻整理之后的文本，不是 ASR 原文。
        XCTAssertEqual(body.result, "明天开会")
        XCTAssertEqual(body.rawTranscript, "呃这个明天开会")
        XCTAssertNotEqual(body.result, body.rawTranscript)
        // 端到端全是用户自己的话，没有模型介入。
        XCTAssertEqual(body.origin, "owner")
        // 听写没有会话。
        XCTAssertNil(body.conversationId)
        XCTAssertEqual(body.mode, "transcribe")
    }

    /// The three-way split, tested on its own: `rawTranscript` is what
    /// Whisper actually heard, `correctedTranscript` is after the entity
    /// dictionary rewrote a known alias, `result` is what `tidy` delivered
    /// after that. All three must be distinct and none may be derived from
    /// another inside `body(...)` — it is a pure passthrough of whatever three
    /// strings `AppModel` hands it, because only `AppModel` knows which
    /// pipeline stage produced each one.
    func testCorrectedTranscriptIsTheDictionaryRewriteDistinctFromRawAndResult() {
        let body = EpisodicEventRecorder.body(
            mode: .transcribe,
            rawTranscript: "呃这个明天去拍拍付款开会",
            correctedTranscript: "呃这个明天去PayPal付款开会",
            deliveredText: "明天去PayPal付款开会",
            selectedContext: nil,
            applicationName: "WeChat",
            conversationId: nil
        )

        XCTAssertEqual(body.rawTranscript, "呃这个明天去拍拍付款开会")
        XCTAssertEqual(body.correctedTranscript, "呃这个明天去PayPal付款开会")
        XCTAssertEqual(body.result, "明天去PayPal付款开会")
        XCTAssertNotEqual(body.rawTranscript, body.correctedTranscript)
        XCTAssertNotEqual(body.correctedTranscript, body.result)
    }

    /// `ask`/`agent` never go through the entity dictionary — there is no
    /// rewrite stage between "what was said" and "what was processed" for
    /// either mode. Pinned explicitly (rather than left to be inferred from
    /// callers always happening to pass the same string twice) so a future
    /// simplification cannot drop one of the two parameters on the theory
    /// that they are redundant — they're redundant for these two modes only,
    /// and `testCorrectedTranscriptIsTheDictionaryRewriteDistinctFromRawAndResult`
    /// above is the proof they are not redundant for `transcribe`.
    func testAskAndAgentHaveNoDictionaryStageSoRawEqualsCorrected() {
        for mode in [InputMode.ask, .agent] {
            let body = EpisodicEventRecorder.body(
                mode: mode,
                rawTranscript: "问题",
                correctedTranscript: "问题",
                deliveredText: "答案",
                selectedContext: nil,
                applicationName: "Xcode",
                conversationId: 17
            )
            XCTAssertEqual(
                body.rawTranscript, body.correctedTranscript,
                "\(mode) has no dictionary stage, so both must be the same string"
            )
        }
    }

    // MARK: - Pin 2: origin is per-mode

    /// `ask`/`agent` must record `"agent"`, never `"owner"` — `result` is
    /// machine-produced and may quote a fetched web page, so recording it as
    /// the user's own words is exactly the provenance confusion `EventOrigin`
    /// exists to prevent (it gates whether a consolidation-derived fact can
    /// ever pass the `origin === "owner"` trust check downstream). Verified
    /// for all three modes so a future edit can't silently special-case one.
    func testOriginIsOwnerForTranscribeAndAgentForAskAndAgent() {
        let transcribeBody = EpisodicEventRecorder.body(
            mode: .transcribe,
            rawTranscript: "听写",
            correctedTranscript: "听写",
            deliveredText: "听写",
            selectedContext: nil,
            applicationName: "Notes",
            conversationId: nil
        )
        XCTAssertEqual(transcribeBody.origin, "owner")

        for mode in [InputMode.ask, .agent] {
            let body = EpisodicEventRecorder.body(
                mode: mode,
                rawTranscript: "问题",
                correctedTranscript: "问题",
                deliveredText: "答案",
                selectedContext: nil,
                applicationName: "Xcode",
                conversationId: 17
            )
            XCTAssertEqual(
                body.origin, "agent",
                "\(mode) must record origin \"agent\", not the owner's own words"
            )
            XCTAssertEqual(body.mode, mode.rawValue)
        }
    }

    // MARK: - Pin 3: applicationName carries the real frontmost app

    /// Since Task 3 no sidecar route invents a placeholder like
    /// `"OpenType Ask"`/`"OpenType Agent"` — this field's truthfulness now
    /// rests entirely on what Swift passes in.
    func testApplicationNameIsCarriedThroughUnchanged() {
        let body = EpisodicEventRecorder.body(
            mode: .transcribe,
            rawTranscript: "x",
            correctedTranscript: "x",
            deliveredText: "x",
            selectedContext: nil,
            applicationName: "Terminal",
            conversationId: nil
        )
        XCTAssertEqual(body.applicationName, "Terminal")
    }

    /// An empty `applicationName` (Accessibility couldn't resolve the
    /// frontmost app) must not become an empty string in the wire body — the
    /// dictation history groups/filters/exports by this field, and an empty
    /// group is worse than a labeled "unknown" one. Pinned to `"Unknown app"`
    /// to match the fallback the rest of the codebase already uses for this
    /// exact situation: `ContextBridge.swift`'s
    /// `application?.localizedName ?? "Unknown app"` and the identical
    /// literal in `AgentMemoryStore.swift` and `AppModel.swift`. If a future
    /// implementation picks a different string, this test — not a comment —
    /// is what should change first.
    ///
    /// **Not the same case as `sidecar/src/memory/routes.ts`'s own
    /// `body.applicationName ?? "Unknown"`** (note: no "app"), and the two
    /// must not later be aligned to one spelling without re-reading this
    /// comment first. The route's default answers "the caller omitted the
    /// field from the POST body entirely" — a defensive fallback for a
    /// malformed/partial request that, once Swift always sends a real value,
    /// should be unreachable from the actual `/memory/events` caller. This
    /// fallback answers a different question this function is actually asked
    /// to answer every call: "Accessibility could resolve a frontmost app,
    /// but it told us nothing" — a normal, expected `CapturedContext` shape.
    /// Same idea, two different layers, two different failure modes; keep the
    /// spellings apart as evidence they are not the same guard.
    func testEmptyApplicationNameFallsBackToUnknownApp() {
        let body = EpisodicEventRecorder.body(
            mode: .transcribe,
            rawTranscript: "x",
            correctedTranscript: "x",
            deliveredText: "x",
            selectedContext: nil,
            applicationName: "",
            conversationId: nil
        )
        XCTAssertEqual(body.applicationName, "Unknown app")
    }

    // MARK: - Pin 4: conversationId present for ask/agent, absent for transcribe

    /// Restated on its own (rather than only inline above) because it is a
    /// distinct, separately-checkable claim: `transcribe` never has a
    /// conversation, `ask`/`agent` always pass the one they were dispatched
    /// with straight through.
    func testConversationIdIsPassedThroughForAskAndAgentOnly() {
        let transcribeBody = EpisodicEventRecorder.body(
            mode: .transcribe,
            rawTranscript: "x",
            correctedTranscript: "x",
            deliveredText: "x",
            selectedContext: nil,
            applicationName: "Notes",
            conversationId: nil
        )
        XCTAssertNil(transcribeBody.conversationId)

        let askBody = EpisodicEventRecorder.body(
            mode: .ask,
            rawTranscript: "问题",
            correctedTranscript: "问题",
            deliveredText: "答案",
            selectedContext: nil,
            applicationName: "Xcode",
            conversationId: 17
        )
        XCTAssertEqual(askBody.conversationId, 17)

        let agentBody = EpisodicEventRecorder.body(
            mode: .agent,
            rawTranscript: "任务",
            correctedTranscript: "任务",
            deliveredText: "已完成",
            selectedContext: nil,
            applicationName: "Xcode",
            conversationId: 23
        )
        XCTAssertEqual(agentBody.conversationId, 23)
    }

    // MARK: - Pin 5: a cancelled (or failed) run records nothing

    /// **Proposed seam, not literally in the plan's Task 5 "Interfaces"
    /// block.** The plan's given `EpisodicEventRecorder.body(...)` signature
    /// always returns a body — there is no input that means "don't record" —
    /// so the "cancelled/failed runs write nothing" rule cannot be pinned
    /// through it at all. In `AppModel.swift` today that rule lives entirely
    /// in *which lines call the write*: `runAgentDispatch`'s success branch
    /// (around line 4585) sits beside `recordAuditEvent(status: .completed)`;
    /// its `catch` branch (around line 4658, `wasCancelled` true or false)
    /// records `.cancelled`/`.failed` to the *audit* trail but must not touch
    /// `/memory/events`. That is exactly the shape of rule this kind of
    /// refactor loses silently — no test proves it "still" holds, only a
    /// comment explains why it should, and the comment is sitting in code
    /// that is being deleted (`sidecar/test/agent/cancelRoute.test.ts`, per
    /// the plan's Task 3 notes).
    ///
    /// `EpisodicEventRecorder.shouldRecord(for:)` gives the rule a pure,
    /// unit-testable home: it reuses the existing `AuditEventStatus` enum
    /// (`ImmutableAuditStore.swift`) that every one of the three call sites
    /// already has in hand at the point it decides what to write, so the
    /// intended implementation is `if EpisodicEventRecorder.shouldRecord(for:
    /// status) { /* POST /memory/events */ }` guarding all three sites
    /// uniformly, rather than "only call the write from the success branch"
    /// left as an unenforced convention repeated three times. This does not,
    /// by itself, prove `AppModel` actually calls the guard at all three
    /// sites — that is a call-site fact no test in this file can reach
    /// without a live `AppModel` (see the file-level note below) — but it
    /// does mean a future regression that flips one call site's status
    /// argument is caught here instead of shipping silently.
    func testShouldRecordOnlyForCompletedStatus() {
        XCTAssertTrue(EpisodicEventRecorder.shouldRecord(for: .completed))
        XCTAssertFalse(
            EpisodicEventRecorder.shouldRecord(for: .cancelled),
            "A cancelled run must not be recorded — teaching the memory layer "
                + "from work the user abandoned fills it with results nobody accepted."
        )
        XCTAssertFalse(EpisodicEventRecorder.shouldRecord(for: .failed))
        // `.recognized` and `.corrected` are mid-session audit events (the
        // Review correction loop), never the moment a body is built at all —
        // included for completeness, not because either is a live call site.
        XCTAssertFalse(EpisodicEventRecorder.shouldRecord(for: .recognized))
        XCTAssertFalse(EpisodicEventRecorder.shouldRecord(for: .corrected))
    }
}

// MARK: - What this file could not pin, and why (report these, don't silently drop them)
//
// 1. **Ordering** (episodic write happens strictly after the answer exists,
//    never at dispatch). This is a fact about *when in `AppModel`'s control
//    flow* a line of code runs relative to a network response — `SidecarClient`
//    is a concrete `final class` with no protocol/mock seam (see
//    `Sources/OpenType/SidecarClient.swift:190`), and `AppModel.init` has
//    side effects that make it uninstantiable in a plain XCTest target (the
//    same reason `LearningLoop.swift`'s doc comment gives for keeping its own
//    logic pure and screen-free). There is no way to drive `runAskDispatch`/
//    `runAgentDispatch` end-to-end here and observe call order. The only
//    testable proxy is the one in Pin 5: since `shouldRecord(for:)` only ever
//    admits `.completed`, and every `.completed` `recordAuditEvent` call in
//    `AppModel.swift` is already *itself* only reachable after a response
//    has been decoded (`response.result` / the ASR `result` local), placing
//    the `/memory/events` POST beside that exact line is sufficient — but
//    that placement is a code-review fact for stage 4, not something this
//    suite can assert.
//
// 2. **`effectiveInput`.** `EpisodicEventBody` has an `effectiveInput:
//    String?` field that `body(...)` still has no parameter for. Left alone
//    deliberately, unlike `correctedTranscript`: `sidecar/src/memory/db.ts`
//    declares `correctedTranscript TEXT NOT NULL` (a real, always-meaningful
//    value) but `effectiveInput TEXT` (nullable), and
//    `sidecar/src/memory/routes.ts` defaults a missing one to plain `null`
//    (`body.effectiveInput ?? null`) — a legitimate "this mode/session has
//    none" rather than a safety net papering over a value that should exist.
//    Not in scope for this pass; flagging so it isn't mistaken for the same
//    kind of gap `correctedTranscript` was.
