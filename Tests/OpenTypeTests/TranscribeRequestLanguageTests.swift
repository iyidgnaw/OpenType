import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the Swift half of §C of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — "转写语言真的传到 Whisper".
///
/// ## What is still broken after the sidecar half landed
///
/// `TranscriptionLanguage.whisperCode` exists and is pinned exhaustively by
/// `TranscriptionLanguageWhisperCodeTests`, and the sidecar accepts an optional
/// `language` on `POST /asr/transcribe` and honours it on both backends. But
/// **`whisperCode` has no production caller**: `AppModel.transcribeLocally`
/// still sends a body of `{ "audioBase64": … }` and nothing else, so the user's
/// choice never leaves the app. The false promise `docs/reviews/2026-08-15-product-review.md`
/// §2 describes is therefore still fully intact — a built seam that nothing
/// reads is worth exactly as much as no seam at all, which is why this repo
/// deleted a whole memory layer for the same reason (P1-7).
///
/// The missing piece is the mapping from the setting to the wire (Stage 3
/// creates it; nothing here builds it):
///
///     extension AppModel {
///         nonisolated static func transcribeRequestBody(
///             audioBase64: String,
///             language: TranscriptionLanguage
///         ) -> TranscribeRequestBody
///     }
///
/// ## Why a request-body seam and not a mock sidecar
///
/// `AppModel` has a no-argument `init()` that spawns the sidecar child process,
/// registers global hotkeys and touches `NSApp` — no test in this suite
/// constructs one, and this change does not justify being the first. What is
/// actually at stake is one mapping (setting → JSON field), so the seam is that
/// mapping as a pure `static` function and `transcribeLocally` becomes its only
/// caller. The gap this leaves is real and named: these tests pin what the body
/// looks like, not that the recording path builds it that way.
///
/// ## Absent means unchanged
///
/// `automatic` must produce byte-for-byte the body that shipped before the
/// field existed — no `"language"` key, not `null` and not `""`. The sidecar
/// pins the same contract from its side (`sidecar/src/asr/routes.ts` only sets
/// `options.language` for a non-empty string), and `testAutomaticSendsNoLanguageKeyAtAll`
/// is what stops a future `String?` → `String` "cleanup" from turning the
/// default setting into a forced language.
final class TranscribeRequestLanguageTests: XCTestCase {

    /// The encoded `/asr/transcribe` body as the sidecar's JSON parser sees it:
    /// a key/value map where an omitted optional is a *missing key*, which is
    /// the distinction every assertion below turns on.
    private func encodedBody(
        audioBase64: String = "UklGRiQAAABXQVZF",
        language: TranscriptionLanguage
    ) throws -> [String: Any] {
        let body = AppModel.transcribeRequestBody(audioBase64: audioBase64, language: language)
        let data = try JSONEncoder().encode(body)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "request body must encode as a JSON object")
    }

    // MARK: - The selected language reaches the wire

    func testSelectedLanguageRidesOnTheTranscribeRequestBody() throws {
        let json = try encodedBody(language: .english)

        XCTAssertEqual(
            json["language"] as? String,
            "en",
            "the user's transcription-language choice must reach /asr/transcribe"
        )
        XCTAssertEqual(json["audioBase64"] as? String, "UklGRiQAAABXQVZF")
    }

    func testEveryLanguageRidesAsItsOwnWhisperCode() throws {
        for language in TranscriptionLanguage.allCases where language != .automatic {
            let json = try encodedBody(language: language)
            XCTAssertEqual(
                json["language"] as? String,
                language.whisperCode,
                """
                \(language.rawValue) must be sent as its `whisperCode`, not as a \
                locale, a prefix of one, or the raw case name — Whisper rejects \
                any code outside its own table outright
                """
            )
        }
    }

    // MARK: - `automatic` sends the body that already existed

    func testAutomaticSendsNoLanguageKeyAtAll() throws {
        let json = try encodedBody(language: .automatic)

        XCTAssertNil(
            json["language"],
            "`automatic` is the absence of a language: an explicit null or \"\" would be a value the sidecar has to special-case"
        )
        XCTAssertEqual(
            Set(json.keys),
            ["audioBase64"],
            "the automatic body must stay exactly the shape that shipped before this field existed"
        )
    }

    /// The audio payload is the part that must survive unchanged for every
    /// setting — a language must never displace or truncate it, the same
    /// independence the sidecar pins between `language` and `initialPrompt`.
    func testAudioSurvivesForEverySetting() throws {
        for language in TranscriptionLanguage.allCases {
            let json = try encodedBody(audioBase64: "QUJD", language: language)
            XCTAssertEqual(
                json["audioBase64"] as? String,
                "QUJD",
                "\(language.rawValue) altered the audio payload"
            )
        }
    }
}
