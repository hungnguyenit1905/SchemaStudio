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
    var pendingTruncates: [UUID: Set<DatabaseTreeTableRef>] = [:]
    var pendingDeletes: [UUID: Set<DatabaseTreeTableRef>] = [:]

    var contextResolver = SidebarNodeContextResolver.live
    var contextCache: [UUID: SidebarNodeContext] = [:]

    var nodeCache: [String: DatabaseTreeNode] = [:]
    var childrenCache: [String: [DatabaseTreeNode]] = [:]
    var lastSelection: Set<DatabaseTreeTableRef> = []
    var isApplyingExpansion = false
    var isSyncingSelection = false
    var isReloading = false
    private var navigationGeneration: UInt = 0
    private var hasRenderedOnce = false
    private var reconcileScheduled = false
    private var observationGeneration = 0
    private var connectionsDidChangeObserver: NSObjectProtocol?

    deinit {
        if let connectionsDidChangeObserver {
            NotificationCenter.default.removeObserver(connectionsDidChangeObserver)
        }
    }

    // MARK: - Attach / input

    func attach(outlineView: NSOutlineView) {
        self.outlineView = outlineView
        observeConnectionListChanges()
    }

    func nextNavigationGeneration() -> UInt {
        navigationGeneration &+= 1
        return navigationGeneration
    }

    func isCurrentNavigation(_ generation: UInt) -> Bool {
        generation == navigationGeneration
    }

    /// The connection and folder levels come from storage, not from any
    /// observable the tree already tracks, so an add, an edit or a delete made
    /// in the welcome window is invisible here without this. The handler only
    /// rebuilds; writing from it would make the next save post again.
    private func observeConnectionListChanges() {
        guard connectionsDidChangeObserver == nil else { return }
        connectionsDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .connectionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
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
        _ = AppSettingsManager.shared.general.showHiddenItems
        _ = ConnectionTreeState.shared.connectFailures
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
        discardSelectedScopeIfDeleted()
        outlineView.reloadData()
        applyDesiredExpansion()
        syncSelectionToModel()
        isReloading = false
        beginObserving()
    }

    private func discardSelectedScopeIfDeleted() {
        guard let scope = windowState?.selectedScope,
              contextResolver.context(for: scope.connectionId) == nil else { return }
        windowState?.selectedScope = nil
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
