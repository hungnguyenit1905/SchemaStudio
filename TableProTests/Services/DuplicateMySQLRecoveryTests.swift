//
//  DuplicateMySQLRecoveryTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

/// MySQL commits every DDL statement, so cleaning up is not optional. What matters just as much
/// is what is *not* cleaned up: a step that fails after the rows have landed leaves a correct,
/// usable table, and dropping it would throw away hours of work for a statistics statement.
@Suite("Duplicate cleanup on MySQL")
struct DuplicateMySQLRecoveryTests {
    private let quoting = DuplicateFixtures.mysqlQuoting

    private func run(
        _ statements: [DuplicateStatement],
        failing failure: String,
        supportsTransactionalDDL: Bool = false
    ) async -> (outcome: DuplicateExecutionOutcome?, driver: DuplicateDrivingStub) {
        let driver = DuplicateDrivingStub(supportsTransactionalDDL: supportsTransactionalDDL)
        driver.errorForQueryContaining[failure] = DuplicateStubError(message: "lock wait timeout exceeded")
        let plan = DuplicatePlan(
            statements: statements,
            copyMode: .chunked,
            indexDialect: .mysql(target: "`orders_copy`")
        )
        let outcome = try? await DuplicateExecutor(driver: driver).run(plan)
        return (outcome, driver)
    }

    // MARK: - Fatal failures

    /// Nothing can be rolled back, so the only way back is to drop what was created. One
    /// statement is enough: it takes the indexes with it.
    @Test("A run that cannot roll back drops the target")
    func nonTransactionalDropsTarget() {
        #expect(
            DuplicateRecovery.action(supportsTransactionalDDL: false, copyMode: .chunked, hasCommittedRows: false)
                == .dropTarget
        )
    }

    @Test("The cleanup is a single DROP TABLE IF EXISTS with no CASCADE")
    func cleanupIsOneStatement() {
        let statement = DuplicateRecovery.dropStatement(
            target: DuplicateTableRef(schema: nil, name: "orders_copy"),
            quoting: quoting
        )
        #expect(statement.body == .sql("DROP TABLE IF EXISTS `orders_copy`"))
        #expect(statement.severity == .fatal)
    }

    /// `DROP TABLE … CASCADE` parses on MySQL and then does nothing, which reads as a working
    /// cleanup that silently is not one.
    @Test("The cleanup never uses CASCADE, which MySQL accepts and ignores")
    func cleanupNeverUsesCascade() {
        let statement = DuplicateRecovery.dropStatement(
            target: DuplicateTableRef(schema: "shop", name: "orders_copy"),
            quoting: quoting
        )
        guard case .sql(let sql) = statement.body else {
            Issue.record("The cleanup is not a plain statement")
            return
        }
        #expect(!sql.uppercased().contains("CASCADE"))
        #expect(sql == "DROP TABLE IF EXISTS `shop`.`orders_copy`")
    }

    /// A drop that itself fails leaves a table the user has to remove by hand, so the message
    /// carries the exact command rather than a description of it.
    @Test("A cleanup that fails hands the user the command to run")
    func failedCleanupCarriesTheCommand() {
        let error = DuplicateError.cleanupFailed(
            target: "orders_copy",
            command: "DROP TABLE IF EXISTS `orders_copy`",
            serverMessage: "table is in use"
        )
        let message = error.errorDescription ?? ""
        #expect(message.contains("DROP TABLE IF EXISTS `orders_copy`"))
        #expect(message.contains("orders_copy"))
    }

    @Test("A fatal statement stops the run so the caller can clean up")
    func fatalFailureStopsTheRun() async {
        let result = await run(
            [
                DuplicateStatement(kind: .createTable, sql: "CREATE TABLE `orders_copy` LIKE `orders`"),
                DuplicateStatement(kind: .copyData, sql: "INSERT INTO `orders_copy` (`id`) SELECT `id` FROM `orders`"),
                DuplicateStatement(kind: .analyze, sql: "ANALYZE TABLE `orders_copy`")
            ],
            failing: "INSERT INTO"
        )
        #expect(result.outcome == nil)
        #expect(!result.driver.executedSQL.contains { $0.hasPrefix("ANALYZE") })
    }

    // MARK: - Best-effort failures

    /// Twenty million rows are already committed and correct. Dropping them because a statistics
    /// statement hit a metadata lock is how a cleanup path turns into the bug it was meant to fix.
    @Test("ANALYZE TABLE failing keeps the table and only warns")
    func analyzeFailureKeepsTheTable() async throws {
        let result = await run(
            [
                DuplicateStatement(kind: .createTable, sql: "CREATE TABLE `orders_copy` LIKE `orders`"),
                DuplicateStatement(kind: .copyData, sql: "INSERT INTO `orders_copy` (`id`) SELECT `id` FROM `orders`"),
                DuplicateStatement(kind: .analyze, sql: "ANALYZE TABLE `orders_copy`")
            ],
            failing: "ANALYZE"
        )
        let outcome = try #require(result.outcome)
        #expect(outcome.executedStatements.count == 2)
        #expect(outcome.warnings.count == 1)
        #expect(!result.driver.executedSQL.contains { $0.hasPrefix("DROP TABLE") })
    }

    @Test("Setting the auto-increment counter failing keeps the table and only warns")
    func autoIncrementFailureKeepsTheTable() async throws {
        let result = await run(
            [
                DuplicateStatement(kind: .createTable, sql: "CREATE TABLE `orders_copy` LIKE `orders`"),
                DuplicateStatement(kind: .resetAutoIncrement, sql: "ALTER TABLE `orders_copy` AUTO_INCREMENT = 1"),
                DuplicateStatement(kind: .analyze, sql: "ANALYZE TABLE `orders_copy`")
            ],
            failing: "AUTO_INCREMENT"
        )
        let outcome = try #require(result.outcome)
        #expect(outcome.warnings.count == 1)
        #expect(outcome.executedStatements.contains { $0.hasPrefix("ANALYZE") })
    }

    // MARK: - Deferred index statements

    /// The executor asks the plan's dialect, so a MySQL harvest reads one `SHOW CREATE TABLE` row
    /// and turns it into exactly two `ALTER` statements no matter how many indexes there are.
    @Test("A MySQL harvest expands into one drop and one replay statement")
    func harvestExpandsIntoTwoStatements() async throws {
        let driver = DuplicateDrivingStub(supportsTransactionalDDL: false)
        driver.rowsForQueryContaining["SHOW CREATE TABLE"] = [["orders_copy", MySQLCreateTableFixtures.mysql8]]
        let plan = DuplicatePlan(
            statements: [
                DuplicateStatement(kind: .harvestIndexes, sql: "SHOW CREATE TABLE `orders_copy`"),
                DuplicateStatement(kind: .dropIndex, deferred: .fromHarvestedIndexes),
                DuplicateStatement(kind: .copyData, sql: "INSERT INTO `orders_copy` (`id`) SELECT `id` FROM `orders`"),
                DuplicateStatement(kind: .replayIndex, deferred: .fromHarvestedIndexes)
            ],
            copyMode: .chunked,
            indexDialect: .mysql(target: "`orders_copy`")
        )

        let outcome = try await DuplicateExecutor(driver: driver).run(plan)
        let alters = outcome.executedStatements.filter { $0.hasPrefix("ALTER TABLE") }
        #expect(alters.count == 2)
        #expect(alters.first?.components(separatedBy: "DROP INDEX").count == 5)
        #expect(alters.first?.contains("uq_orders_email") == true)
        #expect(alters.last?.components(separatedBy: "ADD ").count == 5)
        #expect(alters.last?.contains("ADD FULLTEXT KEY `ft_orders_body` (`body`)") == true)
    }
}

@Suite("MySqlDuplicateCatalog grants")
struct MySqlDuplicateCatalogGrantTests {
    private func rows(_ grants: [String]) -> [[String?]] {
        grants.map { [$0] }
    }

    @Test("A schema grant is read into the privileges it names")
    func readsSchemaGrant() {
        let granted = MySqlDuplicateCatalog.grantedPrivileges(
            from: rows(["GRANT SELECT, INSERT, CREATE, ALTER ON `shop`.* TO `app`@`%`"]),
            schema: "shop"
        )
        #expect(granted == ["SELECT", "INSERT", "CREATE", "ALTER"])
    }

    @Test("A global grant applies to every schema")
    func readsGlobalGrant() {
        let granted = MySqlDuplicateCatalog.grantedPrivileges(
            from: rows(["GRANT ALL PRIVILEGES ON *.* TO `root`@`localhost` WITH GRANT OPTION"]),
            schema: "shop"
        )
        #expect(granted.contains(MySqlDuplicateCatalog.allPrivileges))
    }

    /// A grant on a different database says nothing about the one the copy lands in.
    @Test("A grant on another schema is ignored")
    func ignoresOtherSchema() {
        let granted = MySqlDuplicateCatalog.grantedPrivileges(
            from: rows(["GRANT ALL PRIVILEGES ON `analytics`.* TO `app`@`%`"]),
            schema: "shop"
        )
        #expect(granted.isEmpty)
    }

    /// A table-level grant still proves the privilege exists in that schema, and refusing on it
    /// would block a duplicate the server would allow.
    @Test("A table-level grant counts for its schema")
    func readsTableGrant() {
        let granted = MySqlDuplicateCatalog.grantedPrivileges(
            from: rows(["GRANT SELECT (`id`, `email`) ON `shop`.`orders` TO `app`@`%`"]),
            schema: "shop"
        )
        #expect(granted == ["SELECT"])
    }

    /// A role grant has no `ON` clause at all. Skipping it is the bounded-parsing rule again.
    @Test("A line that is not a privilege grant is skipped")
    func skipsRoleGrant() {
        let granted = MySqlDuplicateCatalog.grantedPrivileges(
            from: rows(["GRANT `reader`@`%` TO `app`@`%`", "not a grant at all"]),
            schema: "shop"
        )
        #expect(granted.isEmpty)
    }

    // MARK: - What the plan actually needs

    @Test("A structure-only copy does not require INSERT")
    func structureOnlyNeedsNoInsert() {
        let request = DuplicateFixtures.mysqlRequest(mode: .structureOnly)
        #expect(!MySqlDuplicateCatalog.requiredPrivileges(for: request).contains("INSERT"))
    }

    @Test("Copying foreign keys requires REFERENCES")
    func foreignKeysNeedReferences() {
        var options = DuplicateOptions()
        options.foreignKeys = true
        let request = DuplicateFixtures.mysqlRequest(options: options)
        #expect(MySqlDuplicateCatalog.requiredPrivileges(for: request).contains("REFERENCES"))
    }

    @Test("Setting the auto-increment counter requires ALTER")
    func autoIncrementNeedsAlter() {
        let request = DuplicateFixtures.mysqlRequest()
        let required = MySqlDuplicateCatalog.requiredPrivileges(for: request)
        #expect(required.contains("ALTER"))
        #expect(required.contains("CREATE"))
        #expect(required.contains("SELECT"))
    }
}
