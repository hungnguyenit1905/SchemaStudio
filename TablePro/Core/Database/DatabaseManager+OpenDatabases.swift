//
//  DatabaseManager+OpenDatabases.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

extension DatabaseManager {
    func openDatabases(for connectionId: UUID) -> Set<String> {
        guard let session = activeSessions[connectionId] else { return [] }
        guard DatabaseLevel.live.hasDatabaseLevel(session.connection.type) else { return [] }
        return session.openDatabases.union(defaultOpenDatabase(of: session).map { [$0] } ?? [])
    }

    func isDatabaseOpen(_ database: String, for connectionId: UUID) -> Bool {
        guard let session = activeSessions[connectionId] else { return false }
        guard DatabaseLevel.live.hasDatabaseLevel(session.connection.type) else { return session.isConnected }
        return openDatabases(for: connectionId).contains(database)
    }

    func isDefaultDatabase(_ database: String, for connectionId: UUID) -> Bool {
        guard let session = activeSessions[connectionId] else { return false }
        return defaultOpenDatabase(of: session) == database
    }

    func markDatabaseOpen(_ database: String, for connectionId: UUID) async throws {
        guard let session = activeSessions[connectionId] else { throw DatabaseError.notConnected }
        guard DatabaseLevel.live.hasDatabaseLevel(session.connection.type), !database.isEmpty else { return }
        if requiresDatabaseSession(database, for: connectionId) {
            try await openDatabaseSession(database, for: connectionId)
        }
        guard activeSessions[connectionId]?.openDatabases.contains(database) == false else { return }
        updateSession(connectionId) { $0.openDatabases.insert(database) }
    }

    @discardableResult
    func markDatabaseClosed(_ database: String, for connectionId: UUID) -> Bool {
        guard let session = activeSessions[connectionId] else { return false }
        guard defaultOpenDatabase(of: session) != database else { return false }
        closeDatabaseSession(database, for: connectionId)
        guard session.openDatabases.contains(database) else { return false }
        updateSession(connectionId) { $0.openDatabases.remove(database) }
        return true
    }

    func closeDatabase(_ database: String, for connectionId: UUID, force: Bool = false) async throws {
        guard !isDefaultDatabase(database, for: connectionId) else {
            throw DatabaseError.queryFailed(
                String(format: String(localized: "%@ is the connection's default database and stays open."), database)
            )
        }
        guard force || !isDatabaseSessionBusy(database, for: connectionId) else {
            throw DatabaseError.queryFailed(
                String(format: String(localized: "A query is still running on %@. Stop it first."), database)
            )
        }
        markDatabaseClosed(database, for: connectionId)
        MetadataConnectionPool.shared.closeAll(connectionId: connectionId, database: database)
        await MetadataConnectionPool.shared.waitUntilIdle(connectionId: connectionId, database: database)
        await DatabaseTreeMetadataService.shared.closeDatabase(connectionId: connectionId, database: database)
    }

    func autoOpenDatabases(for connectionId: UUID) -> [String] {
        guard let session = activeSessions[connectionId],
              DatabaseLevel.live.hasDatabaseLevel(session.connection.type) else { return [] }
        let settings = connectionStorage.loadConnection(id: connectionId)?.databaseListSettings
            ?? session.connection.databaseListSettings
        return settings?.databasesToAutoOpen(defaultDatabase: session.resolvedBrowseDatabase) ?? []
    }

    func openAutoOpenDatabases(for connectionId: UUID) {
        for database in autoOpenDatabases(for: connectionId) {
            Task { @MainActor in
                do {
                    try await markDatabaseOpen(database, for: connectionId)
                } catch {
                    Self.logger.warning(
                        "Auto Open of \(database, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    func seedOpenDatabases(_ session: inout ConnectionSession) {
        guard DatabaseLevel.live.hasDatabaseLevel(session.connection.type),
              let database = defaultOpenDatabase(of: session) else {
            session.openDatabases = []
            return
        }
        session.openDatabases.insert(database)
    }

    private func defaultOpenDatabase(of session: ConnectionSession) -> String? {
        let database = session.resolvedBrowseDatabase
        return database.isEmpty ? nil : database
    }
}
