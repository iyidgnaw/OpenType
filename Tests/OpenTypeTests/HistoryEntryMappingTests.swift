import Foundation
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for Task 7 of `docs/superpowers/plans/
/// 2026-08-25-unified-memory-and-recent-context.md` ("听写历史换源") — the
/// mapping half: turning one row of the sidecar's `GET /memory/events`
/// response (already served, `sidecar/src/memory/routes.ts`, backed by
/// `episodic_events` — Tasks 1/3/6 of the same plan, already landed) into the
/// `HistoryEntry` view model `HistorySearch.swift`/`HistoryExport.swift`/
/// `DictationViews.swift` already know how to render, filter and export.
///
/// Design §3.7: "Swift 侧的关键是保住 `HistoryEntry` 这个视图模型，只把来源从
/// 本地文件换成 sidecar." So this file pins the one seam that changes —
/// `EpisodicEventDTO` and `HistoryEntry.init(from:)` — and nothing about
/// `HistorySearch`/`HistoryExport` themselves, which is why their own test
/// files are touched only where they must change to *compile* (see
/// `HistorySearchTests.swift`'s fixture comment) and not where they assert.
///
/// Expected shape (Stage 3 creates it; nothing here builds it) —
/// `Models.swift` gains:
///
///     struct EpisodicEventDTO: Decodable {
///         let id: Int
///         let createdAt: Int              // ms since epoch, the sidecar's SQLite convention
///         let mode: String                // wire raw value: transcribe/ask/agent
///         let rawTranscript: String
///         let correctedTranscript: String
///         let effectiveInput: String?
///         let selectedContext: String?
///         let result: String?
///         let applicationName: String
///         let origin: String
///         let conversationId: Int?
///     }
///
///     extension HistoryEntry {
///         init(from dto: EpisodicEventDTO)
///     }
///
/// and `HistoryEntry` itself changes exactly two stored properties:
/// `id: UUID` → `id: Int` (it now *is* the sidecar's `eventId`, so a delete
/// maps straight to `DELETE /memory/events/:id` — see
/// `HistoryEventsRequestTests.swift`), and `result: String` → `result:
/// String?`.
///
/// ## Pinned decision 1 — `result` maps straight through, never backfilled
///
/// A row with nothing delivered (`dto.result == nil`) must produce
/// `entry.result == nil`, not `entry.transcript`. Copying the transcript in
/// as a fallback would make "recorded but nothing delivered" indistinguishable
/// from "delivered the original text verbatim" — two different failures the
/// dictation list has to be able to show differently.
///
/// ## Pinned decision 2 — `transcript` maps from `correctedTranscript`, not `rawTranscript`
///
/// Not pinned by the plan's own Step-1 example (it never asserts on
/// `entry.transcript`), so this is this file's own addition, grounded in
/// existing code rather than guessed: every one of `AppModel.swift`'s current
/// `history.add(HistoryEntry(transcript: transcript, ...))` call sites passes
/// the *same* local `transcript` variable it also hands to
/// `EpisodicEventRecorder.body(correctedTranscript:)` two lines away (see
/// `AppModel.swift` around the `.completed` audit-event sites, e.g. the ask
/// dispatch at ~4339–4344 and the agent dispatch at ~4716–4721). `rawTranscript`
/// is what Whisper heard *before* the entity dictionary fixed a misheard
/// alias; `correctedTranscript` is that same text after the fix (identical to
/// `rawTranscript` for `ask`/`agent`, which have no dictionary stage). The
/// dictation list's "Transcript" section has always shown the corrected
/// version, and this mapping keeps it that way.
///
/// ## Pinned decision 3 — `createdAt` is milliseconds since epoch
///
/// The sidecar's SQLite convention, matching `ConversationSummary.createdAt`/
/// `ConversationDetail.createdAt` elsewhere in `Models.swift` and the
/// division `HistoryExport.isoString(millisecondsSinceEpoch:)` already does
/// for the same reason: dividing by 1000 is easy to forget and produces a
/// date in 1970 that nobody notices in a snapshot of one row.
///
/// ## Pinned decision 4 — `contextPreview` re-truncates to 240 characters
///
/// Product decision (team lead, this task). Task 7's strategy is "change
/// only where the data comes from, so the page behaves identically" — and
/// truncation was part of that behaviour: every pre-migration
/// `history.add(HistoryEntry(contextPreview:))` call site cut with
/// `.map { String($0.prefix(240)) }` before storing, because the field
/// renders inside a list row and an untruncated selection would wreck the
/// layout. `dto.selectedContext` on the wire is the **full**, untruncated
/// value (`EpisodicEventRecorder.body(selectedContext:)` never truncates on
/// the way out — the sidecar keeps the whole thing for
/// `opentype__read_history`), so `HistoryEntry.init(from:)` is where the
/// re-truncation now has to happen.
///
/// ## What this file does not pin
///
/// The actual HTTP request `AppModel.refreshHistory()`/`deleteHistoryEntry(id:)`
/// send to fetch/delete these rows, and that a successful `POST
/// /memory/events` (already wired — `AppModel.recordEpisodicEvent`) triggers a
/// refresh — those require a live `AppModel`, which no test in this suite
/// constructs (`AppModel.init` spawns the sidecar child process and touches
/// `NSApp`). The request *shapes* are pinned separately, without a live
/// instance, in `HistoryEventsRequestTests.swift`, following the same seam
/// `HistoryResetContextLogTests.swift` already established for
/// `contextLogResetRequest`. Whether `refreshHistory()` actually calls
/// `HistoryEntry.init(from:)` on every element of the decoded response, and
/// whether a failed fetch leaves `historyEntries` untouched rather than
/// clearing it, is stage-4 reading.
final class HistoryEntryMappingTests: XCTestCase {

    func testTranscribeRowMapsDeliveredTextToResult() {
        let dto = EpisodicEventDTO(
            id: 42, createdAt: 1_700_000_000_000, mode: "transcribe",
            rawTranscript: "呃明天开会", correctedTranscript: "呃明天开会",
            effectiveInput: nil, selectedContext: nil, result: "明天开会",
            applicationName: "WeChat", origin: "owner", conversationId: nil
        )
        let entry = HistoryEntry(from: dto)
        XCTAssertEqual(entry.id, 42)
        XCTAssertEqual(entry.applicationName, "WeChat")
        XCTAssertEqual(entry.result, "明天开会")
        XCTAssertEqual(entry.mode, .transcribe)
    }

    func testRowWithoutResultKeepsNilRatherThanEchoingTranscript() {
        let dto = EpisodicEventDTO(
            id: 43, createdAt: 1, mode: "transcribe",
            rawTranscript: "x", correctedTranscript: "x",
            effectiveInput: nil, selectedContext: nil, result: nil,
            applicationName: "App", origin: "owner", conversationId: nil
        )
        // Copying the transcript into `result` would make the list show
        // "delivered the original text" for a row where nothing was actually
        // delivered — the two must stay distinguishable on screen.
        XCTAssertNil(HistoryEntry(from: dto).result)
    }

    func testTranscriptMapsFromCorrectedTranscriptNotRawTranscript() {
        // The two differ only when the entity dictionary rewrote a misheard
        // alias (`sidecar/src/asr/dictionaryBias.ts`). The dictation list's
        // "Transcript" has always shown the corrected reading, not the raw
        // ASR output the user never saw.
        let dto = EpisodicEventDTO(
            id: 1, createdAt: 1, mode: "transcribe",
            rawTranscript: "用拍拍付款", correctedTranscript: "用PayPal付款",
            effectiveInput: nil, selectedContext: nil, result: "用PayPal付款。",
            applicationName: "App", origin: "owner", conversationId: nil
        )
        XCTAssertEqual(HistoryEntry(from: dto).transcript, "用PayPal付款")
    }

    func testAskAndAgentModesMapToTheirInputModeCase() {
        for (raw, mode) in [("ask", InputMode.ask), ("agent", InputMode.agent)] {
            let dto = EpisodicEventDTO(
                id: 5, createdAt: 1, mode: raw,
                rawTranscript: "问题", correctedTranscript: "问题",
                effectiveInput: nil, selectedContext: nil, result: "答案",
                applicationName: "Xcode", origin: "agent", conversationId: 17
            )
            XCTAssertEqual(HistoryEntry(from: dto).mode, mode, "raw mode \(raw)")
        }
    }

    func testCreatedAtConvertsMillisecondsSinceEpochToASecondsDate() {
        // `1_700_000_000_000` ms == `1_700_000_000` s. A caller that forgets
        // the division produces a date in 1970 that nobody notices in a
        // snapshot of one row — exactly the mistake
        // `HistoryExport.isoString(millisecondsSinceEpoch:)` already guards
        // against for `ConversationMessageSummary`.
        let dto = EpisodicEventDTO(
            id: 1, createdAt: 1_700_000_000_000, mode: "transcribe",
            rawTranscript: "x", correctedTranscript: "x",
            effectiveInput: nil, selectedContext: nil, result: "x",
            applicationName: "App", origin: "owner", conversationId: nil
        )
        XCTAssertEqual(
            HistoryEntry(from: dto).createdAt,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testApplicationNameCarriesThroughVerbatimNotPlaceholdered() {
        let dto = EpisodicEventDTO(
            id: 1, createdAt: 1, mode: "transcribe",
            rawTranscript: "x", correctedTranscript: "x",
            effectiveInput: nil, selectedContext: nil, result: "x",
            applicationName: "Terminal", origin: "owner", conversationId: nil
        )
        XCTAssertEqual(HistoryEntry(from: dto).applicationName, "Terminal")
    }

    func testSelectedContextMapsToContextPreviewAndAbsenceStaysAbsent() {
        let withContext = EpisodicEventDTO(
            id: 1, createdAt: 1, mode: "transcribe",
            rawTranscript: "改一下这里", correctedTranscript: "改一下这里",
            effectiveInput: nil, selectedContext: "季度营收同比增长", result: "改好了",
            applicationName: "Xcode", origin: "owner", conversationId: nil
        )
        XCTAssertEqual(HistoryEntry(from: withContext).contextPreview, "季度营收同比增长")

        let withoutContext = EpisodicEventDTO(
            id: 2, createdAt: 1, mode: "transcribe",
            rawTranscript: "x", correctedTranscript: "x",
            effectiveInput: nil, selectedContext: nil, result: "x",
            applicationName: "Xcode", origin: "owner", conversationId: nil
        )
        XCTAssertNil(HistoryEntry(from: withoutContext).contextPreview)
    }

    func testSelectedContextIsTruncatedToTwoHundredFortyCharactersLikeThePreviousStorageDid() {
        // Product decision (team lead, this task): re-truncate. Every
        // pre-migration `history.add(HistoryEntry(contextPreview:))` call
        // site in `AppModel.swift` cut with `.map { String($0.prefix(240)) }`
        // before storing — the field is named "preview" because it renders
        // inside a list row, where an untruncated selection would wreck the
        // layout. Task 7's whole strategy is "change only where the data
        // comes from", so that display behaviour has to survive unchanged.
        // The full value is not lost: it still exists on the sidecar
        // (`selectedContext` on the wire, and reachable in full through
        // `opentype__read_history`) — only this view model re-truncates.
        let long = String(repeating: "字", count: 300)
        let dto = EpisodicEventDTO(
            id: 1, createdAt: 1, mode: "transcribe",
            rawTranscript: "x", correctedTranscript: "x",
            effectiveInput: nil, selectedContext: long, result: "x",
            applicationName: "Xcode", origin: "owner", conversationId: nil
        )
        let preview = HistoryEntry(from: dto).contextPreview
        XCTAssertEqual(preview?.count, 240)
        XCTAssertEqual(preview, String(long.prefix(240)))
    }

    func testASelectedContextUnderTheLimitPassesThroughUntouched() {
        let dto = EpisodicEventDTO(
            id: 1, createdAt: 1, mode: "transcribe",
            rawTranscript: "改一下这里", correctedTranscript: "改一下这里",
            effectiveInput: nil, selectedContext: "季度营收同比增长", result: "改好了",
            applicationName: "Xcode", origin: "owner", conversationId: nil
        )
        // Not just "does not crash" — a short value must not gain trailing
        // padding or an ellipsis marker either, since `String.prefix(240)`
        // on a shorter string is simply the string itself.
        XCTAssertEqual(HistoryEntry(from: dto).contextPreview, "季度营收同比增长")
    }
}

/// `EpisodicEventDTO` decoding directly against the sidecar's real wire
/// shape (`sidecar/src/memory/routes.ts`'s `GET /memory/events`, itself a raw
/// `SELECT * FROM episodic_events`, i.e. the `EpisodicEventRow` columns from
/// `sidecar/src/memory/MemoryStore.ts`) — camelCase column names, a nullable
/// `conversationId`/`result`/`selectedContext`/`effectiveInput`, and
/// `consolidatedAt` present on the wire but with nothing on the Swift side
/// that needs it (a `Decodable` type simply ignores an unmapped key, so this
/// also doubles as the test that adding `consolidatedAt` to `EpisodicEventDTO`
/// was never required).
///
/// This is deliberately independent of `AppModel` — it decodes literal JSON
/// text, the same bytes `curl` would hand back over the Unix socket, through
/// `JSONDecoder` alone, so it needs no live sidecar and no live `AppModel` to
/// prove `EpisodicEventDTO`'s `CodingKeys` actually match what ships.
final class EpisodicEventDTODecodingTests: XCTestCase {

    func testDecodesOneRowFromTheSidecarsWireShape() throws {
        let json = """
        {
          "id": 43,
          "createdAt": 1700000000000,
          "mode": "ask",
          "rawTranscript": "天气怎么样",
          "correctedTranscript": "天气怎么样",
          "effectiveInput": null,
          "selectedContext": null,
          "result": "多云转晴",
          "applicationName": "Safari",
          "origin": "agent",
          "conversationId": 17,
          "consolidatedAt": null
        }
        """
        let dto = try JSONDecoder().decode(EpisodicEventDTO.self, from: Data(json.utf8))

        XCTAssertEqual(dto.id, 43)
        XCTAssertEqual(dto.createdAt, 1_700_000_000_000)
        XCTAssertEqual(dto.mode, "ask")
        XCTAssertEqual(dto.rawTranscript, "天气怎么样")
        XCTAssertEqual(dto.correctedTranscript, "天气怎么样")
        XCTAssertNil(dto.effectiveInput)
        XCTAssertNil(dto.selectedContext)
        XCTAssertEqual(dto.result, "多云转晴")
        XCTAssertEqual(dto.applicationName, "Safari")
        XCTAssertEqual(dto.origin, "agent")
        XCTAssertEqual(dto.conversationId, 17)
    }

    func testDecodesAnArrayUnderAnEventsKeyTheWayGETMemoryEventsResponds() throws {
        // `GET /memory/events`'s handler returns exactly `Response.json({
        // events })` — this proves `EpisodicEventDTO` composes into that
        // shape via a plain `Decodable` wrapper, which is all
        // `AppModel.refreshHistory()` needs; the wrapper type itself is
        // private to that function and not re-declared here (see this file's
        // header doc for what remains a stage-4 read).
        struct Response: Decodable { let events: [EpisodicEventDTO] }
        let json = """
        { "events": [
          {
            "id": 42, "createdAt": 1, "mode": "transcribe",
            "rawTranscript": "明天开会", "correctedTranscript": "明天开会",
            "effectiveInput": null, "selectedContext": null, "result": null,
            "applicationName": "WeChat", "origin": "owner", "conversationId": null
          }
        ] }
        """
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))

        XCTAssertEqual(response.events.count, 1)
        XCTAssertEqual(response.events[0].id, 42)
        XCTAssertNil(response.events[0].result)
    }
}
