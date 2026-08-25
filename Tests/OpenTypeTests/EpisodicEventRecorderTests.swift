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
    /// `EpisodicEventRecorder.shouldRecord(for:keepHistory:)` gives the rule
    /// a pure, unit-testable home: it reuses the existing `AuditEventStatus`
    /// enum (`ImmutableAuditStore.swift`) that every one of the four call
    /// sites already has in hand at the point it decides what to write, so
    /// the intended implementation is `if EpisodicEventRecorder.shouldRecord(
    /// for: status, keepHistory: configuration.keepHistory) { /* POST
    /// /memory/events */ }` guarding all four sites uniformly, rather than
    /// "only call the write from the success branch, and only when the user
    /// hasn't opted out" left as an unenforced convention repeated four
    /// times. This does not, by itself, prove `AppModel` actually calls the
    /// guard at all four sites — that is a call-site fact no test in this
    /// file can reach without a live `AppModel` (see the file-level note
    /// below) — but it does mean a future regression that flips one call
    /// site's status argument, or that forgets to thread `keepHistory`
    /// through, is caught here instead of shipping silently.
    ///
    /// **`keepHistory` (added for the 2026-08-25 regression fix).** Before
    /// this fix, `shouldRecord` took only `status` — there was no parameter
    /// through which "the user turned history off" could be expressed at
    /// all, even though the Settings row's own subtitle
    /// ("关闭后不再写入听写记录" / "When off, no dictation records are
    /// written") promised exactly that. Commit `a07c1d0` deleted the local
    /// `HistoryStore` that `keepHistory` used to gate, and nothing else ever
    /// read the setting again, so a user who turned it off kept being
    /// recorded regardless — and, since this same batch made those records
    /// injectable into every Ask/Agent prompt (§3.2/§3.4 of the design doc),
    /// an explicit "don't keep my dictation" preference was being overridden
    /// at exactly the moment the product started sending dictation to a
    /// model. `keepHistory` is added as a second **required** parameter
    /// (no default) rather than an optional one, specifically so the
    /// existing call in `AppModel.recordEpisodicEvent(for:_:)` cannot
    /// compile without supplying an answer — see the file-level note for why
    /// that is the only enforcement a pure function can offer, and why it is
    /// nonetheless enough here: all four `AppModel` call sites already funnel
    /// through that one private method (lines ~2520, ~4025, ~4377, ~4724),
    /// so a single updated call site closes the gap for all of them.
    ///
    /// **`isPractice` (added alongside `keepHistory` in the same fix, after
    /// the stage-4 reviewer of `a07c1d0` independently found the same class
    /// of regression on a second gate).** Every pre-migration write was
    /// gated `if configuration.keepHistory, !practice { history.add(...) }`
    /// — three of the four sites, `practice` being the guided first-run
    /// onboarding exercise (`AppModel.togglePracticeDictation()` forces
    /// `mode: .ask, practice: true`) — and neither survived the migration to
    /// `EpisodicEventRecorder`. This one may be worse than `keepHistory`
    /// alone: a practice delivery is by definition not real intent (two
    /// throwaway sentences read aloud during onboarding), but once recorded
    /// it becomes eligible for the same recent-context injection into every
    /// Ask/Agent prompt (§3.2/§3.4) and the same `opentype__read_history`
    /// tool as a real dictation — landing in the exact minutes the user is
    /// forming an impression of whether the product understands them. Made
    /// required for the same reason as `keepHistory`: the one production
    /// caller cannot compile without supplying an answer.
    func testShouldRecordOnlyForCompletedStatusWhenHistoryIsKeptAndNotPractice() {
        // `keepHistory` defaults to `true` (`AppConfiguration.swift`'s
        // `?? true`), so this is the behaviour every existing user sees
        // today and must keep seeing unchanged by this fix.
        XCTAssertTrue(
            EpisodicEventRecorder.shouldRecord(for: .completed, keepHistory: true, isPractice: false)
        )
        XCTAssertFalse(
            EpisodicEventRecorder.shouldRecord(for: .cancelled, keepHistory: true, isPractice: false),
            "A cancelled run must not be recorded — teaching the memory layer "
                + "from work the user abandoned fills it with results nobody accepted."
        )
        XCTAssertFalse(
            EpisodicEventRecorder.shouldRecord(for: .failed, keepHistory: true, isPractice: false)
        )
        // `.recognized` and `.corrected` are mid-session audit events (the
        // Review correction loop), never the moment a body is built at all —
        // included for completeness, not because either is a live call site.
        XCTAssertFalse(
            EpisodicEventRecorder.shouldRecord(for: .recognized, keepHistory: true, isPractice: false)
        )
        XCTAssertFalse(
            EpisodicEventRecorder.shouldRecord(for: .corrected, keepHistory: true, isPractice: false)
        )
    }

    // MARK: - Pin 6: keepHistory off silences every status, including .completed

    /// This is half of the fix. Before it, `.completed` was the one status
    /// that always recorded, unconditionally. With history off, `.completed`
    /// must join every other status in recording nothing — looping over the
    /// full `AuditEventStatus` enum (not just asserting `.completed` alone)
    /// checks that turning history off actually closes the gate for
    /// everything, rather than merely adding a third special case next to
    /// `.completed`'s existing carve-out. `isPractice` is held at `false`
    /// throughout so this pin isolates the `keepHistory` dimension alone —
    /// Pin 7 below is the analogous isolation for `isPractice`.
    ///
    /// This one function is mode-agnostic by construction — `shouldRecord`
    /// has no `InputMode` parameter — so "nothing records, for all three
    /// modes" (transcribe/ask/agent) follows directly from this single test,
    /// not from three separate mode-specific ones: every one of the four
    /// `AppModel` call sites (one transcribe, one Review-commit transcribe,
    /// one ask, one agent) reaches the identical `shouldRecord` check with
    /// the identical `keepHistory` value, so there is no per-mode branch
    /// left for a test to distinguish. `testAskAndAgentHaveNoDictionaryStageSoRawEqualsCorrected`
    /// above shows the analogous pattern for `body(...)`, where mode *does*
    /// change the output and a per-mode loop is the only way to pin it —
    /// this is the contrasting case where it deliberately does not.
    func testKeepHistoryOffRecordsNothingRegardlessOfStatus() {
        for status in [
            AuditEventStatus.completed, .cancelled, .failed, .recognized, .corrected,
        ] {
            XCTAssertFalse(
                EpisodicEventRecorder.shouldRecord(for: status, keepHistory: false, isPractice: false),
                "keepHistory off must silence \(status), including .completed, which "
                    + "used to always record regardless of the setting"
            )
        }
    }

    // MARK: - Pin 7: a practice session never records, regardless of status or keepHistory

    /// The second half of the fix, and the one the team lead flagged as
    /// possibly worse than the first: `isPractice` off (i.e. a real session)
    /// is required for a `.completed`/`keepHistory: true` delivery to
    /// record, exactly the mirror of Pin 6's `keepHistory` isolation. Looped
    /// over every status *and* both `keepHistory` values, unlike Pin 6,
    /// because the failure mode being guarded against is different: Pin 6
    /// guards against "history off doesn't actually override `.completed`";
    /// this pin guards against "practice recording could still slip through
    /// if the user happens to also have history on, or happens to be in a
    /// state that itself would have refused anyway" — i.e. that `isPractice`
    /// closes the gate *on its own*, not only in combination with some other
    /// gate already being closed.
    func testPracticeNeverRecordsRegardlessOfStatusOrKeepHistory() {
        for status in [
            AuditEventStatus.completed, .cancelled, .failed, .recognized, .corrected,
        ] {
            for keepHistory in [true, false] {
                XCTAssertFalse(
                    EpisodicEventRecorder.shouldRecord(
                        for: status, keepHistory: keepHistory, isPractice: true
                    ),
                    "a practice session must never record (status: \(status), "
                        + "keepHistory: \(keepHistory))"
                )
            }
        }
    }

    // MARK: - Pin 8: all three gates refuse independently

    /// Pins 6 and 7 each isolate one gate — status/`keepHistory` held open
    /// while `keepHistory`/`isPractice` (respectively) is swept through
    /// every value they take. This test is the cross-check that ties all
    /// three together, the three-gate extension of what an earlier pass of
    /// this file pinned for status/`keepHistory` alone: each of the first
    /// three assertions below closes exactly one gate while leaving the
    /// other two at their most permissive values (`.completed`, `keepHistory:
    /// true`, `isPractice: false` — the one combination Pin 5's first
    /// assertion proves records) — proving that gate refuses **on its own**,
    /// not merely in combination with another gate that also happens to be
    /// closed. Pins 6/7 already cover "this gate closed, with one *other*
    /// dimension varied through every value, third gate held open" one pair
    /// at a time; what only this test proves is that no implementation could
    /// pass those pairwise sweeps by, say, merging any two gates with `||`
    /// or silently dropping a third gate's check entirely — a mistake like
    /// that only surfaces when the other two gates are held open
    /// *simultaneously*, which Pins 6/7 never do (each always holds the
    /// *third* dimension fixed at its permissive value while sweeping only
    /// one other). The last four assertions round out the truth table (any
    /// two gates closed together; all three closed together) so the full
    /// 2×2×2 cube is covered across this test and Pins 5/6/7, not just the
    /// single-gate corners.
    func testAllThreeGatesRefuseIndependently() {
        // Baseline: every gate open is the one case that must record.
        XCTAssertTrue(
            EpisodicEventRecorder.shouldRecord(for: .completed, keepHistory: true, isPractice: false)
        )

        // Each gate, closed alone.
        XCTAssertFalse(
            EpisodicEventRecorder.shouldRecord(for: .cancelled, keepHistory: true, isPractice: false),
            "status alone must refuse, even with keepHistory on and isPractice off"
        )
        XCTAssertFalse(
            EpisodicEventRecorder.shouldRecord(for: .completed, keepHistory: false, isPractice: false),
            "keepHistory alone must refuse, even with status .completed and isPractice off"
        )
        XCTAssertFalse(
            EpisodicEventRecorder.shouldRecord(for: .completed, keepHistory: true, isPractice: true),
            "isPractice alone must refuse, even with status .completed and keepHistory on"
        )

        // Any two gates closed together.
        XCTAssertFalse(
            EpisodicEventRecorder.shouldRecord(for: .cancelled, keepHistory: false, isPractice: false)
        )
        XCTAssertFalse(
            EpisodicEventRecorder.shouldRecord(for: .cancelled, keepHistory: true, isPractice: true)
        )
        XCTAssertFalse(
            EpisodicEventRecorder.shouldRecord(for: .completed, keepHistory: false, isPractice: true)
        )

        // All three gates closed together.
        XCTAssertFalse(
            EpisodicEventRecorder.shouldRecord(for: .cancelled, keepHistory: false, isPractice: true)
        )
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
//
// 3. **`keepHistory`/`isPractice` call-site facts (2026-08-25 regression
//    fix).** Pins 5-8 prove `shouldRecord(for:keepHistory:isPractice:)`'s own
//    truth table is correct in isolation. They cannot prove
//    `AppModel.recordEpisodicEvent(for:_:)` (the guard's one caller,
//    `AppModel.swift`:340-341) actually threads `configuration.keepHistory`
//    and the right per-site `isPractice` value — as opposed to a stray
//    `true`/`false` literal, or arguments swapped with each other or with
//    `status` — into those two parameters at that call site. That is a
//    call-site fact, same category as item 1 above, and for the same reason
//    (no instantiable `AppModel` in this test target) this file cannot reach
//    it. Stage 4 must read `AppModel.swift`:340-341 by hand and confirm
//    `keepHistory: configuration.keepHistory`, and must separately confirm
//    (item 4 below) what each of the four call sites passes for
//    `isPractice`.
//
//    Separately: this file also cannot prove the Settings row's subtitle
//    (`SettingsViews2.swift`:566-570, "关闭后不再写入听写记录" / "When off,
//    no dictation records are written") is *accurate* once this fix lands.
//    It becomes true again for `transcribe` — that was always the subtitle's
//    literal claim — but the same gate, once wired at all four call sites,
//    also silences the `ask`/`agent` episodic writes those two modes now
//    perform (added in this same design batch, §3.2). The subtitle predates
//    that addition and says nothing about it, so a user reading only the
//    subtitle would not learn that turning history off also stops their
//    questions and agent tasks from being recorded (and, per §3.4/§3.7,
//    from ever being eligible for recent-context injection or
//    consolidation). Left as a documentation gap for the team lead to
//    decide on, not fixed here — this stage does not touch UI strings.
//
// 4. **Does the Review-commit call site have a `practice` value at all?**
//    Checked by hand against `AppModel.swift` (both the current file and
//    `a07c1d0^`'s pre-migration version, since the pre-migration Review
//    write is the shape being restored): no. `commitReview()` has no local
//    `practice`/`isPracticeSession` read at all — it hardcodes
//    `lastResultWasPractice = false` unconditionally, both before and after
//    `a07c1d0` (`AppModel.swift`:2471 today, matching `a07c1d0^`'s
//    equivalent line). That is not an accident of this one line: a Review
//    session is architecturally unreachable from the practice flow.
//    `togglePracticeDictation()` (`AppModel.swift`:907-924) hardcodes
//    `beginRecording(context:, mode: .ask, practice: true)` — practice
//    sessions are *always* `.ask`, never `.transcribe` — and Review is a
//    `TranscribeVariant`, reachable only through `.transcribe` mode
//    (confirmed by the doc comment at `AppModel.swift`:1766, "the practice
//    flow forces `.ask`"). `reviewSession`/`commitReview()` therefore cannot
//    exist for a practice recording in the first place, which is why the
//    pre-migration Review write at `a07c1d0^`'s `AppModel.swift`:2398 was
//    gated only on `configuration.keepHistory` — no `!practice` check — while
//    the other three pre-migration sites all had `keepHistory, !practice`.
//    Conclusion: that asymmetry was **deliberate, not an oversight**, and
//    stage 3 should pass a literal `isPractice: false` at the Review call
//    site (`AppModel.swift`'s current ~line 2520), mirroring the existing
//    `lastResultWasPractice = false` literal already sitting a few lines
//    above it in `commitReview()` — not a local `practice` variable, because
//    none exists there to read.
//
//    **Why reading `isPracticeSession` (`AppModel.swift`:56) at
//    `commitReview()` time would be actively wrong, not just unnecessary**
//    (worth recording since it is the one tempting-looking alternative to
//    the literal): `isPracticeSession` is a real `AppModel` property,
//    readable from `commitReview()`. But it is cleared in `process(audioURL:)`'s
//    `defer` — the same cleanup block that deletes that recording's ephemeral
//    audio file — as soon as recognition finishes and staging (or delivery)
//    begins, for every session, practice or not. A Review commit happens long
//    after that: the panel opens, the user edits at their own pace, then
//    Cmd+Return fires `commitReview()` on a wholly separate, later turn of
//    the run loop. A read there would evaluate to `false` because of *that
//    timing*, not because of the architectural invariant traced above — it
//    would look like a live check while being guaranteed `false` for an
//    unrelated reason, and if a practice exercise in dictation mode were
//    ever added later, it would keep silently reading `false`: protection
//    that looks present but was never actually there. The literal is honest
//    about being a constant; a property read here would not be.
//
//    (Deliberately not citing a line number for that `defer` — three
//    different ones were cited for this exact fact in one evening. The
//    function name plus what it does is the anchor that survives an edit
//    above it; a line number is wrong the moment anyone inserts one.)
//
//    If practice ever *does* become reachable in dictation mode, the fix is
//    not to read `isPracticeSession` at commit time — it is to capture the
//    value into `ReviewSession` (`AppModel.swift`:4968, `private struct`) at
//    `beginReviewSession()` (`AppModel.swift`:1920), the same way that type
//    already captures `rawTranscript` there for exactly this reason (its own
//    doc comment: "the true raw ASR output survives long enough for
//    `commitReview()`'s episodic-event write to reach it" — `AppModel.swift`
//    :4972-4977). `isPracticeSession` at `beginReviewSession()` time is the
//    live value; `isPracticeSession` at `commitReview()` time is not.
