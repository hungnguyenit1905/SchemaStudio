//
//  SidebarScope.swift
//  TablePro
//

import Foundation

struct SidebarScope: Hashable, Sendable {
    let connectionId: UUID
    let database: String?
    let schema: String?

    init(connectionId: UUID, database: String? = nil, schema: String? = nil) {
        self.connectionId = connectionId
        self.database = database.flatMap { $0.isEmpty ? nil : $0 }
        self.schema = self.database == nil ? nil : schema.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func resolve(_ kind: DatabaseTreeNode.Kind) -> SidebarScope? {
        switch kind {
        case .connection(let connection):
            return SidebarScope(connectionId: connection.id)
        case .database(let connectionId, let metadata):
            return SidebarScope(connectionId: connectionId, database: metadata.name)
        case .schema(let connectionId, let database, let schema):
            return SidebarScope(connectionId: connectionId, database: database, schema: schema)
        case .table(let ref), .recentTable(let ref):
            return SidebarScope(connectionId: ref.connectionId, database: ref.database, schema: ref.schema)
        case .routine(let ref):
            return SidebarScope(connectionId: ref.connectionId, database: ref.database, schema: ref.schema)
        case .connectionRoot, .folder, .recentSection, .status:
            return nil
        }
    }

    func resolved(
        connectionExists: (UUID) -> Bool,
        isDatabaseOpen: (String, UUID) -> Bool
    ) -> SidebarScope? {
        guard connectionExists(connectionId) else { return nil }
        guard let database, !isDatabaseOpen(database, connectionId) else { return self }
        return SidebarScope(connectionId: connectionId)
    }

    func databaseScope(defaultDatabase: String) -> DatabaseScope {
        DatabaseScope(
            connectionId: connectionId,
            database: database ?? defaultDatabase,
            schema: database == nil ? nil : schema
        )
    }
}
