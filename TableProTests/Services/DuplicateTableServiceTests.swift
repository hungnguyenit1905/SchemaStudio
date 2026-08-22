//
//  DuplicateTableServiceTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("DuplicateTableService")
struct DuplicateTableServiceTests {
    private func makeDriver(
        columns: [PluginColumnInfo]? = nil,
        supportsTransactionalDDL: Bool = true
    ) -> DuplicateDrivingStub {
        let driver = DuplicateDrivingStub(supportsTransactionalDDL: supportsTransactionalDDL)
        driver.columns = columns ?? DuplicateFixtures.serialTable.columns
        driver.rowsForQueryContaining["obj_description"] = [[nil, "f", "t", "f"]]
        driver.rowsForQueryContaining["has_schema_privilege"] = [["t", "t"]]
        return driver
    }

    private func service(
        _ driver: DuplicateDrivingStub,
        hooks: DuplicateServiceHooks = DuplicateServiceHooks()
    ) -> DuplicateTableService {
        DuplicateTableService(
            databaseType: .postgresql,
            session: DuplicateSessionStub(driver: driver),
            hooks: hooks
        )
    }

    private func request(rowFilter: String? = nil, mode: DuplicateMode = .structureAndData) -> DuplicateTableRequest {
        var options = DuplicateOptions()
        options.rowFilter = rowFilter
        return DuplicateFixtures.request(mode: mode, options: options)
    }

    // MARK: - Row filter defense

    /// The validator runs before a plan is built, so an unsafe filter costs the server nothing.
    @Test("An unsafe row filter is refused before any statement runs")
    func unsafeRowFilterRefusedBeforeExecution() async throws {
        let driver = makeDriver()
        await #expect(throws: DuplicateError.unsafeRowFilter) {
            _ = try await service(driver).run(request(rowFilter: "1=1); DROP TABLE t; SELECT (1"))
        }
        #expect(driver.calls.isEmpty)
    }

    @Test("A semicolon inside a literal is allowed through to the server")
    func literalSemicolonIsAllowed() async throws {
        let driver = makeDriver()
        _ = try await service(driver).run(request(rowFilter: "note = 'a;b'"))
        #expect(driver.executedSQL.contains { $0.hasPrefix("EXPLAIN") })
    }

    /// `EXPLAIN` carries the user's text, so it takes the protocol that refuses a second statement.
    @Test("The filter validation statement takes the extended path")
    func validationUsesExtendedPath() async throws {
        let driver = makeDriver()
        _ = try await service(driver).run(request(rowFilter: "status = 'paid'"))
        let explains = driver.calls.filter { call in
            if case .extended(let sql) = call { return sql.hasPrefix("EXPLAIN") }
            return false
        }
        #expect(explains.count == 1)
    }

    @Test("A filter the server rejects stops the run before anything is created")
    func serverRejectedFilterStopsRun() async throws {
        let driver = makeDriver()
        driver.errorForQueryContaining["EXPLAIN"] = DuplicateStubError(message: "column x does not exist")
        await #expect(throws: DuplicateError.invalidRowFilter("column x does not exist")) {
            _ = try await service(driver).run(request(rowFilter: "x = 1"))
        }
        #expect(!driver.executedSQL.contains { $0.hasPrefix("CREATE TABLE") })
    }

    /// Running it twice would charge the user for the same plan twice, once before the prompt and
    /// once after.
    @Test("The validation statement is not replayed during execution")
    func validationNotReplayed() async throws {
        let driver = makeDriver()
        _ = try await service(driver).run(request(rowFilter: "status = 'paid'"))
        #expect(driver.executedSQL.filter { $0.hasPrefix("EXPLAIN") }.count == 1)
    }

    // MARK: - Authorization ordering

    @Test("Nothing is created before authorization returns")
    func authorizationPrecedesCreation() async throws {
        let driver = makeDriver()
        let seenAtAuthorization = Mutex<[String]>([])
        var hooks = DuplicateServiceHooks()
        hooks.authorize = { seenAtAuthorization.withLock { $0 = driver.executedSQL } }

        _ = try await service(driver, hooks: hooks).run(request())

        let seen = seenAtAuthorization.withLock { $0 }
        #expect(!seen.contains { $0.hasPrefix("CREATE TABLE") })
        #expect(driver.executedSQL.contains { $0.hasPrefix("CREATE TABLE") })
    }

    @Test("A refused authorization stops the run")
    func refusedAuthorizationStopsRun() async throws {
        let driver = makeDriver()
        var hooks = DuplicateServiceHooks()
        hooks.authorize = { throw DuplicateStubError(message: "denied") }

        await #expect(throws: DuplicateStubError(message: "denied")) {
            _ = try await service(driver, hooks: hooks).run(request())
        }
        #expect(!driver.executedSQL.contains { $0.hasPrefix("CREATE TABLE") })
    }

    // MARK: - Structure fingerprint

    /// Authorization can wait on a person, and another tab can alter the source in that gap.
    @Test("A source altered during the authorization prompt aborts the run")
    func alteredSourceAbortsRun() async throws {
        let driver = makeDriver()
        driver.columnsAfterAuthorization = [DuplicateFixtures.column("id", "bigint", primaryKey: true)]

        await #expect(throws: DuplicateError.sourceChangedDuringSetup) {
            _ = try await service(driver).run(request())
        }
        #expect(!driver.executedSQL.contains { $0.hasPrefix("CREATE TABLE") })
    }

    @Test("An unchanged source proceeds")
    func unchangedSourceProceeds() async throws {
        let driver = makeDriver()
        driver.columnsAfterAuthorization = DuplicateFixtures.serialTable.columns
        let result = try await service(driver).run(request())
        #expect(result.target.name == "orders_copy")
    }

    // MARK: - Preflight

    @Test("An existing target name is refused under the cancel policy")
    func existingTargetRefused() async throws {
        let driver = makeDriver()
        driver.rowsForQueryContaining["FROM pg_class c\nJOIN pg_namespace"] = [["1"]]
        await #expect(throws: DuplicateError.targetExists("orders_copy")) {
            _ = try await service(driver).run(request())
        }
    }

    @Test("Missing CREATE permission is reported as a permission problem")
    func missingCreatePermission() async throws {
        let driver = makeDriver()
        driver.rowsForQueryContaining["has_schema_privilege"] = [["f", "t"]]
        await #expect(throws: DuplicateError.missingCreatePrivilege("public")) {
            _ = try await service(driver).run(request())
        }
    }

    @Test("Missing SELECT permission is reported against the source")
    func missingSelectPermission() async throws {
        let driver = makeDriver()
        driver.rowsForQueryContaining["has_schema_privilege"] = [["t", "f"]]
        await #expect(throws: DuplicateError.missingSelectPrivilege("orders")) {
            _ = try await service(driver).run(request())
        }
    }

    @Test("A partitioned source is refused")
    func partitionedSourceRefused() async throws {
        let driver = makeDriver()
        driver.rowsForQueryContaining["obj_description"] = [[nil, "f", "t", "t"]]
        await #expect(throws: DuplicateError.partitionedSource("orders")) {
            _ = try await service(driver).run(request())
        }
    }

    // MARK: - Warnings

    @Test("A source the user does not own under row-level security produces both warnings")
    func rowLevelSecurityWarningsReachTheResult() async throws {
        let driver = makeDriver()
        driver.rowsForQueryContaining["obj_description"] = [[nil, "t", "f", "f"]]
        let result = try await service(driver).run(request())
        #expect(result.warnings == [.rowLevelSecurityPoliciesNotCopied, .rowLevelSecurityMayHideRows])
    }

    @Test("A table comment read from the catalog is copied by its own statement")
    func tableCommentIsCopied() async throws {
        let driver = makeDriver()
        driver.rowsForQueryContaining["obj_description"] = [["Customer orders", "f", "t", "f"]]
        _ = try await service(driver).run(request())
        #expect(driver.executedSQL.contains { $0.hasPrefix("COMMENT ON TABLE") })
    }

    // MARK: - Transactions and recovery

    @Test("A transactional engine wraps the run and commits")
    func transactionalRunCommits() async throws {
        let driver = makeDriver()
        _ = try await service(driver).run(request())
        let beginIndex = driver.calls.firstIndex(of: .begin)
        let createIndex = driver.calls.firstIndex { call in
            if case .simple(let sql) = call { return sql.hasPrefix("CREATE TABLE") }
            return false
        }
        #expect(beginIndex != nil)
        #expect(createIndex != nil)
        if let beginIndex, let createIndex { #expect(beginIndex < createIndex) }
        #expect(driver.calls.last == .commit)
    }

    /// Returning a connection to the pool mid-transaction leaves it unusable for whoever takes it
    /// next, so the rollback is sent even though the statement already failed.
    @Test("A fatal failure inside a transaction rolls back")
    func fatalFailureRollsBack() async throws {
        let driver = makeDriver()
        driver.errorForQueryContaining["INSERT INTO"] = DuplicateStubError(message: "disk full")

        await #expect(throws: (any Error).self) {
            _ = try await service(driver).run(request())
        }
        #expect(driver.calls.contains(.rollback))
        #expect(!driver.calls.contains(.commit))
    }

    /// MySQL commits each DDL statement, so there is nothing to roll back and the table has to be
    /// dropped instead.
    @Test("A failure on an engine without transactional DDL drops the target")
    func nonTransactionalFailureDropsTarget() async throws {
        let driver = makeDriver(supportsTransactionalDDL: false)
        driver.errorForQueryContaining["INSERT INTO"] = DuplicateStubError(message: "disk full")

        await #expect(throws: (any Error).self) {
            _ = try await service(driver).run(request())
        }
        #expect(!driver.calls.contains(.begin))
        #expect(driver.executedSQL.contains("DROP TABLE IF EXISTS \"public\".\"orders_copy\""))
    }

    @Test("A cleanup that also fails reports the command for the user to run")
    func failedCleanupReportsCommand() async throws {
        let driver = makeDriver(supportsTransactionalDDL: false)
        driver.errorForQueryContaining["INSERT INTO"] = DuplicateStubError(message: "disk full")
        driver.errorForQueryContaining["DROP TABLE IF EXISTS"] = DuplicateStubError(message: "in use")

        await #expect(throws: DuplicateError.cleanupFailed(
            target: "orders_copy",
            command: "DROP TABLE IF EXISTS \"public\".\"orders_copy\"",
            serverMessage: DuplicateError.statementFailed(
                sql: "INSERT INTO \"public\".\"orders_copy\" (\"id\", \"total\")\nSELECT \"id\", \"total\" FROM \"public\".\"orders\"",
                serverMessage: "disk full"
            ).localizedDescription
        )) {
            _ = try await service(driver).run(request())
        }
    }

    // MARK: - History

    /// One entry for the run. Chunked mode issues a statement per batch, so a per-statement entry
    /// would flood the history log and the main actor for a single user action.
    @Test("A successful run records exactly one history entry")
    func successRecordsOneHistoryEntry() async throws {
        let driver = makeDriver()
        let entries = Mutex<[(String, Bool)]>([])
        var hooks = DuplicateServiceHooks()
        hooks.recordHistory = { stage, _, succeeded, _ in
            entries.withLock { $0.append((stage, succeeded)) }
        }

        _ = try await service(driver, hooks: hooks).run(request())

        let recorded = entries.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first?.1 == true)
    }

    @Test("A failed run records one entry marked as failed")
    func failureRecordsOneFailedEntry() async throws {
        let driver = makeDriver()
        driver.errorForQueryContaining["INSERT INTO"] = DuplicateStubError(message: "disk full")
        let entries = Mutex<[(String, Bool)]>([])
        var hooks = DuplicateServiceHooks()
        hooks.recordHistory = { stage, _, succeeded, _ in
            entries.withLock { $0.append((stage, succeeded)) }
        }

        await #expect(throws: (any Error).self) {
            _ = try await service(driver, hooks: hooks).run(request())
        }

        let recorded = entries.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first?.1 == false)
    }

    // MARK: - Unsupported vendors

    @Test("A database with no builder is refused up front")
    func unsupportedDatabaseRefused() async throws {
        let driver = makeDriver()
        let unsupported = DuplicateTableService(
            databaseType: .mysql,
            session: DuplicateSessionStub(driver: driver)
        )
        await #expect(throws: DuplicateError.unsupportedDatabase("MySQL")) {
            _ = try await unsupported.run(request())
        }
        #expect(driver.calls.isEmpty)
    }
}
