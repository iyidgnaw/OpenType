import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the second half of **D-3** — 「词典已学会 N 个
/// 词」 (`docs/superpowers/specs/2026-08-15-product-batch-plan.md` §D-3).
///
/// The trend line answers 「is it getting better」. This answers 「what has it
/// actually learned」, which is the figure that makes the loop legible on day
/// three, before there is enough history for a slope to mean anything.
///
/// Sourced from the memory panel's existing `GET /memory/terms` — `AppModel`
/// already keeps that list in `memoryTerms`, so this adds no endpoint, no
/// second store and no counter. It is a pure count over rows the panel has
/// already fetched, factored out for the reason every other decision in this
/// codebase is: `AppModel` is not instantiable in tests.
///
/// ## Why the count is split by `origin`
///
/// §D-3 asks for the owner's share to be shown separately, and the reason is
/// P1-12. `remember_fact` writes terms out of agent context with
/// `origin: "untrusted"` — text that arrived from a web page or a file the agent
/// read, not from the user. Printing one blended 「已学会 42 个词」 would let a
/// number the user reads as "how much I have taught it" quietly include rows
/// nobody taught it, which is precisely the provenance confusion the `origin`
/// badge exists to prevent.
///
/// ## Expected shape (Stage 3 creates it; nothing here builds it)
///
///     enum DictionaryStats {
///         struct LearnedTermCounts: Equatable {
///             let total: Int
///             let owner: Int
///             let untrusted: Int
///         }
///         static func counts(for terms: [EntityTermSummary]) -> LearnedTermCounts
///     }
///
/// These tests fail to COMPILE until it exists.
final class DictionaryStatsTests: XCTestCase {

    func testAnEmptyDictionaryCountsZeroEverywhere() {
        // First launch, and the honest answer: nothing has been learned yet.
        XCTAssertEqual(
            DictionaryStats.counts(for: []),
            DictionaryStats.LearnedTermCounts(total: 0, owner: 0, untrusted: 0)
        )
    }

    func testOwnerAndUntrustedTermsAreCountedSeparatelyAndTogether() {
        let terms = [
            term(id: 1, canonicalTerm: "PayPal", origin: "owner"),
            term(id: 2, canonicalTerm: "Anthropic", origin: "owner"),
            term(id: 3, canonicalTerm: "Contoso", origin: "untrusted"),
        ]

        XCTAssertEqual(
            DictionaryStats.counts(for: terms),
            DictionaryStats.LearnedTermCounts(total: 3, owner: 2, untrusted: 1)
        )
    }

    func testOtherOriginsCountTowardTheTotalOnly() {
        // `EventOrigin` is `"owner" | "agent" | "untrusted" | "system"`, and the
        // panel shows two of those. The remaining rows are real dictionary
        // entries and must still be in the total — dropping them would make the
        // headline disagree with the list printed directly under it.
        let terms = [
            term(id: 1, canonicalTerm: "PayPal", origin: "owner"),
            term(id: 2, canonicalTerm: "Contoso", origin: "agent"),
            term(id: 3, canonicalTerm: "Fabrikam", origin: "system"),
        ]

        XCTAssertEqual(
            DictionaryStats.counts(for: terms),
            DictionaryStats.LearnedTermCounts(total: 3, owner: 1, untrusted: 0)
        )
    }

    func testARowWithNoOriginCountsTowardTheTotalOnly() {
        // `EntityTermSummary.origin` is optional because a term written before
        // the column existed decodes without one. Unknown provenance is not
        // owner provenance: the split has to under-claim rather than credit the
        // user with a row nobody can vouch for.
        let terms = [
            term(id: 1, canonicalTerm: "PayPal", origin: nil),
            term(id: 2, canonicalTerm: "Anthropic", origin: "owner"),
        ]

        XCTAssertEqual(
            DictionaryStats.counts(for: terms),
            DictionaryStats.LearnedTermCounts(total: 2, owner: 1, untrusted: 0)
        )
    }

    func testTheCountIsRowsNotAliases() {
        // 「学会了 N 个词」 means N entries in the dictionary. Counting aliases
        // instead would make a single term the user corrected three times read
        // as three learned words, and the number would climb fastest exactly
        // when recognition was working worst.
        let terms = [
            term(id: 1, canonicalTerm: "PayPal",
                 aliases: ["呸泡", "paipal", "拍拍"], origin: "owner")
        ]

        XCTAssertEqual(
            DictionaryStats.counts(for: terms),
            DictionaryStats.LearnedTermCounts(total: 1, owner: 1, untrusted: 0)
        )
    }

    // MARK: - Fixtures

    private func term(
        id: Int,
        canonicalTerm: String,
        aliases: [String] = [],
        origin: String?
    ) -> EntityTermSummary {
        EntityTermSummary(
            id: id,
            canonicalTerm: canonicalTerm,
            aliases: aliases,
            category: "term",
            confidence: 0.9,
            origin: origin
        )
    }
}
