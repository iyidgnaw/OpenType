import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the two edges P2-12 left open in
/// `docs/superpowers/specs/2026-08-09-current-system-state.md` §11 — edge (b),
/// the trend, was closed separately (`UsageStatsTrendTests.swift`); this file
/// covers (a) and (c).
///
/// **(a) A Review-mode commit with no corrections pollutes the headline
/// wait.** `averageEndToEndLatency` already excludes a session with a
/// correction round *before* delivery (Review-panel editing time), but a
/// Review session the user committed **without** correcting anything is
/// indistinguishable from a Direct delivery in the trail as it stands today —
/// its dwell time, possibly minutes, lands in a figure labelled 「松开快捷键 →
/// 出字」.
///
/// **(c) No per-mode breakdown.** `transcribe` and `ask` are blended into one
/// headline, and a web-search `ask` (30s) against two-second dictation makes a
/// week heavy on questions read as a slow week for dictation.
///
/// ## Expected shape (Stage 3 creates it; nothing here builds it)
///
/// 1. `ImmutableAuditEvent` gains `let variant: String?`, following
///    `recordingEndedAt`'s precedent exactly (appended last, defaulted to
///    `nil`, `decodeIfPresent` so pre-existing rows that lack the key keep
///    decoding). It is stamped on the `.completed` event for `transcribe`
///    sessions with the **effective** `TranscribeVariant` — the one
///    `AppRules.transcribeVariant(for:userSelected:perAppRulesEnabled:)`
///    resolved for that delivery, not necessarily the user's raw Settings
///    choice — and `nil` for every other mode.
///
/// 2. `UsageStats.summarize` excludes a `variant == "review"` session from
///    `averageEndToEndLatency` and from the new per-mode transcribe figure
///    below, while `direct`/`tidy` keep counting exactly as before. A session
///    whose `.completed` row carries **no** `variant` at all (every row on
///    disk before this batch) keeps counting — the field cannot be
///    back-filled onto rows already written, and treating `nil` as "might be
///    Review, exclude to be safe" would blank the panel for every existing
///    user. Only the two latency figures are affected: a Review session the
///    user committed is still a real delivery with real dictated words
///    everywhere else in `Summary`.
///
/// 3. Two new optional `Summary` fields, named in this file's chosen register
///    (parallel to `averageEndToEndLatency`, which they are a per-mode split
///    of — not `averageResponseLatency`, which measures a different span):
///
///        /// The headline wait, `transcribe` sessions only — same exclusion
///        /// rules as `averageEndToEndLatency` (Review committed without a
///        /// correction, pre-delivery correction rounds), computed from
///        /// exactly the spans that figure sums. `nil`, never `0`, when
///        /// nothing measurable delivered this week.
///        let averageTranscribeEndToEndLatency: TimeInterval?
///        /// The headline wait, `ask` sessions only, same rule. `agent` is
///        /// deliberately absent — see `averageResponseLatency`'s existing
///        /// doc comment for why an agent run's duration does not belong in
///        /// any "how long did I wait" figure.
///        let averageAskEndToEndLatency: TimeInterval?
///
///    Both are computed in the same pass as `averageEndToEndLatency`, from
///    the *same* `endToEndSpans` collection point, so that a week containing
///    only one of the two modes has that mode's per-mode figure equal to the
///    headline bit-for-bit — pinned directly below, because it is the
///    property that stops the breakdown from quietly disagreeing with the
///    number printed above it.
///
/// This file duplicates small `transcribeSession`/`askSession`/`agentSession`
/// fixture builders rather than reaching into `UsageStatsTests`'s or
/// `UsageStatsTrendTests`'s private helpers, following the precedent
/// `UsageStatsTrendTests.swift` already set for itself.
final class UsageStatsPerModeLatencyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - `variant` on `ImmutableAuditEvent` (round trip)

    func testCompletedEventVariantRoundTripsThroughEncodeDecode() throws {
        let event = makeEvent(
            .completed, requestId: UUID(), at: now, mode: .transcribe,
            rawTranscript: "今天要开会", result: "今天要开会", variant: .tidy
        )

        let decoded = UsageStats.decodeEvents(jsonl: try encodeLine(event))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.variant, "tidy")
    }

    func testCompletedEventWithNoVariantEncodesAndDecodesAsNil() throws {
        // `ask`/`agent` completions, and any `transcribe` completion this
        // batch does not touch, must round-trip with `variant == nil` — this
        // is the ordinary case, not an edge one.
        let event = makeEvent(
            .completed, requestId: UUID(), at: now, mode: .ask,
            rawTranscript: "what time is it", result: "3pm", variant: nil
        )

        let decoded = UsageStats.decodeEvents(jsonl: try encodeLine(event))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded.first?.variant)
    }

    func testHistoricalRowsWithoutTheVariantKeyStillDecode() throws {
        // Mirrors `testHistoricalRowsWithoutTheRecordingTimestampKeyStillDecode`
        // in `UsageStatsTests`: `audit-events.v1.jsonl` is append-only, so
        // every row written before this field existed genuinely lacks the
        // key (not a JSON `null`) and must keep decoding, with
        // `variant == nil`, forever — there is no migration pass that will
        // ever touch these rows.
        let event = makeEvent(
            .completed, requestId: UUID(), at: now, mode: .transcribe,
            rawTranscript: "旧数据", result: "旧数据"
        )
        let legacyLine = try lineWithoutVariant(event)
        XCTAssertFalse(
            legacyLine.contains("\"variant\""),
            "fixture must actually be missing the key"
        )

        let decoded = UsageStats.decodeEvents(jsonl: legacyLine)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded.first?.variant)
    }

    // MARK: - (a) Review, committed clean, no longer pollutes the headline

    func testAReviewSessionCommittedWithoutCorrectionIsExcludedFromTheHeadlineLatency() throws {
        // The gap this batch closes: a Review session with zero correction
        // rounds passes every guard `averageEndToEndLatency` had before this
        // change (it has `recordingEndedAt`, and no correction landed before
        // `.completed`), so it was indistinguishable from Direct — its
        // multi-minute reading/deciding time landed in a figure labelled
        // 「松开快捷键 → 出字」.
        let direct = UUID()
        let review = UUID()
        let events =
            transcribeSession(direct, recordingEndedAt: now - 100, latency: 2, variant: .direct)
            + transcribeSession(review, recordingEndedAt: now - 400, latency: 180, variant: .review)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageEndToEndLatency), 2.0, accuracy: 1e-6)
    }

    func testDirectAndTidyVariantSessionsAreBothCountedInTheHeadlineLatency() throws {
        let direct = UUID()
        let tidy = UUID()
        let events =
            transcribeSession(direct, recordingEndedAt: now - 100, latency: 2, variant: .direct)
            + transcribeSession(tidy, recordingEndedAt: now - 200, latency: 4, variant: .tidy)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageEndToEndLatency), 3.0, accuracy: 1e-6)
    }

    func testASessionWithNoVariantAtAllStillCountsTowardTheHeadlineLatency() throws {
        // The case a careless implementation gets wrong: treating a missing
        // `variant` as "might be Review, exclude to be safe" would silently
        // blank the panel for every session recorded before this field
        // existed. Paired with a real Review session so the two are
        // distinguishable in one assertion — only the labelled one drops out.
        let legacy = UUID()
        let review = UUID()
        let events =
            transcribeSession(legacy, recordingEndedAt: now - 100, latency: 2, variant: nil)
            + transcribeSession(review, recordingEndedAt: now - 400, latency: 180, variant: .review)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageEndToEndLatency), 2.0, accuracy: 1e-6)
    }

    func testReviewExclusionLeavesWordsAndDeliveryCountsUntouched() {
        // Only the two latency figures are affected. A Review session the
        // user committed is still a real delivery with real dictated words —
        // dropping it from `deliveries`/`wordsDictated` too would be a second,
        // unrequested behavior change riding along with this one.
        let review = UUID()
        let events = transcribeSession(
            review, recordingEndedAt: now - 400, latency: 180, variant: .review,
            text: String(repeating: "字", count: 50)
        )

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.deliveries, 1)
        XCTAssertEqual(summary.wordsDictated, 50)
        XCTAssertNil(summary.averageEndToEndLatency)
    }

    // MARK: - (c) Per-mode breakdown

    func testTranscribeAndAskLatenciesAreBrokenOutSeparately() throws {
        let transcribe = UUID()
        let ask = UUID()
        let events =
            transcribeSession(transcribe, recordingEndedAt: now - 100, latency: 2, variant: .direct)
            + askSession(ask, recordingEndedAt: now - 200, latency: 30)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageTranscribeEndToEndLatency), 2.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(summary.averageAskEndToEndLatency), 30.0, accuracy: 1e-6)
        // The headline stays the plain mean over every qualifying span — a
        // week heavy on questions moves it, which is exactly the blending the
        // per-mode figures exist to unblend.
        XCTAssertEqual(try XCTUnwrap(summary.averageEndToEndLatency), 16.0, accuracy: 1e-6)
    }

    func testTranscribeFigureIsNilNotZeroWhenOnlyAskContributedThisWeek() throws {
        let ask = UUID()
        let events = askSession(ask, recordingEndedAt: now - 200, latency: 30)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageAskEndToEndLatency), 30.0, accuracy: 1e-6)
        XCTAssertNil(summary.averageTranscribeEndToEndLatency)
    }

    func testAskFigureIsNilNotZeroWhenOnlyTranscribeContributedThisWeek() throws {
        let transcribe = UUID()
        let events = transcribeSession(transcribe, recordingEndedAt: now - 100, latency: 2, variant: .direct)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageTranscribeEndToEndLatency), 2.0, accuracy: 1e-6)
        XCTAssertNil(summary.averageAskEndToEndLatency)
    }

    func testAWeekOfOnlyDictationMatchesTheHeadlineExactly() throws {
        // The property that stops the breakdown from quietly disagreeing with
        // the number printed above it: with nothing but `transcribe` sessions
        // this week, the two figures are drawn from the exact same spans and
        // must be the same average, not merely close.
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let events =
            transcribeSession(first, recordingEndedAt: now - 100, latency: 2, variant: .direct)
            + transcribeSession(second, recordingEndedAt: now - 5_000, latency: 5, variant: .tidy)
            + transcribeSession(third, recordingEndedAt: now - 9_000, latency: 3, variant: .direct)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(
            try XCTUnwrap(summary.averageEndToEndLatency),
            try XCTUnwrap(summary.averageTranscribeEndToEndLatency),
            accuracy: 1e-9
        )
        XCTAssertNil(summary.averageAskEndToEndLatency)
    }

    func testASessionWithNoVariantAtAllStillCountsTowardThePerModeTranscribeFigure() throws {
        // The same trap as `testASessionWithNoVariantAtAllStillCountsTowardTheHeadlineLatency`
        // above, but for the per-mode breakdown: an implementation that
        // filters the transcribe column with an allow-list
        // (`variant == "direct" || variant == "tidy"`) instead of a deny-list
        // (`variant != "review"`, `nil` included) would pass every other test
        // in this file while silently dropping every pre-this-batch row from
        // the new panel — exactly the headline/per-mode disagreement
        // `testAWeekOfOnlyDictationMatchesTheHeadlineExactly` exists to rule
        // out, just not caught there because that test never constructs a
        // `nil`-variant fixture.
        let legacy = UUID()
        let events = transcribeSession(legacy, recordingEndedAt: now - 100, latency: 2, variant: nil)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageTranscribeEndToEndLatency), 2.0, accuracy: 1e-6)
        XCTAssertEqual(
            try XCTUnwrap(summary.averageEndToEndLatency),
            try XCTUnwrap(summary.averageTranscribeEndToEndLatency),
            accuracy: 1e-9
        )
    }

    func testThePerModeTranscribeFigureAlsoExcludesReviewSessions() throws {
        // Edges (a) and (c) compose: the per-mode transcribe figure is built
        // from the same excluded-Review set as the headline, so the two keep
        // agreeing even with a Review session sitting in the file.
        let direct = UUID()
        let review = UUID()
        let events =
            transcribeSession(direct, recordingEndedAt: now - 100, latency: 2, variant: .direct)
            + transcribeSession(review, recordingEndedAt: now - 400, latency: 180, variant: .review)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageTranscribeEndToEndLatency), 2.0, accuracy: 1e-6)
        XCTAssertEqual(
            try XCTUnwrap(summary.averageEndToEndLatency),
            try XCTUnwrap(summary.averageTranscribeEndToEndLatency),
            accuracy: 1e-9
        )
    }

    func testAgentSessionsNeverAppearInEitherPerModeFigure() {
        // `agent` is dispatch-and-walk-away and is already excluded from the
        // headline for that reason (`averageResponseLatency`'s doc comment);
        // it must not leak into either breakdown column instead.
        let agent = UUID()
        let events = agentSession(agent, recordingEndedAt: now - 100, latency: 400)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertNil(summary.averageTranscribeEndToEndLatency)
        XCTAssertNil(summary.averageAskEndToEndLatency)
        XCTAssertNil(summary.averageEndToEndLatency)
    }

    func testEmptySummaryHasNilPerModeLatencies() {
        XCTAssertNil(UsageStats.Summary.empty.averageTranscribeEndToEndLatency)
        XCTAssertNil(UsageStats.Summary.empty.averageAskEndToEndLatency)

        let summary = UsageStats.summarize(events: [], now: now)
        XCTAssertNil(summary.averageTranscribeEndToEndLatency)
        XCTAssertNil(summary.averageAskEndToEndLatency)
    }

    // MARK: - Fixtures

    /// One delivered `transcribe` session: `.recognized` (carrying
    /// `recordingEndedAt`) then `.completed` `latency` seconds later, stamped
    /// with `variant` — the **effective** `TranscribeVariant` that delivered
    /// it. `variant: nil` simulates a row written before this field existed.
    private func transcribeSession(
        _ requestId: UUID,
        recordingEndedAt: Date,
        latency: TimeInterval,
        variant: TranscribeVariant?,
        text: String = "今天要开会"
    ) -> [ImmutableAuditEvent] {
        [
            makeEvent(
                .recognized, requestId: requestId, at: recordingEndedAt,
                mode: .transcribe, rawTranscript: text,
                recordingEndedAt: recordingEndedAt
            ),
            makeEvent(
                .completed, requestId: requestId,
                at: recordingEndedAt.addingTimeInterval(latency),
                mode: .transcribe, rawTranscript: text, result: text,
                variant: variant
            ),
        ]
    }

    /// One delivered `ask` session, same shape as `transcribeSession` minus
    /// the variant axis — `ask` never carries one.
    private func askSession(
        _ requestId: UUID,
        recordingEndedAt: Date,
        latency: TimeInterval,
        text: String = "what is this"
    ) -> [ImmutableAuditEvent] {
        [
            makeEvent(
                .recognized, requestId: requestId, at: recordingEndedAt,
                mode: .ask, rawTranscript: text, recordingEndedAt: recordingEndedAt
            ),
            makeEvent(
                .completed, requestId: requestId,
                at: recordingEndedAt.addingTimeInterval(latency),
                mode: .ask, rawTranscript: text, result: "an answer"
            ),
        ]
    }

    /// One delivered `agent` session — used only to pin that it stays out of
    /// both per-mode figures, exactly as it already stays out of the headline.
    private func agentSession(
        _ requestId: UUID,
        recordingEndedAt: Date,
        latency: TimeInterval,
        text: String = "do the thing"
    ) -> [ImmutableAuditEvent] {
        [
            makeEvent(
                .recognized, requestId: requestId, at: recordingEndedAt,
                mode: .agent, rawTranscript: text, recordingEndedAt: recordingEndedAt
            ),
            makeEvent(
                .completed, requestId: requestId,
                at: recordingEndedAt.addingTimeInterval(latency),
                mode: .agent, rawTranscript: text, result: "done"
            ),
        ]
    }

    private func makeEvent(
        _ status: AuditEventStatus,
        id: UUID = UUID(),
        requestId: UUID,
        at createdAt: Date,
        mode: InputMode,
        rawTranscript: String,
        result: String? = nil,
        recordingEndedAt: Date? = nil,
        variant: TranscribeVariant? = nil
    ) -> ImmutableAuditEvent {
        ImmutableAuditEvent(
            id: id,
            requestId: requestId,
            createdAt: createdAt,
            status: status,
            mode: mode,
            rawTranscript: rawTranscript,
            effectiveInput: rawTranscript,
            selectedContext: nil,
            result: result,
            provider: "mlx-whisper",
            model: nil,
            error: nil,
            supersedesEventId: nil,
            recordingEndedAt: recordingEndedAt,
            variant: variant?.rawValue
        )
    }

    /// Encodes exactly the way `ImmutableAuditStore.append` does, so the
    /// decode-side tests exercise the real on-disk shape.
    private func encodeLine(_ event: ImmutableAuditEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(event), as: UTF8.self)
    }

    /// A row as it would have been written before `variant` existed: the key
    /// is absent, not null.
    private func lineWithoutVariant(_ event: ImmutableAuditEvent) throws -> String {
        let data = Data(try encodeLine(event).utf8)
        guard var object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        object.removeValue(forKey: "variant")
        let stripped = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return String(decoding: stripped, as: UTF8.self)
    }
}
