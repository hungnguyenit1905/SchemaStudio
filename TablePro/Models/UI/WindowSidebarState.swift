//
//  WindowSidebarState.swift
//  TablePro
//

import Foundation
import Observation
import TableProPluginKit

struct ConnectionDatabaseKey: Hashable, Sendable, Codable {
    let connectionId: UUID
    let database: String
}

struct ConnectionSchemaKey: Hashable, Sendable, Codable {
    let connectionId: UUID
    let database: String
    let schema: String
}

struct ConnectionTableKey: Hashable, Sendable, Codable {
    let connectionId: UUID
    let database: String
    let schema: String?
    let table: String
}

@MainActor
@Observable
internal final class WindowSidebarState {
    @ObservationIgnored private let connectionId: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoaded = false

    var selectedTables: Set<DatabaseTreeTableRef> = []

    var selectedScope: SidebarScope?
    var expandedTreeSchemas: Set<String> = [] { didSet { persistExpansion() } }
    var expandedTreeDatabases: Set<ConnectionDatabaseKey> = [] { didSet { persistExpansion() } }
    var expandedTreeDatabaseSchemas: Set<ConnectionSchemaKey> = [] { didSet { persistExpansion() } }
    var expandedTreeTables: Set<ConnectionTableKey> = [] { didSet { persistExpansion() } }

    init(connectionId: UUID? = nil, defaults: UserDefaults = .standard) {
        self.connectionId = connectionId
        self.defaults = defaults
        loadExpansion()
        isLoaded = true
    }

    private struct PersistedExpansion: Codable {
        var schemas: [String]
        var databases: [ConnectionDatabaseKey]
        var databaseSchemas: [ConnectionSchemaKey]
        var tables: [ConnectionTableKey]
    }

    private var storageKey: String? {
        connectionId.map { "com.SchemaStudio.sidebar.treeExpansion.\($0.uuidString)" }
    }

    private func loadExpansion() {
        guard let storageKey,
              let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(PersistedExpansion.self, from: data) else { return }
        expandedTreeSchemas = Set(decoded.schemas)
        expandedTreeDatabases = Set(decoded.databases)
        expandedTreeDatabaseSchemas = Set(decoded.databaseSchemas)
        expandedTreeTables = Set(decoded.tables)
    }

    private func persistExpansion() {
        guard isLoaded, let storageKey else { return }

        if expandedTreeSchemas.isEmpty, expandedTreeDatabases.isEmpty,
           expandedTreeDatabaseSchemas.isEmpty, expandedTreeTables.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }

        let snapshot = PersistedExpansion(
            schemas: Array(expandedTreeSchemas),
            databases: Array(expandedTreeDatabases),
            databaseSchemas: Array(expandedTreeDatabaseSchemas),
            tables: Array(expandedTreeTables)
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
