import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for §C of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — "转写语言真的传到 Whisper".
///
/// ## What is actually broken
///
/// This is not a missing feature, it is a **false promise that already
/// shipped** (`docs/reviews/2026-08-15-product-review.md` §2). Settings offers
/// 27 languages, and today `TranscriptionLanguage` only knows how to express
/// itself as `appleLocaleIdentifier` — the locale for Apple's *live-caption
/// preview*. The final transcript comes from MLX-Whisper via the sidecar, which
/// is never told anything about language at all. A user who picks "English"
/// and still gets Chinese punctuation concludes the product is broken.
///
/// The missing piece is one property (Stage 3 creates it; nothing here builds
/// it):
///
///     extension TranscriptionLanguage {
///         /// The ISO-639 code Whisper expects, or nil for "let it detect".
///         var whisperCode: String? { ... }
///     }
///
/// ## Why the table below is written out in full
///
/// A `default:` arm that silently returns `nil` for an unmapped case is exactly
/// the bug this suite exists to prevent: it would compile, ship, and turn the
/// 28th language back into a decorative picker with nobody noticing. So the
/// expectations live in one exhaustive table and
/// `testEveryLanguageHasAnExpectationRecordedInThisTable` fails loudly when a
/// case is added without one — the test is the forcing function, not a
/// `switch`'s exhaustiveness (which a `default:` defeats).
///
/// ## Two codes, not one
///
/// `appleLocaleIdentifier` (`"zh-CN"`, `"nb-NO"`, `"fil-PH"`) and `whisperCode`
/// (`"zh"`, `"no"`, `"tl"`) are different vocabularies and must not be derived
/// from each other. Whisper rejects a code outside its own table, so
/// `String(appleLocaleIdentifier.prefix(2))` — the obvious-looking shortcut —
/// produces `"fi"` (Finnish) for Filipino and `"nb"` (not in Whisper's set at
/// all) for Norwegian. Hence the shape assertions below.
final class TranscriptionLanguageWhisperCodeTests: XCTestCase {

    // MARK: - The mapping table

    /// Every case, exhaustively, with the code Whisper's own language table
    /// uses. Codes are ISO-639-1 two-letter codes (Whisper's `LANGUAGES` keys),
    /// **not** BCP-47 locale identifiers and not the App's Apple-locale
    /// strings.
    ///
    /// Three entries are deliberately not what a reader would guess, and each
    /// has its own named test below so a future "cleanup" cannot quietly
    /// normalise them:
    ///  - `.filipino` → `"tl"` — Whisper's set has Tagalog (`tl`) and no
    ///    `fil`/`ph` entry at all.
    ///  - `.norwegian` → `"no"` — Whisper's key is the macrolanguage `no`, not
    ///    Bokmål (`nb`, which its tokenizer does not know) despite the app's
    ///    `nb-NO` live-caption locale.
    ///  - `.cantonese` → `"zh"`, **not** `"yue"` — measured, see
    ///    `testCantoneseFallsBackToChineseBecauseTheShippedWeightsRejectYue`.
    ///    This is the one deliberate collision in the table.
    private static let expectedWhisperCodes: [TranscriptionLanguage: String?] = [
        // "Automatic" is the absence of a language, not a language: Whisper
        // detects it from the audio. Anything other than nil here would turn
        // the default setting into a forced language.
        .automatic: nil,
        .chinese: "zh",
        // Deliberately the same code as `.chinese`; measured, not a slip.
        .cantonese: "zh",
        .english: "en",
        .japanese: "ja",
        .korean: "ko",
        .german: "de",
        .french: "fr",
        .spanish: "es",
        .italian: "it",
        .portuguese: "pt",
        .russian: "ru",
        .arabic: "ar",
        .hindi: "hi",
        .indonesian: "id",
        .thai: "th",
        .turkish: "tr",
        .vietnamese: "vi",
        .ukrainian: "uk",
        .czech: "cs",
        .danish: "da",
        .filipino: "tl",
        .finnish: "fi",
        .icelandic: "is",
        .malay: "ms",
        .norwegian: "no",
        .polish: "pl",
        .swedish: "sv",
    ]

    // MARK: - Exhaustiveness

    func testEveryLanguageHasAnExpectationRecordedInThisTable() {
        // The guard against "added a 28th case, forgot the mapping". A new case
        // with no table entry fails here; a new case with a table entry but no
        // `whisperCode` arm fails in the next test.
        for language in TranscriptionLanguage.allCases {
            XCTAssertNotNil(
                Self.expectedWhisperCodes[language],
                """
                \(language.rawValue) has no expected Whisper code. Adding a \
                language means adding it to `whisperCode` AND to this table — \
                a `default:` that returns nil would ship a language picker \
                entry that silently does nothing.
                """
            )
        }
        // And the reverse: a case deleted from the enum must not leave a stale
        // expectation behind pretending to cover something.
        XCTAssertEqual(
            TranscriptionLanguage.allCases.count,
            Self.expectedWhisperCodes.count,
            "the table and the enum disagree on how many languages exist"
        )
    }

    // MARK: - The mapping itself

    func testEveryLanguageMapsToItsWhisperCode() {
        for language in TranscriptionLanguage.allCases {
            guard let expected = Self.expectedWhisperCodes[language] else {
                // Reported by the exhaustiveness test above; nothing to assert.
                continue
            }
            XCTAssertEqual(
                language.whisperCode,
                expected,
                "\(language.rawValue) should map to \(expected.map { "\"\($0)\"" } ?? "nil")"
            )
        }
    }

    func testAutomaticSendsNoLanguageAtAll() {
        // nil is the whole contract on the sidecar side: no `language` field in
        // the request body, no `language` query parameter, no decode option —
        // Whisper's own detection, which is what "自动识别（支持混合语言）"
        // promises. An empty string would not be equivalent: it would travel
        // as `language=""` and reach `mlx_whisper` as a language named "".
        XCTAssertNil(TranscriptionLanguage.automatic.whisperCode)
    }

    func testAutomaticIsTheOnlyLanguageWithoutACode() {
        for language in TranscriptionLanguage.allCases where language != .automatic {
            XCTAssertNotNil(
                language.whisperCode,
                "\(language.rawValue) is a real language and must resolve to a Whisper code"
            )
        }
    }

    // MARK: - Shape (a Whisper code is not an Apple locale)

    func testCodesAreBareLowercaseISOCodesRatherThanLocaleIdentifiers() {
        for language in TranscriptionLanguage.allCases {
            guard let code = language.whisperCode else { continue }
            XCTAssertFalse(
                code.contains("-") || code.contains("_"),
                "\(language.rawValue): \"\(code)\" looks like a locale identifier, not a Whisper language code"
            )
            XCTAssertTrue(
                code.allSatisfy { $0.isASCII && $0.isLowercase && $0.isLetter },
                "\(language.rawValue): \"\(code)\" must be lowercase ASCII letters"
            )
            // Every code in the table today is a two-letter ISO-639-1 key. The
            // upper bound is deliberately 3 rather than 2 so that a future
            // three-letter Whisper key (`yue`, `nan`, `haw`) is a decision the
            // cantonese/table tests adjudicate on the merits, not something
            // this shape check rejects on sight.
            XCTAssertTrue(
                (2...3).contains(code.count),
                "\(language.rawValue): \"\(code)\" is not a 2- or 3-letter code"
            )
        }
    }

    func testTheWhisperCodeIsIndependentOfTheAppleLiveCaptionLocale() {
        // The bug being fixed is precisely that the picker only ever reached
        // the Apple recognizer. These two vocabularies must stay separate:
        // deriving one from the other is wrong for Filipino and Norwegian.
        XCTAssertEqual(TranscriptionLanguage.chinese.appleLocaleIdentifier, "zh-CN")
        XCTAssertEqual(TranscriptionLanguage.chinese.whisperCode, "zh")

        // `.automatic` still needs a locale for live captions (it falls back to
        // zh-CN) while having no Whisper language at all.
        XCTAssertEqual(TranscriptionLanguage.automatic.appleLocaleIdentifier, "zh-CN")
        XCTAssertNil(TranscriptionLanguage.automatic.whisperCode)
    }

    func testNoTwoLanguagesShareACodeApartFromTheCantoneseFallback() {
        // A copy-paste slip in a 28-arm switch (`.icelandic: return "da"`) is
        // invisible by inspection and produces confidently wrong transcripts.
        //
        // `.cantonese` is excluded because it is the one case that genuinely
        // does collide: the shipped MLX weights reject `yue`, so it falls back
        // to `"zh"`, which `.chinese` already uses. That collision is pinned by
        // the cantonese test below — excluding it here is not a licence to let
        // it drift, it is what keeps this test about copy-paste slips.
        let codes = TranscriptionLanguage.allCases
            .filter { $0 != .cantonese }
            .compactMap(\.whisperCode)
        XCTAssertEqual(
            Set(codes).count,
            codes.count,
            "two languages resolve to the same Whisper code"
        )
    }

    // MARK: - The three entries that are not what they look like

    func testCantoneseFallsBackToChineseBecauseTheShippedWeightsRejectYue() {
        // §C of the batch plan names `"yue"` as the intended value but requires
        // it to be measured first ("实现阶段实测一次，不支持就退回 zh"). It was
        // measured on 2026-08-15, against the model `serve.py` actually ships
        // (`DEFAULT_MODEL = mlx-community/whisper-small-mlx`, mlx_whisper
        // 0.4.3) and through the same `mlx_whisper.transcribe` call serve.py
        // makes:
        //
        //   $ sidecar/whisper-env/bin/python3 -c "import numpy as np, mlx_whisper; \
        //       mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), \
        //       path_or_hf_repo='mlx-community/whisper-small-mlx', language='yue')"
        //   ValueError: tuple.index(x): x not in tuple
        //
        // The same call with `language="zh"` returns normally. The reason is
        // structural, not a version fluke: `yue` is the 100th and last key of
        // Whisper's LANGUAGES table (added with large-v3), whisper-small's
        // checkpoint has `n_vocab == 51865` so `model.num_languages` is 99, and
        // the tokenizer truncates the table to the first 99 keys before looking
        // the language up.
        //
        // That is not a degradation, it is an outage: `serve.py` catches every
        // exception and answers HTTP 500, which `asr/routes.ts` turns into a
        // 502, so mapping 粤语 to `"yue"` would fail *every* Cantonese
        // transcription — strictly worse than today's setting-that-does-nothing.
        //
        // Stage 3 obligations: re-run the command above rather than trusting
        // this comment, and record the measurement as a comment on the enum
        // case itself, which is what §C asks for. Note the mapping is static
        // while the model is not (`OPENTYPE_WHISPER_MODEL`, and item E's model
        // picker) — on large-v3 `yue` would work, so if the default model ever
        // changes this is the first thing to re-measure. Until then, do not
        // "fix" this to `"yue"`, and do not delete the test to make it pass.
        XCTAssertEqual(TranscriptionLanguage.cantonese.whisperCode, "zh")
        // Stated as its own assertion because this collision is exactly what
        // `testNoTwoLanguagesShareACodeApartFromTheCantoneseFallback` waives.
        XCTAssertEqual(
            TranscriptionLanguage.cantonese.whisperCode,
            TranscriptionLanguage.chinese.whisperCode
        )
    }

    func testFilipinoUsesWhispersTagalogCode() {
        // Whisper has no `fil` and no `ph`; Tagalog (`tl`) is the entry that
        // covers Filipino. Note the app's locale is `fil-PH`, whose first two
        // characters spell Finnish.
        XCTAssertEqual(TranscriptionLanguage.filipino.whisperCode, "tl")
        XCTAssertNotEqual(TranscriptionLanguage.filipino.whisperCode, "fil")
        XCTAssertNotEqual(
            TranscriptionLanguage.filipino.whisperCode,
            TranscriptionLanguage.finnish.whisperCode
        )
    }

    func testNorwegianUsesWhispersMacrolanguageCodeNotBokmal() {
        // The app's live-caption locale is `nb-NO` (Bokmål), but Whisper's
        // table keys Norwegian as `no`. `nb` is not in it.
        XCTAssertEqual(TranscriptionLanguage.norwegian.whisperCode, "no")
    }

    // MARK: - Spot checks named by the spec

    func testTheSpecsWorkedExamplesMapAsWritten() {
        // `docs/superpowers/specs/2026-08-15-product-batch-plan.md` §C spells
        // these out inline; keeping them as literals here means a reader can
        // diff spec against test without reconstructing the table.
        XCTAssertNil(TranscriptionLanguage.automatic.whisperCode)
        XCTAssertEqual(TranscriptionLanguage.chinese.whisperCode, "zh")
        XCTAssertEqual(TranscriptionLanguage.english.whisperCode, "en")
        XCTAssertEqual(TranscriptionLanguage.japanese.whisperCode, "ja")
    }
}
