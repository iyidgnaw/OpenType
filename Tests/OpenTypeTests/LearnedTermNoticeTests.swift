import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for **D-2** — 「入典结果可见（已记住）」
/// (`docs/superpowers/specs/2026-08-15-product-batch-plan.md` §D-2, motivated by
/// `docs/reviews/2026-08-15-product-review.md` §1).
///
/// `POST /transcribe/correct` has returned `learned: { canonicalTerm, alias }`
/// since P0-2, and `AppModel`'s `CorrectionResponseBody` has decoded it since
/// then too — into a property whose own doc comment says 「nothing reads this
/// yet」. So the second of the loop's three exits is silent: the user corrects
/// 「呸泡」 to PayPal, the product quietly writes an alias that will change every
/// future transcription, and says nothing about having done so. The one moment
/// where the user could notice, verify, or object is spent in silence.
///
/// ## Why the acknowledgement is a value, not a string
///
/// §D-2 asks for 「已记住：呸泡 → PayPal」 **and** for clicking it to open the
/// memory page with that row selected. A bare `String` cannot carry the second
/// half, and re-parsing the term back out of the sentence is exactly the kind of
/// thing that survives until someone translates the copy (§F). So the notice
/// carries the sentence and the term it is about.
///
/// ## Both correction paths, one function
///
/// The Review panel's `processCorrection` and Direct mode's
/// `processInPlaceCorrection` are separate methods that share exactly one thing:
/// `requestCorrection`, and therefore this response. `notice(for:)` takes the
/// decoded `learned` and nothing else — no path parameter, no mode — precisely
/// so there is one implementation for both to call and no way for them to
/// disagree about what a correction taught. `AppModel` is not instantiable in
/// tests (its `init` has side effects), so **Stage 3 must wire both call sites
/// and Stage 4 must check that it did**: an acknowledgement that only appears
/// in the Review panel would leave the in-place path — the higher-frequency one,
/// since P0-3 put it one keypress after every Direct delivery — exactly as
/// silent as it is today.
///
/// ## Expected shape (Stage 3 creates it; nothing here builds it)
///
///     struct LearnedTerm: Decodable, Equatable {
///         let canonicalTerm: String
///         let alias: String
///     }
///
///     struct CorrectionResponse: Decodable, Equatable {
///         let replacement: String
///         let learned: LearnedTerm?
///     }
///
///     enum LearnedTermNotice {
///         struct Notice: Equatable {
///             let text: String            // 「已记住：呸泡 → PayPal」
///             let canonicalTerm: String   // the row the click reveals
///         }
///         static func notice(for learned: LearnedTerm?) -> Notice?
///     }
///
/// `AppModel`'s private `CorrectionResponseBody` is expected to be replaced by
/// `CorrectionResponse` rather than duplicated — two decoders for one endpoint
/// is how the field ended up read by nobody in the first place.
///
/// These tests fail to COMPILE until those exist — the established red here.
final class LearnedTermNoticeTests: XCTestCase {

    // MARK: - Decoding what the sidecar actually sends

    func testACorrectionThatTaughtNothingDecodesWithNoLearnedTerm() throws {
        // `sidecar/src/transcribe/routes.ts` omits the key entirely rather than
        // sending null (「a caller can test for the key's presence」), and it
        // does so for every rewrite that did not qualify — a reworded phrase, a
        // pure case fix, a span too long to be a term. That is the common case,
        // and it has to decode.
        let response = try decode(
            CorrectionResponse.self,
            from: #"{"replacement":"把这段话改得更正式一些"}"#
        )

        XCTAssertEqual(response.replacement, "把这段话改得更正式一些")
        XCTAssertNil(response.learned)
    }

    func testACorrectionThatTaughtATermCarriesBothSpellings() throws {
        let response = try decode(
            CorrectionResponse.self,
            from: #"{"replacement":"PayPal","learned":{"canonicalTerm":"PayPal","alias":"呸泡"}}"#
        )

        XCTAssertEqual(response.replacement, "PayPal")
        XCTAssertEqual(
            response.learned,
            LearnedTerm(canonicalTerm: "PayPal", alias: "呸泡")
        )
    }

    // MARK: - The acknowledgement

    func testNothingIsAcknowledgedWhenTheCorrectionTaughtNothing() {
        // Silence is correct here, and it is the majority case: claiming 「已
        // 记住」 after a rewrite that was deliberately *not* learned would teach
        // the user to distrust the one signal this feature adds.
        XCTAssertNil(LearnedTermNotice.notice(for: nil))
    }

    func testTheAcknowledgementNamesBothSpellingsInTheDirectionOfTheRewrite() throws {
        // 「呸泡 → PayPal」 and 「PayPal → 呸泡」 describe opposite dictionaries,
        // and only one of them is what just happened. The direction is asserted
        // by position rather than by pinning the whole sentence, so the copy can
        // still be translated (§F) without this test having an opinion.
        let notice = try XCTUnwrap(
            LearnedTermNotice.notice(
                for: LearnedTerm(canonicalTerm: "PayPal", alias: "呸泡")
            )
        )

        let aliasRange = try XCTUnwrap(notice.text.range(of: "呸泡"))
        let canonicalRange = try XCTUnwrap(notice.text.range(of: "PayPal"))
        XCTAssertTrue(
            aliasRange.lowerBound < canonicalRange.lowerBound,
            "the misheard spelling comes first: \(notice.text)"
        )
    }

    func testTheAcknowledgementCarriesTheCanonicalTermForTheClickThrough() throws {
        // Clicking 「已记住」 opens the memory page with this row selected, and
        // the dictionary is keyed on the canonical spelling — the alias is one
        // of possibly several on that row and would select nothing on its own.
        let notice = try XCTUnwrap(
            LearnedTermNotice.notice(
                for: LearnedTerm(canonicalTerm: "PayPal", alias: "呸泡")
            )
        )

        XCTAssertEqual(notice.canonicalTerm, "PayPal")
    }

    func testTwoDifferentLearnedTermsProduceDifferentAcknowledgements() {
        // Guards the shape where the sentence is a constant 「已记住一个新词」
        // and the term is dropped: the user could not then tell a correct entry
        // from one they need to go delete, which is the whole reason the
        // dictionary panel became editable (P0-4).
        let payPal = LearnedTermNotice.notice(
            for: LearnedTerm(canonicalTerm: "PayPal", alias: "呸泡")
        )
        let anthropic = LearnedTermNotice.notice(
            for: LearnedTerm(canonicalTerm: "Anthropic", alias: "安思罗匹克")
        )

        XCTAssertNotNil(payPal)
        XCTAssertNotNil(anthropic)
        XCTAssertNotEqual(payPal, anthropic)
    }

    func testAnEmptyOrBlankLearnedTermIsNotAcknowledged() {
        // Defensive, and cheap: the sidecar's gate should never emit one, but a
        // toast reading 「已记住： →  」 is a bug the user is left holding, and
        // the alternative — showing nothing — costs nothing.
        XCTAssertNil(
            LearnedTermNotice.notice(
                for: LearnedTerm(canonicalTerm: "", alias: "呸泡")
            )
        )
        XCTAssertNil(
            LearnedTermNotice.notice(
                for: LearnedTerm(canonicalTerm: "PayPal", alias: "   ")
            )
        )
    }

    // MARK: - Fixtures

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
