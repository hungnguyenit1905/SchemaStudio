import Foundation
import TableProPluginKit

extension PluginPrivilegeScope {
    enum Level: Int, Comparable {
        case server
        case database
        case schema
        case table
        case column

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var level: Level {
        switch self {
        case .server: .server
        case .database: .database
        case .schema: .schema
        case .table: .table
        case .column: .column
        }
    }

    var persistentKey: String {
        switch self {
        case .server:
            "server"
        case .database(let name):
            "db:\(name)"
        case .schema(let database, let schema):
            "db:\(database)/schema:\(schema)"
        case .table(let database, let schema, let table):
            schema.map { "db:\(database)/schema:\($0)/table:\(table)" }
                ?? "db:\(database)/table:\(table)"
        case .column(let database, let schema, let table, let column):
            schema.map { "db:\(database)/schema:\($0)/table:\(table)/column:\(column)" }
                ?? "db:\(database)/table:\(table)/column:\(column)"
        }
    }

    var displayPath: String {
        switch self {
        case .server:
            String(localized: "Server")
        case .database(let name):
            name
        case .schema(let database, let schema):
            "\(database) › \(schema)"
        case .table(let database, let schema, let table):
            schema.map { "\(database) › \($0) › \(table)" } ?? "\(database) › \(table)"
        case .column(let database, let schema, let table, let column):
            schema.map { "\(database) › \($0) › \(table) › \(column)" }
                ?? "\(database) › \(table) › \(column)"
        }
    }

    var displayName: String {
        switch self {
        case .server:
            String(localized: "Server")
        case .database(let name):
            name
        case .schema(_, let schema):
            schema
        case .table(_, _, let table):
            table
        case .column(_, _, _, let column):
            column
        }
    }

    var symbolName: String {
        switch self {
        case .server: "server.rack"
        case .database: "cylinder"
        case .schema: "folder"
        case .table: "tablecells"
        case .column: "rectangle.split.3x1"
        }
    }
}
