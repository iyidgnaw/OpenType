import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for **D-1** — 「`replacements` 返回并可见」, the
/// Swift half (`docs/superpowers/specs/2026-08-15-product-batch-plan.md` §D-1,
/// motivated by `docs/reviews/2026-08-15-product-review.md` §1).
///
/// The sidecar half is pinned by `sidecar/test/asr/replacements.test.ts`:
/// `POST /asr/transcribe` grows an optional `replacements: [{ from, to, termId }]`
/// beside `text`, omitted entirely when nothing was rewritten.
///
/// ## What this file is actually for
///
/// Not the toast. **The undo.** Showing 「自动修正 2 处」 is a display change and
/// display changes do not need a pure seam; what needs one is the decision
/// behind 「撤销并删除该词条」, because alias learning is heuristic and a
/// wrongly-learned alias today rewrites the user's words with no explanation
/// and no exit except hunting through the memory page. That click has to be
/// able to fail safely, and every way it can fail is a product decision:
///
///  - it must never paste over text the user has moved on from,
///  - it must never paste into an app that was not the delivery's target,
///  - it must never guess *which* occurrence of a word to put back, and
///  - it must delete the offending term in **all** of those cases, because the
///    term is wrong regardless of whether this particular paste can be undone.
///
/// That last one is why the outcome is one value rather than a `Bool`: "did it
/// restore the text" and "did it delete the term" have different answers, and a
/// UI that collapses them either lies about the deletion or re-asks the user to
/// go delete it themselves.
///
/// ## Timing is not re-derived here
///
/// §D-1 says the undo is live only while 「前台应用未变 + 交付后 8 秒内」 and to
/// **reuse `CorrectionWindow`'s judgement rather than invent a second time
/// limit**. So `decide` takes a `CorrectionWindow.State?` and a frontmost bundle
/// id, and the tests below assert agreement with `CorrectionWindow.State.isExpired(at:)`
/// and `OutputDeliveryPolicy.shouldInsert(capturedBundleId:frontmostBundleId:)`
/// across a matrix, rather than restating 8 seconds or `==` on bundle ids. If
/// someone later changes `CorrectionWindow.windowSeconds`, this feature moves
/// with it or these tests fail — which is the point.
///
/// ## Expected shape (Stage 3 creates it; nothing here builds it)
///
///     struct AliasReplacement: Decodable, Equatable {
///         let from: String        // the alias, as it sits in the dictionary
///         let to: String          // the canonical spelling that was written
///         let termId: Int         // the row `DELETE /memory/terms/:id` targets
///     }
///
///     struct TranscribeResponse: Decodable, Equatable {
///         let text: String
///         let rawText: String                    // Task 4: unrewritten ASR output
///         let replacements: [AliasReplacement]   // `[]` when the key is absent
///     }
///
///     enum AliasReplacementNotice {
///         static func summary(for: [AliasReplacement]) -> String?
///     }
///
///     enum AliasUndo {
///         enum Blocker: Equatable {
///             case windowExpired
///             case targetApplicationChanged
///             case textNoLongerMatches
///         }
///         enum Decision: Equatable {
///             case restoreText(String)
///             case forgetTermOnly(Blocker)
///             var restoredText: String? { get }
///             var deletesTerm: Bool { get }
///         }
///         static func decide(
///             undoing: AliasReplacement,
///             in deliveredText: String,
///             replacements: [AliasReplacement],
///             window: CorrectionWindow.State?,
///             now: Date,
///             frontmostBundleId: String?
///         ) -> Decision
///         static func message(for: Decision) -> String
///     }
///
/// These tests fail to COMPILE until those exist — the established red for this
/// codebase.
final class AliasReplacementTests: XCTestCase {

    /// A fixed, exactly-representable instant, so the window arithmetic is not
    /// at the mercy of `Date()` or floating-point drift.
    private let deliveredAt = Date(timeIntervalSinceReferenceDate: 2_000_000)
    private let targetApp = "com.apple.Notes"

    private func window(capturedBundleId: String? = "com.apple.Notes") -> CorrectionWindow.State {
        CorrectionWindow.State(
            deliveredAt: deliveredAt,
            capturedBundleId: capturedBundleId
        )
    }

    private let payPal = AliasReplacement(from: "呸泡", to: "PayPal", termId: 7)

    // MARK: - Decoding the response

    func testATranscriptionThatRewroteNothingDecodesToAnEmptyList() throws {
        // The backward-compatible half: the sidecar omits the key entirely
        // rather than sending `[]`, and every response written before D-1
        // looked exactly like this. Decoding must not throw, and the absence
        // must arrive as an empty list rather than as an optional every call
        // site then has to unwrap.
        //
        // `rawText` (Task 4) is unrelated to this backward-compat case and is
        // unconditional on the wire, so it's included here even though it
        // predates this test.
        let json = #"{"text":"今天要开会","rawText":"今天要开会"}"#

        let response = try decode(TranscribeResponse.self, from: json)

        XCTAssertEqual(response.text, "今天要开会")
        XCTAssertEqual(response.replacements, [])
    }

    func testReplacementsDecodeInOrderWithTheirTermIds() throws {
        let json = """
        {"text":"先问Anthropic，再用PayPal付款","rawText":"先问安思罗匹克，再用呸泡付款","replacements":[\
        {"from":"安思罗匹克","to":"Anthropic","termId":3},\
        {"from":"呸泡","to":"PayPal","termId":7}]}
        """

        let response = try decode(TranscribeResponse.self, from: json)

        XCTAssertEqual(
            response.replacements,
            [
                AliasReplacement(from: "安思罗匹克", to: "Anthropic", termId: 3),
                AliasReplacement(from: "呸泡", to: "PayPal", termId: 7),
            ]
        )
    }

    func testAnExplicitlyEmptyListAlsoDecodes() throws {
        // The sidecar omits the key, but a hand-rolled or older/newer build
        // sending `[]` must not be a decoding failure — this response is on the
        // hottest path in the product, and a decode error there costs the user
        // their dictation, not a toast.
        let response = try decode(
            TranscribeResponse.self,
            from: #"{"text":"hello","rawText":"hello","replacements":[]}"#
        )

        XCTAssertEqual(response.replacements, [])
    }

    // MARK: - The toast line

    func testNothingIsAnnouncedWhenNothingWasRewritten() {
        // 「自动修正 0 处」 is noise on the one path the user takes hundreds of
        // times a day. Absence has to be representable.
        XCTAssertNil(AliasReplacementNotice.summary(for: []))
    }

    func testTheSummaryCountsPlacesRatherThanDistinctTerms() throws {
        // Two rewrites of the same term in one utterance are two places the
        // text changed, and the expanded list offers an undo control for each.
        let summary = try XCTUnwrap(
            AliasReplacementNotice.summary(for: [payPal, payPal])
        )

        XCTAssertTrue(
            summary.contains("2"),
            "the count of rewritten places has to appear in the line: \(summary)"
        )
        XCTAssertNotEqual(
            summary,
            try XCTUnwrap(AliasReplacementNotice.summary(for: [payPal])),
            "one rewrite and two must not read identically"
        )
    }

    // MARK: - Undo: the ordinary case

    func testUndoInsideTheWindowRestoresTheSpokenWordAndDeletesTheTerm() {
        // The whole feature in one case: the dictionary turned 「呸泡」 into
        // PayPal, that was wrong, and one click puts the user's own word back
        // and forgets the alias that did it.
        let decision = AliasUndo.decide(
            undoing: payPal,
            in: "我用PayPal付款",
            replacements: [payPal],
            window: window(),
            now: deliveredAt + 2,
            frontmostBundleId: targetApp
        )

        XCTAssertEqual(decision, .restoreText("我用呸泡付款"))
        XCTAssertEqual(decision.restoredText, "我用呸泡付款")
        XCTAssertTrue(decision.deletesTerm)
    }

    func testUndoRestoresEveryPlaceTheDeletedTermRewrote() {
        // The term is being deleted, so every rewrite it caused in this
        // delivery goes with it — otherwise the user clicks undo and half their
        // sentence still carries the word they just rejected.
        let decision = AliasUndo.decide(
            undoing: payPal,
            in: "PayPal转账给我，我也用PayPal",
            replacements: [payPal, payPal],
            window: window(),
            now: deliveredAt + 1,
            frontmostBundleId: targetApp
        )

        XCTAssertEqual(decision, .restoreText("呸泡转账给我，我也用呸泡"))
    }

    func testUndoLeavesOtherTermsRewritesInPlace() {
        // Undo is scoped to one term. Anthropic was rewritten correctly and its
        // row is not the one being deleted, so it stays exactly as delivered.
        let anthropic = AliasReplacement(
            from: "安思罗匹克", to: "Anthropic", termId: 3
        )

        let decision = AliasUndo.decide(
            undoing: payPal,
            in: "先问Anthropic，再用PayPal付款",
            replacements: [anthropic, payPal],
            window: window(),
            now: deliveredAt + 1,
            frontmostBundleId: targetApp
        )

        XCTAssertEqual(decision, .restoreText("先问Anthropic，再用呸泡付款"))
    }

    func testUndoRestoresEachAliasThatProducedTheSameCanonical() {
        // One term can carry several aliases, and a single utterance can hit
        // more than one of them. Reverting has to give each place back the word
        // the user actually said, not whichever alias happens to be first in
        // the list — the rows are in text order, and so are the occurrences.
        let heard = AliasReplacement(from: "呸泡", to: "PayPal", termId: 7)
        let alsoHeard = AliasReplacement(from: "paipal", to: "PayPal", termId: 7)

        let decision = AliasUndo.decide(
            undoing: heard,
            in: "PayPal 和 PayPal",
            replacements: [heard, alsoHeard],
            window: window(),
            now: deliveredAt + 1,
            frontmostBundleId: targetApp
        )

        XCTAssertEqual(decision, .restoreText("呸泡 和 paipal"))
    }

    // MARK: - Undo: when the text can no longer be reasoned about

    func testUndoDeletesTheTermButLeavesTextThatDoesNotMatchTheRewriteCount() {
        // The user said PayPal correctly once *and* was misheard once, so the
        // delivered text carries two PayPals but only one of them came from the
        // dictionary. Nothing in `{from, to, termId}` says which, and replacing
        // both would destroy a word the user said correctly — strictly worse
        // than the mis-transcription being undone. So: forget the term, leave
        // the text, and say so.
        let decision = AliasUndo.decide(
            undoing: payPal,
            in: "PayPal 和 PayPal",
            replacements: [payPal],
            window: window(),
            now: deliveredAt + 1,
            frontmostBundleId: targetApp
        )

        XCTAssertEqual(decision, .forgetTermOnly(.textNoLongerMatches))
        XCTAssertNil(decision.restoredText)
        XCTAssertTrue(decision.deletesTerm, "the term is wrong either way")
    }

    func testUndoDeletesTheTermWhenTheCanonicalIsNoLongerInTheDeliveredText() {
        // Tidy runs after alias correction and Review lets the user edit before
        // committing, so the delivered text is not always the ASR text. If the
        // word is not there any more there is nothing to put back.
        let decision = AliasUndo.decide(
            undoing: payPal,
            in: "我用支付宝付款",
            replacements: [payPal],
            window: window(),
            now: deliveredAt + 1,
            frontmostBundleId: targetApp
        )

        XCTAssertEqual(decision, .forgetTermOnly(.textNoLongerMatches))
    }

    func testMatchingTheCanonicalIsCaseSensitive() {
        // The canonical is written back with its own casing, so an occurrence
        // in different casing came from the user, not from us, and must not be
        // counted as one of ours.
        let decision = AliasUndo.decide(
            undoing: payPal,
            in: "PAYPAL 和 PayPal",
            replacements: [payPal],
            window: window(),
            now: deliveredAt + 1,
            frontmostBundleId: targetApp
        )

        XCTAssertEqual(decision, .restoreText("PAYPAL 和 呸泡"))
    }

    // MARK: - Undo: the window, borrowed rather than re-invented

    func testUndoAfterTheWindowClosesDeletesTheTermWithoutTouchingTheText() {
        let expired = deliveredAt + CorrectionWindow.windowSeconds

        let decision = AliasUndo.decide(
            undoing: payPal,
            in: "我用PayPal付款",
            replacements: [payPal],
            window: window(),
            now: expired,
            frontmostBundleId: targetApp
        )

        XCTAssertEqual(decision, .forgetTermOnly(.windowExpired))
        XCTAssertNil(decision.restoredText)
        XCTAssertTrue(decision.deletesTerm)
    }

    func testTheUndoDeadlineIsExactlyCorrectionWindowsOwnDeadline() {
        // Deliberately expressed in terms of `CorrectionWindow.windowSeconds`
        // rather than the literal 8: the feature has one time limit, and it is
        // that one.
        let state = window()
        let justInside = deliveredAt + CorrectionWindow.windowSeconds - 0.001
        let atDeadline = deliveredAt + CorrectionWindow.windowSeconds

        XCTAssertFalse(state.isExpired(at: justInside))
        XCTAssertTrue(state.isExpired(at: atDeadline))

        XCTAssertEqual(
            AliasUndo.decide(
                undoing: payPal,
                in: "我用PayPal付款",
                replacements: [payPal],
                window: state,
                now: justInside,
                frontmostBundleId: targetApp
            ),
            .restoreText("我用呸泡付款")
        )
        XCTAssertEqual(
            AliasUndo.decide(
                undoing: payPal,
                in: "我用PayPal付款",
                replacements: [payPal],
                window: state,
                now: atDeadline,
                frontmostBundleId: targetApp
            ),
            .forgetTermOnly(.windowExpired)
        )
    }

    func testUndoAgreesWithCorrectionWindowAcrossTheWholeWindow() {
        // The reuse, asserted rather than asked for: at every instant either
        // side of the boundary, "may I restore the text" and "is the correction
        // window still open" have to be the same answer. A second timing rule
        // — a longer one for undo, a rounded one, one measured from the toast
        // instead of the delivery — would show up here as a disagreement.
        let state = window()
        let offsets: [TimeInterval] = [
            -1, 0, 0.001, 1, 4,
            CorrectionWindow.windowSeconds - 1,
            CorrectionWindow.windowSeconds - 0.001,
            CorrectionWindow.windowSeconds,
            CorrectionWindow.windowSeconds + 0.001,
            CorrectionWindow.windowSeconds * 2,
        ]

        for offset in offsets {
            let now = deliveredAt + offset
            let decision = AliasUndo.decide(
                undoing: payPal,
                in: "我用PayPal付款",
                replacements: [payPal],
                window: state,
                now: now,
                frontmostBundleId: targetApp
            )
            XCTAssertEqual(
                decision.restoredText != nil,
                !state.isExpired(at: now),
                "undo and the correction window disagree at offset \(offset)"
            )
        }
    }

    func testNoOpenWindowAtAllIsTreatedAsExpired() {
        // `AppModel` clears the window on a new recording, on Esc, and on an
        // ineligible delivery. A toast can outlive that, so `nil` has to be a
        // defined input rather than a crash or a permissive default.
        let decision = AliasUndo.decide(
            undoing: payPal,
            in: "我用PayPal付款",
            replacements: [payPal],
            window: nil,
            now: deliveredAt + 1,
            frontmostBundleId: targetApp
        )

        XCTAssertEqual(decision, .forgetTermOnly(.windowExpired))
    }

    // MARK: - Undo: the target app, borrowed rather than re-invented

    func testUndoInADifferentAppDeletesTheTermWithoutTouchingTheText() {
        // Restoring goes out through the same `ContextBridge.insert` (Cmd+V)
        // path a delivery does, so pasting after the user has switched apps
        // would overwrite whatever they have selected somewhere else entirely.
        let decision = AliasUndo.decide(
            undoing: payPal,
            in: "我用PayPal付款",
            replacements: [payPal],
            window: window(),
            now: deliveredAt + 1,
            frontmostBundleId: "com.tinyspeck.slackmacgap"
        )

        XCTAssertEqual(decision, .forgetTermOnly(.targetApplicationChanged))
        XCTAssertNil(decision.restoredText)
        XCTAssertTrue(decision.deletesTerm)
    }

    func testUndoAgreesWithOutputDeliveryPolicyOnEveryPairOfApps() {
        // The same reuse argument as the window: a correction and a delivery
        // write through one path, so they must never disagree about one pair of
        // apps. Note the `nil`-captured case, where `OutputDeliveryPolicy`
        // deliberately permits the write — undo must inherit that rather than
        // quietly being stricter.
        let pairs: [(captured: String?, frontmost: String?)] = [
            ("com.apple.Notes", "com.apple.Notes"),
            ("com.apple.Notes", "com.tinyspeck.slackmacgap"),
            ("com.apple.Notes", nil),
            (nil, "com.apple.Notes"),
            (nil, nil),
        ]

        for pair in pairs {
            let decision = AliasUndo.decide(
                undoing: payPal,
                in: "我用PayPal付款",
                replacements: [payPal],
                window: window(capturedBundleId: pair.captured),
                now: deliveredAt + 1,
                frontmostBundleId: pair.frontmost
            )
            XCTAssertEqual(
                decision.restoredText != nil,
                OutputDeliveryPolicy.shouldInsert(
                    capturedBundleId: pair.captured,
                    frontmostBundleId: pair.frontmost
                ),
                "undo and the delivery policy disagree for \(String(describing: pair))"
            )
        }
    }

    // MARK: - Undo: precedence, so one click has one explanation

    func testAnExpiredWindowIsReportedEvenWhenTheAppAlsoChanged() {
        // Both are true and only one sentence gets shown. Expiry wins because
        // it is the one that is unconditionally true: telling someone who
        // waited a minute that the problem was switching apps invites them to
        // switch back and try again, which will not work.
        let decision = AliasUndo.decide(
            undoing: payPal,
            in: "完全不同的一段文字",
            replacements: [payPal],
            window: window(),
            now: deliveredAt + CorrectionWindow.windowSeconds + 60,
            frontmostBundleId: "com.tinyspeck.slackmacgap"
        )

        XCTAssertEqual(decision, .forgetTermOnly(.windowExpired))
    }

    func testAChangedAppIsReportedEvenWhenTheTextAlsoNoLongerMatches() {
        // Where the caret is beats what the text says: the user's fix for the
        // first is real ("go back to Notes"), and reporting the second would
        // send them looking at text they cannot even see.
        let decision = AliasUndo.decide(
            undoing: payPal,
            in: "完全不同的一段文字",
            replacements: [payPal],
            window: window(),
            now: deliveredAt + 1,
            frontmostBundleId: "com.tinyspeck.slackmacgap"
        )

        XCTAssertEqual(decision, .forgetTermOnly(.targetApplicationChanged))
    }

    // MARK: - What the user is told

    func testEveryOutcomeSaysSomethingAndTheThreeSayDifferentThings() {
        // The failure this guards against is one shared 「已撤销」 for all of
        // them: the user clicks, the text does not change, and nothing on
        // screen explains why. Exact wording is not pinned — it moves with the
        // interface-language work (§F) — but distinctness is, because that is
        // the property the product needs.
        let restored = AliasUndo.message(for: .restoreText("我用呸泡付款"))
        let expired = AliasUndo.message(for: .forgetTermOnly(.windowExpired))
        let switched = AliasUndo.message(
            for: .forgetTermOnly(.targetApplicationChanged)
        )
        let unmatched = AliasUndo.message(
            for: .forgetTermOnly(.textNoLongerMatches)
        )

        let messages: [String] = [restored, expired, switched, unmatched]
        for message in messages {
            XCTAssertFalse(
                message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        XCTAssertEqual(Set(messages).count, messages.count)
    }

    // MARK: - Fixtures

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
