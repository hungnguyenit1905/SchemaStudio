//
//  DataTransferStructurePhaseTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

private final class RecordingStructureDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    var supportsForeignKeyToggle = true
    private(set) var executedQueries: [String] = []

    func foreignKeyDisableStatements() -> [String]? {
        supportsForeignKeyToggle ? ["SET FOREIGN_KEY_CHECKS=0"] : nil
    }

    func foreignKeyEnableStatements() -> [String]? {
        supportsForeignKeyToggle ? ["SET FOREIGN_KEY_CHECKS=1"] : nil
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        ["TRUNCATE TABLE `\(table)`"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        "DROP \(objectType) `\(name)`"
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

@MainActor
@Suite("DataTransfer structure phase")
struct DataTransferStructurePhaseTests {
    private func makeContext(driver: RecordingStructureDriver) -> TransferDriverContext {
        let connection = DatabaseConnection(name: "Target", type: .mysql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        let endpoint = TransferEndpoint(
            connectionId: connection.id,
            databaseType: .mysql,
            database: "shop",
            schema: nil
        )
        guard let context = TransferDriverContext(driver: adapter, endpoint: endpoint) else {
            fatalError("PluginDriverAdapter is always a valid transfer context")
        }
        return context
    }

    private func makePlan(table: String, steps: [TransferStep]) -> TransferTablePlan {
        let structure = TransferStructureBuilder.build(
            table: table,
            columns: [PluginColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true)],
            indexes: [],
            foreignKeys: [],
            targetSchema: nil
        )
        return TransferTablePlan(
            table: table,
            structure: structure,
            targetExists: true,
            steps: steps,
            extraTargetColumns: []
        )
    }

    @Test("Truncating the target runs with foreign key checks off, then restores them")
    func truncateRunsWithoutForeignKeyChecks() async {
        let driver = RecordingStructureDriver()
        let context = makeContext(driver: driver)
        var run = TransferRunState()

        await DataTransferService().runStructurePhase(
            [makePlan(table: "orders", steps: [.truncateTarget, .transferRows])],
            target: context,
            options: TransferOptions(),
            run: &run
        )

        #expect(driver.executedQueries == [
            "SET FOREIGN_KEY_CHECKS=0",
            "TRUNCATE TABLE `orders`",
            "SET FOREIGN_KEY_CHECKS=1"
        ])
    }

    @Test("Every table is prepared inside one disabled window")
    func multipleTablesShareOneWindow() async {
        let driver = RecordingStructureDriver()
        let context = makeContext(driver: driver)
        var run = TransferRunState()

        await DataTransferService().runStructurePhase(
            [
                makePlan(table: "orders", steps: [.truncateTarget]),
                makePlan(table: "customers", steps: [.truncateTarget])
            ],
            target: context,
            options: TransferOptions(),
            run: &run
        )

        #expect(driver.executedQueries.count(where: { $0 == "SET FOREIGN_KEY_CHECKS=0" }) == 1)
        #expect(driver.executedQueries.last == "SET FOREIGN_KEY_CHECKS=1")
        #expect(driver.executedQueries.contains("TRUNCATE TABLE `orders`"))
        #expect(driver.executedQueries.contains("TRUNCATE TABLE `customers`"))
    }

    @Test("A driver with no foreign key toggle issues no extra statement")
    func noToggleLeavesStatementsUntouched() async {
        let driver = RecordingStructureDriver()
        driver.supportsForeignKeyToggle = false
        let context = makeContext(driver: driver)
        var run = TransferRunState()

        await DataTransferService().runStructurePhase(
            [makePlan(table: "orders", steps: [.truncateTarget])],
            target: context,
            options: TransferOptions(),
            run: &run
        )

        #expect(driver.executedQueries == ["TRUNCATE TABLE `orders`"])
    }
}
