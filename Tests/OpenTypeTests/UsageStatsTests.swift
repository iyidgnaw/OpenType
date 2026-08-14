import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for P2-12 「本地统计面板」 — a pure aggregator over
/// the existing `audit-events.v1.jsonl` trail. Nothing uploaded; `UsageStats`
/// is expected to be a pure, dependency-free namespace so the panel can be
/// tested without touching the filesystem or `AppModel`.
///
/// Expected shape (Stage 3 creates it; nothing here builds it):
///
///     enum UsageStats {
///         struct Summary {
///             let wordsDictated: Int
///             let deliveries: Int
///             let corrections: Int
///             let correctionsPerHundredWords: Double
///             let averageEndToEndLatency: TimeInterval?   // headline
///             let averageResponseLatency: TimeInterval?   // post-ASR only
///         }
///         static func summarize(events: [ImmutableAuditEvent], now: Date) -> Summary
///         static func wordCount(_ text: String) -> Int
///         static func decodeEvents(jsonl: String) -> [ImmutableAuditEvent]
///     }
///
/// It also requires ONE data-format change, approved by the product owner:
/// an optional `recordingEndedAt: Date?` on `ImmutableAuditEvent`, appended
/// **last** in the initializer and defaulted to `nil` so the ~10 existing
/// call sites in `AppModel` compile untouched. Only the `.recognized` event
/// populates it, from the moment the recording stopped — i.e. immediately
/// before `process(audioURL:)` calls `transcribeLocally(audioURL:)`.
///
/// ---
///
/// ## Pinned decision 1 — the word-counting rule
///
/// `split(separator: " ")` reports 1 for a whole Chinese sentence, and an
/// obviously-wrong number destroys trust in every other figure on the panel.
/// This suite pins a **script-aware hybrid** rule:
///
/// - Each CJK-family character (CJK ideographs + Ext A + compatibility
///   ideographs, Hiragana, Katakana, Hangul syllables) counts as **one word**,
///   matching the Chinese 「字数」 convention users already expect.
/// - Every maximal run of alphanumerics (with `'`/`’` allowed *inside* a run,
///   so `don't` stays one word) counts as **one word**.
/// - Everything else — ASCII and full-width punctuation, hyphens, whitespace,
///   emoji — is a separator and contributes nothing.
/// - A **script boundary ends a run even without whitespace**: this product's
///   normal input is 中英混排 typed with no spaces (「今天review一下PR」), so the
///   rule has to be applied per character, not per whitespace-delimited token.
///   Two hazards, both pinned below because a plausible implementation of each
///   passes every spaced example: splitting on whitespace first and counting
///   CJK characters inside each token undercounts an unspaced sentence, and
///   `Character.isNumber` is `true` for CJK numerals (一 二 十 百 千 万), so the
///   CJK test must be applied *before* the alphanumeric-run test or「3万」
///   collapses into a single word.
///
/// Deliberately NOT using `String.enumerateSubstrings(options: .byWords)`:
/// ICU applies dictionary-based segmentation to Chinese, so 「你好世界」 would
/// come back as 2 words rather than 4, and the result varies with the OS's
/// bundled ICU data — non-deterministic numbers in a trust-critical panel.
///
/// **Known limits (state these next to the number in the UI, not just here):**
/// 100 Chinese characters and 100 English words are not the same quantity of
/// speech, so a mixed-language user's total is a blend of two different units.
/// The figure is therefore only meaningfully comparable *to itself over time*
/// for a user whose language mix is stable — which is exactly what P2-12 needs
/// it for (is corrections-per-100-words falling?), but it is not a
/// cross-user or cross-language benchmark.
///
/// ## Pinned decision 2 — latency is end-to-end, and that needs a new field
///
/// What a user feels is hotkey-release → text-appears, and ASR is the dominant
/// term in it. The audit rows as they stood could not express that: the
/// earliest event a session writes, `.recognized`, is stamped *after*
/// `transcribeLocally` returns, so recording duration and ASR time left no
/// trace. A post-ASR-only figure would move for reasons nobody notices while
/// staying flat for the one they do — and, concretely, it would report nothing
/// about P0-1 now feeding an `initial_prompt` into every MLX-Whisper decode,
/// the change most likely to have made this product slower.
///
/// So the headline metric is `averageEndToEndLatency` =
/// `completed.createdAt − recognized.recordingEndedAt`, and the new optional
/// field above is what makes it computable. `averageResponseLatency`
/// (`.recognized → .completed`, `ask`/`agent` only) is kept alongside it as the
/// post-ASR breakdown — the difference between the two figures *is* the ASR
/// cost, which is the shape of the P0-1 question.
///
/// The field is safe to add precisely because `audit-events.v1.jsonl` is
/// append-only and never rewritten: it is optional, historical rows decode as
/// `nil`, and there is no migration to get wrong. Rows without it are
/// **excluded** from the latency average rather than counted as zero — counting
/// them as zero would drag the average toward a flattering lie, and is pinned
/// against below.
///
/// **Residual contaminant, stated rather than papered over:** a Review-variant
/// transcribe session's `.completed` fires when the user presses Cmd+Return, so
/// its span includes human editing time. Sessions with a correction round
/// *before* their delivery are excluded for that reason (see
/// `testEndToEndLatencyExcludesSessionsWithInSessionCorrectionRounds`), but a
/// Review session the user committed without correcting anything still counts
/// its dwell time. Closing that fully needs either the `TranscribeVariant`
/// recorded on the event or a separate `deliveredAt` stamp; out of scope here.
///
/// ## Pinned decision 3 — sessions, not events
///
/// Events are grouped by `requestId`. A session counts once, as a **delivery**,
/// iff it contains a `.completed` event; `.cancelled`/`.failed` sessions
/// contribute nothing (no words, and none of their corrections). Words come
/// from the session's *dictated* text — the `.recognized` event's
/// `rawTranscript`, falling back to the `.completed` event's `rawTranscript` —
/// never from a `.corrected` event's `rawTranscript` (that field holds the
/// spoken correction *instruction*) and never from an `ask`/`agent` answer
/// (the model wrote those words, the user did not dictate them).
///
/// ## Pinned decision 4 — the window
///
/// A rolling 7-day window, `now - 7d ... now`, inclusive at both ends. A
/// session is attributed to the timestamp of its `.completed` event, so a
/// session that straddles the boundary is counted whole, on the side its
/// delivery landed. Events dated after `now` (clock skew) are excluded.
final class UsageStatsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let day: TimeInterval = 86_400

    // MARK: - Word-counting rule

    func testWordCountTreatsEachCJKCharacterAsOneWord() {
        XCTAssertEqual(UsageStats.wordCount("你好世界"), 4)
        XCTAssertEqual(UsageStats.wordCount("今天要开会"), 5)
    }

    func testWordCountTreatsEachLatinRunAsOneWord() {
        XCTAssertEqual(UsageStats.wordCount("hello world"), 2)
        XCTAssertEqual(UsageStats.wordCount("  hello   world  "), 2)
        XCTAssertEqual(UsageStats.wordCount("123 apples"), 2)
    }

    func testWordCountHandlesMixedChineseEnglishAndDigits() {
        // 今(1) 天(1) review(1) 一(1) 下(1) PR(1)
        XCTAssertEqual(UsageStats.wordCount("今天 review 一下 PR"), 6)
        // 帮(1) 我(1) 把(1) OpenType(1) 的(1) 3(1) 个(1) bug(1) 修(1) 了(1)
        XCTAssertEqual(UsageStats.wordCount("帮我把 OpenType 的 3 个 bug 修了"), 10)
    }

    func testWordCountHandlesMixedScriptsWithNoSpacesBetweenThem() {
        // The product's actual normal case: 中英混排 typed without spaces. The
        // count must not depend on whether the user (or Whisper) inserted
        // spaces around the Latin runs.
        // 今(1) 天(1) review(1) 一(1) 下(1) PR(1)
        XCTAssertEqual(UsageStats.wordCount("今天review一下PR"), 6)
        XCTAssertEqual(
            UsageStats.wordCount("帮我把OpenType的3个bug修了"),
            UsageStats.wordCount("帮我把 OpenType 的 3 个 bug 修了"),
            "spacing must not change the count"
        )
        XCTAssertEqual(UsageStats.wordCount("帮我把OpenType的3个bug修了"), 10)
        // 这是一个(4) very long English word(4) 接在中文后面(6)
        XCTAssertEqual(
            UsageStats.wordCount("这是一个very long English word接在中文后面"),
            14
        )
    }

    func testWordCountSplitsDigitRunsFromAdjacentCJKNumerals() {
        // 万/千/百/十/一 are CJK ideographs that Swift also reports as
        // `isNumber`, so an implementation that tests for an alphanumeric run
        // before testing for CJK glues「3万」into one word.
        // 预(1) 算(1) 是(1) 3(1) 万(1) 块(1)
        XCTAssertEqual(UsageStats.wordCount("预算是3万块"), 6)
        XCTAssertEqual(UsageStats.wordCount("十一"), 2)
    }

    func testWordCountIgnoresPunctuationWhitespaceAndEmoji() {
        XCTAssertEqual(UsageStats.wordCount("你好，世界！"), 4)
        XCTAssertEqual(UsageStats.wordCount("Hello, world!"), 2)
        XCTAssertEqual(UsageStats.wordCount("……？！，。"), 0)
        XCTAssertEqual(UsageStats.wordCount("hello 👋"), 1)
    }

    func testWordCountKeepsApostrophesInsideAWordButSplitsOnHyphens() {
        // Contractions and possessives are one word — an apostrophe never
        // splits a run.
        XCTAssertEqual(UsageStats.wordCount("don't"), 1)
        XCTAssertEqual(UsageStats.wordCount("it’s Diyi's laptop"), 3)
        // A hyphen joins words that were spoken separately, so it separates.
        XCTAssertEqual(UsageStats.wordCount("state-of-the-art"), 4)
    }

    func testWordCountOfEmptyOrBlankTextIsZero() {
        XCTAssertEqual(UsageStats.wordCount(""), 0)
        XCTAssertEqual(UsageStats.wordCount("   \n\t  "), 0)
    }

    // MARK: - Words dictated this week

    func testWordsDictatedCountsTheSpokenTranscriptNotTheModelAnswer() {
        let transcribe = UUID()
        let ask = UUID()
        let events = [
            makeEvent(.recognized, requestId: transcribe, at: now - 3_600,
                      mode: .transcribe, rawTranscript: "今天要开会"),
            makeEvent(.completed, requestId: transcribe, at: now - 3_599,
                      mode: .transcribe, rawTranscript: "今天要开会",
                      result: "今天要开会"),
            makeEvent(.recognized, requestId: ask, at: now - 7_200,
                      mode: .ask, rawTranscript: "hello there world"),
            makeEvent(.completed, requestId: ask, at: now - 7_195,
                      mode: .ask, rawTranscript: "hello there world",
                      result: "a long generated answer with many many words in it"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        // 5 dictated Chinese characters + 3 spoken English words. The 10-word
        // model answer is not something the user dictated.
        XCTAssertEqual(summary.wordsDictated, 8)
        XCTAssertEqual(summary.deliveries, 2)
    }

    func testCancelledAndFailedSessionsContributeNoDictatedWords() {
        let delivered = UUID()
        let cancelled = UUID()
        let failed = UUID()
        let events = [
            makeEvent(.recognized, requestId: delivered, at: now - 600,
                      mode: .transcribe, rawTranscript: "今天要开会"),
            makeEvent(.completed, requestId: delivered, at: now - 599,
                      mode: .transcribe, rawTranscript: "今天要开会",
                      result: "今天要开会"),
            makeEvent(.recognized, requestId: cancelled, at: now - 500,
                      mode: .transcribe, rawTranscript: "这句话最后被取消了"),
            makeEvent(.cancelled, requestId: cancelled, at: now - 499,
                      mode: .transcribe, rawTranscript: "这句话最后被取消了"),
            makeEvent(.recognized, requestId: failed, at: now - 400,
                      mode: .ask, rawTranscript: "this request failed"),
            makeEvent(.failed, requestId: failed, at: now - 399,
                      mode: .ask, rawTranscript: "this request failed"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.wordsDictated, 5)
        XCTAssertEqual(summary.deliveries, 1)
    }

    // MARK: - Review sessions: one delivery, N corrections

    func testReviewSessionWithSeveralCorrectionRoundsIsOneDeliveryWithThreeCorrections() {
        // A Review session chains `.recognized` -> `.corrected` * N ->
        // `.completed` under one `requestId`. The `wordsDictated` assertion is
        // what forces the grouping: an implementation that summed every row's
        // `rawTranscript` would report 27 words for a 7-word dictation, and one
        // that summed the `.corrected` rows' transcripts would count the spoken
        // correction *instructions* as if the user had dictated them.
        let request = UUID()
        let recognizedId = UUID()
        let firstCorrection = UUID()
        let secondCorrection = UUID()
        let events = [
            makeEvent(.recognized, id: recognizedId, requestId: request,
                      at: now - 600, mode: .transcribe,
                      rawTranscript: "把这句话改一下"),
            makeEvent(.corrected, id: firstCorrection, requestId: request,
                      at: now - 590, mode: .transcribe,
                      rawTranscript: "改成开会",
                      result: "把这句话改一下", supersedes: recognizedId),
            makeEvent(.corrected, id: secondCorrection, requestId: request,
                      at: now - 580, mode: .transcribe,
                      rawTranscript: "再改一个词",
                      result: "把这段话改一下", supersedes: firstCorrection),
            makeEvent(.corrected, requestId: request, at: now - 570,
                      mode: .transcribe, rawTranscript: "最后一次",
                      result: "把这段话改好了", supersedes: secondCorrection),
            makeEvent(.completed, requestId: request, at: now - 560,
                      mode: .transcribe, rawTranscript: "把这句话改一下",
                      result: "把这段话改好了"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.deliveries, 1, "the whole chain is one delivery")
        XCTAssertEqual(summary.corrections, 3)
        // The dictated text is the original 7-character transcript — not the
        // spoken correction instructions, and not the corrected text.
        XCTAssertEqual(summary.wordsDictated, 7)
    }

    func testCorrectionsInsideACancelledSessionAreExcluded() {
        // The user threw the session away: it delivered nothing, so it belongs
        // in neither the numerator nor the denominator.
        let request = UUID()
        let recognizedId = UUID()
        let events = [
            makeEvent(.recognized, id: recognizedId, requestId: request,
                      at: now - 300, mode: .transcribe,
                      rawTranscript: "这段话改到一半不要了"),
            makeEvent(.corrected, requestId: request, at: now - 290,
                      mode: .transcribe, rawTranscript: "改一下",
                      result: "这段话改到一半不要了", supersedes: recognizedId),
            makeEvent(.corrected, requestId: request, at: now - 280,
                      mode: .transcribe, rawTranscript: "再改一下",
                      result: "这段话改到一半不要了"),
            makeEvent(.cancelled, requestId: request, at: now - 270,
                      mode: .transcribe, rawTranscript: "这段话改到一半不要了"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.deliveries, 0)
        XCTAssertEqual(summary.corrections, 0)
        XCTAssertEqual(summary.wordsDictated, 0)
        XCTAssertEqual(summary.correctionsPerHundredWords, 0, accuracy: 1e-9)
    }

    // MARK: - Corrections per 100 words (the batch's own success metric)

    func testCorrectionsPerHundredWordsOverAWeekOfSessions() {
        // 200 dictated characters, 3 corrections -> 1.5 per 100 words.
        let clean = UUID()
        let corrected = UUID()
        let cleanText = String(repeating: "字", count: 150)
        let correctedText = String(repeating: "词", count: 50)
        let recognizedId = UUID()
        let events = [
            makeEvent(.recognized, requestId: clean, at: now - 2 * day,
                      mode: .transcribe, rawTranscript: cleanText),
            makeEvent(.completed, requestId: clean, at: now - 2 * day + 1,
                      mode: .transcribe, rawTranscript: cleanText,
                      result: cleanText),
            makeEvent(.recognized, id: recognizedId, requestId: corrected,
                      at: now - day, mode: .transcribe,
                      rawTranscript: correctedText),
            makeEvent(.corrected, requestId: corrected, at: now - day + 5,
                      mode: .transcribe, rawTranscript: "改一下",
                      result: correctedText, supersedes: recognizedId),
            makeEvent(.corrected, requestId: corrected, at: now - day + 10,
                      mode: .transcribe, rawTranscript: "再改一下",
                      result: correctedText),
            makeEvent(.completed, requestId: corrected, at: now - day + 15,
                      mode: .transcribe, rawTranscript: correctedText,
                      result: correctedText),
            // A third correction arriving through the post-delivery correction
            // window (P0-3): same `requestId`, timestamped *after* `.completed`.
            makeEvent(.corrected, requestId: corrected, at: now - day + 20,
                      mode: .transcribe, rawTranscript: "还要再改",
                      result: correctedText),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.wordsDictated, 200)
        XCTAssertEqual(summary.deliveries, 2)
        XCTAssertEqual(summary.corrections, 3)
        XCTAssertEqual(summary.correctionsPerHundredWords, 1.5, accuracy: 1e-9)
    }

    func testCorrectionsPerHundredWordsIsExactForANonRoundRatio() {
        let request = UUID()
        let events = [
            makeEvent(.recognized, requestId: request, at: now - 600,
                      mode: .transcribe, rawTranscript: "把这句话改一下"),
            makeEvent(.corrected, requestId: request, at: now - 590,
                      mode: .transcribe, rawTranscript: "改一下",
                      result: "把这段话改一下"),
            makeEvent(.completed, requestId: request, at: now - 580,
                      mode: .transcribe, rawTranscript: "把这句话改一下",
                      result: "把这段话改一下"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.correctionsPerHundredWords, 100.0 / 7.0, accuracy: 1e-9)
    }

    func testCorrectionsPerHundredWordsIsZeroWhenNoWordsWereDictated() {
        // Guards the divide-by-zero: an empty transcript can still be delivered
        // (and, absurdly, corrected). The ratio must be 0, not NaN or infinity.
        let request = UUID()
        let events = [
            makeEvent(.recognized, requestId: request, at: now - 60,
                      mode: .transcribe, rawTranscript: ""),
            makeEvent(.corrected, requestId: request, at: now - 50,
                      mode: .transcribe, rawTranscript: "改一下", result: ""),
            makeEvent(.completed, requestId: request, at: now - 40,
                      mode: .transcribe, rawTranscript: "", result: ""),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.wordsDictated, 0)
        XCTAssertEqual(summary.corrections, 1)
        XCTAssertEqual(summary.correctionsPerHundredWords, 0, accuracy: 1e-9)
        XCTAssertFalse(summary.correctionsPerHundredWords.isNaN)
        XCTAssertTrue(summary.correctionsPerHundredWords.isFinite)
    }

    // MARK: - The 7-day window

    func testSessionsOutsideTheSevenDayWindowAreExcluded() {
        let inside = UUID()
        let outside = UUID()
        let events = [
            makeEvent(.recognized, requestId: inside, at: now - 6 * day,
                      mode: .transcribe, rawTranscript: "本周说的话"),
            makeEvent(.completed, requestId: inside, at: now - 6 * day + 1,
                      mode: .transcribe, rawTranscript: "本周说的话",
                      result: "本周说的话"),
            makeEvent(.recognized, requestId: outside, at: now - 30 * day,
                      mode: .transcribe, rawTranscript: "上个月说的一大段话"),
            makeEvent(.completed, requestId: outside, at: now - 30 * day + 1,
                      mode: .transcribe, rawTranscript: "上个月说的一大段话",
                      result: "上个月说的一大段话"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.wordsDictated, 5)
        XCTAssertEqual(summary.deliveries, 1)
    }

    func testDeliveryExactlyAtTheWindowStartIsIncludedAndOneSecondEarlierIsNot() {
        let onBoundary = UUID()
        let justBefore = UUID()
        let start = now - 7 * day
        let events = [
            makeEvent(.recognized, requestId: onBoundary, at: start,
                      mode: .transcribe, rawTranscript: "边界"),
            makeEvent(.completed, requestId: onBoundary, at: start,
                      mode: .transcribe, rawTranscript: "边界", result: "边界"),
            makeEvent(.recognized, requestId: justBefore, at: start - 1,
                      mode: .transcribe, rawTranscript: "界外"),
            makeEvent(.completed, requestId: justBefore, at: start - 1,
                      mode: .transcribe, rawTranscript: "界外", result: "界外"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.deliveries, 1, "the window start instant is inclusive")
        XCTAssertEqual(summary.wordsDictated, 2)
    }

    func testEventsTimestampedAfterNowAreExcluded() {
        // Clock skew or a corrected system clock must not let a "future"
        // session inflate this week's numbers.
        let future = UUID()
        let events = [
            makeEvent(.recognized, requestId: future, at: now + 60,
                      mode: .transcribe, rawTranscript: "来自未来的一句话"),
            makeEvent(.completed, requestId: future, at: now + 61,
                      mode: .transcribe, rawTranscript: "来自未来的一句话",
                      result: "来自未来的一句话"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.deliveries, 0)
        XCTAssertEqual(summary.wordsDictated, 0)
    }

    func testDeliveryExactlyAtNowIsIncluded() {
        // The other end of the same window: `now` itself is inside it, so the
        // session the user just finished is on this week's panel immediately.
        let request = UUID()
        let events = [
            makeEvent(.recognized, requestId: request, at: now - 2,
                      mode: .transcribe, rawTranscript: "刚刚说完"),
            makeEvent(.completed, requestId: request, at: now,
                      mode: .transcribe, rawTranscript: "刚刚说完",
                      result: "刚刚说完"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.deliveries, 1)
        XCTAssertEqual(summary.wordsDictated, 4)
    }

    func testStraddlingSessionIsAttributedToItsCompletionTimestamp() {
        // Started before the window opened, delivered inside it: counted whole.
        let straddling = UUID()
        // Delivered just before the window opened, then corrected inside it via
        // the post-delivery correction window: excluded whole, corrections and
        // all, so a session is never split across two weeks' figures.
        let deliveredEarlier = UUID()
        let start = now - 7 * day
        let events = [
            makeEvent(.recognized, requestId: straddling, at: start - 3_600,
                      mode: .transcribe, rawTranscript: "跨过边界的一段话"),
            makeEvent(.completed, requestId: straddling, at: start + 3_600,
                      mode: .transcribe, rawTranscript: "跨过边界的一段话",
                      result: "跨过边界的一段话"),
            makeEvent(.recognized, requestId: deliveredEarlier, at: start - 120,
                      mode: .transcribe, rawTranscript: "上周就交付了"),
            makeEvent(.completed, requestId: deliveredEarlier, at: start - 1,
                      mode: .transcribe, rawTranscript: "上周就交付了",
                      result: "上周就交付了"),
            makeEvent(.corrected, requestId: deliveredEarlier, at: start + 10,
                      mode: .transcribe, rawTranscript: "改一下",
                      result: "上周就交付好了"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.deliveries, 1)
        XCTAssertEqual(summary.wordsDictated, 8)
        XCTAssertEqual(summary.corrections, 0)
    }

    // MARK: - End-to-end latency (the headline figure)

    func testAverageEndToEndLatencyMeasuresRecordingEndToDelivery() {
        let transcribe = UUID()
        let ask = UUID()
        let events = [
            makeEvent(.recognized, requestId: transcribe, at: now - 998.5,
                      mode: .transcribe, rawTranscript: "今天要开会",
                      recordingEndedAt: now - 1_000),
            makeEvent(.completed, requestId: transcribe, at: now - 998,
                      mode: .transcribe, rawTranscript: "今天要开会",
                      result: "今天要开会"),
            makeEvent(.recognized, requestId: ask, at: now - 1_995,
                      mode: .ask, rawTranscript: "what is this",
                      recordingEndedAt: now - 2_000),
            makeEvent(.completed, requestId: ask, at: now - 1_994,
                      mode: .ask, rawTranscript: "what is this",
                      result: "an answer"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        // 2.0s and 6.0s from the moment each recording stopped.
        XCTAssertEqual(try XCTUnwrap(summary.averageEndToEndLatency), 4.0, accuracy: 1e-6)
    }

    func testEndToEndLatencyIncludesTheASRSpanNotJustThePostASRWork() {
        // The whole point of the new field: 3s of MLX-Whisper decoding is
        // invisible to `.recognized -> .completed`, and a slower decode (e.g.
        // P0-1's `initial_prompt`) has to show up in the headline number.
        let ask = UUID()
        let events = [
            makeEvent(.recognized, requestId: ask, at: now - 97,
                      mode: .ask, rawTranscript: "what is this",
                      recordingEndedAt: now - 100),
            makeEvent(.completed, requestId: ask, at: now - 96.5,
                      mode: .ask, rawTranscript: "what is this",
                      result: "an answer"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageEndToEndLatency), 3.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(summary.averageResponseLatency), 0.5, accuracy: 1e-6)
    }

    func testHistoricalRowsWithoutARecordingTimestampAreExcludedNotCountedAsZero() {
        // `audit-events.v1.jsonl` is append-only, so rows written before the
        // field existed keep decoding — they just carry no timing. Averaging
        // them in as 0s would drag the figure toward a flattering lie.
        let legacy = UUID()
        let modern = UUID()
        let events = [
            makeEvent(.recognized, requestId: legacy, at: now - 500,
                      mode: .transcribe, rawTranscript: "旧数据"),
            makeEvent(.completed, requestId: legacy, at: now - 499,
                      mode: .transcribe, rawTranscript: "旧数据", result: "旧数据"),
            makeEvent(.recognized, requestId: modern, at: now - 195,
                      mode: .transcribe, rawTranscript: "新数据",
                      recordingEndedAt: now - 200),
            makeEvent(.completed, requestId: modern, at: now - 194,
                      mode: .transcribe, rawTranscript: "新数据", result: "新数据"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageEndToEndLatency), 6.0, accuracy: 1e-6)
        // The legacy session still counts everywhere else.
        XCTAssertEqual(summary.deliveries, 2)
        XCTAssertEqual(summary.wordsDictated, 6)
    }

    func testAverageEndToEndLatencyIsNilWhenNoSessionCarriesARecordingTimestamp() {
        // A user upgrading mid-week sees "—", not "0s".
        let legacy = UUID()
        let events = [
            makeEvent(.recognized, requestId: legacy, at: now - 500,
                      mode: .transcribe, rawTranscript: "旧数据"),
            makeEvent(.completed, requestId: legacy, at: now - 499,
                      mode: .transcribe, rawTranscript: "旧数据", result: "旧数据"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertNil(summary.averageEndToEndLatency)
        XCTAssertEqual(summary.deliveries, 1)
        XCTAssertEqual(summary.wordsDictated, 3)
    }

    func testEndToEndLatencyExcludesSessionsWithInSessionCorrectionRounds() {
        // A correction round *before* delivery means the user was editing in
        // the Review panel: that span is human time, not system time. A
        // correction *after* delivery (P0-3's post-delivery window) does not
        // touch the measured span, so it must not disqualify the session.
        let review = UUID()
        let direct = UUID()
        let events = [
            makeEvent(.recognized, requestId: review, at: now - 598,
                      mode: .transcribe, rawTranscript: "慢慢改的一段话",
                      recordingEndedAt: now - 600),
            makeEvent(.corrected, requestId: review, at: now - 590,
                      mode: .transcribe, rawTranscript: "改一下",
                      result: "慢慢改的一段话"),
            makeEvent(.completed, requestId: review, at: now - 560,
                      mode: .transcribe, rawTranscript: "慢慢改的一段话",
                      result: "慢慢改好的一段话"),
            makeEvent(.recognized, requestId: direct, at: now - 298,
                      mode: .transcribe, rawTranscript: "直接听写",
                      recordingEndedAt: now - 300),
            makeEvent(.completed, requestId: direct, at: now - 297,
                      mode: .transcribe, rawTranscript: "直接听写",
                      result: "直接听写"),
            makeEvent(.corrected, requestId: direct, at: now - 290,
                      mode: .transcribe, rawTranscript: "改个词",
                      result: "直接听写好"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageEndToEndLatency), 3.0, accuracy: 1e-6)
    }

    func testLatencyFiguresIgnoreFailedAndCancelledSessions() {
        let ok = UUID()
        let failed = UUID()
        let cancelled = UUID()
        let events = [
            makeEvent(.recognized, requestId: ok, at: now - 998,
                      mode: .ask, rawTranscript: "question one",
                      recordingEndedAt: now - 1_000),
            makeEvent(.completed, requestId: ok, at: now - 995,
                      mode: .ask, rawTranscript: "question one", result: "answer"),
            makeEvent(.recognized, requestId: failed, at: now - 900,
                      mode: .ask, rawTranscript: "question two",
                      recordingEndedAt: now - 902),
            makeEvent(.failed, requestId: failed, at: now - 800,
                      mode: .ask, rawTranscript: "question two"),
            makeEvent(.recognized, requestId: cancelled, at: now - 700,
                      mode: .agent, rawTranscript: "task three",
                      recordingEndedAt: now - 703),
            makeEvent(.cancelled, requestId: cancelled, at: now - 400,
                      mode: .agent, rawTranscript: "task three"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageEndToEndLatency), 5.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(summary.averageResponseLatency), 3.0, accuracy: 1e-6)
    }

    // MARK: - Response latency (post-ASR breakdown)

    func testAverageResponseLatencyMeasuresRecognizedToCompletedForAskAndAgent() {
        let ask = UUID()
        let agent = UUID()
        let events = [
            makeEvent(.recognized, requestId: ask, at: now - 1_000,
                      mode: .ask, rawTranscript: "what is this"),
            makeEvent(.completed, requestId: ask, at: now - 996,
                      mode: .ask, rawTranscript: "what is this",
                      result: "an answer"),
            makeEvent(.recognized, requestId: agent, at: now - 2_000,
                      mode: .agent, rawTranscript: "do the thing"),
            makeEvent(.completed, requestId: agent, at: now - 1_990,
                      mode: .agent, rawTranscript: "do the thing",
                      result: "done"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageResponseLatency), 7.0, accuracy: 1e-6)
    }

    func testAverageResponseLatencyExcludesTranscribeSessions() {
        // For `transcribe` this span is either near-zero (direct: just the
        // splice) or human editing time (Review: completes on Cmd+Return).
        // Neither belongs in a "how long did the model take" figure.
        let ask = UUID()
        let review = UUID()
        let events = [
            makeEvent(.recognized, requestId: ask, at: now - 1_000,
                      mode: .ask, rawTranscript: "what is this"),
            makeEvent(.completed, requestId: ask, at: now - 994,
                      mode: .ask, rawTranscript: "what is this",
                      result: "an answer"),
            makeEvent(.recognized, requestId: review, at: now - 500,
                      mode: .transcribe, rawTranscript: "慢慢改的一段话"),
            makeEvent(.completed, requestId: review, at: now - 380,
                      mode: .transcribe, rawTranscript: "慢慢改的一段话",
                      result: "慢慢改的一段话"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(try XCTUnwrap(summary.averageResponseLatency), 6.0, accuracy: 1e-6)
    }

    func testAverageResponseLatencyIsNilWhenOnlyTranscribeSessionsExist() {
        // Absent, not zero: "0 ms" would be read as "instant".
        let request = UUID()
        let events = [
            makeEvent(.recognized, requestId: request, at: now - 500,
                      mode: .transcribe, rawTranscript: "只有听写",
                      recordingEndedAt: now - 502),
            makeEvent(.completed, requestId: request, at: now - 499,
                      mode: .transcribe, rawTranscript: "只有听写",
                      result: "只有听写"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertNil(summary.averageResponseLatency)
        // …while the end-to-end figure, which is what the panel shows, is not.
        XCTAssertEqual(try XCTUnwrap(summary.averageEndToEndLatency), 3.0, accuracy: 1e-6)
    }

    // MARK: - Empty input

    func testEmptyEventListProducesZeroesAndNoLatency() {
        let summary = UsageStats.summarize(events: [], now: now)

        XCTAssertEqual(summary.wordsDictated, 0)
        XCTAssertEqual(summary.deliveries, 0)
        XCTAssertEqual(summary.corrections, 0)
        XCTAssertEqual(summary.correctionsPerHundredWords, 0, accuracy: 1e-9)
        XCTAssertFalse(summary.correctionsPerHundredWords.isNaN)
        XCTAssertNil(summary.averageEndToEndLatency)
        XCTAssertNil(summary.averageResponseLatency)
    }

    // MARK: - Truncated / malformed / historical JSONL

    func testDecodeEventsSkipsMalformedTruncatedAndBlankLines() throws {
        // `audit-events.v1.jsonl` is append-only and can be cut mid-write by a
        // crash. One bad tail line must not cost the user their whole week.
        let request = UUID()
        let first = makeEvent(.recognized, requestId: request, at: now - 600,
                              mode: .transcribe, rawTranscript: "第一句",
                              recordingEndedAt: now - 602)
        let second = makeEvent(.completed, requestId: request, at: now - 599,
                               mode: .transcribe, rawTranscript: "第一句",
                               result: "第一句")
        let third = makeEvent(.recognized, requestId: UUID(), at: now - 300,
                              mode: .ask, rawTranscript: "hello")

        let firstLine = try encodeLine(first)
        let truncated = String(firstLine.prefix(firstLine.count / 2))
        let jsonl = [
            firstLine,
            "",
            "this is not json at all",
            try encodeLine(second),
            truncated,
            "{\"schemaVersion\":1}",
            try encodeLine(third),
        ].joined(separator: "\n") + "\n"

        let decoded = UsageStats.decodeEvents(jsonl: jsonl)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded.map(\.id), [first.id, second.id, third.id])
    }

    func testHistoricalRowsWithoutTheRecordingTimestampKeyStillDecode() throws {
        // The no-migration guarantee, checked against a row that genuinely
        // lacks the key rather than one that encodes it as null: an old line
        // must decode, with `recordingEndedAt == nil`.
        let event = makeEvent(.recognized, requestId: UUID(), at: now - 600,
                              mode: .transcribe, rawTranscript: "旧数据",
                              recordingEndedAt: now - 602)
        let legacyLine = try lineWithoutRecordingTimestamp(event)
        XCTAssertFalse(
            legacyLine.contains("recordingEndedAt"),
            "fixture must actually be missing the key"
        )

        let decoded = UsageStats.decodeEvents(jsonl: legacyLine)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.id, event.id)
        XCTAssertNil(decoded.first?.recordingEndedAt)
    }

    func testSummarizingADamagedLogStillProducesTheWeeksNumbers() throws {
        let request = UUID()
        let recognized = makeEvent(.recognized, requestId: request, at: now - 598,
                                   mode: .transcribe, rawTranscript: "今天要开会",
                                   recordingEndedAt: now - 600)
        let completed = makeEvent(.completed, requestId: request, at: now - 597,
                                  mode: .transcribe, rawTranscript: "今天要开会",
                                  result: "今天要开会")
        let jsonl = [
            try encodeLine(recognized),
            "{ garbage",
            try encodeLine(completed),
            "{\"schemaVersion\":1,\"requestId\":\"not-a-uuid\"",
        ].joined(separator: "\n")

        let summary = UsageStats.summarize(
            events: UsageStats.decodeEvents(jsonl: jsonl),
            now: now
        )

        XCTAssertEqual(summary.wordsDictated, 5)
        XCTAssertEqual(summary.deliveries, 1)
        XCTAssertEqual(try XCTUnwrap(summary.averageEndToEndLatency), 3.0, accuracy: 1e-6)
    }

    // MARK: - Daily buckets (the 7-day bar strip)

    // The redesign's statistics band
    // (`design_handoff_opentype_redesign_v1/README.md` §6) puts a 7-bar strip
    // beside the four figures, and a 「上周 2.1」 comparison under the fourth.
    // Both are additions to `Summary`, computed in the same pass:
    //
    //     let dailyWords: [Int]                            // 7, oldest → newest
    //     let previousCorrectionsPerHundredWords: Double?   // the prior 7 days
    //
    // ## Pinned decision — the buckets are rolling 24h slices, not calendar days
    //
    // `windowDuration` is deliberately rolling ("this week" must mean the same
    // span of days whichever day the panel is opened on), and the buckets are
    // slices of that same window: bucket 6 is the 24 hours ending at `now`,
    // bucket 0 is the oldest. Three reasons, in order of weight:
    //
    // 1. **The strip has to add up to the number beside it.** Calendar days
    //    would leave sessions inside the window that belong to no bucket (a
    //    rolling 7-day window covers parts of 8 calendar days), so the bars
    //    would sum to less than 「说出的字数」 on the same card. That is pinned
    //    below as `dailyWords.reduce(0, +) == wordsDictated`.
    // 2. **It keeps `UsageStats` pure.** Calendar days need a `Calendar` and a
    //    time zone, which makes the summary depend on ambient system state that
    //    tests cannot see and a traveller's laptop changes mid-week.
    // 3. The 星期字 under each bar is a label the *view* draws, and it can draw
    //    it from `now - k * 86_400` without the summary knowing what a week is.
    //
    // Attribution matches the rest of `summarize`: by the `.completed`
    // timestamp, so a session is never split and never counted twice.

    func testDailyWordsHasSevenBucketsOldestFirstAndSumsToTheWeeksTotal() {
        let today = UUID()
        let yesterday = UUID()
        let sixDaysAgo = UUID()
        let events = [
            makeEvent(.recognized, requestId: today, at: now - 120,
                      mode: .transcribe, rawTranscript: "今天说的话"),
            makeEvent(.completed, requestId: today, at: now - 60,
                      mode: .transcribe, rawTranscript: "今天说的话",
                      result: "今天说的话"),
            makeEvent(.recognized, requestId: yesterday, at: now - day - 3_700,
                      mode: .transcribe, rawTranscript: "昨天"),
            makeEvent(.completed, requestId: yesterday, at: now - day - 3_600,
                      mode: .transcribe, rawTranscript: "昨天", result: "昨天"),
            makeEvent(.recognized, requestId: sixDaysAgo, at: now - 6 * day - 3_700,
                      mode: .transcribe, rawTranscript: "一周前说的"),
            makeEvent(.completed, requestId: sixDaysAgo, at: now - 6 * day - 3_600,
                      mode: .transcribe, rawTranscript: "一周前说的",
                      result: "一周前说的"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        // Oldest first: 5 characters six days ago, 2 yesterday, 5 today, and
        // four untouched days in between printed as 0 rather than skipped.
        XCTAssertEqual(summary.dailyWords, [5, 0, 0, 0, 0, 2, 5])
        XCTAssertEqual(summary.dailyWords.reduce(0, +), summary.wordsDictated)
    }

    func testDailyWordsIsAlwaysSevenBucketsEvenWithNothingToShow() {
        // A day with no dictation is a 0-height bar, not a missing one — and a
        // week with none is seven of them, which is what the strip draws on
        // first launch.
        XCTAssertEqual(
            UsageStats.summarize(events: [], now: now).dailyWords,
            [0, 0, 0, 0, 0, 0, 0]
        )
        XCTAssertEqual(UsageStats.Summary.empty.dailyWords, [0, 0, 0, 0, 0, 0, 0])
    }

    func testTheBucketBoundaryIsExactlyTwentyFourHoursBeforeNow() {
        // The one arithmetic that decides whether "today" is a full bar or a
        // half-empty one.
        let onBoundary = UUID()
        let justInside = UUID()
        let events = [
            makeEvent(.recognized, requestId: onBoundary, at: now - day - 1,
                      mode: .transcribe, rawTranscript: "整一天"),
            makeEvent(.completed, requestId: onBoundary, at: now - day,
                      mode: .transcribe, rawTranscript: "整一天", result: "整一天"),
            makeEvent(.recognized, requestId: justInside, at: now - day,
                      mode: .transcribe, rawTranscript: "刚"),
            makeEvent(.completed, requestId: justInside, at: now - day + 1,
                      mode: .transcribe, rawTranscript: "刚", result: "刚"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        // Exactly 24h old is yesterday's bar; one second younger is today's.
        XCTAssertEqual(summary.dailyWords, [0, 0, 0, 0, 0, 3, 1])
    }

    func testTheWindowStartInstantLandsInTheOldestBucket() {
        // The window is inclusive at `now - 7d`
        // (`testDeliveryExactlyAtTheWindowStartIsIncludedAndOneSecondEarlierIsNot`),
        // so that instant must have a bar to live in — otherwise the session
        // counts toward 「说出的字数」 while being invisible in the strip.
        let onBoundary = UUID()
        let justOutside = UUID()
        let start = now - 7 * day
        let events = [
            makeEvent(.recognized, requestId: onBoundary, at: start,
                      mode: .transcribe, rawTranscript: "边界"),
            makeEvent(.completed, requestId: onBoundary, at: start,
                      mode: .transcribe, rawTranscript: "边界", result: "边界"),
            makeEvent(.recognized, requestId: justOutside, at: start - 1,
                      mode: .transcribe, rawTranscript: "界外说的一大段话"),
            makeEvent(.completed, requestId: justOutside, at: start - 1,
                      mode: .transcribe, rawTranscript: "界外说的一大段话",
                      result: "界外说的一大段话"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.dailyWords, [2, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(summary.dailyWords.reduce(0, +), summary.wordsDictated)
    }

    func testDailyWordsAttributesASessionToItsDeliveryNotItsRecording() {
        // A session that starts before midnight-minus-24h and delivers after it
        // belongs to one bar, the same way it belongs to one week
        // (`testStraddlingSessionIsAttributedToItsCompletionTimestamp`).
        let straddling = UUID()
        let events = [
            makeEvent(.recognized, requestId: straddling, at: now - day - 60,
                      mode: .transcribe, rawTranscript: "跨过分界"),
            makeEvent(.completed, requestId: straddling, at: now - day + 60,
                      mode: .transcribe, rawTranscript: "跨过分界",
                      result: "跨过分界"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.dailyWords, [0, 0, 0, 0, 0, 0, 4])
    }

    func testDailyWordsCountsNothingForCancelledFailedOrFutureSessions() {
        let delivered = UUID()
        let cancelled = UUID()
        let failed = UUID()
        let future = UUID()
        let events = [
            makeEvent(.recognized, requestId: delivered, at: now - 3 * day - 10,
                      mode: .transcribe, rawTranscript: "交付了"),
            makeEvent(.completed, requestId: delivered, at: now - 3 * day,
                      mode: .transcribe, rawTranscript: "交付了", result: "交付了"),
            makeEvent(.recognized, requestId: cancelled, at: now - 3 * day - 10,
                      mode: .transcribe, rawTranscript: "取消掉的一大段话"),
            makeEvent(.cancelled, requestId: cancelled, at: now - 3 * day,
                      mode: .transcribe, rawTranscript: "取消掉的一大段话"),
            makeEvent(.recognized, requestId: failed, at: now - day - 10,
                      mode: .ask, rawTranscript: "this one failed"),
            makeEvent(.failed, requestId: failed, at: now - day,
                      mode: .ask, rawTranscript: "this one failed"),
            makeEvent(.recognized, requestId: future, at: now + 60,
                      mode: .transcribe, rawTranscript: "来自未来的一句话"),
            makeEvent(.completed, requestId: future, at: now + 61,
                      mode: .transcribe, rawTranscript: "来自未来的一句话",
                      result: "来自未来的一句话"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.dailyWords, [0, 0, 0, 3, 0, 0, 0])
        XCTAssertEqual(summary.dailyWords.reduce(0, +), summary.wordsDictated)
    }

    // MARK: - Last week's correction rate (the trend under the fourth figure)

    // `previousCorrectionsPerHundredWords` is the same ratio over the *previous*
    // 7 days: `[now - 14d, now - 7d)`. Half-open at the young end on purpose —
    // the current window is inclusive at `now - 7d`, so a session delivered at
    // exactly that instant belongs to this week and must not also be counted in
    // last week's. Inclusive at the old end, mirroring the current window's own
    // start rule, so the two windows tile with neither a gap nor an overlap.
    //
    // Optional, unlike `correctionsPerHundredWords`: 「上周 2.1」 is a comparison,
    // and there is nothing to compare against in a user's first week. `nil`
    // means "no prior week", which the panel prints as nothing at all — not as
    // 「上周 0」, which would read as a week of flawless recognition.

    func testPreviousCorrectionsPerHundredWordsMeasuresThePriorSevenDays() {
        let thisWeek = UUID()
        let lastWeek = UUID()
        let thisWeekText = String(repeating: "字", count: 100)
        let lastWeekText = String(repeating: "词", count: 200)
        let events = [
            makeEvent(.recognized, requestId: thisWeek, at: now - 2 * day - 30,
                      mode: .transcribe, rawTranscript: thisWeekText),
            makeEvent(.corrected, requestId: thisWeek, at: now - 2 * day - 20,
                      mode: .transcribe, rawTranscript: "改一下",
                      result: thisWeekText),
            makeEvent(.corrected, requestId: thisWeek, at: now - 2 * day - 10,
                      mode: .transcribe, rawTranscript: "再改一下",
                      result: thisWeekText),
            makeEvent(.completed, requestId: thisWeek, at: now - 2 * day,
                      mode: .transcribe, rawTranscript: thisWeekText,
                      result: thisWeekText),
            makeEvent(.recognized, requestId: lastWeek, at: now - 10 * day - 10,
                      mode: .transcribe, rawTranscript: lastWeekText),
            makeEvent(.corrected, requestId: lastWeek, at: now - 10 * day - 5,
                      mode: .transcribe, rawTranscript: "改一下",
                      result: lastWeekText),
            makeEvent(.completed, requestId: lastWeek, at: now - 10 * day,
                      mode: .transcribe, rawTranscript: lastWeekText,
                      result: lastWeekText),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        // 2 corrections over 100 words this week, 1 over 200 last week.
        XCTAssertEqual(summary.correctionsPerHundredWords, 2.0, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(summary.previousCorrectionsPerHundredWords),
            0.5,
            accuracy: 1e-9
        )
        // Last week stays out of every figure the panel prints as "this week".
        XCTAssertEqual(summary.wordsDictated, 100)
        XCTAssertEqual(summary.corrections, 2)
        XCTAssertEqual(summary.deliveries, 1)
        XCTAssertEqual(summary.dailyWords, [0, 0, 0, 0, 100, 0, 0])
    }

    func testTheTwoWindowsShareNoSessionAtTheirBoundary() {
        // A delivery at exactly `now - 7d` is this week's
        // (`testDeliveryExactlyAtTheWindowStartIsIncludedAndOneSecondEarlierIsNot`).
        // If it also landed in last week's figure it would be counted twice,
        // and a heavily-corrected boundary session would make last week look
        // worse than it was.
        let boundary = UUID()
        let lastWeek = UUID()
        let start = now - 7 * day
        let boundaryText = String(repeating: "字", count: 100)
        let lastWeekText = String(repeating: "词", count: 100)
        let events = [
            makeEvent(.recognized, requestId: boundary, at: start - 30,
                      mode: .transcribe, rawTranscript: boundaryText),
            makeEvent(.corrected, requestId: boundary, at: start - 20,
                      mode: .transcribe, rawTranscript: "改", result: boundaryText),
            makeEvent(.corrected, requestId: boundary, at: start - 19,
                      mode: .transcribe, rawTranscript: "改", result: boundaryText),
            makeEvent(.corrected, requestId: boundary, at: start - 18,
                      mode: .transcribe, rawTranscript: "改", result: boundaryText),
            makeEvent(.corrected, requestId: boundary, at: start - 17,
                      mode: .transcribe, rawTranscript: "改", result: boundaryText),
            makeEvent(.corrected, requestId: boundary, at: start - 16,
                      mode: .transcribe, rawTranscript: "改", result: boundaryText),
            makeEvent(.completed, requestId: boundary, at: start,
                      mode: .transcribe, rawTranscript: boundaryText,
                      result: boundaryText),
            makeEvent(.recognized, requestId: lastWeek, at: now - 9 * day - 10,
                      mode: .transcribe, rawTranscript: lastWeekText),
            makeEvent(.corrected, requestId: lastWeek, at: now - 9 * day - 5,
                      mode: .transcribe, rawTranscript: "改", result: lastWeekText),
            makeEvent(.completed, requestId: lastWeek, at: now - 9 * day,
                      mode: .transcribe, rawTranscript: lastWeekText,
                      result: lastWeekText),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertEqual(summary.correctionsPerHundredWords, 5.0, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(summary.previousCorrectionsPerHundredWords),
            1.0,
            accuracy: 1e-9
        )
    }

    func testThePreviousWindowStartsFourteenDaysBackInclusive() {
        let onBoundary = UUID()
        let tooOld = UUID()
        let start = now - 14 * day
        let text = String(repeating: "字", count: 100)
        let events = [
            makeEvent(.recognized, requestId: onBoundary, at: start - 30,
                      mode: .transcribe, rawTranscript: text),
            makeEvent(.corrected, requestId: onBoundary, at: start - 20,
                      mode: .transcribe, rawTranscript: "改", result: text),
            makeEvent(.corrected, requestId: onBoundary, at: start - 10,
                      mode: .transcribe, rawTranscript: "改", result: text),
            makeEvent(.completed, requestId: onBoundary, at: start,
                      mode: .transcribe, rawTranscript: text, result: text),
            makeEvent(.recognized, requestId: tooOld, at: start - 60,
                      mode: .transcribe, rawTranscript: text),
            makeEvent(.corrected, requestId: tooOld, at: start - 50,
                      mode: .transcribe, rawTranscript: "改", result: text),
            makeEvent(.corrected, requestId: tooOld, at: start - 45,
                      mode: .transcribe, rawTranscript: "改", result: text),
            makeEvent(.corrected, requestId: tooOld, at: start - 40,
                      mode: .transcribe, rawTranscript: "改", result: text),
            makeEvent(.corrected, requestId: tooOld, at: start - 35,
                      mode: .transcribe, rawTranscript: "改", result: text),
            makeEvent(.completed, requestId: tooOld, at: start - 1,
                      mode: .transcribe, rawTranscript: text, result: text),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        // Only the boundary session: 2 corrections over 100 words. The session
        // one second older is two weeks ago, which nothing on this panel shows.
        XCTAssertEqual(
            try XCTUnwrap(summary.previousCorrectionsPerHundredWords),
            2.0,
            accuracy: 1e-9
        )
    }

    func testPreviousCorrectionsPerHundredWordsIsNilWithNoPriorWeek() {
        // A user's first week: there is no 「上周」 to print.
        let thisWeek = UUID()
        let events = [
            makeEvent(.recognized, requestId: thisWeek, at: now - 600,
                      mode: .transcribe, rawTranscript: "只有这周"),
            makeEvent(.corrected, requestId: thisWeek, at: now - 590,
                      mode: .transcribe, rawTranscript: "改一下", result: "只有这周"),
            makeEvent(.completed, requestId: thisWeek, at: now - 580,
                      mode: .transcribe, rawTranscript: "只有这周", result: "只有这周"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertNil(summary.previousCorrectionsPerHundredWords)
        XCTAssertNil(UsageStats.Summary.empty.previousCorrectionsPerHundredWords)
    }

    func testAPriorWeekThatDeliveredNothingIsNilRatherThanZero() {
        // Cancelled and failed sessions are not deliveries, here as everywhere
        // else — a week the user threw away is a week with no rate, not a week
        // with a perfect one.
        let lastWeek = UUID()
        let events = [
            makeEvent(.recognized, requestId: lastWeek, at: now - 10 * day - 10,
                      mode: .transcribe, rawTranscript: "上周取消掉的一段话"),
            makeEvent(.corrected, requestId: lastWeek, at: now - 10 * day - 5,
                      mode: .transcribe, rawTranscript: "改一下",
                      result: "上周取消掉的一段话"),
            makeEvent(.cancelled, requestId: lastWeek, at: now - 10 * day,
                      mode: .transcribe, rawTranscript: "上周取消掉的一段话"),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        XCTAssertNil(summary.previousCorrectionsPerHundredWords)
    }

    func testAPriorWeekThatDeliveredOnlyEmptyTranscriptsIsZeroNotNaN() throws {
        // Same divide-by-zero guard the current week's ratio has: it delivered,
        // so there is a rate; the rate is 0.
        let lastWeek = UUID()
        let events = [
            makeEvent(.recognized, requestId: lastWeek, at: now - 10 * day - 10,
                      mode: .transcribe, rawTranscript: ""),
            makeEvent(.corrected, requestId: lastWeek, at: now - 10 * day - 5,
                      mode: .transcribe, rawTranscript: "改一下", result: ""),
            makeEvent(.completed, requestId: lastWeek, at: now - 10 * day,
                      mode: .transcribe, rawTranscript: "", result: ""),
        ]

        let summary = UsageStats.summarize(events: events, now: now)

        let previous = try XCTUnwrap(summary.previousCorrectionsPerHundredWords)
        XCTAssertEqual(previous, 0, accuracy: 1e-9)
        XCTAssertFalse(previous.isNaN)
        XCTAssertTrue(previous.isFinite)
    }

    // MARK: - Fixtures

    private func makeEvent(
        _ status: AuditEventStatus,
        id: UUID = UUID(),
        requestId: UUID,
        at createdAt: Date,
        mode: InputMode,
        rawTranscript: String,
        result: String? = nil,
        supersedes: UUID? = nil,
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
            supersedesEventId: supersedes,
            recordingEndedAt: recordingEndedAt
        )
    }

    /// Encodes exactly the way `ImmutableAuditStore.append` does, so the
    /// decode-side tests exercise the real on-disk shape.
    private func encodeLine(_ event: ImmutableAuditEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(event), as: UTF8.self)
    }

    /// A row as it would have been written before `recordingEndedAt` existed:
    /// the key is absent, not null.
    private func lineWithoutRecordingTimestamp(
        _ event: ImmutableAuditEvent
    ) throws -> String {
        let data = Data(try encodeLine(event).utf8)
        guard var object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        object.removeValue(forKey: "recordingEndedAt")
        let stripped = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return String(decoding: stripped, as: UTF8.self)
    }
}
