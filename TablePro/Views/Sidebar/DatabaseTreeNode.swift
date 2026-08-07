//
//  DatabaseTreeNode.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class DatabaseTreeNode {
    enum Status: Equatable {
        case loading
        case empty
        case error(String)
        /// An expanded connection with no session. Launch restores the shape of
        /// the tree without connecting, so this is the resting state of every
        /// remembered connection, not a transient one on the way to `.loading`.
        case disconnected

        var identifierSuffix: String {
            switch self {
            case .loading: return "loading"
            case .empty: return "empty"
            case .error: return "error"
            case .disconnected: return "disconnected"
            }
        }
    }

    enum Kind {
        case connectionRoot
        case folder(ConnectionGroup)
        case connection(DatabaseConnection)
        case recentSection(connectionId: UUID)
        case recentTable(DatabaseTreeTableRef)
        case database(connectionId: UUID, metadata: DatabaseMetadata)
        case schema(connectionId: UUID, database: String, schema: String)
        case table(DatabaseTreeTableRef)
        case routine(DatabaseTreeRoutineRef)
        case status(Status)
    }

    let id: String
    var kind: Kind

    init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    var isExpandable: Bool {
        switch kind {
        case .connectionRoot, .folder, .connection, .recentSection, .database, .schema: return true
        case .table(let ref): return ref.table.type == .partitionedTable
        case .recentTable, .routine, .status: return false
        }
    }

    var connectionId: UUID? {
        switch kind {
        case .connectionRoot, .folder, .status: return nil
        case .connection(let connection): return connection.id
        case .recentSection(let connectionId): return connectionId
        case .recentTable(let ref), .table(let ref): return ref.connectionId
        case .database(let connectionId, _): return connectionId
        case .schema(let connectionId, _, _): return connectionId
        case .routine(let ref): return ref.connectionId
        }
    }

    var tableRef: DatabaseTreeTableRef? {
        if case .table(let ref) = kind { return ref }
        return nil
    }

    var recentTableRef: DatabaseTreeTableRef? {
        if case .recentTable(let ref) = kind { return ref }
        return nil
    }

    /// A readable handle for UI tests. The node ids themselves are keyed by
    /// UUID and joined with a control character, which a test has no way to
    /// predict or type, so rows are addressed by the names the user sees.
    var accessibilityIdentifier: String {
        switch kind {
        case .connectionRoot: return "tree-root"
        case .folder(let group): return "tree-folder-\(group.name)"
        case .connection(let connection): return "tree-connection-\(connection.name)"
        case .recentSection: return "tree-recent-section"
        case .recentTable(let ref): return "tree-recent-\(ref.table.name)"
        case .database(_, let metadata): return "tree-database-\(metadata.name)"
        case .schema(_, _, let schema): return "tree-schema-\(schema)"
        case .table(let ref): return "tree-table-\(ref.table.name)"
        case .routine(let ref): return "tree-routine-\(ref.routine.name)"
        case .status(let status): return "tree-status-\(status.identifierSuffix)"
        }
    }

    static let connectionRootId = "connections-root"
    static func folderId(_ group: ConnectionGroup) -> String { "folder\u{1}\(group.id.uuidString)" }
    static func connectionNodeId(_ connectionId: UUID) -> String { "connection\u{1}\(connectionId.uuidString)" }

    static func recentSectionId(connectionId: UUID) -> String {
        "recent-section\u{1}\(connectionId.uuidString)"
    }

    static func databaseId(connectionId: UUID, database: String) -> String {
        "db\u{1}\(connectionId.uuidString)\u{1}\(database)"
    }

    static func schemaId(connectionId: UUID, database: String, schema: String) -> String {
        "schema\u{1}\(connectionId.uuidString)\u{1}\(database)\u{1}\(schema)"
    }

    static func tableId(_ ref: DatabaseTreeTableRef) -> String { "table\u{1}\(ref.id)" }
    static func recentTableId(_ ref: DatabaseTreeTableRef) -> String { "recent\u{1}table\u{1}\(ref.id)" }
    static func routineId(_ ref: DatabaseTreeRoutineRef) -> String { "routine\u{1}\(ref.id)" }
    static func statusId(parentId: String, status: Status) -> String {
        switch status {
        case .loading: return "\(parentId)\u{1}status.loading"
        case .empty: return "\(parentId)\u{1}status.empty"
        case .error: return "\(parentId)\u{1}status.error"
        case .disconnected: return "\(parentId)\u{1}status.disconnected"
        }
    }
}
