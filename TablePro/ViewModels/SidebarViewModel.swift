//
//  SidebarViewModel.swift
//  TablePro
//

import Observation
import SwiftUI
import TableProPluginKit

@MainActor @Observable
final class SidebarViewModel {
    private static var registry: [UUID: SidebarViewModel] = [:]
    private static let searchDebounceNanoseconds: UInt64 = 150_000_000

    static func shared(
        connectionId: UUID,
        databaseType: DatabaseType,
        selectedTables: Binding<Set<DatabaseTreeTableRef>>,
        pendingTruncates: Binding<Set<DatabaseTreeTableRef>>,
        pendingDeletes: Binding<Set<DatabaseTreeTableRef>>,
        tableOperationOptions: Binding<[DatabaseTreeTableRef: TableOperationOptions]>
    ) -> SidebarViewModel {
        if let existing = registry[connectionId] {
            existing.updateBindings(
                selectedTables: selectedTables,
                pendingTruncates: pendingTruncates,
                pendingDeletes: pendingDeletes,
                tableOperationOptions: tableOperationOptions
            )
            return existing
        }
        let viewModel = SidebarViewModel(
            selectedTables: selectedTables,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            tableOperationOptions: tableOperationOptions,
            databaseType: databaseType,
            connectionId: connectionId
        )
        registry[connectionId] = viewModel
        return viewModel
    }

    static func removeConnection(_ connectionId: UUID) {
        registry.removeValue(forKey: connectionId)
    }

    func updateBindings(
        selectedTables: Binding<Set<DatabaseTreeTableRef>>,
        pendingTruncates: Binding<Set<DatabaseTreeTableRef>>,
        pendingDeletes: Binding<Set<DatabaseTreeTableRef>>,
        tableOperationOptions: Binding<[DatabaseTreeTableRef: TableOperationOptions]>
    ) {
        selectedTablesBinding = selectedTables
        pendingTruncatesBinding = pendingTruncates
        pendingDeletesBinding = pendingDeletes
        tableOperationOptionsBinding = tableOperationOptions
    }

    // MARK: - Expansion State

    struct ExpansionState: Sendable {
        var values: [SidebarObjectKind: Bool]

        init(values: [SidebarObjectKind: Bool] = [:]) {
            self.values = values
        }

        subscript(kind: SidebarObjectKind) -> Bool {
            get { values[kind] ?? Self.defaultValue(for: kind) }
            set { values[kind] = newValue }
        }

        static func defaultValue(for kind: SidebarObjectKind) -> Bool {
            kind == .table
        }
    }

    // MARK: - Published State

    var searchText: String {
        get { sharedState.searchText }
        set {
            let oldValue = sharedState.searchText
            sharedState.searchText = newValue
            scheduleFilterQueryUpdate(oldValue: oldValue)
        }
    }

    private(set) var filterQuery = "" {
        didSet { invalidateFilterCaches() }
    }

    @ObservationIgnored private var filterDebounceTask: Task<Void, Never>?

    var expanded: ExpansionState {
        didSet { persistExpansion(oldValue: oldValue) }
    }

    var isRedisKeysExpanded: Bool {
        didSet {
            UserDefaults.standard.set(
                isRedisKeysExpanded,
                forKey: SidebarPersistenceKey.redisKeysExpanded(connectionId: connectionId)
            )
        }
    }

    var isRecentsExpanded: Bool {
        didSet {
            UserDefaults.standard.set(
                isRecentsExpanded,
                forKey: SidebarPersistenceKey.recentsExpanded(connectionId: connectionId)
            )
        }
    }

    var redisKeyTreeViewModel: RedisKeyTreeViewModel? {
        get { sharedState.redisKeyTreeViewModel }
        set { sharedState.redisKeyTreeViewModel = newValue }
    }

    var showOperationDialog = false
    var pendingOperationType: TableOperationType?
    var pendingOperationTables: [DatabaseTreeTableRef] = []

    // MARK: - Binding Storage

    private var selectedTablesBinding: Binding<Set<DatabaseTreeTableRef>>
    private var pendingTruncatesBinding: Binding<Set<DatabaseTreeTableRef>>
    private var pendingDeletesBinding: Binding<Set<DatabaseTreeTableRef>>
    private var tableOperationOptionsBinding: Binding<[DatabaseTreeTableRef: TableOperationOptions]>
    let databaseType: DatabaseType

    // MARK: - Dependencies

    private let connectionId: UUID

    /// The single connection-scoped state holder. Search text and the Redis key
    /// tree live here so this view model and the sidebar views share one source.
    @ObservationIgnored let sharedState: SharedSidebarState

    // MARK: - Convenience Accessors

    var selectedTables: Set<DatabaseTreeTableRef> {
        get { selectedTablesBinding.wrappedValue }
        set { selectedTablesBinding.wrappedValue = newValue }
    }

    var pendingTruncates: Set<DatabaseTreeTableRef> {
        get { pendingTruncatesBinding.wrappedValue }
        set { pendingTruncatesBinding.wrappedValue = newValue }
    }

    var pendingDeletes: Set<DatabaseTreeTableRef> {
        get { pendingDeletesBinding.wrappedValue }
        set { pendingDeletesBinding.wrappedValue = newValue }
    }

    var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] {
        get { tableOperationOptionsBinding.wrappedValue }
        set { tableOperationOptionsBinding.wrappedValue = newValue }
    }

    var isTablesExpanded: Bool {
        get { expanded[.table] }
        set { expanded[.table] = newValue }
    }

    // MARK: - Initialization

    init(
        selectedTables: Binding<Set<DatabaseTreeTableRef>>,
        pendingTruncates: Binding<Set<DatabaseTreeTableRef>>,
        pendingDeletes: Binding<Set<DatabaseTreeTableRef>>,
        tableOperationOptions: Binding<[DatabaseTreeTableRef: TableOperationOptions]>,
        databaseType: DatabaseType,
        connectionId: UUID
    ) {
        self.selectedTablesBinding = selectedTables
        self.pendingTruncatesBinding = pendingTruncates
        self.pendingDeletesBinding = pendingDeletes
        self.tableOperationOptionsBinding = tableOperationOptions
        self.databaseType = databaseType
        self.connectionId = connectionId
        self.sharedState = SharedSidebarState.forConnection(connectionId)
        self.expanded = Self.loadInitialExpansion(connectionId: connectionId)
        self.isRedisKeysExpanded = Self.loadExpansion(
            perConnectionKey: SidebarPersistenceKey.redisKeysExpanded(connectionId: connectionId),
            legacyKey: SidebarPersistenceKey.legacyRedisKeysExpanded,
            defaultValue: true
        )
        self.isRecentsExpanded = Self.loadExpansion(
            perConnectionKey: SidebarPersistenceKey.recentsExpanded(connectionId: connectionId),
            defaultValue: true
        )
    }

    private static func loadInitialExpansion(connectionId: UUID) -> ExpansionState {
        var values: [SidebarObjectKind: Bool] = [:]
        for kind in SidebarObjectKind.allCases {
            values[kind] = loadKindExpansion(connectionId: connectionId, kind: kind)
        }
        return ExpansionState(values: values)
    }

    private static func loadKindExpansion(connectionId: UUID, kind: SidebarObjectKind) -> Bool {
        let defaults = UserDefaults.standard
        let perKindKey = SidebarPersistenceKey.expanded(connectionId: connectionId, kind: kind)
        if defaults.object(forKey: perKindKey) != nil {
            return defaults.bool(forKey: perKindKey)
        }
        if kind == .table {
            let legacyPerConnection = SidebarPersistenceKey.tablesExpanded(connectionId: connectionId)
            if defaults.object(forKey: legacyPerConnection) != nil {
                let seeded = defaults.bool(forKey: legacyPerConnection)
                defaults.set(seeded, forKey: perKindKey)
                return seeded
            }
            if defaults.object(forKey: SidebarPersistenceKey.legacyTablesExpanded) != nil {
                let seeded = defaults.bool(forKey: SidebarPersistenceKey.legacyTablesExpanded)
                defaults.set(seeded, forKey: perKindKey)
                return seeded
            }
        }
        return ExpansionState.defaultValue(for: kind)
    }

    private static func loadExpansion(
        perConnectionKey: String,
        legacyKey: String? = nil,
        defaultValue: Bool
    ) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: perConnectionKey) != nil {
            return defaults.bool(forKey: perConnectionKey)
        }
        if let legacyKey, defaults.object(forKey: legacyKey) != nil {
            let seeded = defaults.bool(forKey: legacyKey)
            defaults.set(seeded, forKey: perConnectionKey)
            return seeded
        }
        return defaultValue
    }

    private func persistExpansion(oldValue: ExpansionState) {
        let defaults = UserDefaults.standard
        for kind in SidebarObjectKind.allCases where oldValue[kind] != expanded[kind] {
            defaults.set(
                expanded[kind],
                forKey: SidebarPersistenceKey.expanded(connectionId: connectionId, kind: kind)
            )
        }
    }

    // MARK: - Capability Gating

    func capabilities(for connectionId: UUID) -> PluginCapabilities {
        guard let adapter = DatabaseManager.shared.driver(for: connectionId) as? PluginDriverAdapter else {
            return []
        }
        return adapter.schemaPluginDriver.capabilities
    }

    func sectionShouldRender(
        kind: SidebarObjectKind,
        itemCount: Int,
        capabilities: PluginCapabilities
    ) -> Bool {
        if kind == .table { return true }
        if let flag = kind.capabilityFlag, !capabilities.contains(flag) { return false }
        if itemCount > 0 { return true }
        return false
    }

    // MARK: - Batch Operations

    func batchToggleTruncate(tables: [DatabaseTreeTableRef]? = nil) {
        batchToggle(.truncate, tables: tables)
    }

    func batchToggleDelete(tables: [DatabaseTreeTableRef]? = nil) {
        batchToggle(.drop, tables: tables)
    }

    private func batchToggle(_ operation: TableOperationType, tables: [DatabaseTreeTableRef]?) {
        let tablesToToggle = tables ?? selectedTables.filter { $0.connectionId == connectionId }.sorted { $0.id < $1.id }
        guard !tablesToToggle.isEmpty else { return }

        let allAlreadyPending = tablesToToggle.allSatisfy { ref in
            let state = pendingState(for: ref.connectionId)
            return operation == .truncate ? state.truncates.contains(ref) : state.deletes.contains(ref)
        }
        guard allAlreadyPending else {
            pendingOperationType = operation
            pendingOperationTables = tablesToToggle
            showOperationDialog = true
            return
        }

        for (connectionId, refs) in Dictionary(grouping: tablesToToggle, by: \.connectionId) {
            var state = pendingState(for: connectionId)
            for ref in refs {
                if operation == .truncate {
                    state.truncates.remove(ref)
                } else {
                    state.deletes.remove(ref)
                }
                state.options.removeValue(forKey: ref)
            }
            writePendingState(state, for: connectionId)
        }
    }

    func confirmOperation(options: TableOperationOptions) {
        guard let operationType = pendingOperationType else { return }

        for (connectionId, refs) in Dictionary(grouping: pendingOperationTables, by: \.connectionId) {
            var state = pendingState(for: connectionId)
            for ref in refs {
                if operationType == .truncate {
                    state.deletes.remove(ref)
                    state.truncates.insert(ref)
                } else {
                    state.truncates.remove(ref)
                    state.deletes.insert(ref)
                }
                state.options[ref] = options
            }
            writePendingState(state, for: connectionId)
        }

        pendingOperationType = nil
        pendingOperationTables = []
    }

    private struct PendingTableState {
        var truncates: Set<DatabaseTreeTableRef>
        var deletes: Set<DatabaseTreeTableRef>
        var options: [DatabaseTreeTableRef: TableOperationOptions]
    }

    private func pendingState(for connectionId: UUID) -> PendingTableState {
        guard connectionId != self.connectionId else {
            return PendingTableState(truncates: pendingTruncates, deletes: pendingDeletes, options: tableOperationOptions)
        }
        let session = DatabaseManager.shared.session(for: connectionId)
        return PendingTableState(
            truncates: session?.pendingTruncates ?? [],
            deletes: session?.pendingDeletes ?? [],
            options: session?.tableOperationOptions ?? [:]
        )
    }

    private func writePendingState(_ state: PendingTableState, for connectionId: UUID) {
        guard connectionId != self.connectionId else {
            pendingTruncates = state.truncates
            pendingDeletes = state.deletes
            tableOperationOptions = state.options
            return
        }
        DatabaseManager.shared.updateSession(connectionId) { session in
            session.pendingTruncates = state.truncates
            session.pendingDeletes = state.deletes
            session.tableOperationOptions = state.options
        }
    }

    // MARK: - Clipboard

    func copySelectedTableNames() {
        guard !selectedTables.isEmpty else { return }
        let names = selectedTables.map { $0.table.name }.sorted()
        ClipboardService.shared.writeText(names.joined(separator: ","))
    }

    // MARK: - Filtering

    @ObservationIgnored private var cachedKindBuckets: [SidebarObjectKind: [TableInfo]] = [:]
    @ObservationIgnored private var cachedKindFingerprint: (count: Int, generation: Int)?

    @ObservationIgnored private var cachedFilteredByKind: [SidebarObjectKind: [TableInfo]] = [:]
    @ObservationIgnored private var cachedFilteredByKindFingerprint: (count: Int, generation: Int, query: String)?

    @ObservationIgnored private var cachedFilteredRoutines: [SidebarObjectKind: [RoutineInfo]] = [:]
    @ObservationIgnored private var cachedFilteredRoutinesFingerprint: (count: Int, generation: Int, query: String)?

    private var schemaGeneration: Int {
        SchemaService.shared.generationToken(for: connectionId)
    }

    func tables(of kind: SidebarObjectKind, from tables: [TableInfo]) -> [TableInfo] {
        guard !kind.isRoutine else { return [] }
        let fingerprint = (count: tables.count, generation: schemaGeneration)
        if cachedKindFingerprint?.count != fingerprint.count
            || cachedKindFingerprint?.generation != fingerprint.generation {
            rebuildKindBuckets(from: tables)
            cachedKindFingerprint = fingerprint
        }
        return cachedKindBuckets[kind] ?? []
    }

    func filteredTables(of kind: SidebarObjectKind, from tables: [TableInfo]) -> [TableInfo] {
        let query = filterQuery
        let fingerprint = (count: tables.count, generation: schemaGeneration, query: query)
        if cachedFilteredByKindFingerprint?.count != fingerprint.count
            || cachedFilteredByKindFingerprint?.generation != fingerprint.generation
            || cachedFilteredByKindFingerprint?.query != fingerprint.query {
            let bucket = self.tables(of: .table, from: tables)
            let bucketView = self.tables(of: .view, from: tables)
            let bucketMat = self.tables(of: .materializedView, from: tables)
            let bucketForeign = self.tables(of: .foreignTable, from: tables)
            cachedFilteredByKind[.table] = applyQuery(query, to: bucket)
            cachedFilteredByKind[.view] = applyQuery(query, to: bucketView)
            cachedFilteredByKind[.materializedView] = applyQuery(query, to: bucketMat)
            cachedFilteredByKind[.foreignTable] = applyQuery(query, to: bucketForeign)
            cachedFilteredByKindFingerprint = fingerprint
        }
        return cachedFilteredByKind[kind] ?? []
    }

    func filteredRecentTables(_ tables: [TableInfo]) -> [TableInfo] {
        let query = filterQuery
        guard !query.isEmpty else { return tables }
        return tables.filter { SidebarNameFilter.matches(query: query, candidate: $0.name) }
    }

    func filteredRoutines(of kind: SidebarObjectKind, from routines: [RoutineInfo]) -> [RoutineInfo] {
        let query = filterQuery
        let fingerprint = (count: routines.count, generation: schemaGeneration, query: query)
        if cachedFilteredRoutinesFingerprint?.count != fingerprint.count
            || cachedFilteredRoutinesFingerprint?.generation != fingerprint.generation
            || cachedFilteredRoutinesFingerprint?.query != fingerprint.query {
            let procs = routines.filter { $0.kind == .procedure }
            let funcs = routines.filter { $0.kind == .function }
            cachedFilteredRoutines[.procedure] = applyRoutineQuery(query, to: procs)
            cachedFilteredRoutines[.function] = applyRoutineQuery(query, to: funcs)
            cachedFilteredRoutinesFingerprint = fingerprint
        }
        return cachedFilteredRoutines[kind] ?? []
    }

    func effectiveExpanded(kind: SidebarObjectKind, hasMatches: Bool) -> Bool {
        if !filterQuery.isEmpty, hasMatches { return true }
        return expanded[kind]
    }

    private func applyQuery(_ query: String, to tables: [TableInfo]) -> [TableInfo] {
        SidebarNameFilter.ranked(tables, query: query, name: { $0.name })
    }

    private func applyRoutineQuery(_ query: String, to routines: [RoutineInfo]) -> [RoutineInfo] {
        SidebarNameFilter.ranked(routines, query: query, name: { $0.name })
    }

    private func rebuildKindBuckets(from tables: [TableInfo]) {
        var buckets: [SidebarObjectKind: [TableInfo]] = [:]
        for kind in SidebarObjectKind.allCases {
            buckets[kind] = []
        }
        for table in tables {
            let kind = Self.sidebarObjectKind(for: table.type)
            buckets[kind, default: []].append(table)
        }
        cachedKindBuckets = buckets
    }

    private static func sidebarObjectKind(for tableType: TableInfo.TableType) -> SidebarObjectKind {
        switch tableType.rawValue {
        case "VIEW": return .view
        case "MATERIALIZED VIEW": return .materializedView
        case "FOREIGN TABLE": return .foreignTable
        default: return .table
        }
    }

    private func invalidateFilterCaches() {
        cachedFilteredByKind = [:]
        cachedFilteredByKindFingerprint = nil
        cachedFilteredRoutines = [:]
        cachedFilteredRoutinesFingerprint = nil
    }

    private func scheduleFilterQueryUpdate(oldValue: String) {
        if searchText.isEmpty || oldValue.isEmpty {
            filterDebounceTask?.cancel()
            filterDebounceTask = nil
            filterQuery = searchText
            return
        }
        filterDebounceTask?.cancel()
        filterDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.filterQuery = self.searchText
        }
    }

    deinit {
        filterDebounceTask?.cancel()
    }
}
