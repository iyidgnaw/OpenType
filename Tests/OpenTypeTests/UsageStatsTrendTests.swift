import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for **D-3** — 「收敛趋势」
/// (`docs/superpowers/specs/2026-08-15-product-batch-plan.md` §D-3, motivated by
/// `docs/reviews/2026-08-15-product-review.md` §1).
///
/// The statistics panel prints corrections-per-100-words as a single number for
/// this week, with 「上周 N」 under it. But the question the learning loop poses
/// is not 「how many corrections did I make」, it is 「**is this falling**」 — the
/// whole promise of P0-1/P0-2 is that the dictionary makes the next
/// transcription better, and two numbers a week apart is the weakest possible
/// way to show a slope. This is the third of the loop's three silent exits: the
/// product improves, and the panel reports it as a number that also moves when
/// the user simply talked more.
///
/// ## Expected shape (Stage 3 creates it; nothing here builds it)
///
/// One new field on `UsageStats.Summary`, computed in the same pass as
/// `dailyWords`:
///
///     /// Seven rolling days, oldest first. `nil` = nothing was delivered
///     /// that day, which is not the same as a day with a rate of zero.
///     let dailyCorrectionsPerHundredWords: [Double?]
///
/// **A deliberate deviation from §D-3's wording**, flagged here rather than
/// done quietly: the plan sketches a standalone
/// `correctionsPerHundredWordsTrend(days:) -> [(date, value)]`. It is pinned as
/// a `Summary` field instead, for the two reasons the existing code already
/// gives itself. `summarize` computes every figure in one walk on purpose (「a
/// second walk over the file to compute one ratio would double the cost of a
/// panel whose whole job is to be cheap enough to recompute on every
/// appearance」), and `dailyWords` already established that a seven-slot,
/// oldest-first array is how this file expresses a week — the view labels bar
/// *i* from `now - (6 - i) * 86400` without the summary needing to know what a
/// calendar is. A parallel API with its own `days:` parameter and its own dates
/// would be a second bucketing rule for the same strip, and the two would drift.
///
/// ## Pinned decision — `nil` is a day that delivered nothing
///
/// The cover asks for three cases and they must stay distinguishable:
///
///  - a day with words **and** corrections → the ratio,
///  - a day with words and **no** corrections → `0`, a real, earned zero, which
///    is the best day the product can have and must be drawn on the line,
///  - a day with **nothing** → `nil`, drawn as a gap.
///
/// Collapsing the last two onto `0` is the failure mode worth naming: a user who
/// took the weekend off would see the line dive to zero on Saturday and spike on
/// Monday, which reads as "it got worse when I came back" rather than "there is
/// no data here". This mirrors `previousCorrectionsPerHundredWords`, which is
/// already `nil`-able for exactly this reason.
///
/// ## The accounting edges that must survive
///
/// `UsageStatsTests` and `docs/superpowers/specs/2026-08-09-current-system-state.md`
/// §11 pin that rows lacking the optional `recordingEndedAt` are **excluded**
/// from timing figures rather than counted as zero. The trend is not a timing
/// figure — it is words and corrections — so those rows must keep contributing
/// to it in full while continuing to be absent from `averageEndToEndLatency`.
/// Both halves of that are asserted below, in one test, because the tempting
/// implementation ("skip rows we can't time") would silently drop a mid-week
/// upgrader's older days from the very trend they are looking at.
final class UsageStatsTrendTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let day: TimeInterval = 86_400

    // MARK: - Shape

    func testTheTrendIsAlwaysSevenDaysOldestFirst() {
        let summary = UsageStats.summarize(events: [], now: now)

        XCTAssertEqual(summary.dailyCorrectionsPerHundredWords.count, 7)
        XCTAssertEqual(
            summary.dailyCorrectionsPerHundredWords,
            [nil, nil, nil, nil, nil, nil, nil]
        )
        XCTAssertEqual(
            UsageStats.Summary.empty.dailyCorrectionsPerHundredWords,
            [nil, nil, nil, nil, nil, nil, nil]
        )
    }

    func testTheTrendUsesTheSameBucketsAsTheWordStrip() {
        // The two are drawn on the same seven columns, so index *i* has to mean
        // the same day in both. A trend bucketed even one slot differently would
        // put a spike under the wrong bar and nothing in the UI would say so.
        let sixDaysAgo = UUID()
        let today = UUID()
        let events =
            session(sixDaysAgo, at: now - 6 * day, text: String(repeating: "字", count: 100), corrections: 3)
            + session(today, at: now - 60, text: String(repeating: "词", count: 50), corrections: 1)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.dailyWords, [100, 0, 0, 0, 0, 0, 50])
        XCTAssertEqual(
            summary.dailyCorrectionsPerHundredWords,
            [3, nil, nil, nil, nil, nil, 2]
        )
    }

    func testTheBucketBoundaryIsExactlyTwentyFourHoursBeforeNow() {
        // Mirrors `testTheBucketBoundaryIsExactlyTwentyFourHoursBeforeNow` in
        // `UsageStatsTests`: exactly 24h old is yesterday's column, one second
        // younger is today's. Restated here because a trend that rounded
        // differently would disagree with the bars beside it.
        let onBoundary = UUID()
        let justInside = UUID()
        let events =
            session(onBoundary, at: now - day, text: String(repeating: "字", count: 100), corrections: 4)
            + session(justInside, at: now - day + 1, text: String(repeating: "词", count: 100), corrections: 1)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(
            summary.dailyCorrectionsPerHundredWords,
            [nil, nil, nil, nil, nil, 4, 1]
        )
    }

    // MARK: - The three cases the line has to tell apart

    func testADayWithWordsButNoCorrectionsIsZeroNotAGap() {
        // The best day the product can have. It is a point on the line, not a
        // hole in it — a gap would make a perfect day look like an idle one.
        let request = UUID()
        let events = session(
            request,
            at: now - 2 * day,
            text: String(repeating: "字", count: 120),
            corrections: 0
        )

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(
            summary.dailyCorrectionsPerHundredWords,
            [nil, nil, nil, nil, 0, nil, nil]
        )
    }

    func testADayWithNothingIsAGapNotZero() {
        // Asserted against the neighbouring real zero so the two cannot be
        // conflated by an implementation that defaults the array to zeroes.
        let request = UUID()
        let events = session(
            request,
            at: now - 3 * day,
            text: String(repeating: "字", count: 100),
            corrections: 0
        )

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.dailyCorrectionsPerHundredWords[3], 0)
        XCTAssertNil(summary.dailyCorrectionsPerHundredWords[2])
        XCTAssertNil(summary.dailyCorrectionsPerHundredWords[4])
    }

    func testADayThatOnlyCancelledOrFailedIsAGap() {
        // Cancelled and failed sessions are not deliveries anywhere else in
        // this file, and a day the user threw away has no rate — not a perfect
        // one.
        let cancelled = UUID()
        let failed = UUID()
        let events = [
            makeEvent(.recognized, requestId: cancelled, at: now - 2 * day - 10,
                      mode: .transcribe, rawTranscript: "取消掉的一段话"),
            makeEvent(.corrected, requestId: cancelled, at: now - 2 * day - 5,
                      mode: .transcribe, rawTranscript: "改一下",
                      result: "取消掉的一段话"),
            makeEvent(.cancelled, requestId: cancelled, at: now - 2 * day,
                      mode: .transcribe, rawTranscript: "取消掉的一段话"),
            makeEvent(.recognized, requestId: failed, at: now - 2 * day - 10,
                      mode: .ask, rawTranscript: "this one failed"),
            makeEvent(.failed, requestId: failed, at: now - 2 * day,
                      mode: .ask, rawTranscript: "this one failed"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(
            summary.dailyCorrectionsPerHundredWords,
            [nil, nil, nil, nil, nil, nil, nil]
        )
    }

    func testADayThatDeliveredOnlyEmptyTranscriptsIsZeroRatherThanNaN() throws {
        // The same divide-by-zero guard the weekly figures carry: it delivered,
        // so there is a rate; the rate is 0. A NaN here would propagate into
        // whatever `Path` the view draws and take the whole line with it.
        let request = UUID()
        let events = [
            makeEvent(.recognized, requestId: request, at: now - day - 20,
                      mode: .transcribe, rawTranscript: ""),
            makeEvent(.corrected, requestId: request, at: now - day - 10,
                      mode: .transcribe, rawTranscript: "改一下", result: ""),
            makeEvent(.completed, requestId: request, at: now - day,
                      mode: .transcribe, rawTranscript: "", result: ""),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        let value = try XCTUnwrap(summary.dailyCorrectionsPerHundredWords[5])
        XCTAssertEqual(value, 0, accuracy: 1e-9)
        XCTAssertFalse(value.isNaN)
        XCTAssertTrue(value.isFinite)
    }

    // MARK: - A user with less than a week of history

    func testAFirstDayUserGetsOnePointAndSixGaps() {
        // Installed today: one real value at the young end, and six days that
        // predate the install drawn as gaps rather than as a flat zero line
        // implying a week of flawless recognition.
        let request = UUID()
        let events = session(
            request,
            at: now - 3_600,
            text: String(repeating: "字", count: 200),
            corrections: 5
        )

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(
            summary.dailyCorrectionsPerHundredWords,
            [nil, nil, nil, nil, nil, nil, 2.5]
        )
        XCTAssertNil(summary.previousCorrectionsPerHundredWords)
    }

    func testASingleDaysTrendPointEqualsTheWeeklyFigure() throws {
        // With one day of data the line and the headline are the same
        // measurement, so they must agree — this is what catches a trend that
        // divides by the wrong denominator (deliveries, or the week's words
        // instead of the day's).
        let request = UUID()
        let events = session(
            request,
            at: now - 600,
            text: String(repeating: "字", count: 70),
            corrections: 3
        )

        let summary = UsageStats.summarize(events: events, now: now)

        let point = try XCTUnwrap(summary.dailyCorrectionsPerHundredWords[6])
        XCTAssertEqual(point, summary.correctionsPerHundredWords, accuracy: 1e-9)
        XCTAssertEqual(summary.correctionsPerHundredWords, 300.0 / 70.0, accuracy: 1e-9)
    }

    func testTheWindowStartInstantLandsInTheOldestBucket() {
        // The window is inclusive at `now - 7d`, so that instant has a column to
        // live in — otherwise a session counts toward the weekly rate while
        // being invisible on the line drawn beside it.
        let request = UUID()
        let events = session(
            request,
            at: now - 7 * day,
            text: String(repeating: "字", count: 100),
            corrections: 2
        )

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(
            summary.dailyCorrectionsPerHundredWords,
            [2, nil, nil, nil, nil, nil, nil]
        )
    }

    // MARK: - The accounting edges recorded in current-state §11

    func testRowsWithoutARecordingTimestampStillCountTowardTheTrend() throws {
        // The edge this cover exists to protect. `recordingEndedAt` is optional
        // and old rows lack it; those rows are excluded from *timing* figures
        // and from nothing else. A trend that dropped them would erase the
        // early days of any user who upgraded mid-week — precisely the stretch
        // that would show the improvement.
        let legacy = UUID()
        let modern = UUID()
        let modernText = String(repeating: "词", count: 100)
        var events = session(
            legacy,
            at: now - 4 * day,
            text: String(repeating: "字", count: 100),
            corrections: 4
        )
        events += [
            makeEvent(.recognized, requestId: modern, at: now - 62,
                      mode: .transcribe, rawTranscript: modernText,
                      recordingEndedAt: now - 65),
            makeEvent(.completed, requestId: modern, at: now - 60,
                      mode: .transcribe, rawTranscript: modernText,
                      result: modernText),
            // Through P0-3's post-delivery window, so it does not disqualify the
            // measured span (`UsageStatsTests` pins that distinction).
            makeEvent(.corrected, requestId: modern, at: now - 55,
                      mode: .transcribe, rawTranscript: "改一下", result: modernText),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        // Both days are on the line…
        XCTAssertEqual(
            summary.dailyCorrectionsPerHundredWords,
            [nil, nil, 4, nil, nil, nil, 1]
        )
        XCTAssertEqual(summary.dailyWords, [0, 0, 100, 0, 0, 0, 100])
        // …while the timing figure still sees only the row that can express a
        // span, rather than averaging the untimed one in as zero.
        XCTAssertEqual(try XCTUnwrap(summary.averageEndToEndLatency), 5.0, accuracy: 1e-6)
    }

    func testAWeekOfUntimedRowsStillDrawsATrendWithNoLatency() {
        // The mid-upgrade extreme: nothing in the file can be timed, so the
        // latency figure is 「—」, and the trend is fully populated regardless.
        let older = UUID()
        let newer = UUID()
        let events =
            session(older, at: now - 5 * day, text: String(repeating: "字", count: 100), corrections: 6)
            + session(newer, at: now - day, text: String(repeating: "词", count: 100), corrections: 2)

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertNil(summary.averageEndToEndLatency)
        XCTAssertEqual(
            summary.dailyCorrectionsPerHundredWords,
            [nil, 6, nil, nil, nil, 2, nil]
        )
    }

    // MARK: - Attribution, matching the rest of the file

    func testASessionIsAttributedToItsDeliveryEvenWhenCorrectedAfterwards() {
        // P0-3's post-delivery window puts `.corrected` rows *after*
        // `.completed`, sometimes in the next 24-hour slice. A session belongs
        // to one column — its delivery's — so those corrections count there,
        // not in the column their own timestamp falls in. Otherwise a single
        // correction at 00:01 lands on a day with no words and produces an
        // infinite rate.
        let request = UUID()
        let deliveredAt = now - day - 30
        let events = [
            makeEvent(.recognized, requestId: request, at: deliveredAt - 10,
                      mode: .transcribe, rawTranscript: String(repeating: "字", count: 100)),
            makeEvent(.completed, requestId: request, at: deliveredAt,
                      mode: .transcribe, rawTranscript: String(repeating: "字", count: 100),
                      result: String(repeating: "字", count: 100)),
            makeEvent(.corrected, requestId: request, at: now - day + 30,
                      mode: .transcribe, rawTranscript: "改一下",
                      result: String(repeating: "字", count: 100)),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(
            summary.dailyCorrectionsPerHundredWords,
            [nil, nil, nil, nil, nil, 1, nil]
        )
        for value in summary.dailyCorrectionsPerHundredWords {
            XCTAssertFalse(value?.isInfinite ?? false)
        }
    }

    func testFutureSessionsAreExcludedFromTheTrend() {
        // Clock skew, handled the same way as everywhere else in this file.
        let future = UUID()
        let events = session(
            future,
            at: now + 60,
            text: String(repeating: "字", count: 100),
            corrections: 3
        )

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(
            summary.dailyCorrectionsPerHundredWords,
            [nil, nil, nil, nil, nil, nil, nil]
        )
    }

    func testLastWeeksSessionsDoNotAppearOnThisWeeksLine() throws {
        // The line covers the same rolling window as everything else on the
        // card; last week is represented by the single
        // `previousCorrectionsPerHundredWords` figure and nothing else.
        let lastWeek = UUID()
        let events = session(
            lastWeek,
            at: now - 9 * day,
            text: String(repeating: "字", count: 100),
            corrections: 7
        )

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(
            summary.dailyCorrectionsPerHundredWords,
            [nil, nil, nil, nil, nil, nil, nil]
        )
        XCTAssertEqual(
            try XCTUnwrap(summary.previousCorrectionsPerHundredWords),
            7,
            accuracy: 1e-9
        )
    }

    // MARK: - Fixtures

    /// One delivered session: `.recognized`, `corrections` × `.corrected`, then
    /// `.completed` at `at`. The events before the delivery are stamped just
    /// ahead of it so the whole session lands in one bucket.
    private func session(
        _ requestId: UUID,
        at completedAt: Date,
        text: String,
        corrections: Int
    ) -> [ImmutableAuditEvent] {
        var events = [
            makeEvent(.recognized, requestId: requestId, at: completedAt - 30,
                      mode: .transcribe, rawTranscript: text)
        ]
        for index in 0..<corrections {
            events.append(
                makeEvent(.corrected, requestId: requestId,
                          at: completedAt - 20 + TimeInterval(index),
                          mode: .transcribe, rawTranscript: "改一下", result: text)
            )
        }
        events.append(
            makeEvent(.completed, requestId: requestId, at: completedAt,
                      mode: .transcribe, rawTranscript: text, result: text)
        )
        return events
    }

    private func makeEvent(
        _ status: AuditEventStatus,
        id: UUID = UUID(),
        requestId: UUID,
        at createdAt: Date,
        mode: InputMode,
        rawTranscript: String,
        result: String? = nil,
        recordingEndedAt: Date? = nil
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
            recordingEndedAt: recordingEndedAt
        )
    }
}
