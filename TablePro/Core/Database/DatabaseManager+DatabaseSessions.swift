//
//  DatabaseManager+DatabaseSessions.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

struct RunningDriver {
    let driver: DatabaseDriver
    let owner: UUID?
}

struct DatabaseOpenRegistry {
    private var generations: [ConnectionDatabaseKey: Int] = [:]
    private var inFlight: [ConnectionDatabaseKey: Task<DatabaseDriver, Error>] = [:]
    private var lastGeneration = 0

    mutating func reserve(_ key: ConnectionDatabaseKey) -> Int {
        lastGeneration += 1
        generations[key] = lastGeneration
        return lastGeneration
    }

    mutating func attach(_ task: Task<DatabaseDriver, Error>, generation: Int, for key: ConnectionDatabaseKey) {
        guard generations[key] == generation else {
            task.cancel()
            return
        }
        inFlight[key] = task
    }

    func task(for key: ConnectionDatabaseKey) -> Task<DatabaseDriver, Error>? {
        inFlight[key]
    }

    func isCurrent(_ generation: Int, for key: ConnectionDatabaseKey) -> Bool {
        generations[key] == generation
    }

    mutating func finish(_ generation: Int, for key: ConnectionDatabaseKey) {
        guard generations[key] == generation else { return }
        inFlight.removeValue(forKey: key)
    }

    mutating func invalidate(_ key: ConnectionDatabaseKey) {
        generations.removeValue(forKey: key)
        inFlight.removeValue(forKey: key)?.cancel()
    }

    func keys(for connectionId: UUID) -> [ConnectionDatabaseKey] {
        generations.keys.filter { $0.connectionId == connectionId }
    }
}

extension DatabaseManager {
    static let databaseSessionLogger = Logger(subsystem: "com.SchemaStudio", category: "DatabaseSessions")
    static let databaseSessionSoftCap = 8

    func requiresDatabaseSession(_ database: String, for connectionId: UUID) -> Bool {
        guard let session = activeSessions[connectionId], !database.isEmpty else { return false }
        let type = session.connection.type
        guard pluginManager.supportsDatabaseSwitching(for: type),
              pluginManager.requiresReconnectForDatabaseSwitch(for: type) else { return false }
        return database != session.resolvedBrowseDatabase
    }

    func canOpenDatabaseSession(for connectionId: UUID) -> Bool {
        guard let session = activeSessions[connectionId] else { return false }
        return canPool(session)
    }

    func databaseDriver(for database: String, connectionId: UUID) -> DatabaseDriver? {
        databaseDrivers[ConnectionDatabaseKey(connectionId: connectionId, database: database)]
    }

    func databaseDriverCount(for connectionId: UUID) -> Int {
        databaseDrivers.keys.filter { $0.connectionId == connectionId }.count
    }

    @discardableResult
    func openDatabaseSession(_ database: String, for connectionId: UUID) async throws -> DatabaseDriver {
        let key = ConnectionDatabaseKey(connectionId: connectionId, database: database)
        if let existing = databaseDrivers[key], existing.status == .connected {
            return existing
        }
        if let pending = databaseSessionOpens.task(for: key) {
            let driver = try await pending.value
            guard databaseDrivers[key] === driver else { throw CancellationError() }
            return driver
        }
        guard let session = activeSessions[connectionId] else { throw DatabaseError.notConnected }
        guard canPool(session) else {
            throw DatabaseError.queryFailed(
                String(
                    format: String(localized: "%@ can only work with one database at a time. %@ is not its default database."),
                    session.connection.type.rawValue,
                    database
                )
            )
        }

        let connectedAt = session.connectedAt
        let scope = DatabaseScope(connectionId: connectionId, database: database, schema: nil)
        let opener = databaseDriverOpener
        let generation = databaseSessionOpens.reserve(key)
        let task = Task { @MainActor [weak self] () throws -> DatabaseDriver in
            let driver = try await opener(scope)
            guard let self else {
                driver.disconnect()
                throw CancellationError()
            }
            return try self.adoptDatabaseDriver(driver, for: key, generation: generation, connectedAt: connectedAt)
        }
        databaseSessionOpens.attach(task, generation: generation, for: key)
        defer { databaseSessionOpens.finish(generation, for: key) }

        return try await task.value
    }

    private func adoptDatabaseDriver(
        _ driver: DatabaseDriver,
        for key: ConnectionDatabaseKey,
        generation: Int,
        connectedAt: Date
    ) throws -> DatabaseDriver {
        guard databaseSessionOpens.isCurrent(generation, for: key),
              activeSessions[key.connectionId]?.connectedAt == connectedAt else {
            driver.disconnect()
            Self.databaseSessionLogger.info(
                "Discarded a late database driver for \(key.database, privacy: .public) on \(key.connectionId, privacy: .public)"
            )
            throw CancellationError()
        }
        databaseDrivers[key]?.disconnect()
        databaseDrivers[key] = driver
        logDatabaseSessionCount(for: key.connectionId, opened: key.database)
        return driver
    }

    func closeDatabaseSession(_ database: String, for connectionId: UUID) {
        let key = ConnectionDatabaseKey(connectionId: connectionId, database: database)
        databaseSessionOpens.invalidate(key)
        guard let driver = databaseDrivers.removeValue(forKey: key) else { return }
        databaseDriverGate.drain(connectionId: key)
        driver.disconnect()
        Self.databaseSessionLogger.info(
            "Closed database driver for \(database, privacy: .public) on \(connectionId, privacy: .public)"
        )
    }

    func closeAllDatabaseSessions(for connectionId: UUID) {
        let keys = Set(databaseDrivers.keys.filter { $0.connectionId == connectionId })
            .union(databaseSessionOpens.keys(for: connectionId))
        for key in keys {
            closeDatabaseSession(key.database, for: connectionId)
        }
    }

    func isDatabaseSessionBusy(_ database: String, for connectionId: UUID) -> Bool {
        guard let driver = databaseDriver(for: database, connectionId: connectionId) else { return false }
        return (runningDrivers[connectionId] ?? [:]).values.contains { $0.driver === driver }
    }

    func rebuildDatabaseSessions(for connectionId: UUID) {
        closeAllDatabaseSessions(for: connectionId)
        for database in openDatabases(for: connectionId) where requiresDatabaseSession(database, for: connectionId) {
            Task { @MainActor in
                do {
                    try await self.openDatabaseSession(database, for: connectionId)
                } catch {
                    Self.databaseSessionLogger.warning(
                        "Rebuilding the driver for \(database, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    func pingDatabaseSessions(for connectionId: UUID) async {
        let drivers = databaseDrivers.filter { $0.key.connectionId == connectionId }
        for (key, driver) in drivers {
            do {
                _ = try await databaseDriverGate.withExclusiveAccessIfIdle(key) {
                    try await driver.ping()
                }
            } catch {
                Self.databaseSessionLogger.warning(
                    "Ping failed for \(key.database, privacy: .public), rebuilding its driver"
                )
                closeDatabaseSession(key.database, for: connectionId)
                guard isDatabaseOpen(key.database, for: connectionId) else { continue }
                _ = try? await openDatabaseSession(key.database, for: connectionId)
            }
        }
    }

    private func logDatabaseSessionCount(for connectionId: UUID, opened database: String) {
        let count = databaseDriverCount(for: connectionId)
        Self.databaseSessionLogger.info(
            "Opened database driver for \(database, privacy: .public) on \(connectionId, privacy: .public), \(count) open"
        )
        guard count > Self.databaseSessionSoftCap else { return }
        Self.databaseSessionLogger.warning(
            "\(count) databases are open on \(connectionId, privacy: .public), each holding its own server connection"
        )
    }
}
