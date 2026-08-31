import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the Direct/Tidy post-delivery correction
/// history rewrite. In-place correction pastes only the replacement back into
/// the target app, but Dictation history and recent activity need the full
/// delivered text as it stands *after* that correction.
///
/// The approved design keeps this as a pure Swift seam rather than burying it
/// inside `AppModel.processInPlaceCorrection(...)`: Swift is the only side that
/// knows the last full delivered text, and whether a correction can safely be
/// lifted back to that whole string is a deterministic text question with no
/// AppKit, I/O, or sidecar dependency.
///
/// Expected Stage-3 seam:
///
///     enum DeliveredTextCorrection {
///         static func reconstruct(
///             deliveredText: String,
///             selectedText: String,
///             replacement: String
///         ) -> String?
///     }
///
/// `nil` means "do not mutate episodic history": the selected text either does
/// not occur in the delivered string at all, or occurs more than once so the
/// exact intended occurrence is ambiguous once the sidecar has only text, not
/// the live target app's selection range.
final class DeliveredTextCorrectionTests: XCTestCase {

    func testUniqueOccurrenceReconstructsTheWholeCorrectedDelivery() {
        XCTAssertEqual(
            DeliveredTextCorrection.reconstruct(
                deliveredText: "请把这笔钱通过呸泡转给他",
                selectedText: "呸泡",
                replacement: "PayPal"
            ),
            "请把这笔钱通过PayPal转给他"
        )
    }

    func testAbsentSelectionReturnsNilSoHistoryIsLeftUntouched() {
        XCTAssertNil(
            DeliveredTextCorrection.reconstruct(
                deliveredText: "请把这笔钱通过微信转给他",
                selectedText: "呸泡",
                replacement: "PayPal"
            )
        )
    }

    func testRepeatedSelectionReturnsNilRatherThanGuessingWhichOccurrenceToRewrite() {
        XCTAssertNil(
            DeliveredTextCorrection.reconstruct(
                deliveredText: "PayPa 先记一下，PayPa 稍后再改",
                selectedText: "PayPa",
                replacement: "PayPal"
            )
        )
    }

    func testUtf16AndCjkTextAreMatchedAsOrdinaryVisibleText() {
        XCTAssertEqual(
            DeliveredTextCorrection.reconstruct(
                deliveredText: "把🍣发给小王，然后告诉上海团队",
                selectedText: "🍣",
                replacement: "寿司"
            ),
            "把寿司发给小王，然后告诉上海团队"
        )
    }

    func testConsecutiveCorrectionsCarryForwardTheLatestFullDeliveredText() {
        let first = DeliveredTextCorrection.reconstruct(
            deliveredText: "请把这笔钱通过呸泡转给他，明天再催一下",
            selectedText: "呸泡",
            replacement: "PayPal"
        )
        XCTAssertEqual(first, "请把这笔钱通过PayPal转给他，明天再催一下")

        XCTAssertEqual(
            DeliveredTextCorrection.reconstruct(
                deliveredText: first!,
                selectedText: "明天再催一下",
                replacement: "明天下午三点再催一下"
            ),
            "请把这笔钱通过PayPal转给他，明天下午三点再催一下"
        )
    }
}
