import Foundation
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for §I of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — export.
///
/// Motivation (`docs/reviews/2026-08-15-product-review.md` §7): "一个
/// local-first 产品把用户数据锁在自己的 `history.json` 里，和定位正面冲突."
/// Local-first means the user's data is theirs; a store with no way out is
/// merely a store nobody else can read.
///
/// Expected shape (Stage 3 creates it; nothing here builds it) — a new
/// `Sources/OpenType/HistoryExport.swift`, pure, no filesystem and no
/// `NSSavePanel` (the caller writes the returned string):
///
///     enum HistoryExport {
///         static func markdown(entries: [HistoryEntry], exportedAt: Date) -> String
///         static func json(entries: [HistoryEntry], exportedAt: Date) -> String
///         static func markdown(conversation: ConversationDetail, exportedAt: Date) -> String
///         static func json(conversation: ConversationDetail, exportedAt: Date) -> String
///
///         static func decodeHistory(_ json: String) throws -> HistoryExportDocument
///         static func decodeConversation(_ json: String) throws -> ConversationExportDocument
///     }
///
///     struct HistoryExportDocument: Decodable, Equatable {
///         let format: String      // "opentype.history"
///         let version: Int        // 1
///         let exportedAt: Date
///         let entries: [HistoryEntry]
///     }
///
///     struct ConversationExportDocument: Decodable, Equatable {
///         let format: String      // "opentype.conversation"
///         let version: Int        // 1
///         let exportedAt: Date
///         let conversation: ConversationDetail
///     }
///
/// No `Models.swift` change is *required*. `ConversationDetail` is `Decodable`
/// only, so the JSON writer either gains a private encodable mirror inside
/// `HistoryExport.swift` or `ConversationDetail`/`ConversationMessageSummary`
/// widen to `Codable` — these tests deliberately do not pin which, because they
/// assert on the emitted JSON, not on how it was produced.
///
/// ---
///
/// ## Pinned decision 1 — the export's vocabulary does not follow the UI language
///
/// Structural labels (`Exported:`, `### Transcript`) are fixed English, and the
/// mode is written as its **wire raw value** (`transcribe`/`ask`/`agent`) rather
/// than `InputMode.title`'s 听写/问答/Agent. Item F of this same batch makes
/// `OpenTypeL10n.text` follow the system language; if the export read from it,
/// the same history would export with different structure depending on a
/// display setting, and two files from the same user would not diff. The user's
/// own text is of course untouched — it is the scaffolding that is fixed.
///
/// ## Pinned decision 2 — timestamps are ISO-8601 in UTC
///
/// Fixed offset, second resolution, `.withInternetDateTime`. Local time would
/// make the export non-deterministic across machines and unsortable across
/// timezone changes, and a snapshot test of a locale-dependent format tests the
/// test machine. It also matches what `history.json` already stores.
///
/// ## Pinned decision 3 — the body is emitted verbatim, never escaped
///
/// A transcript containing `# `, `---` or a code fence is written as-is. The
/// export exists so the user gets *what they said*; escaping it produces a file
/// that is no longer their text, and the alternative (wrapping every body in a
/// fence) breaks copy-paste, which is the main thing anyone does with an
/// exported dictation.
///
/// The cost is stated rather than hidden: a body can contain a line identical
/// to the record separator, so **the Markdown export is not round-trippable**.
/// That is exactly why JSON exists alongside it, and why JSON is the one with a
/// decoder pinned below. Markdown is for reading; JSON is the archive.
///
/// ## Pinned decision 4 — `Result` is always emitted, even when it equals `Transcript`
///
/// In 听写 `direct` the two strings are identical, and skipping the duplicate
/// would save real bytes over a thousand entries. It is still wrong: a reader
/// parsing the file cannot distinguish "omitted because identical" from
/// "missing", so the saving buys an ambiguity in the one property this feature
/// is judged on. `contextPreview` is different — it is genuinely optional, so
/// its absence is unambiguous and its section is omitted when there is none.
///
/// ## Pinned decision 5 — export preserves the order it was handed
///
/// Not re-sorted by date. The caller passes what is on screen (newest-first,
/// after the source filter and the body search), so "export" means "export what
/// I am looking at" — which is also what makes exporting a *search result* work
/// without a second entry point.
final class HistoryExportMarkdownTests: XCTestCase {

    private let exportedAt = Date(timeIntervalSince1970: 1_755_086_400)  // 2025-08-13T12:00:00Z

    // MARK: - Dictation history

    func testHistoryMarkdownSnapshot() {
        let markdown = HistoryExport.markdown(
            entries: [
                HistoryEntry(
                    createdAt: Date(timeIntervalSince1970: 1_755_000_000),
                    mode: .transcribe,
                    applicationName: "Xcode",
                    transcript: "把这段话记下来",
                    result: "把这段话记下来。",
                    contextPreview: nil
                ),
                HistoryEntry(
                    createdAt: Date(timeIntervalSince1970: 1_754_900_000),
                    mode: .ask,
                    applicationName: "Safari",
                    transcript: "这个词什么意思",
                    result: "它指的是灰度发布",
                    contextPreview: "选中的原文"
                ),
            ],
            exportedAt: exportedAt
        )

        let expected = """
        # OpenType History

        Exported: 2025-08-13T12:00:00Z
        Entries: 2

        ---

        ## 2025-08-12T12:00:00Z · transcribe · Xcode

        ### Transcript

        把这段话记下来

        ### Result

        把这段话记下来。

        ---

        ## 2025-08-11T08:13:20Z · ask · Safari

        ### Transcript

        这个词什么意思

        ### Result

        它指的是灰度发布

        ### Context

        选中的原文
        """

        // Swift's multi-line literal drops the newline before its closing
        // delimiter; the document itself ends with exactly one.
        XCTAssertEqual(markdown, expected + "\n")
    }

    func testAnEmptyHistoryStillProducesAValidDocument() {
        let markdown = HistoryExport.markdown(entries: [], exportedAt: exportedAt)

        let expected = """
        # OpenType History

        Exported: 2025-08-13T12:00:00Z
        Entries: 0
        """

        XCTAssertEqual(markdown, expected + "\n")
    }

    func testTheDocumentEndsWithExactlyOneNewline() {
        let markdown = HistoryExport.markdown(entries: [entry()], exportedAt: exportedAt)
        XCTAssertTrue(markdown.hasSuffix("\n"))
        XCTAssertFalse(markdown.hasSuffix("\n\n"))
    }

    func testResultIsEmittedEvenWhenItIsIdenticalToTheTranscript() {
        let markdown = HistoryExport.markdown(
            entries: [entry(transcript: "一模一样", result: "一模一样")],
            exportedAt: exportedAt
        )

        XCTAssertTrue(markdown.contains("### Transcript"))
        XCTAssertTrue(
            markdown.contains("### Result"),
            "omitting the duplicate would make 'identical' indistinguishable from 'missing'"
        )
    }

    /// `HistoryEntry.result` became `String?` in Task 7 of
    /// `docs/superpowers/plans/2026-08-25-unified-memory-and-recent-context.md`
    /// (a row can now be "recorded, nothing delivered" —
    /// `HistoryEntryMappingTests.swift` pins that `nil` stays `nil` rather
    /// than echoing the transcript). `entrySection`'s `\(entry.result)`
    /// interpolation compiles unchanged against an `Optional<String>` — Swift
    /// does not error on that — so nothing before this test would have caught
    /// it printing the string `Optional("…")`, or bare `nil`, straight into a
    /// file a user opens in a text editor.
    ///
    /// Chosen rendering: keep the `### Result` heading present — an omitted
    /// section would be ambiguous between "nothing delivered" and "exported
    /// by an older build that had no such row", the same shape of ambiguity
    /// decision 4 above already rules out for the identical-to-transcript
    /// case — and render the body as a bare em dash rather than an empty
    /// string. Empty was rejected because it is reachable for a real,
    /// non-nil result too (e.g. a `tidy` rewrite that trims a transcript down
    /// to nothing), so an empty `### Result` body would be confusable with
    /// "delivered the empty string" instead of unambiguously meaning
    /// "nothing was delivered".
    func testANilResultRendersAsAnExplicitPlaceholderNotSwiftsOptionalDescription() {
        let markdown = HistoryExport.markdown(
            entries: [entry(result: nil)],
            exportedAt: exportedAt
        )

        // Two assertions below that look redundant are not — keep both.
        //  - The bare-`nil` check is the one that actually fails without the
        //    fix: `\(entry.result)` for a genuinely-nil `Optional<String>`
        //    interpolates as the literal text "nil", never "Optional(nil)".
        //  - The `Optional(` check is vacuous on *this* nil-result input —
        //    nothing here would ever produce that text — but it stays as
        //    the guard against a *different* regression: a non-nil result
        //    getting double-wrapped upstream (e.g. `String??`). That shape
        //    of bug is otherwise only caught by `testHistoryMarkdownSnapshot`'s
        //    exact-string comparison over a *non-nil* result, so removing
        //    this line as "redundant" would quietly drop coverage for the
        //    nil-result path of that same failure mode.
        XCTAssertFalse(markdown.contains("### Result\n\nnil"), "must not print the bare word nil")
        XCTAssertFalse(markdown.contains("Optional("), "must not leak Swift's Optional description")
        XCTAssertTrue(
            markdown.contains("### Result\n\n—"),
            "expected the heading to stay present with an em-dash placeholder body"
        )
    }

    func testTheContextSectionIsOmittedWhenThereIsNoContext() {
        let markdown = HistoryExport.markdown(
            entries: [entry(contextPreview: nil)],
            exportedAt: exportedAt
        )
        XCTAssertFalse(markdown.contains("### Context"))
    }

    func testAnEmptyApplicationNameDropsItsHeadingSegmentRatherThanLeavingASeparator() {
        let markdown = HistoryExport.markdown(
            entries: [entry(applicationName: "")],
            exportedAt: exportedAt
        )

        XCTAssertTrue(markdown.contains("## 2025-08-12T12:00:00Z · transcribe\n"))
        XCTAssertFalse(markdown.contains("· transcribe · \n"))
    }

    func testTheModeIsTheWireValueNotTheLocalisedTitle() {
        // Item F of this batch makes `OpenTypeL10n` follow the system language.
        // An export whose structure changes with a display setting cannot be
        // diffed against last month's export of the same history.
        for mode in InputMode.allCases {
            let markdown = HistoryExport.markdown(
                entries: [entry(mode: mode)],
                exportedAt: exportedAt
            )
            XCTAssertTrue(
                markdown.contains("· \(mode.rawValue) ·"),
                "expected the raw value for \(mode)"
            )
        }
    }

    func testEntriesAreExportedInTheOrderTheyWereGivenNotReSorted() throws {
        // Deliberately handed oldest-first: the caller decides the order, and
        // "export what I am looking at" is the whole contract.
        let markdown = HistoryExport.markdown(
            entries: [
                entry(createdAt: Date(timeIntervalSince1970: 1_754_800_000), transcript: "最早"),
                entry(createdAt: Date(timeIntervalSince1970: 1_755_000_000), transcript: "最新"),
            ],
            exportedAt: exportedAt
        )

        let earliest = try XCTUnwrap(markdown.range(of: "最早"))
        let latest = try XCTUnwrap(markdown.range(of: "最新"))
        XCTAssertTrue(earliest.lowerBound < latest.lowerBound)
    }

    // MARK: - Content survival (the part that matters more than the shape)

    func testAMultilineTranscriptSurvivesWithItsNewlines() {
        let transcript = "第一行\n第二行\n\n第四行（第三行是空行）"
        let markdown = HistoryExport.markdown(
            entries: [entry(transcript: transcript, result: transcript)],
            exportedAt: exportedAt
        )

        XCTAssertTrue(markdown.contains(transcript))
    }

    func testMarkdownSyntaxInsideATranscriptIsNotEscapedOrStripped() {
        // The user dictated it; the file has to contain it. This is also the
        // reason the Markdown export is not the archive format.
        let transcript = "# 这不是标题\n---\n```\ncode\n```\n*星号* 和 _下划线_"
        let markdown = HistoryExport.markdown(
            entries: [entry(transcript: transcript, result: transcript)],
            exportedAt: exportedAt
        )

        XCTAssertTrue(markdown.contains(transcript))
    }

    func testALongTranscriptIsNotTruncated() {
        // An export that silently caps at some length is worse than no export:
        // the user believes they have their data.
        let transcript = String(repeating: "很长的一段口述内容。", count: 2_000)
        XCTAssertEqual(transcript.count, 20_000)

        let markdown = HistoryExport.markdown(
            entries: [entry(transcript: transcript, result: transcript)],
            exportedAt: exportedAt
        )

        XCTAssertTrue(markdown.contains(transcript))
    }

    func testEveryEntryInALargeHistoryIsPresent() {
        // The 1000-entry cap this batch raises to is the realistic export size;
        // a per-document limit would only show up at that scale.
        let entries = (0..<1_000).map { index in
            entry(transcript: "标记-\(index)", result: "结果-\(index)")
        }
        let markdown = HistoryExport.markdown(entries: entries, exportedAt: exportedAt)

        XCTAssertTrue(markdown.contains("Entries: 1000"))
        for index in [0, 1, 499, 998, 999] {
            XCTAssertTrue(markdown.contains("标记-\(index)"), "entry \(index) is missing")
        }
    }

    // MARK: - One conversation

    func testConversationMarkdownSnapshot() {
        let markdown = HistoryExport.markdown(
            conversation: conversation(
                messages: [
                    ("user", "帮我总结一下", 1_760_000_000_000),
                    ("assistant", "好的，总结如下：\n\n- 第一点\n- 第二点", 1_760_000_060_000),
                ]
            ),
            exportedAt: exportedAt
        )

        let expected = """
        # 会议纪要

        Exported: 2025-08-13T12:00:00Z
        Conversation: 42
        Kind: ask
        Messages: 2

        ---

        ## user · 2025-10-09T08:53:20Z

        帮我总结一下

        ---

        ## assistant · 2025-10-09T08:54:20Z

        好的，总结如下：

        - 第一点
        - 第二点
        """

        XCTAssertEqual(markdown, expected + "\n")
    }

    func testAConversationWithNoMessagesStillProducesAValidDocument() {
        let markdown = HistoryExport.markdown(
            conversation: conversation(messages: []),
            exportedAt: exportedAt
        )

        let expected = """
        # 会议纪要

        Exported: 2025-08-13T12:00:00Z
        Conversation: 42
        Kind: ask
        Messages: 0
        """

        XCTAssertEqual(markdown, expected + "\n")
    }

    func testAnUntitledConversationFallsBackToItsIdRatherThanAnEmptyHeading() {
        let markdown = HistoryExport.markdown(
            conversation: conversation(title: "", messages: []),
            exportedAt: exportedAt
        )

        XCTAssertTrue(markdown.hasPrefix("# Conversation 42\n"))
    }

    func testMessageTimestampsAreConvertedFromMillisecondsToUTC() {
        // `ConversationDetail.createdAt` is milliseconds since epoch (the
        // sidecar's SQLite column); dividing by 1000 is easy to forget and
        // produces a date in 1970 that nobody notices in a snapshot of one row.
        let markdown = HistoryExport.markdown(
            conversation: conversation(
                messages: [("user", "只有一条", 1_760_000_000_000)]
            ),
            exportedAt: exportedAt
        )

        XCTAssertTrue(markdown.contains("## user · 2025-10-09T08:53:20Z"))
    }

    func testAConversationMessageIsExportedInFullIncludingNewlinesAndCJK() {
        let content = "第一段。\n\n第二段，带 CJK 和 ASCII mixed 内容。\n" +
            String(repeating: "补充说明。", count: 2_000)
        let markdown = HistoryExport.markdown(
            conversation: conversation(messages: [("assistant", content, 1_760_000_000_000)]),
            exportedAt: exportedAt
        )

        XCTAssertTrue(markdown.contains(content))
    }

    func testMessagesAreExportedInTheOrderTheThreadHoldsThem() {
        let markdown = HistoryExport.markdown(
            conversation: conversation(
                messages: [
                    ("user", "问题一", 1_760_000_000_000),
                    ("assistant", "回答一", 1_760_000_010_000),
                    ("user", "问题二", 1_760_000_020_000),
                ]
            ),
            exportedAt: exportedAt
        )

        let positions = ["问题一", "回答一", "问题二"].compactMap {
            markdown.range(of: $0)?.lowerBound
        }
        XCTAssertEqual(positions.count, 3)
        XCTAssertEqual(positions, positions.sorted())
    }

    // MARK: - Fixtures

    // `result` became `String?` in Task 7 of `docs/superpowers/plans/
    // 2026-08-25-unified-memory-and-recent-context.md` (a row can now be
    // "recorded, nothing delivered") — widened here from `String` so
    // `testANilResultRendersAsAnExplicitPlaceholderNotSwiftsOptionalDescription`
    // below can pass `nil`. Every other call site keeps passing a plain
    // `String` literal, which still compiles unchanged (implicit promotion to
    // the optional parameter).
    private func entry(
        createdAt: Date = Date(timeIntervalSince1970: 1_755_000_000),
        mode: InputMode = .transcribe,
        applicationName: String = "Xcode",
        transcript: String = "把这段话记下来",
        result: String? = "把这段话记下来。",
        contextPreview: String? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            createdAt: createdAt,
            mode: mode,
            applicationName: applicationName,
            transcript: transcript,
            result: result,
            contextPreview: contextPreview
        )
    }

    private func conversation(
        title: String = "会议纪要",
        messages: [(role: String, content: String, createdAt: Int)]
    ) -> ConversationDetail {
        ConversationDetail(
            id: 42,
            kind: "ask",
            title: title,
            createdAt: 1_760_000_000_000,
            updatedAt: 1_760_000_060_000,
            messages: messages.enumerated().map { index, message in
                ConversationMessageSummary(
                    id: index + 1,
                    conversationId: 42,
                    role: message.role,
                    content: message.content,
                    createdAt: message.createdAt
                )
            }
        )
    }
}

/// JSON is the archive half: Markdown is for reading, JSON is what has to come
/// back in unchanged. So this suite is a round-trip suite rather than a
/// snapshot suite — the properties worth pinning are "nothing was lost" and
/// "the same input produces the same bytes", not Foundation's exact indentation
/// of a nested array.
final class HistoryExportJSONTests: XCTestCase {

    private let exportedAt = Date(timeIntervalSince1970: 1_755_086_400)  // 2025-08-13T12:00:00Z

    // MARK: - Dictation history

    func testHistoryJSONRoundTripsEveryEntryUnchanged() throws {
        let entries = [
            HistoryEntry(
                createdAt: Date(timeIntervalSince1970: 1_755_000_000),
                mode: .transcribe,
                applicationName: "Xcode",
                transcript: "把这段话记下来\n第二行",
                result: "把这段话记下来。\n第二行",
                contextPreview: nil
            ),
            HistoryEntry(
                createdAt: Date(timeIntervalSince1970: 1_754_900_000),
                mode: .agent,
                applicationName: "Finder",
                transcript: "找一下那个文档",
                result: "已打开 ~/Desktop/纪要.md",
                contextPreview: "选中的原文"
            ),
        ]

        let document = try HistoryExport.decodeHistory(
            HistoryExport.json(entries: entries, exportedAt: exportedAt)
        )

        XCTAssertEqual(document.entries, entries, "ids, dates, modes and both bodies must survive")
        XCTAssertEqual(document.exportedAt, exportedAt)
        XCTAssertEqual(document.format, "opentype.history")
        XCTAssertEqual(document.version, 1)
    }

    func testHistoryJSONPreservesOrder() throws {
        let entries = (0..<50).map { index in
            HistoryEntry(
                createdAt: Date(timeIntervalSince1970: 1_755_000_000),
                mode: .transcribe,
                applicationName: "Xcode",
                transcript: "标记-\(index)",
                result: "结果-\(index)",
                contextPreview: nil
            )
        }

        let document = try HistoryExport.decodeHistory(
            HistoryExport.json(entries: entries, exportedAt: exportedAt)
        )

        XCTAssertEqual(document.entries.map(\.id), entries.map(\.id))
    }

    func testALongTranscriptRoundTripsIntact() throws {
        let transcript = String(repeating: "很长的一段口述内容。", count: 2_000)
        let entries = [
            HistoryEntry(
                createdAt: Date(timeIntervalSince1970: 1_755_000_000),
                mode: .transcribe,
                applicationName: "Xcode",
                transcript: transcript,
                result: transcript,
                contextPreview: nil
            ),
        ]

        let document = try HistoryExport.decodeHistory(
            HistoryExport.json(entries: entries, exportedAt: exportedAt)
        )

        XCTAssertEqual(document.entries.first?.transcript.count, 20_000)
        XCTAssertEqual(document.entries.first?.transcript, transcript)
    }

    /// Companion to the Markdown placeholder test above: JSON is the archive
    /// format (decision 3), so the em-dash rendering chosen for Markdown must
    /// stay purely cosmetic and never leak into the round-trippable format.
    /// `HistoryEntry` is a plain `Codable` struct, so a `nil` `result` is
    /// expected to already round-trip correctly via `encodeIfPresent` with no
    /// extra code — this test exists to prove that expectation rather than
    /// leave it assumed, the same way `testMigratedRowsKeepTheirFieldsIncludingAnAbsentContextPreview`
    /// in `HistoryStoreDeleteTests.swift` proves it for `contextPreview`.
    func testJSONResultRoundTripsAsNilRatherThanThePlaceholder() throws {
        // Spelled out in full rather than calling `entry(...)` — that helper
        // is `private` to the sibling `HistoryExportMarkdownTests` class,
        // scoped to its enclosing type (not the file), so it is not visible
        // here; this class's other tests already build `HistoryEntry`
        // directly for the same reason.
        let entries = [
            HistoryEntry(
                createdAt: Date(timeIntervalSince1970: 1_755_000_000),
                mode: .transcribe,
                applicationName: "Xcode",
                transcript: "把这段话记下来",
                result: nil,
                contextPreview: nil
            ),
        ]

        let document = try HistoryExport.decodeHistory(
            HistoryExport.json(entries: entries, exportedAt: exportedAt)
        )

        XCTAssertNil(document.entries.first?.result)
    }

    func testAnEmptyHistoryExportsAsAValidEmptyDocument() throws {
        let json = HistoryExport.json(entries: [], exportedAt: exportedAt)
        let document = try HistoryExport.decodeHistory(json)

        XCTAssertEqual(document.entries, [])
        XCTAssertEqual(document.format, "opentype.history")
    }

    func testTheSameHistoryExportsToTheSameBytes() {
        let entries = [
            HistoryEntry(
                createdAt: Date(timeIntervalSince1970: 1_755_000_000),
                mode: .transcribe,
                applicationName: "Xcode",
                transcript: "一致性",
                result: "一致性",
                contextPreview: "上下文"
            ),
        ]

        XCTAssertEqual(
            HistoryExport.json(entries: entries, exportedAt: exportedAt),
            HistoryExport.json(entries: entries, exportedAt: exportedAt)
        )
    }

    func testTheJSONIsHumanReadableWithSortedKeys() throws {
        let json = HistoryExport.json(
            entries: [
                HistoryEntry(
                    createdAt: Date(timeIntervalSince1970: 1_755_000_000),
                    mode: .transcribe,
                    applicationName: "Xcode",
                    transcript: "内容",
                    result: "内容",
                    contextPreview: nil
                ),
            ],
            exportedAt: exportedAt
        )

        // A local-first export lands in the user's Documents folder and gets
        // opened in a text editor; a single-line blob is technically the same
        // data and practically a different product. Sorted keys are what make
        // two exports diffable.
        XCTAssertTrue(json.contains("\n"), "expected pretty-printed output")
        let entriesAt = try XCTUnwrap(json.range(of: "\"entries\"")).lowerBound
        let exportedAtAt = try XCTUnwrap(json.range(of: "\"exportedAt\"")).lowerBound
        let formatAt = try XCTUnwrap(json.range(of: "\"format\"")).lowerBound
        let versionAt = try XCTUnwrap(json.range(of: "\"version\"")).lowerBound
        XCTAssertTrue(entriesAt < exportedAtAt)
        XCTAssertTrue(exportedAtAt < formatAt)
        XCTAssertTrue(formatAt < versionAt)
    }

    func testTheJSONParsesAsJSON() throws {
        let json = HistoryExport.json(entries: [], exportedAt: exportedAt)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertNotNil(object as? [String: Any])
    }

    func testDatesAreISO8601Strings() {
        // Matching `history.json`'s own on-disk encoding, so an exported file
        // and the store's file describe a timestamp the same way.
        let json = HistoryExport.json(
            entries: [
                HistoryEntry(
                    createdAt: Date(timeIntervalSince1970: 1_755_000_000),
                    mode: .transcribe,
                    applicationName: "Xcode",
                    transcript: "内容",
                    result: "内容",
                    contextPreview: nil
                ),
            ],
            exportedAt: exportedAt
        )

        XCTAssertTrue(json.contains("2025-08-12T12:00:00Z"))
        XCTAssertTrue(json.contains("2025-08-13T12:00:00Z"))
    }

    // MARK: - One conversation

    func testConversationJSONRoundTripsTheWholeThread() throws {
        let detail = ConversationDetail(
            id: 42,
            kind: "agent",
            title: "会议纪要",
            createdAt: 1_760_000_000_000,
            updatedAt: 1_760_000_060_000,
            messages: [
                ConversationMessageSummary(
                    id: 1,
                    conversationId: 42,
                    role: "user",
                    content: "帮我总结一下",
                    createdAt: 1_760_000_000_000
                ),
                ConversationMessageSummary(
                    id: 2,
                    conversationId: 42,
                    role: "assistant",
                    content: "好的，总结如下：\n\n- 第一点\n- 第二点",
                    createdAt: 1_760_000_060_000
                ),
            ]
        )

        let document = try HistoryExport.decodeConversation(
            HistoryExport.json(conversation: detail, exportedAt: exportedAt)
        )

        XCTAssertEqual(document.conversation, detail)
        XCTAssertEqual(document.exportedAt, exportedAt)
        XCTAssertEqual(document.format, "opentype.conversation")
        XCTAssertEqual(document.version, 1)
    }

    func testAConversationWithNoMessagesRoundTrips() throws {
        let detail = ConversationDetail(
            id: 7,
            kind: "ask",
            title: "新对话",
            createdAt: 1_760_000_000_000,
            updatedAt: 1_760_000_000_000,
            messages: []
        )

        let document = try HistoryExport.decodeConversation(
            HistoryExport.json(conversation: detail, exportedAt: exportedAt)
        )

        XCTAssertEqual(document.conversation, detail)
    }

    func testALongAssistantAnswerRoundTripsIntact() throws {
        let content = String(repeating: "补充说明。", count: 4_000)
        let detail = ConversationDetail(
            id: 7,
            kind: "agent",
            title: "长回答",
            createdAt: 1_760_000_000_000,
            updatedAt: 1_760_000_000_000,
            messages: [
                ConversationMessageSummary(
                    id: 1,
                    conversationId: 7,
                    role: "assistant",
                    content: content,
                    createdAt: 1_760_000_000_000
                ),
            ]
        )

        let document = try HistoryExport.decodeConversation(
            HistoryExport.json(conversation: detail, exportedAt: exportedAt)
        )

        XCTAssertEqual(document.conversation.messages.first?.content, content)
    }

    func testTheSameConversationExportsToTheSameBytes() {
        let detail = ConversationDetail(
            id: 42,
            kind: "ask",
            title: "会议纪要",
            createdAt: 1_760_000_000_000,
            updatedAt: 1_760_000_060_000,
            messages: []
        )

        XCTAssertEqual(
            HistoryExport.json(conversation: detail, exportedAt: exportedAt),
            HistoryExport.json(conversation: detail, exportedAt: exportedAt)
        )
    }

    func testConversationTimestampsStayMillisecondIntegersInJSON() throws {
        // The Markdown export renders them as ISO strings for reading; the JSON
        // keeps the sidecar's own representation so a re-import needs no
        // guesswork about units.
        let detail = ConversationDetail(
            id: 42,
            kind: "ask",
            title: "会议纪要",
            createdAt: 1_760_000_000_000,
            updatedAt: 1_760_000_060_000,
            messages: []
        )
        let json = HistoryExport.json(conversation: detail, exportedAt: exportedAt)

        XCTAssertTrue(json.contains("1760000000000"))
        XCTAssertTrue(json.contains("1760000060000"))
    }

    func testDecodingSomethingThatIsNotAnExportThrows() throws {
        XCTAssertThrowsError(try HistoryExport.decodeHistory("{}"))
        XCTAssertThrowsError(try HistoryExport.decodeConversation("not json"))
    }
}
