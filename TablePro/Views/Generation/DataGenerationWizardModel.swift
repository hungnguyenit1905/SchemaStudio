//
//  DataGenerationWizardModel.swift
//  TablePro
//

import Foundation
import Observation
import os
import TableProPluginKit

struct GenerationTableSelection: Identifiable, Sendable {
    let name: String
    var isSelected: Bool
    var rowCount: Int

    /// Parents this table points at, inside the same schema. Ticking a child whose
    /// parent is untucked cannot fill the child's keys, so the wizard offers to tick
    /// the parent rather than letting the run fail at pre-flight.
    let parents: [String]

    var id: String { name }
}

struct GenerationLogEntry: Identifiable, Sendable {
    enum Kind: Sendable {
        case info
        case warning
        case failure
    }

    let id = UUID()
    let at: Date
    let kind: Kind
    let message: String
}

@MainActor @Observable
final class DataGenerationWizardModel {
    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "DataGenerationWizard")

    enum Step {
        case scope
        case columns
        case options
        case running
        case report
    }

    var step: Step = .scope

    var connections: [DatabaseConnection] = []
    var connectionId: UUID?
    var database = ""
    var schema: String?
    var databases: [String] = []
    var schemas: [String] = []
    var isLoadingScope = false

    var tables: [GenerationTableSelection] = []
    var tableSearch = ""
    var isLoadingTables = false

    var selectedTableName: String?
    var selectedColumnName: String?

    var seedText = String(GenerationSeed.randomSeed())
    var defaultRowCountText = String(GenerationDialogStorage.shared.loadLastRowCount())
    var emptyFirst = false
    var singleTransaction = GenerationDialogStorage.shared.loadSingleTransaction()
    var continueOnError = GenerationDialogStorage.shared.loadContinueOnError()

    /// Only reaches a composite foreign key's pool: a single-column `Reference`
    /// draws from its own seeded stream and ignores the strategy entirely. It is not
    /// offered as a control for that reason, and it is set here so the preview and
    /// the run agree on it.
    var referenceStrategy: ReferencePoolStrategy = .random

    var preview: GenerationPreview?
    var isPreparingPreview = false

    var log: [GenerationLogEntry] = []
    var report: GenerationReport?
    var errorMessage: String?
    var isCancelling = false
    var rowsWritten = 0
    var totalRows = 0
    var currentTable = ""

    /// Facts read from the server, re-read at the start of every run. The profile
    /// remembers names; it never remembers shape.
    private(set) var schemaFacts: [GenerationTable] = []
    private(set) var profile = GenerationProfile(name: "generation", seed: 0, tables: [])
    private(set) var mappingWarnings: [ValidationWarning] = []

    /// Turns true once `blocksDestructiveOperations` lands on `DatabaseConnection`,
    /// which belongs to the pending destructive-operation plan. Until then nothing
    /// is gated here. It only decides whether the emptying option is *offered*: the
    /// engine refuses an emptying run on a gated connection on its own, so the UI
    /// state is an affordance and never the enforcement.
    private(set) var blocksDestructiveOperations = false

    private var engine: GenerationEngine?

    // MARK: - Scope

    func loadConnections(preselectedScope: DatabaseScope?) async {
        connections = ConnectionStorage.shared.loadConnections()
        guard let preselectedScope else { return }
        await select(connectionId: preselectedScope.connectionId, preferredDatabase: preselectedScope.database)
        if let schema = preselectedScope.schema, schemas.contains(schema) {
            self.schema = schema
            await loadTables()
        }
    }

    func select(connectionId: UUID?, preferredDatabase: String? = nil) async {
        self.connectionId = connectionId
        database = ""
        schema = nil
        databases = []
        schemas = []
        tables = []
        guard let connectionId, let connection = connection(for: connectionId) else { return }

        isLoadingScope = true
        defer { isLoadingScope = false }
        do {
            try await connectIfNeeded(connection)
            databases = try await DatabaseManager.shared.withBrowseMetadataDriver(connectionId: connectionId) { driver in
                try await driver.fetchDatabases()
            }
            database = preferredDatabase ?? databases.first ?? connection.database
            await loadSchemas()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(database: String) async {
        self.database = database
        schema = nil
        tables = []
        await loadSchemas()
    }

    func select(schema: String?) async {
        self.schema = schema
        await loadTables()
    }

    private func loadSchemas() async {
        guard let scope = currentScope else { return }
        do {
            schemas = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchSchemas()
            }
            schema = schemas.first
            await loadTables()
        } catch {
            schemas = []
            await loadTables()
        }
    }

    func loadTables() async {
        guard let scope = currentScope else { return }
        isLoadingTables = true
        defer { isLoadingTables = false }
        do {
            let listed = try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk) { driver in
                try await driver.fetchTables(schema: scope.schema)
            }
            let names = listed.filter { Self.isFillable($0.type) }.map(\.name)
            schemaFacts = try await loadSchemaFacts(tables: names, scope: scope)
            tables = Self.ordered(schemaFacts).map { table in
                GenerationTableSelection(
                    name: table.name,
                    isSelected: false,
                    rowCount: Int(defaultRowCountText) ?? 100,
                    parents: Self.parents(of: table, among: Set(names))
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            tables = []
        }
    }

    /// A view has no rows of its own, so the list holds tables only.
    static func isFillable(_ type: TableInfo.TableType) -> Bool {
        switch type {
        case .table, .partitionedTable:
            return true
        case .view, .materializedView, .foreignTable, .systemTable, .externalTable:
            return false
        }
    }

    /// The engine's own column model, assembled from what the driver reports. The
    /// wizard never queries a catalog itself.
    private func loadSchemaFacts(tables: [String], scope: DatabaseScope) async throws -> [GenerationTable] {
        guard let type = connection(for: scope.connectionId)?.type else { return [] }
        let schemaName = scope.schema
        return try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk) { driver in
            guard let adapter = driver as? PluginDriverAdapter else { return [] }
            let plugin = adapter.schemaPluginDriver
            let assembler = SchemaFactsAssembler(databaseType: type)
            var facts: [GenerationTable] = []
            for table in tables {
                facts.append(
                    assembler.assemble(
                        schema: schemaName,
                        table: table,
                        columns: try await plugin.fetchColumns(table: table, schema: schemaName),
                        foreignKeys: try await plugin.fetchForeignKeys(table: table, schema: schemaName),
                        indexes: try await plugin.fetchIndexes(table: table, schema: schemaName)
                    )
                )
            }
            return facts
        }
    }

    /// Parents first, so ticking down the list never leaves a child ahead of the
    /// table it points at. Alphabetical order would.
    static func ordered(_ facts: [GenerationTable]) -> [GenerationTable] {
        guard let order = try? DependencyResolver(canDisableConstraints: true).resolve(facts) else {
            return facts
        }
        var byReference: [GenerationTableReference: GenerationTable] = [:]
        for table in facts {
            byReference[DependencyResolver.reference(table)] = table
        }
        var ordered = order.ordered.compactMap { byReference[$0] }
        let seen = Set(ordered.map(\.name))
        ordered.append(contentsOf: facts.filter { !seen.contains($0.name) })
        return ordered
    }

    static func parents(of table: GenerationTable, among present: Set<String>) -> [String] {
        var names: [String] = []
        for key in table.foreignKeys where key.referencedTable != table.name {
            guard present.contains(key.referencedTable), !names.contains(key.referencedTable) else { continue }
            names.append(key.referencedTable)
        }
        return names
    }

    // MARK: - Selection

    var visibleTables: [GenerationTableSelection] {
        guard !tableSearch.isEmpty else { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(tableSearch) }
    }

    var selectedTableNames: [String] {
        tables.filter(\.isSelected).map(\.name)
    }

    func setSelected(_ isSelected: Bool, for name: String) {
        guard let index = tables.firstIndex(where: { $0.name == name }) else { return }
        tables[index].isSelected = isSelected
    }

    func setRowCount(_ rowCount: Int, for name: String) {
        guard let index = tables.firstIndex(where: { $0.name == name }) else { return }
        tables[index].rowCount = max(0, rowCount)
    }

    /// The parents of everything ticked that are not ticked themselves. The wizard
    /// offers to tick them rather than letting the run fail on an empty parent.
    var untickedParents: [String] {
        let selected = Set(selectedTableNames)
        var missing: [String] = []
        for table in tables where table.isSelected {
            for parent in table.parents where !selected.contains(parent) && !missing.contains(parent) {
                missing.append(parent)
            }
        }
        return missing
    }

    func tickUntickedParents() {
        for parent in untickedParents {
            setSelected(true, for: parent)
        }
    }

    // MARK: - Mapping

    /// Builds the profile the run will execute: every selected table, every column
    /// auto-mapped, warnings kept for the grid to show.
    func buildProfile() {
        let selected = Set(selectedTableNames)
        var tableProfiles: [GenerationTableProfile] = []
        var warnings: [ValidationWarning] = []

        for facts in schemaFacts where selected.contains(facts.name) {
            let rowCount = tables.first { $0.name == facts.name }?.rowCount ?? 100
            var columns: [GenerationColumnProfile] = []
            for column in facts.columns {
                let resolution = AutoMapper.resolve(column, table: facts.name)
                warnings.append(contentsOf: resolution.warnings)
                columns.append(
                    GenerationColumnProfile(
                        column: column.name,
                        generator: resolution.identifier,
                        params: resolution.params,
                        common: resolution.common
                    )
                )
            }
            tableProfiles.append(
                GenerationTableProfile(
                    schema: facts.schema,
                    table: facts.name,
                    rowCount: rowCount,
                    emptyFirst: emptyFirst && !blocksDestructiveOperations,
                    columns: columns
                )
            )
        }

        profile = GenerationProfile(
            name: database.isEmpty ? "generation" : database,
            seed: UInt64(seedText) ?? GenerationSeed.randomSeed(),
            tables: tableProfiles
        )
        mappingWarnings = warnings
        selectedTableName = tableProfiles.first?.table
        selectedColumnName = tableProfiles.first?.columns.first?.column
    }

    func columns(ofTable table: String) -> [GenerationColumnProfile] {
        profile.tables.first { $0.table == table }?.columns ?? []
    }

    func facts(ofTable table: String) -> GenerationTable? {
        schemaFacts.first { $0.name == table }
    }

    func column(_ name: String, inTable table: String) -> GenerationColumn? {
        facts(ofTable: table)?.column(named: name)
    }

    func warnings(forColumn column: String) -> [ValidationWarning] {
        mappingWarnings.filter { $0.column == column }
    }

    func setGenerator(_ identifier: String, forColumn column: String, inTable table: String) {
        update(column: column, inTable: table) { profile in
            profile.generator = identifier
            profile.params = .object(
                GeneratorRegistry.standard.paramSchema(for: identifier)?.defaults ?? [:]
            )
        }
    }

    func setParams(_ params: JSONValue, forColumn column: String, inTable table: String) {
        update(column: column, inTable: table) { $0.params = params }
    }

    func setCommon(_ common: CommonParams, forColumn column: String, inTable table: String) {
        update(column: column, inTable: table) { $0.common = common }
    }

    private func update(
        column: String,
        inTable table: String,
        _ change: (inout GenerationColumnProfile) -> Void
    ) {
        guard let tableIndex = profile.tables.firstIndex(where: { $0.table == table }) else { return }
        guard
            let columnIndex = profile.tables[tableIndex].columns.firstIndex(where: { $0.column == column })
        else { return }
        change(&profile.tables[tableIndex].columns[columnIndex])
        preview = nil
    }

    /// A column the server fills is read-only in the grid: the run leaves it out of
    /// the insert, so offering a generator for it would be a lie.
    func isReadOnly(column: String, inTable table: String) -> Bool {
        guard let column = self.column(column, inTable: table) else { return false }
        return column.isServerAssigned
    }

    // MARK: - Preview

    func loadPreview() async {
        guard let scope = currentScope, let type = connection(for: scope.connectionId)?.type else { return }
        isPreparingPreview = true
        errorMessage = nil
        defer { isPreparingPreview = false }

        let profile = profile
        let facts = schemaFacts
        let options = runOptions
        do {
            let plan = try GenerationPlanCompiler().compile(profile: profile, schema: facts)
            let previewed = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                guard
                    let generationDriver = PluginGenerationDriver(
                        driver: driver,
                        databaseType: type,
                        schema: scope.schema
                    )
                else { throw GenerationError.writeFailed(table: "", reason: "no driver") }
                return try await GenerationPreviewService(
                    driver: generationDriver,
                    truncator: GenerationStringTruncator.forVendor(TransferVendor(type)),
                    options: options
                ).preview(plan: plan)
            }
            preview = previewed
        } catch {
            preview = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    var validationErrors: [GenerationError] {
        guard !profile.tables.isEmpty else { return [] }
        return GenerationProfileValidator().validate(profile: profile, schema: schemaFacts)
    }

    var canStart: Bool {
        !profile.tables.isEmpty && validationErrors.isEmpty
    }

    // MARK: - Run

    func start() async {
        guard let scope = currentScope, let type = connection(for: scope.connectionId)?.type else { return }
        errorMessage = nil
        log = []
        report = nil
        rowsWritten = 0
        isCancelling = false
        step = .running

        let profile = profile
        let facts = schemaFacts
        let options = runOptions
        saveDialogSettings()

        do {
            let plan = try GenerationPlanCompiler().compile(profile: profile, schema: facts)
            totalRows = plan.totalRowCount
            append(.info, String(format: String(localized: "Generating %d rows."), plan.totalRowCount))
            try await run(plan: plan, scope: scope, type: type, options: options)
        } catch {
            append(.failure, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            step = .report
        }
    }

    private func run(
        plan: GenerationPlan,
        scope: DatabaseScope,
        type: DatabaseType,
        options: GenerationRunOptions
    ) async throws {
        let blocked = blocksDestructiveOperations
        try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk) { [weak self] driver in
            guard
                let generationDriver = PluginGenerationDriver(
                    driver: driver,
                    databaseType: type,
                    schema: scope.schema,
                    blocksDestructiveOperations: blocked
                )
            else {
                throw GenerationError.writeFailed(
                    table: "",
                    reason: String(localized: "this connection cannot write generated rows")
                )
            }
            let engine = GenerationEngine(
                driver: generationDriver,
                truncator: GenerationStringTruncator.forVendor(TransferVendor(type)),
                options: options
            )
            await MainActor.run { self?.engine = engine }

            // A Stop pressed while the connection was still being checked out would
            // otherwise be dropped: the engine it has to reach did not exist yet.
            if await MainActor.run(resultType: Bool.self, body: { self?.isCancelling ?? false }) {
                await engine.cancel()
            }

            for try await event in engine.run(plan: plan) {
                await MainActor.run { self?.handle(event) }
            }
        }
    }

    func cancelRun() {
        isCancelling = true
        append(.info, String(localized: "Stopping after the current batch."))
        let engine = engine
        Task { await engine?.cancel() }
    }

    /// Closing the sheet has to stop the run, not just forget about it. The engine
    /// holds a bulk metadata connection for as long as its row loop runs, so a
    /// forgotten run keeps writing rows and keeps that connection checked out after
    /// the UI is gone.
    func tearDown() {
        let engine = engine
        self.engine = nil
        Task { await engine?.cancel() }
    }

    private func handle(_ event: GenerationEvent) {
        switch event {
        case .started(let totalTables, let totalRows):
            self.totalRows = totalRows
            append(
                .info,
                String(format: String(localized: "Starting %d tables, %d rows."), totalTables, totalRows)
            )
        case .tableStarted(let table, let rowCount):
            currentTable = table
            append(.info, String(format: String(localized: "%@: writing %d rows."), table, rowCount))
        case .progress(_, let rowsWritten, _):
            self.rowsWritten = rowsWritten
        case .tableFinished(let table, let rowsWritten, let duration):
            append(
                .info,
                String(
                    format: String(localized: "%@: %d rows in %.1fs."),
                    table,
                    rowsWritten,
                    duration
                )
            )
        case .secondPassFinished(let table, let columns, let rowsUpdated):
            append(
                .info,
                String(
                    format: String(localized: "%@: filled %@ on %d rows."),
                    table,
                    columns.joined(separator: ", "),
                    rowsUpdated
                )
            )
        case .warning(let message):
            append(.warning, message)
        case .batchFailed(let table, let error):
            append(.failure, String(format: String(localized: "%@: %@"), table, error))
        case .finished(let report):
            self.report = report
            append(
                .info,
                String(
                    format: String(localized: "Finished: %d rows in %.1fs."),
                    report.totalRowsWritten,
                    report.duration
                )
            )
            step = .report
        case .cancelled(let rowsWritten):
            append(.info, String(format: String(localized: "Stopped after %d rows."), rowsWritten))
            report = GenerationReport(tables: [], warnings: [], duration: 0, wasCancelled: true)
            step = .report
        }
    }

    private func append(_ kind: GenerationLogEntry.Kind, _ message: String) {
        log.append(GenerationLogEntry(at: Date(), kind: kind, message: message))
    }

    // MARK: - Scope helpers

    var runOptions: GenerationRunOptions {
        GenerationRunOptions(
            singleTransaction: singleTransaction,
            continueOnError: continueOnError,
            referenceStrategy: referenceStrategy
        )
    }

    private func saveDialogSettings() {
        let storage = GenerationDialogStorage.shared
        storage.saveLastRowCount(Int(defaultRowCountText) ?? 0)
        storage.saveSingleTransaction(singleTransaction)
        storage.saveContinueOnError(continueOnError)
    }

    var currentScope: DatabaseScope? {
        guard let connectionId, !database.isEmpty else { return nil }
        return DatabaseScope(connectionId: connectionId, database: database, schema: schema)
    }

    func connection(for id: UUID?) -> DatabaseConnection? {
        guard let id else { return nil }
        return connections.first { $0.id == id }
    }

    var emptyFirstDisabledReason: String? {
        guard blocksDestructiveOperations else { return nil }
        return String(localized: "This connection does not allow emptying tables.")
    }

    private func connectIfNeeded(_ connection: DatabaseConnection) async throws {
        guard DatabaseManager.shared.session(for: connection.id)?.driver == nil else { return }
        try await DatabaseManager.shared.connectToSession(connection)
    }
}
