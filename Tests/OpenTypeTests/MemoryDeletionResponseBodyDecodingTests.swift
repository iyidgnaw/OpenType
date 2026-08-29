import Foundation
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for a pre-existing bug surfaced while adding
/// the third `resetHistory()` leg (`RunLogsResetRequestTests.swift`) and
/// confirmed by the coordinator's own review.
///
/// `AppModel.MemoryDeletionResponseBody` is declared
/// `Decodable { let deleted: Bool }` (`AppModel.swift:3226`), but the three
/// DELETE endpoints `resetHistory()` calls do not agree on that shape:
///   - `DELETE /memory/events` -> `Response.json({ deleted: result.changes })`
///     -- a JSON NUMBER (`sidecar/src/memory/routes.ts:226`)
///   - `DELETE /memory/context-log` -> `Response.json({ deleted: true })`
///     -- a JSON BOOLEAN (`routes.ts:464`)
///   - `DELETE /agent/run-logs` (the new third leg) -> `{ deleted: <count> }`
///     -- a NUMBER, same shape as the events leg
///
/// Decoding a JSON number into a `Bool`-typed field throws `typeMismatch`,
/// so the events leg has always recorded a spurious `historyResetError`
/// even when the delete succeeded, and the new run-logs leg would inherit
/// the exact same bug on day one if shipped as-is.
///
/// ## Owner-pinned fix shape
///
/// Every Swift call site already discards the decoded value (`let _:
/// MemoryDeletionResponseBody = try await ...`), and both wire shapes are
/// already live in production, so the fix is a lenient decoder on the Swift
/// side rather than a change to either sidecar endpoint's contract (no
/// existing sidecar test is touched by this). `MemoryDeletionResponseBody`
/// gains a custom `init(from decoder:)` that accepts EITHER a JSON boolean
/// (mapped straight through) OR a JSON number (normalized to "did it delete
/// anything" semantics: `count > 0` -> `true`, `0` -> `false`). The
/// `deleted` field stays so the type still documents the contract.
/// Leniency is bounded to exactly those two real wire shapes -- a string, an
/// object, or a missing key must still throw, not be coerced.
///
/// ## Access-level note (same precedent as `McpBuiltInCatalogTests`)
///
/// `MemoryDeletionResponseBody` is currently `private` inside `AppModel`,
/// and `@testable import` does not reach across a `private` boundary --
/// `private`'s scope is the declaring file, not the module.
/// `McpBuiltInCatalogTests.swift` already established the precedent for
/// exactly this situation (`McpServerViews.swift:36`'s "Internal rather
/// than `private` so `McpBuiltInCatalogTests`..." comment): widen
/// `MemoryDeletionResponseBody` to `internal` (drop the `private` keyword --
/// nested types default to their enclosing type's access level, `internal`
/// for `AppModel`) so this file can reach it. This file is written against
/// that intended surface, not today's, so it currently FAILS TO COMPILE --
/// that access-level error, not a runtime `typeMismatch`, is this file's
/// actual red evidence (the task note says either is acceptable; this is
/// which one actually occurs, since the type cannot even be named from here
/// today).
///
/// Deliberately independent of a live `AppModel`/sidecar, following
/// `EpisodicEventDTODecodingTests`'s precedent in
/// `HistoryEntryMappingTests.swift`: literal JSON text decoded through
/// `JSONDecoder` alone, no HTTP, no live instance.
final class MemoryDeletionResponseBodyDecodingTests: XCTestCase {

    func testDecodesATrueBooleanWireValue() throws {
        // `DELETE /memory/context-log`'s real shape.
        let body = try JSONDecoder().decode(
            AppModel.MemoryDeletionResponseBody.self,
            from: Data(#"{"deleted": true}"#.utf8)
        )
        XCTAssertEqual(body.deleted, true)
    }

    func testDecodesAFalseBooleanWireValue() throws {
        let body = try JSONDecoder().decode(
            AppModel.MemoryDeletionResponseBody.self,
            from: Data(#"{"deleted": false}"#.utf8)
        )
        XCTAssertEqual(body.deleted, false)
    }

    func testDecodesAPositiveCountAsTrue_theRegressionThisFileExistsToCatch() throws {
        // The actual bug: `DELETE /memory/events` and the new
        // `DELETE /agent/run-logs` both answer with a JSON NUMBER on
        // `deleted` (a row/file count). Today's `Bool`-only decoder throws
        // `typeMismatch` on this, silently turning a SUCCESSFUL delete into
        // a recorded `historyResetError`.
        let body = try JSONDecoder().decode(
            AppModel.MemoryDeletionResponseBody.self,
            from: Data(#"{"deleted": 3}"#.utf8)
        )
        XCTAssertEqual(body.deleted, true)
    }

    func testDecodesAZeroCountAsFalse() throws {
        let body = try JSONDecoder().decode(
            AppModel.MemoryDeletionResponseBody.self,
            from: Data(#"{"deleted": 0}"#.utf8)
        )
        XCTAssertEqual(body.deleted, false)
    }

    func testAStringValueStillThrows_leniencyIsBoundedNotUnlimited() {
        // Leniency covers exactly the two real wire shapes (bool, number) --
        // not "coerce whatever JSON is there". A string on `deleted` must
        // still be a decode failure, same as always.
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AppModel.MemoryDeletionResponseBody.self,
                from: Data(#"{"deleted": "yes"}"#.utf8)
            )
        )
    }

    func testAMissingDeletedKeyStillThrows() {
        // The other malformed-shape case named in the task: an empty object
        // has no `deleted` key at all, which must still fail rather than
        // silently default to `false`.
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AppModel.MemoryDeletionResponseBody.self,
                from: Data("{}".utf8)
            )
        )
    }
}
