import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL
    private let maximumEntries: Int

    init(
        fileURL: URL? = nil,
        maximumEntries: Int = 1000
    ) {
        self.maximumEntries = maximumEntries

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let directory = support.appendingPathComponent("OpenType", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            self.fileURL = directory.appendingPathComponent("history.json")
        }

        load()
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maximumEntries {
            entries.removeLast(entries.count - maximumEntries)
        }
        save()
    }

    /// Removes exactly the entry with this id, or does nothing if it is not
    /// present — a row can be deleted from a context menu that a second window
    /// opened before an earlier delete landed, and that is an ordinary race,
    /// not a programmer error.
    ///
    /// Persists the shortened list, including when it becomes empty: writing
    /// nothing and leaving the old file in place would give a deletion that
    /// survives until relaunch and then resurrects.
    func delete(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        save()
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder.openType.decode([HistoryEntry].self, from: data)
        else { return }
        entries = Array(decoded.prefix(maximumEntries))
    }

    private func save() {
        guard let data = try? JSONEncoder.openType.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var openType: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var openType: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
