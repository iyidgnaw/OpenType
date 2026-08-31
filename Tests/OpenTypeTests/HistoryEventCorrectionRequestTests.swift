import Foundation
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the Swift-side request seam that updates the
/// original episodic row after an in-place Direct/Tidy correction lands.
///
/// `AppModel.init` is not constructible in tests, so this follows the existing
/// `/memory/events` request-shape pattern: a static pure builder that pins the
/// exact method, path, and JSON body without spawning the sidecar or touching
/// AppKit.
///
/// Expected Stage-3 seam:
///
///     extension AppModel {
///         struct HistoryEventCorrectionRequest: Equatable {
///             let method: String
///             let path: String
///             let body: HistoryEventCorrectionBody
///         }
///
///         struct HistoryEventCorrectionBody: Encodable, Equatable {
///             let correctedTranscript: String
///             let result: String
///         }
///
///         static func historyEventCorrectionRequest(
///             id: Int,
///             deliveredText: String,
///             selectedText: String,
///             replacement: String
///         ) -> HistoryEventCorrectionRequest?
///     }
///
/// The body is intentionally *narrow*: only the two columns that change on a
/// post-delivery correction are writable here. `rawTranscript` is what ASR
/// heard before any correction and must stay untouched.
final class HistoryEventCorrectionRequestTests: XCTestCase {

    func testPatchRequestTargetsTheExactEventId() {
        let request = AppModel.historyEventCorrectionRequest(
            id: 42,
            deliveredText: "请把这笔钱通过呸泡转给他",
            selectedText: "呸泡",
            replacement: "PayPal"
        )
        XCTAssertEqual(
            request?.path,
            "/memory/events/42"
        )
    }

    func testPatchRequestUsesPatchMethod() {
        let request = AppModel.historyEventCorrectionRequest(
            id: 7,
            deliveredText: "这里有一个错词",
            selectedText: "错词",
            replacement: "正确词"
        )
        XCTAssertEqual(
            request?.method,
            "PATCH"
        )
    }

    func testPatchRequestCarriesTheSameReconstructedFullDeliveryInBothWritableFields() throws {
        let request = try XCTUnwrap(AppModel.historyEventCorrectionRequest(
            id: 9,
            deliveredText: "把🍣发给小王",
            selectedText: "🍣",
            replacement: "寿司"
        ))

        XCTAssertEqual(
            request.body,
            AppModel.HistoryEventCorrectionBody(
                correctedTranscript: "把寿司发给小王",
                result: "把寿司发给小王"
            )
        )

        let data = try JSONEncoder().encode(request.body)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        XCTAssertEqual(Set(json.keys), ["correctedTranscript", "result"])
        XCTAssertEqual(json["correctedTranscript"], "把寿司发给小王")
        XCTAssertEqual(json["result"], "把寿司发给小王")
        XCTAssertNil(json["rawTranscript"])
    }

    func testAbsentSelectionProducesNoPatchRequest() {
        XCTAssertNil(
            AppModel.historyEventCorrectionRequest(
                id: 10,
                deliveredText: "请把这笔钱通过微信转给他",
                selectedText: "呸泡",
                replacement: "PayPal"
            )
        )
    }

    func testRepeatedSelectionProducesNoPatchRequest() {
        XCTAssertNil(
            AppModel.historyEventCorrectionRequest(
                id: 11,
                deliveredText: "PayPa 先记一下，PayPa 稍后再改",
                selectedText: "PayPa",
                replacement: "PayPal"
            )
        )
    }
}
