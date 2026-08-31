import Foundation

/// The Swift-side request seam that lifts a Direct/Tidy in-place correction
/// back to the episodic row that recorded the delivery (2026-08-30 batch,
/// `docs/superpowers/specs/2026-08-30-direct-tidy-in-place-correction-history-design.md`
/// §3.3).
///
/// An in-place correction pastes only the replacement into the target app, so
/// `AppModel.processInPlaceCorrection(...)` reconstructs the corrected *full*
/// text via `DeliveredTextCorrection` and sends this narrow PATCH to
/// `sidecar/src/memory/routes.ts`. The body carries exactly the two writable
/// columns — `correctedTranscript` and `result` — and nothing else:
/// `rawTranscript` is what ASR heard before any correction and must stay
/// untouched.
///
/// `AppModel.init` is not constructible in tests, so — exactly like
/// `HistoryEventsRequest`/`ContextLogResetRequest` before it — this is a
/// static pure builder that pins the method/path/body shape without spawning
/// the sidecar or touching AppKit (see `HistoryEventCorrectionRequestTests`).
/// `nonisolated` for the same reason `AppModel.mergedRefresh` et al. are: the
/// builder never touches actor state, so it must not inherit the class's
/// main-actor isolation and block a plain XCTest call.
extension AppModel {

    /// One full PATCH request against `PATCH /memory/events/:id`, as the
    /// correction path would send it.
    struct HistoryEventCorrectionRequest: Equatable {
        let method: String
        let path: String
        let body: HistoryEventCorrectionBody
    }

    /// The body of that PATCH: the corrected full delivered text in both
    /// writable fields. Deliberately narrow — no `rawTranscript`, no other
    /// columns; the sidecar refuses anything this shape does not name.
    struct HistoryEventCorrectionBody: Encodable, Equatable {
        let correctedTranscript: String
        let result: String
    }

    /// Builds the PATCH request that updates the episodic row for a completed
    /// delivery after an in-place correction lands, or `nil` when no such
    /// request should be sent.
    ///
    /// - Parameters:
    ///   - id: The retained `eventId` of the delivery's episodic row (see
    ///     `AppModel.lastDirectTidyEventId`).
    ///   - deliveredText: The full text that delivery put in front of the
    ///     user, as it stands after any earlier corrections.
    ///   - selectedText: The span the user corrected in the target app.
    ///   - replacement: What the correction produced for that span.
    /// - Returns: A `PATCH /memory/events/\(id)` request whose body carries
    ///   the reconstructed full text in both fields, or `nil` when
    ///   `DeliveredTextCorrection.reconstruct` returns `nil` — i.e.
    ///   `selectedText` is absent or occurs more than once, so rewriting
    ///   history on it would be a guess. `nil` means "do not mutate episodic
    ///   history."
    nonisolated static func historyEventCorrectionRequest(
        id: Int,
        deliveredText: String,
        selectedText: String,
        replacement: String
    ) -> HistoryEventCorrectionRequest? {
        guard let corrected = DeliveredTextCorrection.reconstruct(
            deliveredText: deliveredText,
            selectedText: selectedText,
            replacement: replacement
        ) else { return nil }
        return HistoryEventCorrectionRequest(
            method: "PATCH",
            path: "/memory/events/\(id)",
            body: HistoryEventCorrectionBody(
                correctedTranscript: corrected,
                result: corrected
            )
        )
    }
}