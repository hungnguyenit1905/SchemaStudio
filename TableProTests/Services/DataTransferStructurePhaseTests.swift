//
//  DataTransferStructurePhaseTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

private enum RecordingDriverError: LocalizedError {
    case statementRejected(String)

    var errorDescription: String? {
        switch self {
        case .statementRejected(let query):
            return "Rejected: \(query)"
        }
    }
}

private final class RecordingStructureDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    var supportsForeignKeyToggle = true
    var failingQueries: Set<String> = []
    var foreignKeysByTable: [String: [PluginForeignKeyInfo]] = [:]
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
        if failingQueries.contains(query) {
            throw RecordingDriverError.statementRejected(query)
        }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        "CREATE INDEX `\(index.name)` ON `\(table)` (\(index.columns.joined(separator: ", ")))"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE `\(table)` ADD CONSTRAINT `\(fk.name)` FOREIGN KEY (\(fk.columns.joined(separator: ", ")))"
            + " REFERENCES `\(fk.referencedTable)` (\(fk.referencedColumns.joined(separator: ", ")))"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE `\(table)` DROP CONSTRAINT `\(constraintName)`"
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        foreignKeysByTable
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
    private func makeContext(
        driver: RecordingStructureDriver,
        type: DatabaseType = .mysql
    ) -> TransferDriverContext {
        let connection = DatabaseConnection(name: "Target", type: type)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        let endpoint = TransferEndpoint(
            connectionId: connection.id,
            databaseType: type,
            database: "shop",
            schema: nil
        )
        guard let context = TransferDriverContext(driver: adapter, endpoint: endpoint) else {
            fatalError("PluginDriverAdapter is always a valid transfer context")
        }
        return context
    }

    @Test("PostgreSQL copy removes selected foreign keys before dropping referenced tables")
    func postgresCopyDropsInternalForeignKeysFirst() async {
        let driver = RecordingStructureDriver()
        driver.foreignKeysByTable = [
            "child": [PluginForeignKeyInfo(
                name: "child_parent_fk",
                column: "parent_id",
                referencedTable: "parent",
                referencedColumn: "id"
            )],
            "unselected": [PluginForeignKeyInfo(
                name: "unselected_parent_fk",
                column: "parent_id",
                referencedTable: "parent",
                referencedColumn: "id"
            )]
        ]
        let context = makeContext(driver: driver, type: .postgresql)
        var run = TransferRunState()

        await DataTransferService().runStructurePhase(
            [
                makePlan(table: "parent", steps: [.dropTargetTable]),
                makePlan(table: "child", steps: [.dropTargetTable])
            ],
            target: context,
            options: TransferOptions(),
            run: &run
        )

        let dropForeignKey = "ALTER TABLE `child` DROP CONSTRAINT `child_parent_fk`"
        #expect(driver.executedQueries.first == dropForeignKey)
        #expect(driver.executedQueries.contains("DROP TABLE `parent`"))
        #expect(!driver.executedQueries.contains("ALTER TABLE `unselected` DROP CONSTRAINT `unselected_parent_fk`"))
    }

    private func makePlan(
        table: String,
        steps: [TransferStep],
        indexes: [PluginIndexInfo] = [],
        foreignKeys: [PluginForeignKeyInfo] = []
    ) -> TransferTablePlan {
        let structure = TransferStructureBuilder.build(
            table: table,
            columns: [PluginColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true)],
            indexes: indexes,
            foreignKeys: foreignKeys,
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

    private func constraintPlan(table: String = "orders") -> TransferTablePlan {
        makePlan(
            table: table,
            steps: [.createIndexes, .createForeignKeys],
            indexes: [PluginIndexInfo(name: "idx_customer", columns: ["customer_id"])],
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "fk_customer",
                    column: "customer_id",
                    referencedTable: "customers",
                    referencedColumn: "id"
                )
            ]
        )
    }

    private var addForeignKeySQL: String {
        "ALTER TABLE `orders` ADD CONSTRAINT `fk_customer` FOREIGN KEY (customer_id) REFERENCES `customers` (id)"
    }

    private var addIndexSQL: String {
        "CREATE INDEX `idx_customer` ON `orders` (customer_id)"
    }

    @Test("Constraints are added with foreign key checks off, then restored")
    func constraintsRunWithoutForeignKeyChecks() async {
        let driver = RecordingStructureDriver()
        let context = makeContext(driver: driver)
        var run = TransferRunState()

        await DataTransferService().runConstraintPhase([constraintPlan()], target: context, run: &run)

        #expect(driver.executedQueries == [
            "SET FOREIGN_KEY_CHECKS=0",
            addIndexSQL,
            addForeignKeySQL,
            "SET FOREIGN_KEY_CHECKS=1"
        ])
    }

    @Test("Checks are restored when the phase stops early")
    func checksRestoredOnEarlyStop() async {
        let driver = RecordingStructureDriver()
        let context = makeContext(driver: driver)
        var run = TransferRunState()
        let service = DataTransferService()
        service.state.isTransferring = true
        service.cancel()

        await service.runConstraintPhase([constraintPlan()], target: context, run: &run)

        #expect(driver.executedQueries == ["SET FOREIGN_KEY_CHECKS=0", "SET FOREIGN_KEY_CHECKS=1"])
        #expect(run.stopped)
    }

    @Test("Checks are restored when a constraint statement fails")
    func checksRestoredOnFailure() async {
        let driver = RecordingStructureDriver()
        driver.failingQueries = [addForeignKeySQL]
        let context = makeContext(driver: driver)
        var run = TransferRunState()

        await DataTransferService().runConstraintPhase([constraintPlan()], target: context, run: &run)

        #expect(driver.executedQueries.last == "SET FOREIGN_KEY_CHECKS=1")
    }

    @Test("A driver with no foreign key toggle still applies the constraints")
    func constraintsWithoutToggle() async {
        let driver = RecordingStructureDriver()
        driver.supportsForeignKeyToggle = false
        let context = makeContext(driver: driver)
        var run = TransferRunState()

        await DataTransferService().runConstraintPhase([constraintPlan()], target: context, run: &run)

        #expect(driver.executedQueries == [addIndexSQL, addForeignKeySQL])
    }

    @Test("A rejected foreign key becomes a warning and keeps the copied row count")
    func rejectedForeignKeyWarns() async {
        let driver = RecordingStructureDriver()
        driver.failingQueries = [addForeignKeySQL]
        let context = makeContext(driver: driver)
        var run = TransferRunState()
        run.succeed("orders", rows: 36_284, duration: 1)

        await DataTransferService().runConstraintPhase([constraintPlan()], target: context, run: &run)

        let report = run.report(for: [TransferTableSelection(table: "orders")])
        #expect(report.results[0].warningMessages == ["Rejected: \(addForeignKeySQL)"])
        #expect(report.results[0].rowsTransferred == 36_284)
        #expect(report.warningCount == 1)
        #expect(report.failedCount == 0)
        #expect(!run.stopped)
    }

    @Test("A rejected index still lets the same table's foreign keys be created")
    func rejectedIndexDoesNotSkipForeignKeys() async {
        let driver = RecordingStructureDriver()
        driver.failingQueries = [addIndexSQL]
        let context = makeContext(driver: driver)
        var run = TransferRunState()

        await DataTransferService().runConstraintPhase([constraintPlan()], target: context, run: &run)

        #expect(driver.executedQueries.contains(addForeignKeySQL))
    }

    @Test("Tables after a rejected constraint still run when continueOnError is off")
    func laterTablesStillRunAfterRejectedConstraint() async {
        let driver = RecordingStructureDriver()
        driver.failingQueries = [addForeignKeySQL]
        let context = makeContext(driver: driver)
        var run = TransferRunState()

        await DataTransferService().runConstraintPhase(
            [constraintPlan(), constraintPlan(table: "invoices")],
            target: context,
            run: &run
        )

        #expect(driver.executedQueries.contains("CREATE INDEX `idx_customer` ON `invoices` (customer_id)"))
        #expect(!run.stopped)
    }

    @Test("A data phase failure outranks a constraint warning")
    func dataFailureOutranksWarning() async {
        var run = TransferRunState()
        run.fail("orders", message: "insert failed")
        run.warn("orders", messages: ["constraint rejected"])
        run.finish("orders")

        let report = run.report(for: [TransferTableSelection(table: "orders")])
        #expect(report.results[0].outcome == .failed("insert failed"))
    }

    @Test("Rows copied before the run stopped are reported as a warning, not as not completed")
    func stoppedRunReportsCopiedRowsAsWarning() {
        var run = TransferRunState()
        run.succeed("orders", rows: 695, duration: 1)
        run.stopped = true

        let report = run.report(for: [
            TransferTableSelection(table: "orders"),
            TransferTableSelection(table: "invoices")
        ])

        #expect(report.results[0].warningMessages.count == 1)
        #expect(report.results[0].rowsTransferred == 695)
        #expect(report.results[1].outcome == .notRun)
        #expect(report.warningCount == 1)
        #expect(report.notRunCount == 1)
    }
}
