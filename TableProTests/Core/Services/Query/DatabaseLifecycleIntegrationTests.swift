//
//  DatabaseLifecycleIntegrationTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

private struct LifecycleServer {
    let connection: DatabaseConnection
    let password: String

    static func fromEnvironment(_ key: String, type: DatabaseType) -> LifecycleServer? {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let url = URLComponents(string: raw),
              let host = url.host else { return nil }
        let database = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let connection = DatabaseConnection(
            name: "database-lifecycle",
            host: host,
            port: url.port ?? type.defaultPort,
            database: database,
            username: url.user ?? "",
            type: type
        )
        return LifecycleServer(connection: connection, password: url.password ?? "")
    }

    static let postgres = fromEnvironment("DATABASE_LIFECYCLE_POSTGRES_URL", type: .postgresql)
    static let mysql = fromEnvironment("DATABASE_LIFECYCLE_MYSQL_URL", type: .mysql)
}

@Suite("Database drop and create against live servers", .serialized)
@MainActor
struct DatabaseLifecycleIntegrationTests {
    private static let target = "ss_lifecycle_probe"
    private static let pluginsLoaded: Void = PluginManager.shared.loadPlugins()

    init() {
        Self.pluginsLoaded
    }

    @Test(
        "PostgreSQL: drop, recreate and create keep the sidebar in sync",
        .enabled(if: LifecycleServer.postgres != nil, "DATABASE_LIFECYCLE_POSTGRES_URL is not set")
    )
    func postgresLifecycle() async throws {
        let server = try #require(LifecycleServer.postgres)
        try await runLifecycle(on: server, schema: "public") { _ in
            var seedConnection = server.connection
            seedConnection.database = Self.target
            let seed = try await DatabaseDriverFactory.createDriver(
                for: seedConnection, passwordOverride: server.password, awaitPlugins: true
            )
            try await seed.connect()
            _ = try await seed.execute(query: "CREATE TABLE old_orders (id int PRIMARY KEY)")
            seed.disconnect()
        }
    }

    @Test(
        "MySQL: drop, recreate and create keep the sidebar in sync",
        .enabled(if: LifecycleServer.mysql != nil, "DATABASE_LIFECYCLE_MYSQL_URL is not set")
    )
    func mysqlLifecycle() async throws {
        let server = try #require(LifecycleServer.mysql)
        try await runLifecycle(on: server, schema: nil) { driver in
            _ = try await driver.execute(query: "CREATE TABLE `\(Self.target)`.old_orders (id int PRIMARY KEY)")
        }
    }

    private func runLifecycle(
        on server: LifecycleServer,
        schema: String?,
        seedTable: (DatabaseDriver) async throws -> Void
    ) async throws {
        let connectionId = server.connection.id
        let databaseType = server.connection.type
        let driver = try await DatabaseDriverFactory.createDriver(
            for: server.connection, passwordOverride: server.password, awaitPlugins: true
        )
        try await driver.connect()
        var session = ConnectionSession(connection: server.connection, driver: driver)
        session.status = .connected
        session.cachedPassword = server.password
        DatabaseManager.shared.injectSession(session, for: connectionId)

        let service = DatabaseTreeMetadataService.shared
        let viewModel = DatabaseSwitcherViewModel(
            connectionId: connectionId, currentDatabase: nil, databaseType: databaseType
        )
        func listedNames() -> [String] { service.databases(for: connectionId).map(\.name) }

        try? await driver.dropDatabase(name: Self.target)
        let createValues = try await defaultCreateValues(viewModel)
        try await viewModel.createDatabase(name: Self.target, values: createValues)
        try await seedTable(driver)

        await service.refreshDatabases(connectionId: connectionId, databaseType: databaseType)
        #expect(listedNames().contains(Self.target))
        await service.loadTables(connectionId: connectionId, database: Self.target, schema: schema)
        let seeded = service.tables(connectionId: connectionId, database: Self.target, schema: schema)
        #expect(seeded.map(\.name) == ["old_orders"])

        try await service.dropDatabase(
            Self.target, connectionId: connectionId, databaseType: databaseType, using: driver
        )
        #expect(!listedNames().contains(Self.target))
        let afterDrop = service.tablesLoadState(connectionId: connectionId, database: Self.target, schema: schema)
        #expect(isIdle(afterDrop))

        try await viewModel.createDatabase(name: Self.target, values: createValues)
        #expect(listedNames().contains(Self.target))

        await service.loadTables(connectionId: connectionId, database: Self.target, schema: schema)
        let recreated = service.tablesLoadState(connectionId: connectionId, database: Self.target, schema: schema)
        guard case .loaded(let tables) = recreated else {
            Issue.record("Recreated database did not load: \(recreated)")
            return
        }
        #expect(tables.isEmpty)

        try? await service.dropDatabase(
            Self.target, connectionId: connectionId, databaseType: databaseType, using: driver
        )
        await service.handleDisconnect(connectionId: connectionId)
        DatabaseManager.shared.removeSession(for: connectionId)
        driver.disconnect()
    }

    private func defaultCreateValues(_ viewModel: DatabaseSwitcherViewModel) async throws -> [String: String] {
        guard let spec = try await viewModel.loadCreateDatabaseForm() else { return [:] }
        var values: [String: String] = [:]
        for field in spec.fields {
            let (options, preferred) = Self.choices(field.kind)
            let optionValues = options.map(\.value)
            if let preferred, optionValues.contains(preferred) {
                values[field.id] = preferred
            } else if let first = optionValues.first {
                values[field.id] = first
            }
        }
        return values.filter { key, _ in
            guard let field = spec.fields.first(where: { $0.id == key }),
                  let visibility = field.visibleWhen else { return true }
            return values[visibility.fieldId] == visibility.equals
        }
    }

    private static func choices(
        _ kind: CreateDatabaseFormSpec.FieldKind
    ) -> ([CreateDatabaseFormSpec.Option], String?) {
        switch kind {
        case .picker(let options, let preferred), .searchable(let options, let preferred):
            return (options, preferred)
        }
    }

    private func isIdle<Value>(_ state: MetadataLoadState<Value>) -> Bool {
        if case .idle = state { return true }
        return false
    }
}
