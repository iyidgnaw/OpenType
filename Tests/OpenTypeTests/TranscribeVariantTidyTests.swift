import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the *settings and routing* half of P1-8
/// (`docs/superpowers/specs/2026-08-14-product-batch-plan.md`, 听写「轻整理」档).
/// The deterministic text rules themselves are pinned in `TidyTranscriptTests`.
///
/// `TranscribeVariant` goes from `direct | review` to `direct | tidy | review`.
/// It stays **one axis — how a transcribe-mode recording is delivered** — and
/// gains no new `InputMode`: tidy is still pure ASR plus deterministic local
/// cleanup, so it must not acquire an LLM call, a provider requirement, or a
/// surface of its own. Everything downstream of the transcript (clipboard copy,
/// optional auto-insert, the post-delivery correction window) must behave for
/// `tidy` exactly as it does for `direct`.
///
/// These tests are RED until Stage 3 adds the `tidy` case to `TranscribeVariant`
/// (`Sources/OpenType/Models.swift`), its `deliverableText(for:)` routing seam,
/// and `Sources/OpenType/TidyTranscript.swift`. They currently fail to COMPILE
/// because none of those exist yet — that is the intended red.
final class TranscribeVariantTidyTests: XCTestCase {

    // MARK: - The enum surface

    func testTidySitsBetweenDirectAndReviewInAllCases() {
        // `allCases` is what Settings' picker renders in order
        // (`Views.swift`'s `ForEach(TranscribeVariant.allCases)`), so the order
        // is user-visible and worth pinning. The three variants form a ladder of
        // increasing intervention — raw ⇢ deterministic cleanup ⇢ human review —
        // and tidy belongs next to the variant it most resembles, not appended
        // to the end where it would read as an afterthought.
        XCTAssertEqual(
            TranscribeVariant.allCases,
            [.direct, .tidy, .review]
        )
    }

    func testRawValuesAreStableSoStoredPreferencesSurvive() {
        // Persisted verbatim in UserDefaults (`AppConfiguration.Keys.transcribeVariant`).
        // Renaming an existing raw value would silently reset every current
        // user's choice back to the default.
        XCTAssertEqual(TranscribeVariant.direct.rawValue, "direct")
        XCTAssertEqual(TranscribeVariant.tidy.rawValue, "tidy")
        XCTAssertEqual(TranscribeVariant.review.rawValue, "review")
        XCTAssertEqual(TranscribeVariant(rawValue: "tidy"), .tidy)
    }

    func testEveryVariantHasItsOwnNonEmptyTitleAndExplanation() {
        // Both strings are rendered in Settings; the picker is unusable if two
        // variants share a label. Content is localized (`OpenTypeL10n`), so
        // assert distinctness rather than specific wording.
        let titles = TranscribeVariant.allCases.map(\.title)
        let explanations = TranscribeVariant.allCases.map(\.explanation)

        for text in titles + explanations {
            XCTAssertFalse(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        XCTAssertEqual(Set(titles).count, TranscribeVariant.allCases.count)
        XCTAssertEqual(
            Set(explanations).count,
            TranscribeVariant.allCases.count
        )
    }

    // MARK: - The default must not move

    @MainActor
    func testDefaultVariantIsStillDirectSoExistingUsersAreUnaffected() {
        // Adding a variant must change nobody's behavior until they pick it.
        // Direct's promise is 「一个字都不多、一个字都不少」 and it stays the
        // out-of-the-box contract.
        let suiteName = "TidyTests.DefaultVariant.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppConfiguration(defaults: defaults).transcribeVariant, .direct)
    }

    @MainActor
    func testTidyPersistsAcrossRelaunchAndGarbageFallsBackToDirect() {
        let suiteName = "TidyTests.PersistVariant.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        configuration.transcribeVariant = .tidy
        XCTAssertEqual(
            AppConfiguration(defaults: defaults).transcribeVariant,
            .tidy
        )

        // An unreadable stored value must land on the safest variant, not on
        // one that rewrites the user's words.
        defaults.set("polish", forKey: "transcribeVariant")
        XCTAssertEqual(
            AppConfiguration(defaults: defaults).transcribeVariant,
            .direct
        )
    }

    // MARK: - Routing: tidy is a delivery variant, not a mode that calls a model

    /// A filler-heavy transcript, so "unchanged" and "tidied" cannot be
    /// accidentally equal.
    private let rawTranscript = "嗯，我我我想说，那个，就是说,好吗?"

    func testDirectDeliversTheTranscriptByteForByte() {
        // The whole point of Direct: not one character more, not one less.
        XCTAssertEqual(
            TranscribeVariant.direct.deliverableText(for: rawTranscript),
            rawTranscript
        )
    }

    func testTidyDeliversExactlyWhatTidyTranscriptProduces() {
        // The routing seam must delegate to the pure module rather than grow a
        // second copy of the rules — and must deliver immediately, like Direct,
        // rather than stage anything.
        let delivered = TranscribeVariant.tidy.deliverableText(for: rawTranscript)

        XCTAssertEqual(delivered, TidyTranscript.tidy(rawTranscript))
        XCTAssertNotEqual(
            delivered,
            rawTranscript,
            "tidy must actually clean a filler-heavy transcript"
        )
    }

    func testReviewDeliversNothingBecauseItStagesInThePanel() {
        // `nil` is the existing "dispatched, don't deliver yet" path
        // (`AppModel.process` hands the transcript to `beginReviewSession`).
        // Tidy must not join it.
        XCTAssertNil(TranscribeVariant.review.deliverableText(for: rawTranscript))
        XCTAssertNotNil(TranscribeVariant.tidy.deliverableText(for: rawTranscript))
        XCTAssertNotNil(TranscribeVariant.direct.deliverableText(for: rawTranscript))
    }

    func testTidyDeliverySurvivesTranscriptsWithNothingToClean() {
        // A clean transcript through tidy is still delivered — never dropped,
        // never emptied.
        let clean = "我们明天开会。"
        XCTAssertEqual(
            TranscribeVariant.tidy.deliverableText(for: clean),
            clean
        )
    }

    func testTidyNeverDeliversAnEmptyStringForATranscriptThatHadWords() {
        // `TidyTranscript` owns the never-empty guarantee, but this is where it
        // becomes user-visible: an all-filler utterance that tidied away to ""
        // would paste nothing into the focused field and copy nothing to the
        // clipboard — the user speaks, and the tool answers with silence. Worse
        // than leaving the fillers in by a wide margin, so it is pinned at the
        // seam that actually hands text to the user, not only in the module.
        for transcript in ["嗯，那个，呃", "um, uh, um", "呃呃呃呃"] {
            let delivered = TranscribeVariant.tidy.deliverableText(for: transcript)
            XCTAssertNotNil(delivered, "\(transcript) produced no delivery at all")
            XCTAssertFalse(
                (delivered ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(transcript) tidied away to an empty delivery"
            )
        }
    }

    func testTidyAddsNoNewDeliveryRuleToOutputDeliveryPolicy() {
        // `OutputDeliveryPolicy` is keyed on `InputMode` only, and tidy adds no
        // mode: a tidied transcript reaches the user through the exact same
        // clipboard-always / auto-insert-when-enabled path a direct one does.
        // Pinned here so a future "tidy needs its own delivery rule" idea has to
        // break a test that says why it shouldn't.
        XCTAssertEqual(
            OutputDeliveryPolicy.strategy(for: .transcribe, automaticallyInsert: true),
            .automaticInsert
        )
        XCTAssertEqual(
            OutputDeliveryPolicy.strategy(for: .transcribe, automaticallyInsert: false),
            .clipboard
        )
    }

    // MARK: - The post-delivery correction window covers tidy too

    private let deliveredAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let targetApp = "com.apple.Notes"

    func testATidyDeliveryArmsTheCorrectionWindow() {
        // P0-3's window exists for variants that paste straight into the target
        // app, which is exactly what tidy does. Review is excluded because its
        // panel already owns the second hotkey press; tidy has no panel, so
        // excluding it would leave the one variant most likely to need a fix
        // (its output differs from what was said) without the affordance.
        XCTAssertNotNil(
            CorrectionWindow.reduce(
                nil,
                on: .delivered(
                    at: deliveredAt,
                    capturedBundleId: targetApp,
                    mode: .transcribe,
                    variant: .tidy
                )
            )
        )
    }

    func testTheHotkeyCorrectsASelectionAfterATidyDeliveryJustLikeDirect() {
        XCTAssertEqual(
            CorrectionWindow.intent(
                lastDeliveryAt: deliveredAt,
                now: deliveredAt.addingTimeInterval(1),
                selectedText: "呸泡",
                capturedBundleId: targetApp,
                frontmostBundleId: targetApp,
                mode: .transcribe,
                variant: .tidy
            ),
            .correctSelection
        )
    }
}
