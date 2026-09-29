//
//  DatabaseManager+ScopedDriver.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Where an operation bound to a `DatabaseScope` runs.
enum ScopedDriverRoute: Equatable {
    /// The connection's one shared driver, moved onto the scope first.
    case sessionDriver
    /// A pooled connection already sitting on the scope's database.
    case pooled
    case databaseSession
    case unavailable(String)
}

extension DatabaseManager {
    /// A metadata read needs no transaction, no temp tables and no cancellation handle,
    /// so it takes a pooled connection and leaves the shared driver where it is.
    func metadataRoute(for scope: DatabaseScope) -> ScopedDriverRoute {
        guard let session = activeSessions[scope.connectionId] else {
            return .unavailable(String(localized: "Not connected to database"))
        }
        guard !scope.isServerScoped else { return .sessionDriver }
        return canPool(session) ? .pooled : .sessionDriver
    }

    func executionRoute(for scope: DatabaseScope) -> ScopedDriverRoute {
        guard let session = activeSessions[scope.connectionId] else {
            return .unavailable(String(localized: "Not connected to database"))
        }
        guard !scope.isServerScoped, requiresDatabaseSession(scope.database, for: scope.connectionId) else {
            return .sessionDriver
        }
        guard canPool(session) else {
            return .unavailable(
                String(
                    format: String(
                        localized: "%@ can only work with one database at a time. %@ is not its default database."
                    ),
                    session.connection.type.rawValue,
                    scope.database
                )
            )
        }
        guard isDatabaseOpen(scope.database, for: scope.connectionId) else {
            return .unavailable(
                String(format: String(localized: "Open %@ in the sidebar to run this tab."), scope.database)
            )
        }
        return .databaseSession
    }

    /// MCP never opens a database in the user's sidebar, so a database the user has not opened
    /// runs on a pooled connection: it shares no transaction with the user's tabs.
    func externalExecutionRoute(for scope: DatabaseScope) -> ScopedDriverRoute {
        let route = executionRoute(for: scope)
        guard case .unavailable = route,
              let session = activeSessions[scope.connectionId],
              requiresDatabaseSession(scope.database, for: scope.connectionId),
              canPool(session) else { return route }
        return .pooled
    }

    func withScopedDriver<T: Sendable>(
        scope: DatabaseScope,
        route: ScopedDriverRoute,
        workload: MetadataConnectionPool.Workload = .interactive,
        tracksCancellation: Bool = false,
        owner: UUID? = nil,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        let leased: @Sendable (DatabaseDriver) async throws -> T
        if tracksCancellation {
            let connectionId = scope.connectionId
            let token = UUID()
            leased = { driver in
                await MainActor.run {
                    DatabaseManager.shared.runningDrivers[connectionId, default: [:]][token] = RunningDriver(
                        driver: driver,
                        owner: owner
                    )
                }
                do {
                    let value = try await body(driver)
                    await MainActor.run { DatabaseManager.shared.releaseRunningDriver(token, for: connectionId) }
                    return value
                } catch {
                    await MainActor.run { DatabaseManager.shared.releaseRunningDriver(token, for: connectionId) }
                    throw error
                }
            }
        } else {
            leased = body
        }

        switch route {
        case .unavailable(let message):
            throw DatabaseError.queryFailed(message)
        case .pooled:
            return try await MetadataConnectionPool.shared.withDriver(
                scope: scope, workload: workload, leased
            )
        case .databaseSession:
            return try await withDatabaseSessionDriver(scope: scope, leased)
        case .sessionDriver:
            return try await withPinnedSessionDriver(scope: scope, leased)
        }
    }

    func releaseRunningDriver(_ token: UUID, for connectionId: UUID) {
        runningDrivers[connectionId]?.removeValue(forKey: token)
        if runningDrivers[connectionId]?.isEmpty == true {
            runningDrivers.removeValue(forKey: connectionId)
        }
    }

    func cancelRunningQuery(for connectionId: UUID, owner: UUID? = nil) throws {
        let running = Array((runningDrivers[connectionId] ?? [:]).values)
        guard !running.isEmpty else {
            guard owner == nil else { return }
            try driver(for: connectionId)?.cancelQuery()
            return
        }
        for entry in running where owner == nil || entry.owner == owner {
            try entry.driver.cancelQuery()
        }
    }

    private func withDatabaseSessionDriver<T: Sendable>(
        scope: DatabaseScope,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        let key = ConnectionDatabaseKey(connectionId: scope.connectionId, database: scope.database)
        let databaseType = activeSessions[scope.connectionId]?.connection.type
        return try await databaseDriverGate.withExclusiveAccess(key) {
            try Task.checkCancellation()
            guard isDatabaseOpen(scope.database, for: scope.connectionId) else {
                throw DatabaseError.queryFailed(
                    String(format: String(localized: "Open %@ in the sidebar to run this tab."), scope.database)
                )
            }
            let driver = try await openDatabaseSession(scope.database, for: scope.connectionId)
            let schema = scope.schema ?? databaseType.map { pluginManager.defaultSchemaName(for: $0) }
            if let schema, !schema.isEmpty,
               let schemaDriver = driver as? SchemaSwitchable,
               schemaDriver.currentSchema != schema {
                try await schemaDriver.switchSchema(to: schema)
            }
            return try await body(driver)
        }
    }

    /// A pooled connection is keyed by database, so one that rewrites the connection's
    /// database field to reach it would authenticate as a different identity, and one
    /// whose database comes from a connection field rather than the database field would
    /// silently serve the wrong database entirely.
    func canPool(_ session: ConnectionSession) -> Bool {
        guard session.connection.type.supportsConnectionPooling else { return false }
        let actions = PluginMetadataRegistry.shared.snapshot(
            forTypeId: session.connection.type.pluginTypeId
        )?.postConnectActions ?? []
        return !actions.contains { action in
            if case .selectDatabaseFromConnectionField = action { return true }
            return false
        }
    }

    private func withPinnedSessionDriver<T: Sendable>(
        scope: DatabaseScope,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await sessionDriverGate.withExclusiveAccess(scope.connectionId) {
            try await trackOperation(sessionId: scope.connectionId) {
                try Task.checkCancellation()
                guard let driver = driver(for: scope.connectionId) else {
                    throw DatabaseError.notConnected
                }
                try await pin(driver, to: scope)
                return try await body(driver)
            }
        }
    }

    /// Moves the shared driver onto the scope. It writes no session state, so the
    /// sidebar and the toolbar do not follow a tab's operation.
    ///
    /// The database switch is issued every time because nothing tracks where the driver
    /// actually is: a reconnect, a Redis SELECT, another window, or a user typing
    /// `USE other` all move it. The schema switch asks the driver, which does know.
    ///
    /// This runs inside the gate, so an engine that cannot move a live connection is
    /// re-checked here rather than trusting the route the caller computed before it
    /// queued. A failed pin throws before the body runs, so a statement never lands on
    /// the wrong database.
    private func pin(_ driver: DatabaseDriver, to scope: DatabaseScope) async throws {
        guard let session = activeSessions[scope.connectionId] else {
            throw DatabaseError.notConnected
        }
        let databaseType = session.connection.type
        if !scope.isServerScoped, pluginManager.supportsDatabaseSwitching(for: databaseType) {
            if pluginManager.requiresReconnectForDatabaseSwitch(for: databaseType) {
                guard scope.database == session.resolvedBrowseDatabase else {
                    throw DatabaseError.queryFailed(
                        String(
                            format: String(
                                localized: "This tab is on %@. Switch the connection to that database to run it."
                            ),
                            scope.database
                        )
                    )
                }
            } else if let adapter = driver as? PluginDriverAdapter {
                try await adapter.switchDatabase(to: scope.database)
            }
        }
        guard let schema = scope.schema,
              let schemaDriver = driver as? SchemaSwitchable,
              schemaDriver.currentSchema != schema else {
            return
        }
        try await schemaDriver.switchSchema(to: schema)
    }
}
