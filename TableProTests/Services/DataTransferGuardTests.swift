import Foundation
@testable import SchemaStudio
import Testing

@MainActor
@Suite("DataTransferService guards")
struct DataTransferGuardTests {
    private func endpoint(
        connectionId: UUID = UUID(),
        type: DatabaseType = .mysql,
        database: String = "shop",
        schema: String? = nil
    ) -> TransferEndpoint {
        TransferEndpoint(connectionId: connectionId, databaseType: type, database: database, schema: schema)
    }

    private let selections = [TransferTableSelection(table: "orders")]

    @Test("An empty selection is refused")
    func emptySelectionRefused() {
        let service = DataTransferService()
        #expect(throws: TransferError.noTablesSelected) {
            try service.validate(selections: [], source: endpoint(), target: endpoint())
        }
    }

    @Test("Two different engines are refused before any driver is taken")
    func crossEngineRefused() {
        let service = DataTransferService()
        #expect(throws: (any Error).self) {
            try service.validate(
                selections: selections,
                source: endpoint(type: .mysql),
                target: endpoint(type: .postgresql)
            )
        }
    }

    @Test("A target that points at the source is refused")
    func sameScopeRefused() {
        let service = DataTransferService()
        let connectionId = UUID()
        #expect(throws: TransferError.sameEndpoint) {
            try service.validate(
                selections: selections,
                source: endpoint(connectionId: connectionId, database: "shop"),
                target: endpoint(connectionId: connectionId, database: "shop")
            )
        }
    }

    @Test("The same connection with a different database is allowed")
    func sameConnectionDifferentDatabaseAllowed() throws {
        let service = DataTransferService()
        let connectionId = UUID()
        try service.validate(
            selections: selections,
            source: endpoint(connectionId: connectionId, database: "shop"),
            target: endpoint(connectionId: connectionId, database: "shop_copy")
        )
    }

    @Test("A failed table is kept out of the later phases")
    func failedTableIsBlocked() {
        var run = TransferRunState()
        run.fail("orders", message: "boom")
        #expect(run.isBlocked("orders"))
        #expect(!run.isBlocked("customers"))
    }

    @Test("A table that never ran is reported as not completed, not as a success")
    func unrunTableIsNotASuccess() {
        var run = TransferRunState()
        run.fail("orders", message: "boom")
        run.succeed("customers", rows: 12, duration: 0.5)
        run.finish("customers")
        run.stopped = true

        let report = run.report(for: [
            TransferTableSelection(table: "orders"),
            TransferTableSelection(table: "customers"),
            TransferTableSelection(table: "invoices")
        ])

        #expect(report.results[0].outcome == .failed("boom"))
        #expect(report.results[1].outcome == .succeeded)
        #expect(report.results[2].outcome == .notRun)
        #expect(report.failedCount == 1)
        #expect(report.notRunCount == 1)
        #expect(report.totalRows == 12)
        #expect(report.wasCancelled)
    }
}
