//
//  DuplicateGateFixtures.swift
//  TableProTests
//
//  Shared setup for the duplicate gates that need a real server. Every gate is
//  skipped unless DUPLICATE_GATES=1 is set or the marker file exists, so the
//  normal suite never needs a database.
//
//  The servers are the ones the transfer gates already use:
//    MySQL      ss_gate_src on 127.0.0.1:33062 as root
//    PostgreSQL ss_gate_src on 127.0.0.1:5432  as postgres
//
//  Every table these gates create is named dup_gate_* and dropped by the test
//  that made it, so the transfer fixtures are left alone.
//
import Foundation
@testable import SchemaStudio
import TableProPluginKit

enum DuplicateGateFixtures {
    /// The scheme's test action replaces the environment xcodebuild was invoked with, so a
    /// `DUPLICATE_GATES=1` argument on the command line never reaches this process: the gates
    /// would skip while still reporting as passed. A marker file is read the same way from every
    /// runner, and `scripts/duplicate-gates.sh` touches it.
    static let markerPath = "/tmp/schemastudio-duplicate-gates"

    static var enabled: Bool {
        if ProcessInfo.processInfo.environment["DUPLICATE_GATES"] == "1" { return true }
        return FileManager.default.fileExists(atPath: markerPath)
    }

    static let database = "ss_gate_src"
    static let postgresSchema = "public"
    static let mysqlPassword = TransferGateFixtures.mysqlPassword
    static let postgresPassword = TransferGateFixtures.postgresPassword

    /// Ids of their own, so a duplicate gate never adopts a session a transfer gate opened with
    /// different expectations about what is in the database.
    private static func stableId(_ suffix: String) -> UUID {
        UUID(uuidString: "D0BE0000-0000-4000-8000-00000000\(suffix)") ?? UUID()
    }

    static func mysqlConnection() -> DatabaseConnection {
        DatabaseConnection(
            id: stableId("0011"),
            name: "gate-dup-mysql",
            host: "127.0.0.1",
            port: 33_062,
            database: database,
            username: "root",
            type: .mysql,
            safeModeLevel: .silent
        )
    }

    static func postgresConnection() -> DatabaseConnection {
        DatabaseConnection(
            id: stableId("0012"),
            name: "gate-dup-pg",
            host: "127.0.0.1",
            port: 5_432,
            database: database,
            username: "postgres",
            type: .postgresql,
            safeModeLevel: .silent
        )
    }

    /// A second connection to the same database, so a gate can write to the source while a copy
    /// reads it without borrowing the connection the copy holds.
    static func postgresWriterConnection() -> DatabaseConnection {
        DatabaseConnection(
            id: stableId("0013"),
            name: "gate-dup-pg-writer",
            host: "127.0.0.1",
            port: 5_432,
            database: database,
            username: "postgres",
            type: .postgresql,
            safeModeLevel: .silent
        )
    }

    /// A login with no CREATE on the schema, used by the permission gate. Created by
    /// `scripts/duplicate-gate-fixtures.sh`.
    static func postgresReadOnlyConnection() -> DatabaseConnection {
        DatabaseConnection(
            id: stableId("0014"),
            name: "gate-dup-pg-readonly",
            host: "127.0.0.1",
            port: 5_432,
            database: database,
            username: "ss_gate_reader",
            type: .postgresql,
            safeModeLevel: .silent
        )
    }

    static let readOnlyPassword = "reader"

    @MainActor
    static func connect(_ connection: DatabaseConnection, password: String) async throws {
        try await TransferGateFixtures.connect(connection, password: password)
    }

    @MainActor
    @discardableResult
    static func execute(_ sql: String, on connection: DatabaseConnection) async throws -> QueryResult {
        try await TransferGateFixtures.execute(sql, on: connection)
    }

    /// The first column of the first row, which is what every count and probe below asks for.
    @MainActor
    static func scalar(_ sql: String, on connection: DatabaseConnection) async throws -> String? {
        let result = try await execute(sql, on: connection)
        return result.rows.first?.first?.asText
    }

    @MainActor
    static func rows(_ sql: String, on connection: DatabaseConnection) async throws -> [[String?]] {
        let result = try await execute(sql, on: connection)
        return result.rows.map { row in row.map(\.asText) }
    }

    // MARK: - Running a duplicate

    static func scope(for connection: DatabaseConnection, schema: String?) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: connection.database, schema: schema)
    }

    static func request(
        schema: String?,
        source: String,
        target: String,
        mode: DuplicateMode = .structureAndData,
        options: DuplicateOptions = DuplicateOptions()
    ) -> DuplicateTableRequest {
        DuplicateTableRequest(
            source: DuplicateTableRef(schema: schema, name: source),
            targetSchema: schema,
            targetName: target,
            mode: mode,
            options: options
        )
    }

    /// Runs one duplicate the way the sheet does, minus the app singletons: the execution gate and
    /// the query history belong to the running app, and a gate that went through them would be
    /// testing the app's alerts rather than the copy.
    @MainActor
    static func duplicate(
        on connection: DatabaseConnection,
        schema: String?,
        request: DuplicateTableRequest,
        hooks: DuplicateServiceHooks = DuplicateServiceHooks(),
        token: DuplicateCancellationToken = DuplicateCancellationToken(),
        onProgress: @escaping @Sendable (DuplicateProgress) -> Void = { _ in }
    ) async throws -> DuplicateResult {
        let service = DuplicateTableService(
            databaseType: connection.type,
            session: DatabaseManagerDuplicateSession(scope: scope(for: connection, schema: schema)),
            hooks: hooks
        )
        return try await service.run(request, token: token, onProgress: onProgress)
    }

    /// The plan the sheet would preview, built from the same introspection the run uses.
    @MainActor
    static func plan(
        on connection: DatabaseConnection,
        schema: String?,
        request: DuplicateTableRequest
    ) async throws -> (plan: DuplicatePlan, introspection: DuplicateTableIntrospection, quoting: DuplicateSQLQuoting) {
        guard let builder = DuplicatePlanBuilder.builder(for: connection.type),
              let catalog = DuplicateVendorCatalogRegistry.catalog(for: connection.type) else {
            throw DuplicateError.unsupportedDatabase(connection.type.rawValue)
        }
        let session = DatabaseManagerDuplicateSession(scope: scope(for: connection, schema: schema))
        return try await session.withDriver(tracksCancellation: false) { driver in
            let introspection = try await DuplicateIntrospector(driver: driver, catalog: catalog)
                .introspect(request.source)
            let quoting = driver.quoting
            return (
                builder.plan(request: request, introspection: introspection, quoting: quoting),
                introspection,
                quoting
            )
        }
    }

    // MARK: - Table lifecycle

    @MainActor
    static func dropTables(_ names: [String], on connection: DatabaseConnection, schema: String?) async {
        for name in names.reversed() {
            let qualified = qualify(name, schema: schema, type: connection.type)
            _ = try? await execute("DROP TABLE IF EXISTS \(qualified)", on: connection)
        }
    }

    static func qualify(_ name: String, schema: String?, type: DatabaseType) -> String {
        let quote = type == .postgresql ? "\"" : "`"
        let quoted = "\(quote)\(name)\(quote)"
        guard let schema, !schema.isEmpty, type == .postgresql else { return quoted }
        return "\(quote)\(schema)\(quote).\(quoted)"
    }
}
