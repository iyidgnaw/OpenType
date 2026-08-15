import Foundation
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for §I of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — the storage half:
/// **single-entry delete** and the **100 → 1000 capacity raise**.
///
/// Motivation (`docs/reviews/2026-08-15-product-review.md` §7): `HistoryStore`
/// ships with `clear()` and nothing else, so a user who dictates one sensitive
/// sentence can only remedy it by destroying every other record they have. That
/// is a delete button the product refuses to give and a wipe button it offers
/// instead — the trade is backwards.
///
/// Expected shape (Stage 3 creates it; nothing here builds it):
///
///     @MainActor
///     final class HistoryStore: ObservableObject {
///         init(fileURL: URL? = nil, maximumEntries: Int = 1000)   // was 100
///         func add(_ entry: HistoryEntry)
///         func delete(id: UUID)                                   // new
///         func clear()
///     }
///
/// No `Models.swift` change is required by this file: `HistoryEntry` already
/// carries a `UUID` id, and it is that id — not an index — that `delete` takes,
/// because the list the user right-clicks is a *filtered* list (source filter +
/// the body search this batch adds) and an index into it means nothing to the
/// store.
///
/// ## Pinned decision 1 — the capacity raise is a load-time migration, and it is silent
///
/// The risky direction of a cap change is not the new cap, it is the old file.
/// `load()` today ends in `Array(decoded.prefix(maximumEntries))`, so the cap is
/// applied *on read* as well as on write: raising it to 1000 must leave an
/// existing 100-entry `history.json` completely intact — same 100 rows, same
/// order, same ids, same `contextPreview` presence/absence — and must not
/// require any versioning, rewrite-on-launch or backup step. That is why the
/// migration test below writes its own fixture JSON by hand rather than
/// producing one through `HistoryStore.add`: a fixture built by the code under
/// test can only prove the code agrees with itself.
///
/// The fixture is written in the exact shape shipped 1.0 produces —
/// `JSONEncoder` with `.iso8601` dates, `.sortedKeys`, `.prettyPrinted`,
/// uppercase UUID strings, and `contextPreview` **absent** when it was `nil`
/// (Swift's synthesised `encode(to:)` uses `encodeIfPresent` for optionals, so
/// real 1.0 files have rows both with and without that key). All three
/// variants — absent, explicit `null`, and a value — are in the fixture,
/// because a decoder that only ever saw one of them is a decoder that has not
/// been tested.
///
/// ## Pinned decision 2 — deleting persists, and it persists as `[]`
///
/// `clear()` deletes the file; `delete(id:)` must **write** the shortened list,
/// including when the list becomes empty. Writing nothing and leaving the old
/// file in place would give a deletion that survives until relaunch and then
/// resurrects — the single worst failure mode available to a feature whose
/// entire purpose is "make that one sentence go away".
///
/// ## Pinned decision 3 — deleting an id that is not there is a no-op
///
/// The list is asynchronous with the store: a row can be deleted from a context
/// menu that a second window opened before an earlier delete landed. That is an
/// ordinary race, not a programmer error, so it must not trap, must not clear,
/// and must not reorder.
///
/// ## Which of these are red, and which are guards
///
/// The suite does not compile against shipped 1.0 (`delete` does not exist), so
/// every case here is red in the strict sense. Measured against a *no-op*
/// `delete` stub — i.e. asking "which of these would a lazy implementation
/// still fail?" — the pins that genuinely drive the implementation are:
/// `testDeleteRemovesExactlyThatEntry`, `testDeletePersistsAcrossAReload`,
/// `testDeletingTheLastEntryPersistsAnEmptyListRatherThanLeavingTheOldFile`,
/// `testDeletingTheSameIdTwiceIsANoOpTheSecondTime`,
/// `testNewestFirstOrderingSurvivesAddDeleteAndAddAgain`,
/// `testTheOrderOnDiskIsTheOrderInMemory`,
/// `testTheDefaultCapacityIsOneThousand`, `testAMigratedFileCanGrowPastTheOldCap`
/// and `testAMigratedRowCanBeDeletedByTheIdItWasStoredWith`.
///
/// The rest are deliberate **regression guards** whose value is that they must
/// keep passing: the two no-op cases (nothing to delete) can only ever be
/// green against a correct implementation, and the load-side migration cases
/// (`testAOneHundredEntryFileFromTheOldCapLoadsWithNothingLostOrReordered`,
/// `testMigratedRowsKeepTheirFieldsIncludingAnAbsentContextPreview`,
/// `testAFileLongerThanTheCapIsTrimmedFromTheOldEndOnLoad`,
/// `testAnInjectedCapacityStillWins`, `testAMissingFileLoadsAsAnEmptyHistory…`)
/// describe behaviour 1.0 already has and the raise must not disturb. A
/// migration test that only failed before the change would be testing the
/// change, not the migration.
@MainActor
final class HistoryStoreDeleteTests: XCTestCase {

    // MARK: - Delete

    func testDeleteRemovesExactlyThatEntry() {
        let store = makeStore()
        let first = entry(transcript: "第一条")
        let second = entry(transcript: "第二条")
        let third = entry(transcript: "第三条")
        store.add(first)
        store.add(second)
        store.add(third)

        store.delete(id: second.id)

        XCTAssertEqual(store.entries.map(\.id), [third.id, first.id])
        XCTAssertEqual(store.entries.map(\.transcript), ["第三条", "第一条"])
    }

    func testDeletePersistsAcrossAReload() {
        let url = temporaryFileURL()
        let store = HistoryStore(fileURL: url)
        let keep = entry(transcript: "留下")
        let sensitive = entry(transcript: "身份证号 110101…")
        store.add(keep)
        store.add(sensitive)

        store.delete(id: sensitive.id)

        // The whole point of the feature: it is gone from disk, not just from
        // the array the view is bound to.
        let reloaded = HistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.entries.map(\.id), [keep.id])
        XCTAssertFalse(
            reloaded.entries.contains { $0.transcript.contains("身份证号") },
            "a deleted transcript must not survive a relaunch"
        )
    }

    func testDeletingTheLastEntryPersistsAnEmptyListRatherThanLeavingTheOldFile() {
        let url = temporaryFileURL()
        let store = HistoryStore(fileURL: url)
        let only = entry(transcript: "唯一一条")
        store.add(only)

        store.delete(id: only.id)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(
            HistoryStore(fileURL: url).entries.isEmpty,
            "an emptied history must stay empty after relaunch"
        )
    }

    func testDeletingAnIdThatIsNotThereChangesNothing() {
        let store = makeStore()
        let first = entry(transcript: "第一条")
        let second = entry(transcript: "第二条")
        store.add(first)
        store.add(second)

        store.delete(id: UUID())

        XCTAssertEqual(store.entries.map(\.id), [second.id, first.id])
    }

    func testDeletingFromAnEmptyStoreIsANoOp() {
        let store = makeStore()
        store.delete(id: UUID())
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testDeletingTheSameIdTwiceIsANoOpTheSecondTime() {
        // A double-click on a context-menu item, or two windows acting on the
        // same row. The second call must not take the next row with it.
        let store = makeStore()
        let first = entry(transcript: "第一条")
        let second = entry(transcript: "第二条")
        store.add(first)
        store.add(second)

        store.delete(id: second.id)
        store.delete(id: second.id)

        XCTAssertEqual(store.entries.map(\.id), [first.id])
    }

    // MARK: - Ordering invariant

    func testNewestFirstOrderingSurvivesAddDeleteAndAddAgain() {
        // `add` inserts at index 0 and the list is rendered top-down, so
        // "newest first" is not a sort the store performs — it is an invariant
        // every mutation has to preserve. A `delete` written as a
        // filter-and-reassign can quietly break it if it re-sorts by date, and
        // dates are *not* a reliable order here: two entries can share a
        // second, and `createdAt` is assigned at capture, not at insert.
        let store = makeStore()
        let a = entry(transcript: "A", createdAt: Date(timeIntervalSince1970: 1_755_000_000))
        let b = entry(transcript: "B", createdAt: Date(timeIntervalSince1970: 1_755_000_000))
        let c = entry(transcript: "C", createdAt: Date(timeIntervalSince1970: 1_755_000_000))
        store.add(a)
        store.add(b)
        store.add(c)
        XCTAssertEqual(store.entries.map(\.transcript), ["C", "B", "A"])

        store.delete(id: b.id)
        XCTAssertEqual(store.entries.map(\.transcript), ["C", "A"])

        let d = entry(transcript: "D", createdAt: Date(timeIntervalSince1970: 1_755_000_000))
        store.add(d)
        XCTAssertEqual(store.entries.map(\.transcript), ["D", "C", "A"])
    }

    func testTheOrderOnDiskIsTheOrderInMemory() {
        let url = temporaryFileURL()
        let store = HistoryStore(fileURL: url)
        for index in 0..<5 {
            store.add(entry(transcript: "第 \(index) 条"))
        }
        store.delete(id: store.entries[2].id)

        XCTAssertEqual(store.entries.count, 4)
        XCTAssertEqual(
            HistoryStore(fileURL: url).entries.map(\.transcript),
            store.entries.map(\.transcript)
        )
    }

    // MARK: - Capacity

    func testTheDefaultCapacityIsOneThousand() {
        // Asserted through behaviour rather than by reading a constant, so the
        // parameter keeps its shape (`maximumEntries:` stays injectable for
        // tests) while its default moves.
        let store = HistoryStore(fileURL: temporaryFileURL())
        for index in 0..<1_001 {
            store.add(entry(transcript: "第 \(index) 条"))
        }

        XCTAssertEqual(store.entries.count, 1_000)
        XCTAssertEqual(store.entries.first?.transcript, "第 1000 条")
        XCTAssertEqual(store.entries.last?.transcript, "第 1 条")
        XCTAssertFalse(
            store.entries.contains { $0.transcript == "第 0 条" },
            "the oldest entry is the one that falls off the end"
        )
    }

    func testAnInjectedCapacityStillWins() {
        let store = HistoryStore(fileURL: temporaryFileURL(), maximumEntries: 3)
        for index in 0..<5 {
            store.add(entry(transcript: "第 \(index) 条"))
        }

        XCTAssertEqual(
            store.entries.map(\.transcript),
            ["第 4 条", "第 3 条", "第 2 条"]
        )
    }

    // MARK: - Migration from the 100-entry era

    func testAOneHundredEntryFileFromTheOldCapLoadsWithNothingLostOrReordered() {
        let url = temporaryFileURL()
        let fixture = legacyFixture(count: 100)
        try! Data(fixture.json.utf8).write(to: url, options: .atomic)

        let store = HistoryStore(fileURL: url)

        XCTAssertEqual(store.entries.count, 100, "no row may be dropped by the raise")
        XCTAssertEqual(
            store.entries.map(\.id),
            fixture.ids,
            "the file's order is the user's order and must survive verbatim"
        )
        XCTAssertEqual(
            store.entries.map(\.transcript),
            fixture.transcripts
        )
    }

    func testMigratedRowsKeepTheirFieldsIncludingAnAbsentContextPreview() {
        let url = temporaryFileURL()
        let fixture = legacyFixture(count: 100)
        try! Data(fixture.json.utf8).write(to: url, options: .atomic)

        let store = HistoryStore(fileURL: url)

        // Row 0: `contextPreview` key absent (what 1.0 wrote for `nil`).
        XCTAssertNil(store.entries[0].contextPreview)
        XCTAssertEqual(store.entries[0].mode, .transcribe)
        XCTAssertEqual(store.entries[0].applicationName, "Xcode")
        XCTAssertEqual(store.entries[0].result, "结果 0")
        XCTAssertEqual(
            store.entries[0].createdAt,
            Date(timeIntervalSince1970: 1_755_000_000)
        )

        // Row 1: explicit `null`.
        XCTAssertNil(store.entries[1].contextPreview)

        // Row 2: a real value, which must not be dropped on the way in.
        XCTAssertEqual(store.entries[2].contextPreview, "选中的原文 2")
    }

    func testAMigratedFileCanGrowPastTheOldCap() {
        // The raise is only real if the 101st entry sticks.
        let url = temporaryFileURL()
        let fixture = legacyFixture(count: 100)
        try! Data(fixture.json.utf8).write(to: url, options: .atomic)

        let store = HistoryStore(fileURL: url)
        let fresh = entry(transcript: "第 101 条")
        store.add(fresh)

        XCTAssertEqual(store.entries.count, 101)
        XCTAssertEqual(store.entries.first?.id, fresh.id)
        XCTAssertEqual(store.entries.last?.id, fixture.ids.last)
        XCTAssertEqual(HistoryStore(fileURL: url).entries.count, 101)
    }

    func testAMigratedRowCanBeDeletedByTheIdItWasStoredWith() {
        // Delete keys on the id the *file* carries, so it has to work on rows
        // this process never inserted.
        let url = temporaryFileURL()
        let fixture = legacyFixture(count: 100)
        try! Data(fixture.json.utf8).write(to: url, options: .atomic)

        let store = HistoryStore(fileURL: url)
        store.delete(id: fixture.ids[50])

        XCTAssertEqual(store.entries.count, 99)
        XCTAssertFalse(store.entries.map(\.id).contains(fixture.ids[50]))
        XCTAssertEqual(HistoryStore(fileURL: url).entries.count, 99)
    }

    func testAFileLongerThanTheCapIsTrimmedFromTheOldEndOnLoad() {
        // Defensive, and it pins the direction: `prefix`, not `suffix`. A file
        // longer than the cap can only come from a build with a larger cap, and
        // the rows worth keeping are the newest ones at the head.
        let url = temporaryFileURL()
        let fixture = legacyFixture(count: 12)
        try! Data(fixture.json.utf8).write(to: url, options: .atomic)

        let store = HistoryStore(fileURL: url, maximumEntries: 10)

        XCTAssertEqual(store.entries.map(\.id), Array(fixture.ids.prefix(10)))
    }

    func testAMissingFileLoadsAsAnEmptyHistoryRatherThanFailing() {
        let store = HistoryStore(fileURL: temporaryFileURL())
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Fixtures

    private func makeStore() -> HistoryStore {
        HistoryStore(fileURL: temporaryFileURL())
    }

    private func temporaryFileURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenType-History-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("history.json")
    }

    private func entry(
        transcript: String,
        createdAt: Date = Date(timeIntervalSince1970: 1_755_000_000),
        mode: InputMode = .transcribe,
        applicationName: String = "Xcode",
        result: String? = nil,
        contextPreview: String? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            createdAt: createdAt,
            mode: mode,
            applicationName: applicationName,
            transcript: transcript,
            result: result ?? transcript,
            contextPreview: contextPreview
        )
    }

    /// A `history.json` in the exact shape shipped 1.0 wrote — hand-built, so
    /// nothing about this fixture depends on the code under test agreeing with
    /// itself. Newest-first, one entry per hour going backwards.
    private func legacyFixture(count: Int) -> (json: String, ids: [UUID], transcripts: [String]) {
        let base = 1_755_000_000
        var ids: [UUID] = []
        var transcripts: [String] = []
        var objects: [String] = []

        for index in 0..<count {
            let id = UUID()
            ids.append(id)
            let transcript = "第 \(index) 条口述内容"
            transcripts.append(transcript)

            let createdAt = iso8601(TimeInterval(base - index * 3_600))
            // Three `contextPreview` shapes, all of which occur in real 1.0
            // files: absent (the `nil` case), explicit null, and a value.
            let contextLine: String
            switch index % 3 {
            case 0: contextLine = ""
            case 1: contextLine = "  \"contextPreview\" : null,\n"
            default: contextLine = "  \"contextPreview\" : \"选中的原文 \(index)\",\n"
            }

            objects.append(
                """
                {
                  "applicationName" : "Xcode",
                \(contextLine)  "createdAt" : "\(createdAt)",
                  "id" : "\(id.uuidString)",
                  "mode" : "transcribe",
                  "result" : "结果 \(index)",
                  "transcript" : "\(transcript)"
                }
                """
            )
        }

        return ("[\n" + objects.joined(separator: ",\n") + "\n]\n", ids, transcripts)
    }

    private func iso8601(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}
