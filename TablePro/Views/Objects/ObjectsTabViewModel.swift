//
//  ObjectsTabViewModel.swift
//  TablePro
//

import Foundation
import Observation
import TableProPluginKit

@MainActor
@Observable
final class ObjectsTabViewModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case tables
        case views
        case functions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return String(localized: "All")
            case .tables: return String(localized: "Tables")
            case .views: return String(localized: "Views")
            case .functions: return String(localized: "Functions")
            }
        }
    }

    enum RowKind: Hashable {
        case database
        case schema
        case table(TableInfo)
        case routine(RoutineInfo)
    }

    struct Row: Identifiable, Hashable {
        let id: String
        let name: String
        let kind: RowKind
        let typeName: String
        let rowCount: Int?
        let size: String?
        let comment: String?

        var sortableRowCount: Int { rowCount ?? -1 }
        var sortableSize: String { size ?? "" }
        var sortableComment: String { comment ?? "" }
    }

    enum Content: Equatable {
        case rows([Row])
        case loading
        case closed(database: String)
        case failed(String)
        case nothing
    }

    let connectionId: UUID
    let windowState: WindowSidebarState
    let fallbackScope: SidebarScope
    var filter: Filter = .all

    @ObservationIgnored private let service: DatabaseTreeMetadataService
    @ObservationIgnored private let manager: DatabaseManager
    @ObservationIgnored private let contextResolver: SidebarNodeContextResolver

    init(
        connectionId: UUID,
        windowState: WindowSidebarState,
        fallbackScope: SidebarScope,
        contextResolver: SidebarNodeContextResolver? = nil
    ) {
        self.connectionId = connectionId
        self.windowState = windowState
        self.fallbackScope = fallbackScope
        self.service = .shared
        self.manager = .shared
        self.contextResolver = contextResolver ?? .live
    }

    var scope: SidebarScope {
        windowState.selectedScope ?? fallbackScope
    }

    var scopeTitle: String {
        let connectionName = contextResolver.connection(scope.connectionId)?.name ?? ""
        return [connectionName, scope.database, scope.schema].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var content: Content {
        let scope = scope
        guard let context = contextResolver.context(for: scope.connectionId), context.isConnected else {
            return .nothing
        }
        guard let database = scope.database ?? containerDatabase(context) else {
            return databaseRows(context)
        }
        guard manager.isDatabaseOpen(database, for: scope.connectionId) else {
            return .closed(database: database)
        }
        if scope.schema == nil, context.listsSchemasUnderDatabase {
            return schemaRows(database: database)
        }
        return objectRows(database: database, schema: scope.schema)
    }

    func loadIfNeeded() {
        let scope = scope
        guard let context = contextResolver.context(for: scope.connectionId), context.isConnected else { return }
        guard let database = scope.database ?? containerDatabase(context) else {
            if case .idle = service.databaseListState(for: scope.connectionId) {
                Task { await service.loadDatabases(connectionId: scope.connectionId, databaseType: context.databaseType) }
            }
            return
        }
        guard manager.isDatabaseOpen(database, for: scope.connectionId) else { return }
        if scope.schema == nil, context.listsSchemasUnderDatabase {
            if case .idle = service.schemaListState(connectionId: scope.connectionId, database: database) {
                Task { await service.loadSchemas(connectionId: scope.connectionId, database: database) }
            }
            return
        }
        let schema = scope.schema
        if case .idle = service.tablesLoadState(connectionId: scope.connectionId, database: database, schema: schema) {
            Task { await service.loadTables(connectionId: scope.connectionId, database: database, schema: schema) }
        }
        if case .idle = service.routinesLoadState(connectionId: scope.connectionId, database: database, schema: schema) {
            Task { await service.loadRoutines(connectionId: scope.connectionId, database: database, schema: schema) }
        }
    }

    func openDatabase() {
        guard case .closed(let database) = content else { return }
        let connectionId = scope.connectionId
        Task { @MainActor in
            try? await manager.markDatabaseOpen(database, for: connectionId)
            loadIfNeeded()
        }
    }

    func drillScope(for row: Row) -> SidebarScope? {
        switch row.kind {
        case .database:
            return SidebarScope(connectionId: scope.connectionId, database: row.name)
        case .schema:
            return SidebarScope(connectionId: scope.connectionId, database: scope.database, schema: row.name)
        case .table, .routine:
            return nil
        }
    }

    func tableRef(for row: Row) -> DatabaseTreeTableRef? {
        guard case .table(let table) = row.kind,
              let context = contextResolver.context(for: scope.connectionId),
              let database = scope.database ?? containerDatabase(context) else { return nil }
        return DatabaseTreeTableRef(
            connectionId: scope.connectionId,
            database: database,
            schema: scope.schema ?? table.schema,
            table: table
        )
    }

    private func containerDatabase(_ context: SidebarNodeContext) -> String? {
        guard !context.hasDatabaseLevel else { return nil }
        return manager.session(for: context.connectionId)?.resolvedBrowseDatabase
    }

    private func databaseRows(_ context: SidebarNodeContext) -> Content {
        switch service.databaseListState(for: context.connectionId) {
        case .idle, .loading:
            return .loading
        case .failed(let message):
            return .failed(message)
        case .loaded:
            let defaultDatabase = manager.session(for: context.connectionId)?.resolvedBrowseDatabase
            let visible = DatabaseTreeVisibility.visible(
                databases: service.databases(for: context.connectionId),
                selected: SharedSidebarState.forConnection(context.connectionId).databaseFilterSelected,
                alwaysShown: defaultDatabase,
                showsHiddenItems: AppSettingsManager.shared.general.showHiddenItems
            )
            return .rows(visible.map { metadata in
                Row(
                    id: "db\u{1}\(metadata.name)",
                    name: metadata.name,
                    kind: .database,
                    typeName: PluginManager.shared.containerEntityName(for: context.databaseType),
                    rowCount: metadata.tableCount,
                    size: metadata.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                    comment: nil
                )
            })
        }
    }

    private func schemaRows(database: String) -> Content {
        switch service.schemaListState(connectionId: scope.connectionId, database: database) {
        case .idle, .loading:
            return .loading
        case .failed(let message):
            return .failed(message)
        case .loaded(let schemas):
            return .rows(schemas.map { schema in
                Row(
                    id: "schema\u{1}\(schema)",
                    name: schema,
                    kind: .schema,
                    typeName: String(localized: "Schema"),
                    rowCount: nil,
                    size: nil,
                    comment: nil
                )
            })
        }
    }

    private func objectRows(database: String, schema: String?) -> Content {
        let connectionId = scope.connectionId
        switch service.tablesLoadState(connectionId: connectionId, database: database, schema: schema) {
        case .idle, .loading:
            return .loading
        case .failed(let message):
            return .failed(message)
        case .loaded:
            break
        }
        let tables = service.tables(connectionId: connectionId, database: database, schema: schema)
            .filter { matches(table: $0) }
            .map { table in
                Row(
                    id: "table\u{1}\(table.id)",
                    name: table.name,
                    kind: .table(table),
                    typeName: table.type.rawValue.capitalized,
                    rowCount: table.rowCount,
                    size: nil,
                    comment: table.comment
                )
            }
        let routines = filter == .all || filter == .functions
            ? service.routines(connectionId: connectionId, database: database, schema: schema).map { routine in
                Row(
                    id: "routine\u{1}\(routine.id)",
                    name: routine.name,
                    kind: .routine(routine),
                    typeName: routine.kind.rawValue.capitalized,
                    rowCount: nil,
                    size: nil,
                    comment: nil
                )
            }
            : []
        return .rows(tables + routines)
    }

    private func matches(table: TableInfo) -> Bool {
        switch filter {
        case .all:
            return true
        case .tables:
            return table.type == .table || table.type == .partitionedTable
                || table.type == .systemTable || table.type == .externalTable || table.type == .foreignTable
        case .views:
            return table.type == .view || table.type == .materializedView
        case .functions:
            return false
        }
    }
}
