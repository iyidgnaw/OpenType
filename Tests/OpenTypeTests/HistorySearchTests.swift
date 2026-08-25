import Foundation
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for §I of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — the search half.
///
/// Motivation (`docs/reviews/2026-08-15-product-review.md` §7): the session
/// search matches titles only, and `SessionsViews.swift`'s own comment admits
/// the motivation was that "the magnifying glass has to do something". What a
/// user remembers about a dictation from last Tuesday is a *word they said*.
/// They have never read the auto-generated title.
///
/// Expected shape (Stage 3 creates it; nothing here builds it) — a new
/// `Sources/OpenType/HistorySearch.swift`, pure and view-free, so both the
/// 听写 list and the 会话 list call one matcher rather than growing a second one
/// each:
///
///     enum HistorySearch {
///         /// Whitespace-separated terms of a raw query; `[]` for blank input.
///         static func terms(_ query: String) -> [String]
///         /// The core predicate: every term appears somewhere in `text`.
///         static func matches(text: String, terms: [String]) -> Bool
///         /// The fields of an entry a query is matched against, joined.
///         static func searchableText(_ entry: HistoryEntry) -> String
///         static func matches(_ entry: HistoryEntry, query: String) -> Bool
///         static func filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry]
///     }
///
///     enum SessionSearchOutcome: Equatable {
///         case matches([ConversationSummary])
///         case noMatches
///         case noMatchesInLoadedSubset(bodiesSearched: Int, total: Int)
///
///         var conversations: [ConversationSummary] { get }   // [] for the two empties
///     }
///
///     enum SessionSearch {
///         static func search(
///             _ conversations: [ConversationSummary],
///             query: String,
///             loadedDetails: [Int: ConversationDetail]
///         ) -> SessionSearchOutcome
///     }
///
/// No `Models.swift` change is required.
///
/// ---
///
/// ## Pinned decision 1 — a query's terms are ANDed, not ORed
///
/// A multi-word query requires **every** term, each matched as a substring,
/// anywhere in the entry, in any order.
///
/// OR is the alternative and it is wrong here for one decisive reason: under OR
/// every extra word the user types makes the result list *longer*. The user is
/// recalling a fragment — 「会议 发布」, "review PR" — and each additional word
/// they dredge up is an attempt to narrow. A field where typing more shows more
/// inverts the only mental model anyone has of a search box, and it degrades
/// exactly when the user is trying hardest: a two-word OR query over a
/// thousand-entry history returns most of the history.
///
/// Order-independence matters as much as the AND itself, because spoken text is
/// not remembered in its original word order — 「发布 会议」 and 「会议 发布」 are
/// the same recollection and must return the same rows.
///
/// It is deliberately *not* phrase search. A CJK query has no spaces to split
/// on, so 「会议纪要」 arrives as one term and is matched as a substring — which
/// is precisely phrase search for the language that needs it. For spaced input,
/// AND-of-substrings is looser than a phrase but tolerant of the filler words
/// ASR inserts between the two words the user actually remembers.
///
/// ## Pinned decision 2 — terms may land in different fields
///
/// Matching runs against the entry's fields **joined**, not per field, so
/// 「微信 发布」 finds a dictation into WeChat whose transcript mentions 发布.
/// Requiring both terms in the same field would fail the most natural
/// two-word query a user can type: one word about *where*, one about *what*.
///
/// ## Pinned decision 3 — `contextPreview` is not searched
///
/// It holds text the user *selected in another app*, not text they authored.
/// Matching it produces rows whose visible content does not contain the query,
/// which reads as a broken search rather than a thorough one. `transcript`,
/// `result` and `applicationName` are searched — the three strings the row
/// actually shows.
///
/// ## Pinned decision 4 — case-insensitive, non-localised
///
/// `localizedCaseInsensitiveContains` folds case per the *current* locale, and
/// under a Turkish locale `I` does not fold to `i`. A history search whose
/// results depend on the user's region setting is a bug that will never be
/// reported. Fold with a fixed, non-localised comparison
/// (`range(of:options:.caseInsensitive)`).
final class HistorySearchTermsTests: XCTestCase {

    func testAnEmptyQueryHasNoTerms() {
        XCTAssertEqual(HistorySearch.terms(""), [])
    }

    func testAWhitespaceOnlyQueryHasNoTermsEither() {
        // A user who taps the search field and then a space has not started
        // searching; this is what makes "whitespace-only behaves like empty"
        // fall out of one rule rather than needing a second one.
        XCTAssertEqual(HistorySearch.terms("   "), [])
        XCTAssertEqual(HistorySearch.terms("\t\n "), [])
        XCTAssertEqual(HistorySearch.terms("\u{3000}"), [], "full-width space too")
    }

    func testTermsSplitOnWhitespaceAndDropEmptyRuns() {
        XCTAssertEqual(HistorySearch.terms("会议 发布"), ["会议", "发布"])
        XCTAssertEqual(HistorySearch.terms("  review   PR  "), ["review", "PR"])
        XCTAssertEqual(HistorySearch.terms("a\tb\nc"), ["a", "b", "c"])
    }

    func testACJKQueryWithNoSpacesIsASingleTerm() {
        // Chinese has no word boundaries, so the query the user types *is* the
        // substring they want. Any tokenisation of it would be a guess.
        XCTAssertEqual(HistorySearch.terms("会议纪要"), ["会议纪要"])
        XCTAssertEqual(HistorySearch.terms("今天review一下"), ["今天review一下"])
    }

    func testTermsKeepTheUsersCasing() {
        // Matching folds case; the terms themselves stay verbatim so a caller
        // that wants to highlight the hit has the user's own string.
        XCTAssertEqual(HistorySearch.terms("Review PR"), ["Review", "PR"])
    }
}

final class HistorySearchMatchingTests: XCTestCase {

    // MARK: - The core predicate

    func testNoTermsMatchesEverything() {
        XCTAssertTrue(HistorySearch.matches(text: "任意内容", terms: []))
        XCTAssertTrue(HistorySearch.matches(text: "", terms: []))
    }

    func testEveryTermMustAppear() {
        let text = "今天开会讨论了发布计划"
        XCTAssertTrue(HistorySearch.matches(text: text, terms: ["开会", "发布"]))
        XCTAssertFalse(
            HistorySearch.matches(text: text, terms: ["开会", "预算"]),
            "AND, not OR — one hit out of two is not a match"
        )
    }

    func testTermOrderDoesNotMatter() {
        let text = "今天开会讨论了发布计划"
        XCTAssertTrue(HistorySearch.matches(text: text, terms: ["发布", "开会"]))
    }

    func testACJKTermMatchesMidStringWithNoWordBoundary() {
        XCTAssertTrue(HistorySearch.matches(text: "今天开会讨论了发布计划", terms: ["论了发"]))
    }

    func testMatchingIsCaseInsensitiveInBothDirections() {
        XCTAssertTrue(HistorySearch.matches(text: "Review the PR", terms: ["review"]))
        XCTAssertTrue(HistorySearch.matches(text: "review the pr", terms: ["REVIEW"]))
        XCTAssertTrue(HistorySearch.matches(text: "ReViEw", terms: ["rEvIeW"]))
    }

    func testAnAsciiTermMatchesInsideAnUnspacedMixedScriptString() {
        // 中英混排 with no spaces is this product's normal input.
        XCTAssertTrue(HistorySearch.matches(text: "今天review一下PR", terms: ["review"]))
        XCTAssertTrue(HistorySearch.matches(text: "今天review一下PR", terms: ["pr"]))
    }

    // MARK: - Entries

    func testAQueryThatMatchesTheBodyMatchesTheEntry() {
        // The entire point of §I: the word the user remembers is in what they
        // said, not in any title or app name.
        let entry = entry(
            applicationName: "Xcode",
            transcript: "把发布计划整理成三条",
            result: "1. …"
        )
        XCTAssertTrue(HistorySearch.matches(entry, query: "发布计划"))
    }

    func testTheResultIsSearchedAsWellAsTheTranscript() {
        // In 听写 the two differ by exactly the tidy-up; in 问答 the result is
        // the answer, which is the half worth finding.
        let entry = entry(
            applicationName: "Safari",
            transcript: "这个词什么意思",
            result: "它指的是灰度发布"
        )
        XCTAssertTrue(HistorySearch.matches(entry, query: "灰度发布"))
    }

    func testTheApplicationNameIsSearched() {
        let entry = entry(applicationName: "微信", transcript: "晚点聊", result: "晚点聊")
        XCTAssertTrue(HistorySearch.matches(entry, query: "微信"))
    }

    func testTermsMayLandInDifferentFields() {
        let entry = entry(
            applicationName: "微信",
            transcript: "发布之后再同步一下",
            result: "发布之后再同步一下"
        )
        XCTAssertTrue(
            HistorySearch.matches(entry, query: "微信 发布"),
            "one term about where, one about what — the most natural two-word query"
        )
    }

    func testTheContextPreviewIsNotSearched() {
        // Text the user selected elsewhere, not text they produced. A row that
        // matches on it shows nothing the query appears in.
        let entry = entry(
            applicationName: "Xcode",
            transcript: "改一下这里",
            result: "改一下这里",
            contextPreview: "季度营收同比增长"
        )
        XCTAssertFalse(HistorySearch.matches(entry, query: "季度营收"))
        XCTAssertFalse(HistorySearch.searchableText(entry).contains("季度营收"))
    }

    func testAnEntryThatMatchesNoTermDoesNotMatch() {
        let entry = entry(applicationName: "Xcode", transcript: "早上好", result: "早上好")
        XCTAssertFalse(HistorySearch.matches(entry, query: "发布"))
    }

    // MARK: - Filtering a list

    func testAnEmptyQueryReturnsEverythingUntouched() {
        let entries = sampleEntries()
        XCTAssertEqual(HistorySearch.filter(entries, query: ""), entries)
    }

    func testAWhitespaceOnlyQueryBehavesExactlyLikeAnEmptyOne() {
        let entries = sampleEntries()
        XCTAssertEqual(HistorySearch.filter(entries, query: "   \n"), entries)
    }

    func testFilteringKeepsOnlyMatchesAndPreservesOrder() {
        let entries = sampleEntries()

        XCTAssertEqual(
            HistorySearch.filter(entries, query: "发布").map(\.transcript),
            ["把发布计划整理成三条", "灰度发布的范围是多少"]
        )
    }

    func testFilteringNarrowsAsTermsAreAdded() {
        // The behavioural statement of the AND decision: typing more shows
        // less. Under OR this assertion inverts.
        let entries = sampleEntries()
        let oneTerm = HistorySearch.filter(entries, query: "发布")
        let twoTerms = HistorySearch.filter(entries, query: "发布 灰度")

        XCTAssertEqual(oneTerm.count, 2)
        XCTAssertEqual(twoTerms.count, 1)
        XCTAssertEqual(twoTerms.first?.transcript, "灰度发布的范围是多少")
    }

    func testNoMatchesReturnsAnEmptyListRatherThanEverything() {
        XCTAssertTrue(HistorySearch.filter(sampleEntries(), query: "银河系").isEmpty)
    }

    func testFilteringDoesNotTouchTheListItWasGiven() {
        let source = sampleEntries()
        _ = HistorySearch.filter(source, query: "发布")
        XCTAssertEqual(source, sampleEntries())
    }

    // MARK: - Fixtures

    // `id` is `Int` as of Task 7 of `docs/superpowers/plans/
    // 2026-08-25-unified-memory-and-recent-context.md` (it is now the
    // sidecar's `eventId`) — only these construction sites change; every
    // assertion above matches on `.transcript`/`.result`/`.applicationName`
    // and is untouched, exactly as that plan's Task 7 requires ("断言不变").
    // The old `uuid(_:)` fixture helper is gone with it; a plain `Int` needs
    // no formatting helper of its own.
    private func sampleEntries() -> [HistoryEntry] {
        [
            entry(
                id: 1,
                applicationName: "Xcode",
                transcript: "把发布计划整理成三条",
                result: "1. …"
            ),
            entry(
                id: 2,
                applicationName: "微信",
                transcript: "晚点聊",
                result: "晚点聊"
            ),
            entry(
                id: 3,
                applicationName: "Safari",
                transcript: "灰度发布的范围是多少",
                result: "先放 5%"
            ),
        ]
    }

    private func entry(
        id: Int = 0,
        applicationName: String,
        transcript: String,
        result: String,
        contextPreview: String? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000),
            mode: .transcribe,
            applicationName: applicationName,
            transcript: transcript,
            result: result,
            contextPreview: contextPreview
        )
    }
}

/// The 会话 list's search, and the one product decision in §I: **what an empty
/// result is allowed to claim.**
///
/// Session bodies live in the sidecar. The main window holds at most the
/// conversation currently open (`AppModel.askConversationDetail` and its agent
/// twin), so a search over bodies is a search over one or two of them — while
/// the list on screen may show fifty. The spec's ruling
/// (`2026-08-15-product-batch-plan.md` §I): match what is loaded, and when
/// nothing matches, **say that only the loaded sessions were searched** rather
/// than implying the archive was searched and is empty.
///
/// That is why the result is an enum and not `[ConversationSummary]` plus a
/// `Bool`. 「没有匹配的会话」 and 「只搜索了已加载的会话，没有匹配」 are different
/// claims about the world, and a UI handed a plain empty array will make the
/// first one — which is a lie about data the product is still holding.
final class SessionSearchTests: XCTestCase {

    // MARK: - Finding things

    func testAnEmptyQueryReturnsEveryConversationEvenWithNothingLoaded() {
        let list = conversations()
        XCTAssertEqual(
            SessionSearch.search(list, query: "", loadedDetails: [:]),
            .matches(list)
        )
    }

    func testAWhitespaceOnlyQueryBehavesLikeAnEmptyOne() {
        let list = conversations()
        XCTAssertEqual(
            SessionSearch.search(list, query: "  \t ", loadedDetails: [:]),
            .matches(list)
        )
    }

    func testABlankQueryOverAnEmptyListIsAnEmptyMatchNotAnEmptyResult() {
        // Pins the order of the two short-circuits. Written the tempting way —
        // `guard !conversations.isEmpty else { return .noMatches }` first — a
        // brand-new user with no sessions and an untouched search box gets
        // 「没有匹配的会话」 where the list's own 「还没有会话」 empty state
        // belongs. They have not searched for anything; nothing can fail to
        // match.
        XCTAssertEqual(
            SessionSearch.search([], query: "", loadedDetails: [:]),
            .matches([])
        )
    }

    func testATitleMatchNeedsNoLoadedBody() {
        let list = conversations()
        XCTAssertEqual(
            SessionSearch.search(list, query: "会议纪要", loadedDetails: [:]).conversations.map(\.id),
            [1]
        )
    }

    func testAMatchInTheBodyOfALoadedConversationIsFoundThoughTheTitleDoesNotMatch() {
        // The headline case. Conversation 2's title is 「新对话」 — an
        // auto-generated string the user has never read — and the word they
        // remember is in a message.
        let list = conversations()
        let outcome = SessionSearch.search(
            list,
            query: "灰度发布",
            loadedDetails: [2: detail(id: 2, title: "新对话", contents: ["灰度发布怎么排期", "先放 5%"])]
        )

        XCTAssertEqual(outcome.conversations.map(\.id), [2])
    }

    func testThePreviewIsMatchedEvenWithoutALoadedDetail() {
        // `ConversationSummary.preview` is the newest message, already on the
        // row. It is local text, so not searching it would be a search that
        // ignores something the user can see.
        let list = [
            conversation(id: 7, title: "新对话", preview: "记得把发布计划发我"),
        ]
        XCTAssertEqual(
            SessionSearch.search(list, query: "发布计划", loadedDetails: [:]).conversations.map(\.id),
            [7]
        )
    }

    func testTermsMayLandInTheTitleAndTheBodySeparately() {
        let list = conversations()
        let outcome = SessionSearch.search(
            list,
            query: "纪要 排期",
            loadedDetails: [1: detail(id: 1, title: "会议纪要", contents: ["排期定在下周"])]
        )

        XCTAssertEqual(outcome.conversations.map(\.id), [1])
    }

    func testMatchesPreserveTheOrderTheListArrivedIn() {
        let list = [
            conversation(id: 1, title: "发布 A"),
            conversation(id: 2, title: "无关"),
            conversation(id: 3, title: "发布 B"),
        ]
        XCTAssertEqual(
            SessionSearch.search(list, query: "发布", loadedDetails: [:]).conversations.map(\.id),
            [1, 3]
        )
    }

    func testALoadedDetailIsSearchedAcrossAllOfItsMessagesNotJustTheLast() {
        let list = [conversation(id: 3, title: "新对话")]
        let outcome = SessionSearch.search(
            list,
            query: "第一句",
            loadedDetails: [
                3: detail(id: 3, title: "新对话", contents: ["第一句在最上面", "中间", "最后一句"]),
            ]
        )

        XCTAssertEqual(outcome.conversations.map(\.id), [3])
    }

    // MARK: - The honesty of an empty result

    func testNothingMatchedAndEveryBodyWasLoadedIsAPlainNoMatches() {
        let list = [
            conversation(id: 1, title: "会议纪要"),
            conversation(id: 2, title: "新对话"),
        ]
        let outcome = SessionSearch.search(
            list,
            query: "银河系",
            loadedDetails: [
                1: detail(id: 1, title: "会议纪要", contents: ["排期"]),
                2: detail(id: 2, title: "新对话", contents: ["好的"]),
            ]
        )

        XCTAssertEqual(outcome, .noMatches)
    }

    func testNothingMatchedWithSomeBodiesUnloadedSaysSoAndCountsThem() {
        // The count is what lets the UI phrase it concretely
        // (「只搜索了已加载的 1 个会话」) instead of a vague disclaimer.
        let list = [
            conversation(id: 1, title: "会议纪要"),
            conversation(id: 2, title: "新对话"),
            conversation(id: 3, title: "另一个"),
        ]
        let outcome = SessionSearch.search(
            list,
            query: "银河系",
            loadedDetails: [1: detail(id: 1, title: "会议纪要", contents: ["排期"])]
        )

        XCTAssertEqual(outcome, .noMatchesInLoadedSubset(bodiesSearched: 1, total: 3))
    }

    func testNothingMatchedWithNoBodiesLoadedAtAllStillSaysSo() {
        let list = conversations()
        XCTAssertEqual(
            SessionSearch.search(list, query: "银河系", loadedDetails: [:]),
            .noMatchesInLoadedSubset(bodiesSearched: 0, total: list.count)
        )
    }

    func testAPreviewDoesNotCountAsASearchedBody() {
        // A preview is one truncated message. Counting it as "this
        // conversation was searched" would let the disclosure disappear
        // precisely when it is still true.
        let list = [conversation(id: 7, title: "新对话", preview: "记得把发布计划发我")]
        let outcome = SessionSearch.search(list, query: "银河系", loadedDetails: [:])

        XCTAssertEqual(outcome, .noMatchesInLoadedSubset(bodiesSearched: 0, total: 1))
    }

    func testALoadedConversationWithNoMessagesCountsAsSearched() {
        // Its body is known to be empty — that is a searched body, not a
        // missing one, and reporting it as missing would keep the disclaimer
        // up forever for a user who only ever opens empty threads.
        let list = [conversation(id: 4, title: "新对话")]
        let outcome = SessionSearch.search(
            list,
            query: "银河系",
            loadedDetails: [4: detail(id: 4, title: "新对话", contents: [])]
        )

        XCTAssertEqual(outcome, .noMatches)
    }

    func testADetailForAConversationNotInTheListNeitherMatchesNorCountsAsSearched() {
        // Reachable through the 会话 list's own filter chips, not a contrived
        // input: `AppModel` holds `askConversationDetail` *and*
        // `agentConversationDetail` at once, so opening an Agent session and
        // then switching the chip to 问答 leaves a loaded body whose row is not
        // on screen. Two failures hide here, and one equality pins both:
        //
        //   - counting it (`bodiesSearched: 1`) retires the disclaimer while
        //     every visible row was still matched on its title alone;
        //   - searching `loadedDetails.values` rather than the list's own ids
        //     returns 会议纪要 for a word that appears only in a thread the
        //     user is not looking at.
        let list = [conversation(id: 1, title: "会议纪要")]
        let outcome = SessionSearch.search(
            list,
            query: "排期",
            loadedDetails: [9: detail(id: 9, title: "另一个话题", contents: ["排期定在下周"])]
        )

        XCTAssertEqual(outcome, .noMatchesInLoadedSubset(bodiesSearched: 0, total: 1))
    }

    func testAnEmptyListIsAPlainNoMatchesRatherThanADisclaimer() {
        // 「只搜索了已加载的会话」 is nonsense when there are no sessions at all;
        // nothing was withheld from the search.
        XCTAssertEqual(
            SessionSearch.search([], query: "发布", loadedDetails: [:]),
            .noMatches
        )
    }

    func testANonEmptyResultCarriesNoDisclaimerEvenWithBodiesUnloaded() {
        // Per the spec, the disclosure attaches to the empty case only. A
        // non-empty list makes no claim about the archive; an empty one does.
        let list = conversations()
        let outcome = SessionSearch.search(list, query: "会议纪要", loadedDetails: [:])

        XCTAssertEqual(outcome, .matches([list[0]]))
    }

    func testTheOutcomeAlwaysExposesConversationsSoTheViewNeedsNoSwitchToRender() {
        XCTAssertTrue(SessionSearchOutcome.noMatches.conversations.isEmpty)
        XCTAssertTrue(
            SessionSearchOutcome.noMatchesInLoadedSubset(bodiesSearched: 0, total: 3)
                .conversations.isEmpty
        )
        let list = conversations()
        XCTAssertEqual(SessionSearchOutcome.matches(list).conversations, list)
    }

    func testTheTwoEmptyOutcomesAreNotEqual() {
        // The reason this is an enum: a UI that cannot tell these apart tells
        // the user the archive is empty when it was never read.
        XCTAssertNotEqual(
            SessionSearchOutcome.noMatches,
            .noMatchesInLoadedSubset(bodiesSearched: 0, total: 3)
        )
    }

    // MARK: - Fixtures

    private func conversations() -> [ConversationSummary] {
        [
            conversation(id: 1, title: "会议纪要"),
            conversation(id: 2, title: "新对话"),
        ]
    }

    private func conversation(
        id: Int,
        title: String,
        preview: String? = nil
    ) -> ConversationSummary {
        ConversationSummary(
            id: id,
            kind: "ask",
            title: title,
            createdAt: 1_760_000_000_000,
            updatedAt: 1_760_000_000_000,
            preview: preview
        )
    }

    private func detail(id: Int, title: String, contents: [String]) -> ConversationDetail {
        ConversationDetail(
            id: id,
            kind: "ask",
            title: title,
            createdAt: 1_760_000_000_000,
            updatedAt: 1_760_000_000_000,
            messages: contents.enumerated().map { index, content in
                ConversationMessageSummary(
                    id: index + 1,
                    conversationId: id,
                    role: index.isMultiple(of: 2) ? "user" : "assistant",
                    content: content,
                    createdAt: 1_760_000_000_000 + index * 1_000
                )
            }
        )
    }
}
