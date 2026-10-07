import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("TransferResumeState")
struct TransferResumeStateTests {
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

    private func state(_ entries: [TransferCheckpointStore.Entry]) -> TransferResumeState {
        let tables = Set(entries.map(\.table)).sorted().map { table in
            let lastPartition = entries.filter { $0.table == table }.map(\.partition).max() ?? 0
            return PluginTransferCheckpointTableManifest(
                table: table,
                boundaries: (0 ..< lastPartition).map { String($0) }
            )
        }
        return TransferResumeState(
            manifest: PluginTransferCheckpointManifest(sourceJobId: UUID(), tables: tables),
            entries: entries
        )
    }

    @Test("a table with one complete partition entry is complete")
    func singlePartitionComplete() {
        let state = state([
            entry(table: "users", lastKey: ["100"], rowsDone: 100, isComplete: true),
        ])
        #expect(state.isComplete(table: "users"))
        #expect(state.hasProgress(table: "users"))
    }

    @Test("a table is complete only when every partition is complete")
    func allPartitionsMustBeComplete() {
        let state = state([
            entry(table: "orders", partition: 0, lastKey: ["500"], rowsDone: 500, isComplete: true),
            entry(table: "orders", partition: 1, lastKey: ["900"], rowsDone: 400, isComplete: false),
        ])
        #expect(state.isComplete(table: "orders") == false)
        #expect(state.hasProgress(table: "orders"))
    }

    @Test("a table with no entries has no progress")
    func noProgress() {
        let state = state([])
        #expect(state.hasProgress(table: "users") == false)
        #expect(state.isComplete(table: "users") == false)
        #expect(state.rowsDone(table: "users") == 0)
    }

    @Test("rows done sums every partition of the table")
    func rowsDoneSumsPartitions() {
        let state = state([
            entry(table: "orders", partition: 0, rowsDone: 500),
            entry(table: "orders", partition: 1, rowsDone: 400),
            entry(table: "audit", partition: 0, rowsDone: 7),
        ])
        #expect(state.rowsDone(table: "orders") == 900)
    }

    @Test("each partition resumes from its own cursor")
    func perPartitionCursor() {
        let state = state([
            entry(table: "orders", partition: 0, lastKey: ["500"], rowsDone: 500),
            entry(table: "orders", partition: 1, lastKey: ["900"], rowsDone: 400),
        ])
        #expect(state.entry(table: "orders", partition: 0)?.cursor.lastKey == ["500"])
        #expect(state.entry(table: "orders", partition: 1)?.cursor.lastKey == ["900"])
    }
}
