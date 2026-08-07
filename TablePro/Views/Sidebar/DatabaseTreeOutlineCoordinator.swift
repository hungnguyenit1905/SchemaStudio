//
//  DatabaseTreeOutlineCoordinator.swift
//  TablePro
//

import AppKit
import Observation
import TableProPluginKit

@MainActor
final class DatabaseTreeOutlineCoordinator: NSObject {
    weak var outlineView: NSOutlineView?
    let service = DatabaseTreeMetadataService.shared
    static let cellIdentifier = NSUserInterfaceItemIdentifier("DatabaseTreeCell")

    var connectionId = UUID()
    var databaseType: DatabaseType = .mysql
    weak var mainCoordinator: MainContentCoordinator?
    var windowState: WindowSidebarState?
    var sidebarState: SharedSidebarState?
    weak var viewModel: SidebarViewModel?
    var searchText = ""
    private var connectionToken = ""
    var activeDatabase: String?
    var activeSchema: String?
    var pendingTruncates: [UUID: Set<String>] = [:]
    var pendingDeletes: [UUID: Set<String>] = [:]

    var contextResolver = SidebarNodeContextResolver.live
    var contextCache: [UUID: SidebarNodeContext] = [:]

    var nodeCache: [String: DatabaseTreeNode] = [:]
    var childrenCache: [String: [DatabaseTreeNode]] = [:]
    var lastSelection: Set<DatabaseTreeTableRef> = []
    var pendingSingleClickWork: DispatchWorkItem?
    var isApplyingExpansion = false
    var isSyncingSelection = false
    var isReloading = false
    private var hasRenderedOnce = false
    private var reconcileScheduled = false
    private var observationGeneration = 0

    // MARK: - Attach / input

    func attach(outlineView: NSOutlineView) {
        self.outlineView = outlineView
    }

    func update(from view: DatabaseTreeOutlineView) {
        connectionId = view.connectionId
        databaseType = view.databaseType
        mainCoordinator = view.coordinator
        windowState = view.windowState
        sidebarState = view.sidebarState
        viewModel = view.viewModel

        let activeChanged = activeDatabase != view.activeDatabase || activeSchema != view.activeSchema
        let changed = searchText != view.searchText
            || connectionToken != view.connectionToken
            || activeChanged
            || pendingTruncates != view.pendingTruncates
            || pendingDeletes != view.pendingDeletes

        searchText = view.searchText
        connectionToken = view.connectionToken
        activeDatabase = view.activeDatabase
        activeSchema = view.activeSchema
        pendingTruncates = view.pendingTruncates
        pendingDeletes = view.pendingDeletes

        if !hasRenderedOnce || activeChanged {
            persistActiveExpansion()
        }

        if !hasRenderedOnce {
            hasRenderedOnce = true
            refresh()
        } else if changed {
            refresh()
        }
    }

    private func persistActiveExpansion() {
        guard let active = activeDatabase, let windowState else { return }
        let databaseKey = ConnectionDatabaseKey(connectionId: connectionId, database: active)
        if !windowState.expandedTreeDatabases.contains(databaseKey) {
            windowState.expandedTreeDatabases.insert(databaseKey)
        }
        if let schema = activeSchema {
            let key = ConnectionSchemaKey(connectionId: connectionId, database: active, schema: schema)
            if !windowState.expandedTreeDatabaseSchemas.contains(key) {
                windowState.expandedTreeDatabaseSchemas.insert(key)
            }
        }
    }

    // MARK: - Observation

    private func beginObserving() {
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking { [weak self] in
            self?.snapshotDependencies()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.observationGeneration else { return }
                self.scheduleReconcile()
            }
        }
    }

    private func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        Task { @MainActor in
            self.reconcileScheduled = false
            self.refresh()
        }
    }

    /// The tree spans every saved connection, so observation has to follow all
    /// of them: `activeSessions` drives the status dot and the connect-to-expand
    /// transition, and each expanded connection contributes its own metadata.
    private func snapshotDependencies() {
        _ = DatabaseManager.shared.activeSessions
        for expandedId in ConnectionTreeState.shared.expandedConnectionIds {
            _ = service.databaseListState(for: expandedId)
            _ = SharedSidebarState.forConnection(expandedId).recentTables
        }
        _ = service.databaseListState(for: connectionId)
        _ = sidebarState?.recentTables
        for node in nodeCache.values {
            switch node.kind {
            case .database(let connectionId, let metadata):
                _ = service.schemaListState(connectionId: connectionId, database: metadata.name)
                _ = service.tablesLoadState(connectionId: connectionId, database: metadata.name, schema: nil)
                _ = service.routinesLoadState(connectionId: connectionId, database: metadata.name, schema: nil)
            case .schema(let connectionId, let database, let schema):
                _ = service.tablesLoadState(connectionId: connectionId, database: database, schema: schema)
                _ = service.routinesLoadState(connectionId: connectionId, database: database, schema: schema)
            case .table(let ref) where ref.table.type == .partitionedTable:
                _ = service.partitionsLoadState(
                    connectionId: ref.connectionId, database: ref.database, schema: ref.schema, table: ref.table.name
                )
            case .connectionRoot, .folder, .connection, .recentSection, .recentTable, .table, .routine, .status:
                break
            }
        }
    }

    func refresh() {
        guard let outlineView else { return }
        isReloading = true
        contextCache.removeAll()
        childrenCache.removeAll()
        outlineView.reloadData()
        applyDesiredExpansion()
        syncSelectionToModel()
        isReloading = false
        beginObserving()
    }

    // MARK: - Node building

    func node(id: String, kind: DatabaseTreeNode.Kind) -> DatabaseTreeNode {
        if let existing = nodeCache[id] {
            existing.kind = kind
            return existing
        }
        let created = DatabaseTreeNode(id: id, kind: kind)
        nodeCache[id] = created
        return created
    }
}
