//
//  DataTransferWizardModel.swift
//  TablePro
//

import Foundation
import Observation
import os
import TableProPluginKit

@MainActor @Observable
final class DataTransferWizardModel {
    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "DataTransferWizard")

    enum Step {
        case endpoints
        case tables
        case options
        case running
        case report
    }

    @MainActor @Observable
    final class EndpointSelection {
        var connectionId: UUID?
        var database: String = ""
        var schema: String?
        var databases: [String] = []
        var schemas: [String] = []
        var isLoading = false
        var errorMessage: String?
    }

    var step: Step = .endpoints
    var connections: [DatabaseConnection] = []
    let source = EndpointSelection()
    let target = EndpointSelection()

    var mode: TransferMode = .copy
    var options = TransferOptions()

    var tableItems: [ExportDatabaseItem] = []
    var tableSearch: String = ""
    var isLoadingTables = false
    var rowCounts: [String: Int] = [:]

    var preview: TransferPreview?
    var isPreparingPreview = false
    var report: TransferReport?
    var errorMessage: String?

    let service = DataTransferService()

    private var rowCountTask: Task<Void, Never>?

    // MARK: - Endpoints

    func loadConnections(preselectedScope: DatabaseScope?) async {
        connections = ConnectionStorage.shared.loadConnections()
        guard let preselectedScope else { return }
        source.connectionId = preselectedScope.connectionId
        await selectSourceConnection(preselectedScope.connectionId, preferredDatabase: preselectedScope.database)
        if let schema = preselectedScope.schema, source.schemas.contains(schema) {
            source.schema = schema
        }
    }

    func selectSourceConnection(_ connectionId: UUID?, preferredDatabase: String? = nil) async {
        target.connectionId = nil
        target.databases = []
        target.schemas = []
        await load(source, connectionId: connectionId, preferredDatabase: preferredDatabase)
        clearTableSelection()
    }

    func selectTargetConnection(_ connectionId: UUID?) async {
        await load(target, connectionId: connectionId, preferredDatabase: nil)
    }

    func selectSourceDatabase(_ database: String) async {
        source.database = database
        await loadSchemas(source)
        clearTableSelection()
    }

    func selectTargetDatabase(_ database: String) async {
        target.database = database
        await loadSchemas(target)
    }

    private func load(_ selection: EndpointSelection, connectionId: UUID?, preferredDatabase: String?) async {
        selection.connectionId = connectionId
        selection.errorMessage = nil
        selection.databases = []
        selection.schemas = []
        selection.schema = nil
        selection.database = ""
        guard let connectionId, let connection = connection(for: connectionId) else { return }

        selection.isLoading = true
        defer { selection.isLoading = false }

        do {
            try await connectIfNeeded(connection)
            selection.databases = try await databases(for: connection)
            selection.database = resolveDatabase(
                preferred: preferredDatabase,
                connection: connection,
                available: selection.databases
            )
            await loadSchemas(selection)
        } catch {
            selection.errorMessage = error.localizedDescription
            Self.logger.warning("Loading databases failed: \(error.localizedDescription)")
        }
    }

    private func loadSchemas(_ selection: EndpointSelection) async {
        selection.schemas = []
        selection.schema = nil
        guard let connectionId = selection.connectionId,
              let connection = connection(for: connectionId),
              usesSchemas(connection.type) else { return }

        do {
            let scope = DatabaseScope(connectionId: connectionId, database: selection.database, schema: nil)
            selection.schemas = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchSchemas()
            }
            let defaultSchema = PluginManager.shared.defaultSchemaName(for: connection.type)
            selection.schema = selection.schemas.first { $0 == defaultSchema } ?? selection.schemas.first
        } catch {
            selection.errorMessage = error.localizedDescription
            Self.logger.warning("Loading schemas failed: \(error.localizedDescription)")
        }
    }

    private func databases(for connection: DatabaseConnection) async throws -> [String] {
        guard usesDatabaseList(connection.type) else {
            return connection.database.isEmpty ? [] : [connection.database]
        }
        return try await DatabaseManager.shared.withBrowseMetadataDriver(connectionId: connection.id) { driver in
            try await driver.fetchDatabases()
        }
    }

    private func resolveDatabase(
        preferred: String?,
        connection: DatabaseConnection,
        available: [String]
    ) -> String {
        if let preferred, available.contains(preferred) { return preferred }
        if available.contains(connection.database) { return connection.database }
        return available.first ?? connection.database
    }

    private func connectIfNeeded(_ connection: DatabaseConnection) async throws {
        guard DatabaseManager.shared.session(for: connection.id)?.driver == nil else { return }
        try await DatabaseManager.shared.connectToSession(connection)
    }

    func connection(for id: UUID?) -> DatabaseConnection? {
        guard let id else { return nil }
        return connections.first { $0.id == id }
    }

    func usesSchemas(_ type: DatabaseType) -> Bool {
        switch PluginManager.shared.databaseGroupingStrategy(for: type) {
        case .bySchema, .hierarchicalSchema:
            return true
        case .byDatabase, .flat:
            return false
        }
    }

    func usesDatabaseList(_ type: DatabaseType) -> Bool {
        switch PluginManager.shared.databaseGroupingStrategy(for: type) {
        case .flat:
            return false
        case .byDatabase, .bySchema, .hierarchicalSchema:
            return true
        }
    }

    var sourceEndpoint: TransferEndpoint? {
        endpoint(from: source)
    }

    var targetEndpoint: TransferEndpoint? {
        endpoint(from: target)
    }

    private func endpoint(from selection: EndpointSelection) -> TransferEndpoint? {
        guard let connectionId = selection.connectionId,
              let connection = connection(for: connectionId) else { return nil }
        return TransferEndpoint(
            connectionId: connectionId,
            databaseType: connection.type,
            database: selection.database,
            schema: selection.schema
        )
    }

    /// The picker already hides a cross-engine target and a target that points
    /// at the source, but the same run also starts from the sidebar, so the
    /// service repeats both checks.
    var endpointProblem: String? {
        guard let sourceEndpoint else { return String(localized: "Choose a source connection.") }
        guard let targetEndpoint else { return String(localized: "Choose a target connection.") }
        guard sourceEndpoint.databaseType == targetEndpoint.databaseType else {
            return TransferError.differentDatabaseTypes(
                source: sourceEndpoint.databaseType.displayName,
                target: targetEndpoint.databaseType.displayName
            ).localizedDescription
        }
        guard sourceEndpoint.scope != targetEndpoint.scope else {
            return TransferError.sameEndpoint.localizedDescription
        }
        guard !service.safeModeLevel(for: targetEndpoint.connectionId).blocksAllWrites else {
            return TransferError.targetIsReadOnly.localizedDescription
        }
        return nil
    }

    func targetCandidates() -> [DatabaseConnection] {
        guard let sourceConnection = connection(for: source.connectionId) else { return [] }
        return connections.filter { $0.type == sourceConnection.type }
    }

    // MARK: - Tables

    func loadTables() async {
        guard let endpoint = sourceEndpoint else { return }
        isLoadingTables = true
        defer { isLoadingTables = false }

        do {
            let scope = endpoint.scope
            let tables = try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk) { driver in
                try await driver.fetchTables(schema: scope.schema)
            }
            let groupName = endpoint.schema ?? endpoint.database
            let items = tables
                .filter { Self.isTransferable($0.type) }
                .map { ExportTableItem(name: $0.name, databaseName: groupName, type: $0.type) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            tableItems = [ExportDatabaseItem(name: groupName, tables: items)]
            startRowCountLoad(endpoint: endpoint, tables: items.map(\.name))
        } catch {
            errorMessage = error.localizedDescription
            tableItems = []
        }
    }

    /// A view has no rows of its own to copy and no meaningful target, so the
    /// list holds tables only.
    static func isTransferable(_ type: TableInfo.TableType) -> Bool {
        switch type {
        case .table, .partitionedTable:
            return true
        case .view, .materializedView, .foreignTable, .systemTable, .externalTable:
            return false
        }
    }

    private func startRowCountLoad(endpoint: TransferEndpoint, tables: [String]) {
        rowCountTask?.cancel()
        rowCounts = [:]
        rowCountTask = Task { [weak self] in
            for table in tables {
                if Task.isCancelled { return }
                let count = try? await DatabaseManager.shared.withMetadataDriver(
                    scope: endpoint.scope,
                    workload: .bulk
                ) { driver in
                    try await driver.fetchApproximateRowCount(table: table)
                }
                guard let self, let resolved = count ?? nil else { continue }
                self.rowCounts[table] = resolved
            }
        }
    }

    var selectedTables: [TransferTableSelection] {
        tableItems
            .flatMap(\.tables)
            .filter(\.isSelected)
            .map { TransferTableSelection(table: $0.name) }
    }

    var filteredTableItems: [ExportDatabaseItem] {
        guard !tableSearch.isEmpty else { return tableItems }
        return tableItems.map { item in
            var copy = item
            copy.tables = item.tables.filter { $0.name.localizedCaseInsensitiveContains(tableSearch) }
            return copy
        }
    }

    func setAllTablesSelected(_ selected: Bool) {
        for itemIndex in tableItems.indices {
            for tableIndex in tableItems[itemIndex].tables.indices {
                tableItems[itemIndex].tables[tableIndex].isSelected = selected
            }
        }
    }

    private func clearTableSelection() {
        rowCountTask?.cancel()
        tableItems = []
        rowCounts = [:]
        preview = nil
    }

    // MARK: - Preview and run

    func loadPreview() async {
        guard let sourceEndpoint, let targetEndpoint else { return }
        isPreparingPreview = true
        errorMessage = nil
        defer { isPreparingPreview = false }
        do {
            preview = try await service.preview(
                selections: selectedTables,
                source: sourceEndpoint,
                target: targetEndpoint,
                mode: mode,
                options: options
            )
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    func start() async {
        guard let sourceEndpoint, let targetEndpoint else { return }
        rowCountTask?.cancel()
        step = .running
        errorMessage = nil
        do {
            report = try await service.transfer(
                selections: selectedTables,
                source: sourceEndpoint,
                target: targetEndpoint,
                mode: mode,
                options: options
            )
            step = .report
        } catch {
            errorMessage = error.localizedDescription
            step = .options
        }
    }

    func cancelRun() {
        service.cancel()
    }

    func tearDown() {
        rowCountTask?.cancel()
        rowCountTask = nil
    }
}
