import Foundation

/// Pure export of local history to Markdown (for reading) and JSON (for
/// archiving) — §I of `docs/superpowers/specs/2026-08-15-product-batch-plan.md`.
///
/// Motivation (`docs/reviews/2026-08-15-product-review.md` §7): a local-first
/// product that locks a user's data inside its own `history.json` contradicts
/// its own positioning. This type does no filesystem work and never touches
/// `NSSavePanel` — the caller writes the string it returns.
///
/// Five decisions carry the whole design, pinned by
/// `HistoryExportTests.swift`:
///
///  1. The export's **vocabulary does not follow the UI language** —
///     structural labels (`Exported:`, `### Transcript`) are fixed English and
///     the mode is written as its wire raw value (`transcribe`/`ask`/`agent`),
///     not `InputMode.title`'s 听写/问答/Agent, so a display-language change
///     does not make two exports of the same history fail to diff. The user's
///     own text is untouched — only the scaffolding is fixed.
///  2. Timestamps are **ISO-8601 in UTC**, matching what `history.json` and
///     the sidecar's own conversation storage already use.
///  3. The body is emitted **verbatim, never escaped** — the export exists so
///     the user gets what they said. The cost is that the Markdown export is
///     not round-trippable (a body can contain a line identical to `---`),
///     which is exactly why the JSON export exists alongside it and is the one
///     with a decoder.
///  4. **`Result` is always emitted**, even when it equals `Transcript` — an
///     omitted-when-identical rule would make "omitted because identical"
///     indistinguishable from "missing".
///  5. Export **preserves the order it was handed**, not re-sorted by date —
///     "export" means "export what I am looking at" (after the source filter
///     and body search), which is also what makes exporting a search result
///     work without a second entry point.
enum HistoryExport {

    // MARK: - Dictation history

    static func markdown(entries: [HistoryEntry], exportedAt: Date) -> String {
        var sections = [
            "# OpenType History\n\nExported: \(isoString(exportedAt))\nEntries: \(entries.count)"
        ]
        sections.append(contentsOf: entries.map(entrySection))
        return sections.joined(separator: "\n\n---\n\n") + "\n"
    }

    static func json(entries: [HistoryEntry], exportedAt: Date) -> String {
        encodedDocument(
            EncodableHistoryExportDocument(
                format: "opentype.history",
                version: 1,
                exportedAt: exportedAt,
                entries: entries
            )
        )
    }

    // MARK: - One conversation

    static func markdown(conversation: ConversationDetail, exportedAt: Date) -> String {
        // A conversation the user never renamed has an empty title in some
        // sidecar rows; falling back to its id avoids an empty `#` heading.
        let title = conversation.title.isEmpty ? "Conversation \(conversation.id)" : conversation.title
        var sections = [
            """
            # \(title)

            Exported: \(isoString(exportedAt))
            Conversation: \(conversation.id)
            Kind: \(conversation.kind)
            Messages: \(conversation.messages.count)
            """
        ]
        sections.append(contentsOf: conversation.messages.map(messageSection))
        return sections.joined(separator: "\n\n---\n\n") + "\n"
    }

    static func json(conversation: ConversationDetail, exportedAt: Date) -> String {
        encodedDocument(
            EncodableConversationExportDocument(
                format: "opentype.conversation",
                version: 1,
                exportedAt: exportedAt,
                conversation: EncodableConversationDetail(conversation)
            )
        )
    }

    // MARK: - Decoding (JSON only — see decision 3 above)

    static func decodeHistory(_ json: String) throws -> HistoryExportDocument {
        try decoder.decode(HistoryExportDocument.self, from: Data(json.utf8))
    }

    static func decodeConversation(_ json: String) throws -> ConversationExportDocument {
        try decoder.decode(ConversationExportDocument.self, from: Data(json.utf8))
    }

    // MARK: - Markdown assembly

    private static func entrySection(_ entry: HistoryEntry) -> String {
        var section = """
        ## \(entryHeading(entry))

        ### Transcript

        \(entry.transcript)

        ### Result

        \(entry.result ?? "—")
        """
        if let contextPreview = entry.contextPreview {
            section += "\n\n### Context\n\n\(contextPreview)"
        }
        return section
    }

    /// `<iso> · <mode> · <app>`, with the app segment dropped entirely (not
    /// left as a trailing separator) when there is none.
    private static func entryHeading(_ entry: HistoryEntry) -> String {
        var parts = [isoString(entry.createdAt), entry.mode.rawValue]
        if !entry.applicationName.isEmpty {
            parts.append(entry.applicationName)
        }
        return parts.joined(separator: " · ")
    }

    private static func messageSection(_ message: ConversationMessageSummary) -> String {
        "## \(message.role) · \(isoString(millisecondsSinceEpoch: message.createdAt))\n\n\(message.content)"
    }

    // MARK: - Dates

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// `ConversationMessageSummary.createdAt` is milliseconds since epoch (the
    /// sidecar's SQLite column) — dividing by 1000 is easy to forget and
    /// produces a date in 1970 that nobody notices in a snapshot of one row.
    private static func isoString(millisecondsSinceEpoch milliseconds: Int) -> String {
        isoString(Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
    }

    // MARK: - JSON encoding

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Pretty-printed and sorted: a local-first export lands in the user's
        // Documents folder and gets opened in a text editor, and sorted keys
        // are what make two exports diffable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encodedDocument<T: Encodable>(_ document: T) -> String {
        guard
            let data = try? encoder.encode(document),
            let string = String(data: data, encoding: .utf8)
        else {
            // Every field reachable here is a plain Codable value type
            // (String, Int, Date, UUID, and arrays of the same) with no
            // cycles, so encoding cannot realistically fail; the fallback
            // exists only so this stays a total function.
            return "{}"
        }
        return string
    }
}

// MARK: - Export document shapes

struct HistoryExportDocument: Decodable, Equatable {
    let format: String
    let version: Int
    let exportedAt: Date
    let entries: [HistoryEntry]
}

struct ConversationExportDocument: Decodable, Equatable {
    let format: String
    let version: Int
    let exportedAt: Date
    let conversation: ConversationDetail
}

// MARK: - Encodable mirrors

/// `HistoryEntry` is already `Codable`, so the history document needs no
/// mirror of its own — only the wrapper shape.
private struct EncodableHistoryExportDocument: Encodable {
    let format: String
    let version: Int
    let exportedAt: Date
    let entries: [HistoryEntry]
}

/// `ConversationDetail`/`ConversationMessageSummary` are `Decodable` only —
/// they exist to decode the sidecar's read-only `GET /conversations/:id`
/// response, and nothing before this export feature ever needed to produce
/// one. Mirroring the two fields' worth of shape here keeps that contract
/// intact instead of widening it to `Codable` for one caller.
private struct EncodableConversationMessage: Encodable {
    let id: Int
    let conversationId: Int
    let role: String
    let content: String
    let createdAt: Int

    init(_ message: ConversationMessageSummary) {
        id = message.id
        conversationId = message.conversationId
        role = message.role
        content = message.content
        createdAt = message.createdAt
    }
}

private struct EncodableConversationDetail: Encodable {
    let id: Int
    let kind: String
    let title: String
    let createdAt: Int
    let updatedAt: Int
    let messages: [EncodableConversationMessage]

    init(_ detail: ConversationDetail) {
        id = detail.id
        kind = detail.kind
        title = detail.title
        createdAt = detail.createdAt
        updatedAt = detail.updatedAt
        messages = detail.messages.map(EncodableConversationMessage.init)
    }
}

private struct EncodableConversationExportDocument: Encodable {
    let format: String
    let version: Int
    let exportedAt: Date
    let conversation: EncodableConversationDetail
}
