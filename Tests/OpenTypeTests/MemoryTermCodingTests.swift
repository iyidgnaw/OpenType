import XCTest
@testable import OpenType

/// Stage-1 (red) tests for P0-4's Swift-side wire models: the Settings memory
/// panel stops being a read-only list and becomes an editable table, which
/// means the Swift side now has to (a) know each term's real row id and its
/// provenance, and (b) be able to encode create/update request bodies.
///
/// Two things must change in `Models.swift` for these to compile:
///
///   * `EntityTermSummary` gains `id: Int` (the sidecar's `entity_terms.id`,
///     replacing the synthesized `canonicalTerm`-as-id) and `origin: String`.
///     The id is what `PUT`/`DELETE /memory/terms/:id` address; the synthesized
///     canonicalTerm id cannot survive a rename, which is exactly the operation
///     the panel is being built for.
///   * Two new internal `Encodable` request bodies —
///     `MemoryTermCreateRequest` and `MemoryTermUpdateRequest` — live in
///     `Models.swift` rather than as `private` nested types inside `AppModel`,
///     so the wire shape is testable at all (`@testable import` does not reach
///     `private` members).
///
/// Decoding goes through `SidecarClient.decodeResponse(fromRawOutput:)`, the
/// same seam `testSidecarClientDecodesCannedHealthResponse` uses, so these
/// tests exercise the real decode path rather than a bespoke one.
final class MemoryTermCodingTests: XCTestCase {

    // MARK: - GET /memory/terms

    private struct MemoryTermsBody: Decodable { let terms: [EntityTermSummary] }

    /// A term payload must round-trip its numeric row id and its `origin`.
    /// `origin` is not decoration: an `"untrusted"` term is one the agent wrote
    /// from possibly-hostile context (P1-12), and the whole point of the panel
    /// is that a user can see that and delete it.
    func testEntityTermSummaryDecodesIdAndOrigin() throws {
        let json = """
        {"terms":[
          {"id":7,"canonicalTerm":"PayPal","aliases":["贝宝","拍拍宝"],"category":"org","confidence":0.8,"origin":"untrusted"},
          {"id":9,"canonicalTerm":"天润","aliases":[],"category":"org","confidence":1,"origin":"owner"}
        ]}
        """

        let body: MemoryTermsBody = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertEqual(body.terms.count, 2)

        let first = try XCTUnwrap(body.terms.first)
        XCTAssertEqual(first.id, 7)
        XCTAssertEqual(first.canonicalTerm, "PayPal")
        XCTAssertEqual(first.aliases, ["贝宝", "拍拍宝"])
        XCTAssertEqual(first.category, "org")
        XCTAssertEqual(first.confidence, 0.8, accuracy: 0.0001)
        XCTAssertEqual(first.origin, "untrusted")

        let second = try XCTUnwrap(body.terms.last)
        XCTAssertEqual(second.id, 9)
        XCTAssertEqual(second.aliases, [])
        XCTAssertEqual(second.origin, "owner")
    }

    /// Two terms that briefly share a canonicalTerm (mid-rename in the editor)
    /// must still be distinct rows to SwiftUI's `ForEach`. That only holds if
    /// `Identifiable.id` is the sidecar row id rather than the canonical text.
    func testEntityTermSummaryIdentityIsTheRowIdNotTheCanonicalTerm() throws {
        let json = """
        {"terms":[
          {"id":1,"canonicalTerm":"PayPal","aliases":[],"category":"org","confidence":1,"origin":"owner"},
          {"id":2,"canonicalTerm":"PayPal","aliases":[],"category":"org","confidence":1,"origin":"owner"}
        ]}
        """

        let body: MemoryTermsBody = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertEqual(body.terms.map(\.id), [1, 2])
    }

    // MARK: - POST/PUT response

    private struct MemoryTermMutationBody: Decodable { let term: EntityTermSummary }

    /// `POST /memory/terms` and `PUT /memory/terms/:id` both answer with the
    /// resulting term, so the panel can refresh a single row without refetching
    /// the whole dictionary.
    func testMutationResponseDecodesTheResultingTerm() throws {
        let json = """
        {"term":{"id":3,"canonicalTerm":"Anthropic","aliases":["安思罗匹克"],"category":"term","confidence":1,"origin":"owner"}}
        """

        let body: MemoryTermMutationBody = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertEqual(body.term.id, 3)
        XCTAssertEqual(body.term.canonicalTerm, "Anthropic")
        XCTAssertEqual(body.term.aliases, ["安思罗匹克"])
        XCTAssertEqual(body.term.origin, "owner")
    }

    // MARK: - Request bodies

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The create body carries only what the user typed. Confidence and origin
    /// are deliberately absent — the sidecar pins an owner-created term at
    /// confidence 1.0 / origin "owner"; the client does not get to claim either.
    func testCreateRequestEncodesCanonicalTermAndAliasesOnly() throws {
        let object = try encodedObject(
            MemoryTermCreateRequest(canonicalTerm: "Anthropic", aliases: ["安思罗匹克"])
        )

        XCTAssertEqual(object["canonicalTerm"] as? String, "Anthropic")
        XCTAssertEqual(object["aliases"] as? [String], ["安思罗匹克"])
        XCTAssertNil(object["confidence"])
        XCTAssertNil(object["origin"])
    }

    func testCreateRequestEncodesAnEmptyAliasList() throws {
        let object = try encodedObject(
            MemoryTermCreateRequest(canonicalTerm: "OpenType", aliases: [])
        )

        XCTAssertEqual(object["canonicalTerm"] as? String, "OpenType")
        XCTAssertEqual(object["aliases"] as? [String], [])
    }

    func testUpdateRequestEncodesEveryProvidedField() throws {
        let object = try encodedObject(
            MemoryTermUpdateRequest(
                canonicalTerm: "PayPal Inc",
                aliases: ["贝宝", "拍拍宝"],
                confidence: 0.5
            )
        )

        XCTAssertEqual(object["canonicalTerm"] as? String, "PayPal Inc")
        XCTAssertEqual(object["aliases"] as? [String], ["贝宝", "拍拍宝"])
        XCTAssertEqual(object["confidence"] as? Double, 0.5)
    }

    /// The update body is a *patch*: a field the user did not touch must be
    /// absent from the JSON entirely, not sent as `null`. A `null` would read on
    /// the sidecar side as "set this field", which for `canonicalTerm` means a
    /// 400 and for `aliases` means silently wiping every alias.
    func testUpdateRequestOmitsUnsetFieldsRatherThanSendingNull() throws {
        let object = try encodedObject(
            MemoryTermUpdateRequest(canonicalTerm: nil, aliases: nil, confidence: 0.42)
        )

        XCTAssertEqual(object["confidence"] as? Double, 0.42)
        XCTAssertEqual(
            Set(object.keys),
            ["confidence"],
            "An untouched field must be omitted from the patch, not encoded as null."
        )
    }

    func testUpdateRequestCanPatchAliasesAlone() throws {
        let object = try encodedObject(
            MemoryTermUpdateRequest(canonicalTerm: nil, aliases: ["tianrun", "添润"], confidence: nil)
        )

        XCTAssertEqual(object["aliases"] as? [String], ["tianrun", "添润"])
        XCTAssertEqual(Set(object.keys), ["aliases"])
    }

    /// Clearing every alias is a real edit, and it must be distinguishable from
    /// "leave aliases alone" — `[]` is sent, `nil` is omitted.
    func testUpdateRequestSendsAnEmptyAliasListWhenClearingAliases() throws {
        let object = try encodedObject(
            MemoryTermUpdateRequest(canonicalTerm: nil, aliases: [], confidence: nil)
        )

        XCTAssertEqual(object["aliases"] as? [String], [])
        XCTAssertEqual(Set(object.keys), ["aliases"])
    }
}
