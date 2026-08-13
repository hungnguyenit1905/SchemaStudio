import Foundation
@testable import SchemaStudio
import Testing

@Suite("TransferCheckpointStore")
struct TransferCheckpointStoreTests {
    private func makeStore() throws -> (TransferCheckpointStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferCheckpointStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (TransferCheckpointStore(directory: directory), directory)
    }

    private let jobId = UUID()

    private func entry(
        table: String,
        partition: Int = 0,
        lastKey: [String]? = ["10"],
        rowsDone: Int = 10,
        isComplete: Bool = false
    ) -> TransferCheckpointStore.Entry {
        TransferCheckpointStore.Entry(
            table: table,
            partition: partition,
            cursor: TransferChunkCursor(lastKey: lastKey, rowsDone: rowsDone),
            isComplete: isComplete
        )
    }

    @Test("an entry records and loads back with its cursor")
    func recordAndLoadRoundTrip() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let saved = entry(table: "users", lastKey: ["42"], rowsDone: 40)
        await store.record(jobId: jobId, mode: .emptyThenTransfer, entry: saved)

        let loaded = await store.load(jobId: jobId)
        #expect(loaded.count == 1)
        #expect(loaded.first?.table == "users")
        #expect(loaded.first?.cursor == TransferChunkCursor(lastKey: ["42"], rowsDone: 40))
        #expect(loaded.first?.isComplete == false)
    }

    @Test("a resumed run starts after the last recorded key")
    func resumeStartsAfterLastRecordedKey() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.record(
            jobId: jobId,
            mode: .emptyThenTransfer,
            entry: entry(table: "orders", lastKey: ["99"], rowsDone: 99)
        )

        let loaded = await store.load(jobId: jobId)
        let resumeCursor = loaded.first(where: { $0.table == "orders" })?.cursor
        #expect(resumeCursor?.lastKey == ["99"])
        #expect(resumeCursor?.rowsDone == 99)
    }

    @Test("mode copy never writes a checkpoint")
    func copyModeWritesNothing() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.record(jobId: jobId, mode: .copy, entry: entry(table: "users"))

        #expect(await store.load(jobId: jobId).isEmpty)
    }

    @Test("recording the same table and partition replaces the older entry")
    func recordingReplacesSameTableAndPartition() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.record(
            jobId: jobId,
            mode: .emptyThenTransfer,
            entry: entry(table: "users", lastKey: ["10"], rowsDone: 10)
        )
        await store.record(
            jobId: jobId,
            mode: .emptyThenTransfer,
            entry: entry(table: "users", lastKey: ["20"], rowsDone: 20)
        )
        await store.record(
            jobId: jobId,
            mode: .emptyThenTransfer,
            entry: entry(table: "audit", lastKey: ["5"], rowsDone: 5)
        )

        let loaded = await store.load(jobId: jobId)
        #expect(loaded.count == 2)
        #expect(loaded.first { $0.table == "users" }?.cursor.lastKey == ["20"])
    }

    @Test("a complete table is recorded with its completion flag")
    func completeTableCarriesFlag() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.record(
            jobId: jobId,
            mode: .emptyThenTransfer,
            entry: entry(table: "users", lastKey: ["40"], rowsDone: 40, isComplete: true)
        )

        let loaded = await store.load(jobId: jobId)
        #expect(loaded.first { $0.table == "users" }?.isComplete == true)
    }

    @Test("a corrupted file reads back as no checkpoint instead of crashing")
    func corruptedFileReadsAsEmpty() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("not json at all".utf8).write(to: directory.appendingPathComponent("\(jobId.uuidString).json"))

        #expect(await store.load(jobId: jobId).isEmpty)
    }

    @Test("clear removes every entry of the job")
    func clearRemovesEntries() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.record(jobId: jobId, mode: .emptyThenTransfer, entry: entry(table: "users"))
        await store.clear(jobId: jobId)

        #expect(await store.load(jobId: jobId).isEmpty)
    }

    @Test("the job id is stable for the same endpoints and mode")
    func jobIdIsDeterministic() {
        let source = TransferEndpoint(
            connectionId: uuid("00000000-0000-0000-0000-000000000001"),
            databaseType: .postgresql,
            database: "app",
            schema: "public"
        )
        let target = TransferEndpoint(
            connectionId: uuid("00000000-0000-0000-0000-000000000002"),
            databaseType: .postgresql,
            database: "staging",
            schema: nil
        )

        let first = TransferCheckpointStore.jobId(source: source, target: target, mode: .emptyThenTransfer)
        let second = TransferCheckpointStore.jobId(source: source, target: target, mode: .emptyThenTransfer)
        #expect(first == second)

        let otherMode = TransferCheckpointStore.jobId(source: source, target: target, mode: .copy)
        #expect(first != otherMode)
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value) ?? UUID()
    }
}
