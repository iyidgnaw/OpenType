import Foundation

/// The local statistics panel (P2-12,
/// `docs/superpowers/specs/2026-08-14-product-batch-plan.md`).
///
/// A pure aggregator over `audit-events.v1.jsonl` — the append-only trail
/// `ImmutableAuditStore` already writes. It adds no storage, no counters and no
/// network path: every figure the panel shows is derived, at read time, from
/// rows that were going to be written anyway. That is the whole design
/// constraint. A statistics feature that starts recording its own numbers is a
/// second source of truth that will disagree with the audit log the first time
/// one of them misses a write, and "we count your dictation" is a sentence a
/// local-first product should never have to say twice.
///
/// Factored out of the views for the reason `CorrectionWindow` and
/// `OutputDeliveryPolicy` were: the arithmetic is pure and screen-free, and a
/// panel whose numbers can only be checked by dictating into a running app is a
/// panel whose numbers nobody will check. Nothing here touches AppKit, the main
/// actor, or the filesystem except through `summarizeLog(at:now:)`.
enum UsageStats {

    /// How far back the panel looks. A rolling window, not a calendar week:
    /// "this week" should mean the same span of days no matter which day the
    /// user opens the panel on, and a calendar week makes Monday morning's
    /// number look like a collapse.
    static let windowDuration: TimeInterval = 7 * 86_400

    /// Bars in the strip — one per rolling day of `windowDuration`.
    static let bucketCount = 7

    /// One week's figures.
    ///
    /// Latency is `nil`-able rather than zero-defaulted throughout: "—" and
    /// "0.0s" are read very differently, and only one of them is honest about
    /// a week with nothing to measure.
    struct Summary: Equatable {
        /// Words the user *dictated*, by `wordCount(_:)`'s rule — never words a
        /// model wrote back.
        let wordsDictated: Int
        /// Sessions that produced a delivery. Cancelled and failed sessions are
        /// not deliveries.
        let deliveries: Int
        /// Voice-correction rounds inside delivered sessions.
        let corrections: Int
        /// `corrections / wordsDictated * 100`, or `0` when nothing was
        /// dictated. This batch's own success metric: it should fall as the
        /// entity dictionary learns (P0-1/P0-2), which is only legible as a
        /// rate — a raw correction count rises with usage no matter how much
        /// recognition improves.
        let correctionsPerHundredWords: Double
        /// Hotkey release → text delivered, averaged over sessions that can
        /// express it. The headline: it is the span the user actually waits
        /// through, and ASR is its dominant term. `agent` sessions are left out
        /// — see `summarize(events:now:)` — because their user does not wait.
        let averageEndToEndLatency: TimeInterval?
        /// `.recognized` → `.completed` for `ask`/`agent` only — the post-ASR
        /// remainder, and the only figure an agent run's duration belongs in.
        /// Kept beside the headline because for `ask`, which is in both, the
        /// *difference* between the two is what ASR cost.
        let averageResponseLatency: TimeInterval?
        /// The headline wait, `transcribe` sessions only — same exclusion
        /// rules as `averageEndToEndLatency` (Review committed without a
        /// correction, a pre-delivery correction round), computed from
        /// exactly the spans that figure sums. Splits the headline apart from
        /// `ask`: a week heavy on web-searched questions (30s) blended with
        /// two-second dictation reads as a slow week for dictation, which it
        /// was not. `nil`, never `0`, when nothing measurable delivered this
        /// week — a bilingual user who only dictated one day still gets a
        /// real number for that day, not a blank.
        let averageTranscribeEndToEndLatency: TimeInterval?
        /// The headline wait, `ask` sessions only, same rule and same source
        /// spans. `agent` is deliberately absent from both per-mode figures —
        /// see `averageResponseLatency`'s doc comment above for why an agent
        /// run's duration does not belong in any "how long did I wait"
        /// figure at all.
        let averageAskEndToEndLatency: TimeInterval?
        /// Seven rolling 24-hour buckets, oldest first, for the bar strip.
        ///
        /// Rolling rather than calendar days so this sums to `wordsDictated`
        /// exactly. A calendar week touches parts of eight calendar days, so
        /// calendar buckets would leave sessions inside the window belonging to
        /// no bar and the strip would visibly fail to add up to the number
        /// printed beside it — which costs more trust than precise weekday
        /// labels buy. The view labels bar *i* from `now - (6 - i) * 86400`.
        let dailyWords: [Int]
        /// `correctionsPerHundredWords` per day, over the same seven buckets as
        /// `dailyWords`, oldest first (D-3).
        ///
        /// The headline rate answers 「how many corrections did I make」; the
        /// question the learning loop actually poses is 「**is this falling**」,
        /// and two numbers a week apart is the weakest possible way to show a
        /// slope. Computed in the same pass as everything else here, on the same
        /// buckets, so index *i* means the same day on the line as it does under
        /// the bar drawn beside it.
        ///
        /// `nil` is a day that delivered nothing, and it is **not** the same as
        /// a rate of zero — a day with words and no corrections is the best day
        /// the product can have and is a real point on the line. Collapsing the
        /// two would make a user who took the weekend off see the line dive on
        /// Saturday and spike on Monday, which reads as "it got worse when I
        /// came back" rather than as "there is no data here".
        let dailyCorrectionsPerHundredWords: [Double?]
        /// `correctionsPerHundredWords` for the *previous* seven days, or `nil`
        /// when there is no prior week to compare against.
        ///
        /// Optional where the current-week figure is not, deliberately: a
        /// trend with nothing behind it prints nothing (「空值印 — 不印 0」),
        /// whereas a real week that dictated nothing is a genuine zero.
        let previousCorrectionsPerHundredWords: Double?

        static let empty = Summary(
            wordsDictated: 0,
            deliveries: 0,
            corrections: 0,
            correctionsPerHundredWords: 0,
            averageEndToEndLatency: nil,
            averageResponseLatency: nil,
            averageTranscribeEndToEndLatency: nil,
            averageAskEndToEndLatency: nil,
            dailyWords: Array(repeating: 0, count: UsageStats.bucketCount),
            dailyCorrectionsPerHundredWords: Array(
                repeating: nil,
                count: UsageStats.bucketCount
            ),
            previousCorrectionsPerHundredWords: nil
        )
    }

    // MARK: - Word counting

    /// How many words a dictated string is worth.
    ///
    /// A **script-aware hybrid**, because this product's normal input is 中英
    /// 混排 typed with no spaces between the scripts:
    ///
    /// - Each CJK-family character (ideographs, kana, Hangul syllables) is one
    ///   word — the 「字数」 convention a Chinese-speaking user already counts
    ///   in.
    /// - Each maximal run of letters/digits is one word, with `'`/`’` allowed
    ///   *inside* a run so `don't` stays one.
    /// - Everything else — punctuation of either width, hyphens, whitespace,
    ///   emoji — separates and counts for nothing.
    ///
    /// Two details are load-bearing rather than incidental. The rule is applied
    /// **per character, not per whitespace-delimited token**, so 「今天review
    /// 一下PR」 counts the same 6 as its spaced form — an implementation that
    /// splits on whitespace first passes every spaced example and undercounts
    /// the actual input. And the CJK test runs **before** the alphanumeric
    /// test, because Swift reports `isNumber == true` for 一 二 十 百 千 万: in
    /// the other order 「3万」 glues into a single word.
    ///
    /// Deliberately not `String.enumerateSubstrings(options: .byWords)`: ICU
    /// applies dictionary segmentation to Chinese, so 「你好世界」 comes back as
    /// 2 rather than 4, and the answer shifts with whatever ICU data the OS
    /// happens to ship. A number that changes under the user after a system
    /// update is worse than a number that is merely approximate.
    ///
    /// **Limits, which the panel states next to the figure rather than hiding
    /// here:** 100 Chinese characters and 100 English words are not the same
    /// quantity of speech, so a bilingual user's total blends two units. The
    /// figure is comparable *to itself over time* for a user whose language mix
    /// is stable — which is exactly what corrections-per-100-words needs — and
    /// is not a cross-user or cross-language benchmark.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var insideRun = false

        for character in text {
            if isCJKFamily(character) {
                // Before the alphanumeric branch on purpose — see above.
                count += 1
                insideRun = false
            } else if character.isLetter || character.isNumber {
                if !insideRun {
                    count += 1
                    insideRun = true
                }
            } else if isIntraWordApostrophe(character) {
                // Neither starts a run nor ends one: it only survives inside a
                // run that is already open, so `don't` is one word while a
                // stray quote is nothing.
                continue
            } else {
                insideRun = false
            }
        }

        return count
    }

    /// Whether a character is written in a script whose characters are counted
    /// individually.
    ///
    /// Block ranges rather than `Character` properties, since Swift classifies
    /// CJK ideographs as letters (and some of them as numbers) exactly like
    /// Latin ones. The punctuation/symbol guard covers the few marks that live
    /// inside these blocks — 「・」 U+30FB and the standalone dakuten — which
    /// separate words rather than being words.
    private static func isCJKFamily(_ character: Character) -> Bool {
        guard !character.isPunctuation, !character.isSymbol,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana + Katakana
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF:   // CJK Compatibility Ideographs
            return true
        default:
            return false
        }
    }

    private static func isIntraWordApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}" || character == "\u{02BC}"
    }

    // MARK: - Reading the trail

    /// Decodes as many events as the file can still yield.
    ///
    /// `audit-events.v1.jsonl` is appended to with an open file handle, so a
    /// crash or a full disk can leave a half-written final line behind. Every
    /// line is decoded independently and a line that fails is dropped: one bad
    /// tail must not cost the user the whole week's figures. Order is
    /// preserved, so callers can still rely on the file's chronology.
    static func decodeEvents(jsonl: String) -> [ImmutableAuditEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return jsonl
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                try? decoder.decode(
                    ImmutableAuditEvent.self,
                    from: Data(line.utf8)
                )
            }
    }

    /// Reads and summarizes the trail at `url`.
    ///
    /// Takes a `URL` rather than the store so it stays a pure, non-isolated
    /// function: `AppModel` is `@MainActor`, and the read has to happen off the
    /// main actor for a user with years of dictation behind them.
    static func summarizeLog(at url: URL, now: Date = Date()) -> Summary {
        guard let jsonl = try? String(contentsOf: url, encoding: .utf8) else {
            // No file yet is the ordinary state on first launch, not an error.
            return .empty
        }
        return summarize(events: decodeEvents(jsonl: jsonl), now: now)
    }

    // MARK: - Summarizing

    /// Rolls a week of audit events into the panel's figures.
    ///
    /// The unit is the **session** (`requestId`), not the event. A session
    /// counts iff it has a `.completed` event whose timestamp lands in
    /// `now - windowDuration ... now`, inclusive at both ends — so a session
    /// that straddles the boundary is counted whole, on the side its delivery
    /// landed, and never split across two weeks' numbers. Cancelled and failed
    /// sessions contribute nothing at all: not their words, and not their
    /// corrections either, since the user threw the whole thing away.
    ///
    /// Events dated after `now` are dropped. Clock skew is real, and a
    /// "future" session inflating this week and then vanishing from next week
    /// is worse than never counting it.
    static func summarize(events: [ImmutableAuditEvent], now: Date) -> Summary {
        let windowStart = now.addingTimeInterval(-windowDuration)

        var sessions: [UUID: [ImmutableAuditEvent]] = [:]
        for event in events {
            sessions[event.requestId, default: []].append(event)
        }

        var wordsDictated = 0
        var deliveries = 0
        var corrections = 0
        var endToEndSpans: [TimeInterval] = []
        var responseSpans: [TimeInterval] = []
        // Per-mode subsets of `endToEndSpans`, collected at the same point
        // below rather than in a second pass — see (c) in this file's
        // header. Each span that qualifies for the headline is appended to
        // exactly one of these two as well (or to neither, for `agent`),
        // which is what keeps a single-mode week's per-mode figure equal to
        // the headline bit-for-bit.
        var transcribeEndToEndSpans: [TimeInterval] = []
        var askEndToEndSpans: [TimeInterval] = []
        var dailyWords = Array(repeating: 0, count: bucketCount)
        // The trend's two other columns. Deliveries are counted per bucket as
        // well as per week because they are what tells a day with a genuine
        // zero rate apart from a day nothing happened on — words alone cannot,
        // since an empty transcript can still be delivered.
        var dailyCorrections = Array(repeating: 0, count: bucketCount)
        var dailyDeliveries = Array(repeating: 0, count: bucketCount)
        // The seven days before the current window, for the trend. Gathered in
        // the same pass — a second walk over the file to compute one ratio
        // would double the cost of a panel whose whole job is to be cheap
        // enough to recompute on every appearance.
        let previousWindowStart = windowStart.addingTimeInterval(-windowDuration)
        var previousWords = 0
        var previousCorrections = 0
        var previousDeliveries = 0

        for (_, unordered) in sessions {
            let session = unordered.sorted { $0.createdAt < $1.createdAt }
            guard let completed = session.first(where: { $0.status == .completed }) else {
                continue
            }
            // The prior seven days, half-open at the young end so the boundary
            // session the current window claims inclusively cannot be counted
            // in both.
            if completed.createdAt >= previousWindowStart,
               completed.createdAt < windowStart {
                previousDeliveries += 1
                previousWords += wordCount(
                    session.first { $0.status == .recognized }?.rawTranscript
                        ?? completed.rawTranscript
                )
                previousCorrections += session.filter { $0.status == .corrected }.count
            }
            guard completed.createdAt >= windowStart,
                  completed.createdAt <= now else {
                continue
            }

            let recognized = session.first { $0.status == .recognized }
            deliveries += 1

            // Attributed to the delivery, not the recording: a session that
            // started before midnight and finished after belongs to the day it
            // produced something. Clamped because a `.completed` exactly at
            // `now` computes to index 7.
            let age = now.timeIntervalSince(completed.createdAt)
            let bucket = min(
                bucketCount - 1,
                max(0, bucketCount - 1 - Int(age / 86_400))
            )
            // The *dictated* text: what ASR heard at the top of the session,
            // falling back to the delivery's own copy of it. Never a
            // `.corrected` row's `rawTranscript` — that field holds the spoken
            // correction instruction — and never `result`, which for ask/agent
            // is the model's words rather than the user's.
            let sessionWords = wordCount(
                recognized?.rawTranscript ?? completed.rawTranscript
            )
            wordsDictated += sessionWords
            dailyWords[bucket] += sessionWords
            dailyDeliveries[bucket] += 1

            let correctionRounds = session.filter { $0.status == .corrected }
            corrections += correctionRounds.count
            // Attributed to the delivery's bucket, not to each correction's own
            // timestamp. P0-3's post-delivery window puts `.corrected` rows
            // *after* `.completed`, sometimes in the next 24-hour slice, and a
            // correction that landed in a column with no words behind it would
            // produce an infinite rate on a day the user never dictated.
            dailyCorrections[bucket] += correctionRounds.count

            // Parsed once, for both figures below. `nil` for a mode string this
            // build no longer knows — rows from the old 5/6-mode era are still
            // in the file — and a `nil` mode keeps counting toward the wait,
            // which is what it was, while staying out of the model-time figure,
            // which it cannot be attributed to.
            let mode = InputMode(rawValue: completed.mode)

            if let recordingEndedAt = recognized?.recordingEndedAt,
               // `agent` is dispatch-and-walk-away: the surface says 「已下发给
               // Agent」 and falls back to idle within a second, and the answer
               // lands minutes later in a notification. That `.completed` is a
               // real delivery, so the session counts everywhere else — but
               // averaging a multi-minute background run into "how long you
               // waited after letting go of the key" triples the headline for a
               // user whose dictation takes two seconds. Arithmetically sound
               // and still a lie about what the label promises.
               // `averageResponseLatency` is where an agent run's duration
               // belongs, and it keeps it.
               mode != .agent,
               // A Review session the user committed — with or without a
               // correction round — is human reading/deciding time in the
               // panel, not the system's. `variant` is only ever stamped on a
               // `transcribe` `.completed` event, so this guard is a no-op
               // for `ask`/`agent`. `nil` (every row written before this
               // field existed) is deliberately *not* excluded here — see
               // `ImmutableAuditEvent.variant`'s doc comment — only a row
               // explicitly labelled `"review"` is.
               completed.variant != TranscribeVariant.review.rawValue,
               // A correction round *before* delivery means the user was
               // editing in the Review panel, so the span is human time rather
               // than the system's. A correction *after* delivery (P0-3's
               // post-delivery window) happened outside the measured span and
               // must not disqualify an otherwise clean session.
               !correctionRounds.contains(where: {
                   $0.createdAt < completed.createdAt
               }) {
                let span = completed.createdAt.timeIntervalSince(recordingEndedAt)
                append(span, to: &endToEndSpans)
                // Same span, filed into its mode's own column too — see (c)
                // above. `agent` is already excluded by the guard this `if`
                // sits inside, so it never reaches either column.
                switch mode {
                case .transcribe:
                    append(span, to: &transcribeEndToEndSpans)
                case .ask:
                    append(span, to: &askEndToEndSpans)
                default:
                    break
                }
            }

            if let recognized, mode == .ask || mode == .agent {
                // Excluded for `transcribe`: there the span is either the
                // near-zero splice (Direct/Tidy) or the user's own editing time
                // (Review completes on Cmd+Return). Neither answers "how long
                // did the model take".
                append(
                    completed.createdAt.timeIntervalSince(recognized.createdAt),
                    to: &responseSpans
                )
            }
        }

        return Summary(
            wordsDictated: wordsDictated,
            deliveries: deliveries,
            corrections: corrections,
            // Guarded rather than left to produce a NaN: an empty transcript
            // can still be delivered, and a panel showing "NaN 次" is worse
            // than one showing nothing.
            correctionsPerHundredWords: wordsDictated > 0
                ? Double(corrections) * 100 / Double(wordsDictated)
                : 0,
            averageEndToEndLatency: average(endToEndSpans),
            averageResponseLatency: average(responseSpans),
            averageTranscribeEndToEndLatency: average(transcribeEndToEndSpans),
            averageAskEndToEndLatency: average(askEndToEndSpans),
            dailyWords: dailyWords,
            // Same three cases as the weekly figures, held apart per day: a day
            // that delivered nothing has no rate (`nil`, drawn as a gap), a day
            // that delivered but dictated no countable words has a real zero
            // rather than a NaN, and everything else is the ratio. Rows lacking
            // `recordingEndedAt` are absent only from the *timing* figures
            // above; they count here in full, because dropping them would erase
            // the early days of any user who upgraded mid-week — precisely the
            // stretch that would show the improvement.
            dailyCorrectionsPerHundredWords: (0..<bucketCount).map { bucket in
                guard dailyDeliveries[bucket] > 0 else { return nil }
                guard dailyWords[bucket] > 0 else { return 0 }
                return Double(dailyCorrections[bucket]) * 100
                    / Double(dailyWords[bucket])
            },
            // `nil` when the prior week delivered nothing at all — there is no
            // trend to draw, and printing 0 would claim an improvement that
            // never happened. A week that delivered but dictated no words is a
            // real 0, mirroring the current-week guard above.
            previousCorrectionsPerHundredWords: previousDeliveries == 0
                ? nil
                : (previousWords > 0
                    ? Double(previousCorrections) * 100 / Double(previousWords)
                    : 0)
        )
    }

    /// Keeps a span only if the two clock readings it came from are ordered.
    ///
    /// A wall-clock difference is a measurement only while the wall clock holds
    /// still. A non-positive span says it did not — an NTP step, or a
    /// sleep/wake across the session — and a single such row is enough to pull
    /// a week's average below zero, which reads as a broken panel rather than
    /// as a fast week. Dropped for the same reason a missing timestamp is
    /// dropped: what it records is the clock moving, not the user waiting.
    private static func append(
        _ span: TimeInterval,
        to spans: inout [TimeInterval]
    ) {
        guard span > 0 else { return }
        spans.append(span)
    }

    /// `nil` for no samples — never `0`. Rows that cannot express a span (every
    /// session recorded before `recordingEndedAt` existed) are absent from
    /// `spans` rather than present as zero, which is what keeps a user who
    /// upgraded mid-week from seeing an average dragged toward a flattering
    /// lie.
    private static func average(_ spans: [TimeInterval]) -> TimeInterval? {
        guard !spans.isEmpty else { return nil }
        return spans.reduce(0, +) / Double(spans.count)
    }
}
