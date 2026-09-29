//
//  SidebarNodeContext.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Everything the tree needs to know about the connection a node belongs to.
/// The sidebar spans every saved connection, so none of this may be read from
/// the window the tree happens to live in.
struct SidebarNodeContext: Equatable {
    let connectionId: UUID
    let databaseType: DatabaseType
    let groupingStrategy: GroupingStrategy
    let systemSchemas: Set<String>
    let safeModeLevel: SafeModeLevel
    let status: ConnectionStatus

    var hasDatabaseLevel = false

    var supportsSchemaLevel: Bool {
        groupingStrategy == .bySchema
    }

    var listsSchemasUnderDatabase: Bool {
        groupingStrategy == .bySchema || (hasDatabaseLevel && groupingStrategy == .hierarchicalSchema)
    }

    var isConnected: Bool {
        status.isConnected
    }
}

/// Resolves a node's connection context. Every dependency is injected so the
/// resolution rules can be tested without a live session or plugin registry.
@MainActor
struct SidebarNodeContextResolver {
    var connection: (UUID) -> DatabaseConnection?
    var session: (UUID) -> ConnectionSession?
    var groupingStrategy: (DatabaseType) -> GroupingStrategy
    var systemSchemas: (DatabaseType) -> Set<String>
    var hasDatabaseLevel: (DatabaseType) -> Bool = { _ in false }

    static var live: SidebarNodeContextResolver {
        SidebarNodeContextResolver(
            connection: { id in
                DatabaseManager.shared.activeSessions[id]?.connection
                    ?? ConnectionStorage.shared.loadConnection(id: id)
            },
            session: { DatabaseManager.shared.activeSessions[$0] },
            groupingStrategy: { PluginManager.shared.databaseGroupingStrategy(for: $0) },
            systemSchemas: { Set(PluginManager.shared.systemSchemaNames(for: $0)) },
            hasDatabaseLevel: { DatabaseLevel.live.hasDatabaseLevel($0) }
        )
    }

    /// A connection that is not connected still resolves: the tree shows saved
    /// connections before any session exists. Safe mode falls back to the saved
    /// connection's own level so a write action is never offered against a
    /// read-only connection just because no session has been created yet.
    func context(for connectionId: UUID) -> SidebarNodeContext? {
        guard let connection = connection(connectionId) else { return nil }
        let liveSession = session(connectionId)
        let type = connection.type
        return SidebarNodeContext(
            connectionId: connectionId,
            databaseType: type,
            groupingStrategy: groupingStrategy(type),
            systemSchemas: systemSchemas(type),
            safeModeLevel: liveSession?.safeModeLevel ?? connection.safeModeLevel,
            status: liveSession?.status ?? .disconnected,
            hasDatabaseLevel: hasDatabaseLevel(type)
        )
    }
}
