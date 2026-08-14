import Foundation

enum AuditEventStatus: String, Codable {
    case recognized
    case completed
    case cancelled
    case failed
    /// Review-mode only: one voice-driven correction round within a Review
    /// session (spoken instruction -> LLM replacement spliced into a
    /// specific span of the stashed text), *not* the session's final
    /// outcome. A Review session normally produces one `.recognized` event
    /// (the original dictation), zero or more `.corrected` events (one per
    /// correction round), and exactly one final `.completed` or `.cancelled`
    /// event — all sharing the same `requestId` and chained in order via
    /// `supersedesEventId`, so a reader can replay the full correction chain
    /// instead of only ever seeing the final result. `rawTranscript` carries
    /// the spoken correction instruction, `selectedContext` the substring
    /// that was replaced, `effectiveInput` the model's replacement, and
    /// `result` the full text after splicing — reusing the existing fields'
    /// meanings rather than adding parallel ones.
    case corrected
}

struct ImmutableAuditEvent: Codable, Equatable, Identifiable {
    let schemaVersion: Int
    let id: UUID
    let requestId: UUID
    let createdAt: Date
    let platform: String
    let status: AuditEventStatus
    let mode: String
    let rawTranscript: String
    let effectiveInput: String?
    let selectedContext: String?
    let result: String?
    let provider: String?
    let model: String?
    let error: String?
    let supersedesEventId: UUID?
    /// When the recording that produced this session stopped — the instant the
    /// user let go of the hotkey, captured in `AppModel.finishRecording()`.
    ///
    /// Only the `.recognized` event carries it, and it exists for exactly one
    /// reason: `.recognized` is stamped *after* ASR returns, so without this
    /// the trail has no trace of how long recording and transcription took,
    /// and the only latency it can express is the post-ASR remainder. The
    /// end-to-end figure a user actually feels — release the key, see the text
    /// — is `completed.createdAt − recognized.recordingEndedAt`
    /// (`UsageStats.summarize(events:now:)`).
    ///
    /// Optional because this file is append-only and never rewritten: rows
    /// written before the field existed simply lack the key and decode as
    /// `nil`, so there is no migration. Readers must **exclude** those rows
    /// from timing figures rather than treat `nil` as zero — averaging a
    /// missing measurement in as 0s would quietly flatter the number forever.
    let recordingEndedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id = "eventId"
        case requestId
        case createdAt
        case platform
        case status
        case mode
        case rawTranscript
        case effectiveInput
        case selectedContext
        case result
        case provider
        case model
        case error
        case supersedesEventId
        case recordingEndedAt
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case id
    }

    init(
        id: UUID = UUID(),
        requestId: UUID,
        createdAt: Date = Date(),
        status: AuditEventStatus,
        mode: InputMode,
        rawTranscript: String,
        effectiveInput: String?,
        selectedContext: String?,
        result: String?,
        provider: String?,
        model: String?,
        error: String?,
        supersedesEventId: UUID? = nil,
        recordingEndedAt: Date? = nil
    ) {
        schemaVersion = 1
        self.id = id
        self.requestId = requestId
        self.createdAt = createdAt
        platform = "macOS"
        self.status = status
        self.mode = mode.rawValue
        self.rawTranscript = rawTranscript
        self.effectiveInput = effectiveInput
        self.selectedContext = selectedContext
        self.result = result
        self.provider = provider
        self.model = model
        self.error = error
        self.supersedesEventId = supersedesEventId
        self.recordingEndedAt = recordingEndedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        if let eventID = try container.decodeIfPresent(UUID.self, forKey: .id) {
            id = eventID
        } else {
            let legacyContainer = try decoder.container(
                keyedBy: LegacyCodingKeys.self
            )
            id = try legacyContainer.decode(UUID.self, forKey: .id)
        }
        requestId = try container.decode(UUID.self, forKey: .requestId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        platform = try container.decode(String.self, forKey: .platform)
        status = try container.decode(AuditEventStatus.self, forKey: .status)
        mode = try container.decode(String.self, forKey: .mode)
        rawTranscript = try container.decode(String.self, forKey: .rawTranscript)
        effectiveInput = try container.decodeIfPresent(
            String.self,
            forKey: .effectiveInput
        )
        selectedContext = try container.decodeIfPresent(
            String.self,
            forKey: .selectedContext
        )
        result = try container.decodeIfPresent(String.self, forKey: .result)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        supersedesEventId = try container.decodeIfPresent(
            UUID.self,
            forKey: .supersedesEventId
        )
        recordingEndedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .recordingEndedAt
        )
    }
}

/// An append-only local record of processing attempts. There is intentionally
/// no delete or rewrite API. User-facing history can be reset independently;
/// this file remains the audit source of truth requested by the product.
final class ImmutableAuditStore {
    let fileURL: URL
    private let lock = NSLock()

    init(directoryURL: URL? = nil) {
        let directory = directoryURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("OpenType", isDirectory: true)
        fileURL = directory.appendingPathComponent("audit-events.v1.jsonl")
    }

    func append(_ event: ImmutableAuditEvent) throws {
        lock.lock()
        defer { lock.unlock() }

        try prepareFile()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(0x0A)

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func recent(limit: Int) -> [ImmutableAuditEvent] {
        guard limit > 0,
              let data = try? Data(contentsOf: fileURL),
              let source = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return source
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit)
            .compactMap { line in
                try? decoder.decode(
                    ImmutableAuditEvent.self,
                    from: Data(line.utf8)
                )
            }
    }

    private func prepareFile() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
