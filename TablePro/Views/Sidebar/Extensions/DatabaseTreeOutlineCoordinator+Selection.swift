//
//  DatabaseTreeOutlineCoordinator+Selection.swift
//  TablePro
//

import AppKit
import Observation
import TableProPluginKit

extension DatabaseTreeOutlineCoordinator {
    // MARK: - Expansion

    func applyDesiredExpansion() {
        guard let outlineView else { return }
        isApplyingExpansion = true
        defer { isApplyingExpansion = false }
        let searching = !searchText.isEmpty
        let recentId = DatabaseTreeNode.recentSectionId(connectionId: connectionId)
        for rootNode in resolvedChildren(of: nil) where rootNode.id == recentId {
            setExpanded(rootNode, searching || (viewModel?.isRecentsExpanded ?? true))
        }
        for databaseNode in resolvedChildren(of: nil) {
            guard case .database(let connectionId, let metadata) = databaseNode.kind else { continue }
            let databaseKey = ConnectionDatabaseKey(connectionId: connectionId, database: metadata.name)
            let want = searching
                ? databaseMatchesSearch(metadata)
                : windowState?.expandedTreeDatabases.contains(databaseKey) ?? false
            setExpanded(databaseNode, want)
            guard outlineView.isItemExpanded(databaseNode) else { continue }
            triggerLoad(for: databaseNode)
            guard supportsSchemaLevel else {
                restorePartitionExpansion(under: databaseNode)
                continue
            }
            for schemaNode in resolvedChildren(of: databaseNode) {
                guard case .schema(let connectionId, let database, let schema) = schemaNode.kind else { continue }
                let schemaKey = ConnectionSchemaKey(connectionId: connectionId, database: database, schema: schema)
                let wantSchema = searching
                    ? DatabaseTreeFilter.matches(searchText, schema) || schemaContentMatchesSearch(database: database, schema: schema)
                    : windowState?.expandedTreeDatabaseSchemas.contains(schemaKey) ?? false
                setExpanded(schemaNode, wantSchema)
                if outlineView.isItemExpanded(schemaNode) {
                    triggerLoad(for: schemaNode)
                    restorePartitionExpansion(under: schemaNode)
                }
            }
        }
    }

    private func restorePartitionExpansion(under parent: DatabaseTreeNode) {
        guard searchText.isEmpty, let outlineView, let windowState else { return }
        for tableNode in resolvedChildren(of: parent) {
            guard case .table(let ref) = tableNode.kind, ref.table.type == .partitionedTable else { continue }
            let key = ConnectionTableKey(
                connectionId: ref.connectionId, database: ref.database, schema: ref.schema, table: ref.table.name
            )
            guard windowState.expandedTreeTables.contains(key) else { continue }
            setExpanded(tableNode, true)
            guard outlineView.isItemExpanded(tableNode) else { continue }
            triggerLoad(for: tableNode)
            restorePartitionExpansion(under: tableNode)
        }
    }

    func setExpanded(_ node: DatabaseTreeNode, _ expanded: Bool) {
        guard let outlineView else { return }
        if expanded, !outlineView.isItemExpanded(node) {
            outlineView.expandItem(node)
        } else if !expanded, outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        }
    }

    func recordExpansion(_ node: DatabaseTreeNode, expanded: Bool) {
        switch node.kind {
        case .recentSection:
            viewModel?.isRecentsExpanded = expanded
        case .folder(let group):
            if expanded {
                ConnectionTreeState.shared.expandedFolderIds.insert(group.id)
            } else {
                ConnectionTreeState.shared.expandedFolderIds.remove(group.id)
            }
        case .connection(let connection):
            if expanded {
                ConnectionTreeState.shared.expandedConnectionIds.insert(connection.id)
            } else {
                ConnectionTreeState.shared.expandedConnectionIds.remove(connection.id)
            }
        case .database(let connectionId, let metadata):
            let key = ConnectionDatabaseKey(connectionId: connectionId, database: metadata.name)
            if expanded {
                windowState?.expandedTreeDatabases.insert(key)
            } else {
                windowState?.expandedTreeDatabases.remove(key)
            }
        case .schema(let connectionId, let database, let schema):
            let key = ConnectionSchemaKey(connectionId: connectionId, database: database, schema: schema)
            if expanded {
                windowState?.expandedTreeDatabaseSchemas.insert(key)
            } else {
                windowState?.expandedTreeDatabaseSchemas.remove(key)
            }
        case .table(let ref):
            let key = ConnectionTableKey(
                connectionId: ref.connectionId, database: ref.database, schema: ref.schema, table: ref.table.name
            )
            if expanded {
                windowState?.expandedTreeTables.insert(key)
            } else {
                windowState?.expandedTreeTables.remove(key)
            }
        case .connectionRoot, .recentTable, .routine, .status:
            break
        }
    }

    func triggerLoad(for node: DatabaseTreeNode) {
        switch node.kind {
        case .database(_, let metadata):
            if supportsSchemaLevel {
                if isIdle(service.schemaListState(connectionId: connectionId, database: metadata.name)) {
                    Task { await service.loadSchemas(connectionId: connectionId, database: metadata.name) }
                }
                loadExternalSchemaNames(database: metadata.name)
            } else {
                loadObjects(database: metadata.name, schema: nil)
            }
        case .schema(_, let database, let schema):
            loadObjects(database: database, schema: schema)
        case .table(let ref):
            loadPartitions(ref)
        case .connectionRoot, .folder, .connection, .recentSection, .recentTable, .routine, .status:
            break
        }
    }

    private func loadExternalSchemaNames(database: String) {
        guard let session = DatabaseManager.shared.session(for: connectionId),
              DatabaseManager.shared.browseDatabaseName(for: session.connection) == database,
              let driver = DatabaseManager.shared.driver(for: connectionId)
        else { return }
        let connectionId = connectionId
        Task {
            await ExternalSchemaTracker.shared.load(
                connectionId: connectionId,
                database: database,
                driver: driver
            )
        }
    }

    private func loadPartitions(_ ref: DatabaseTreeTableRef) {
        guard ref.table.type == .partitionedTable else { return }
        let state = service.partitionsLoadState(
            connectionId: ref.connectionId, database: ref.database, schema: ref.schema, table: ref.table.name
        )
        guard isIdle(state) else { return }
        Task {
            await service.loadPartitions(
                connectionId: ref.connectionId, database: ref.database, schema: ref.schema, table: ref.table.name
            )
        }
    }

    private func loadObjects(database: String, schema: String?) {
        if isIdle(service.tablesLoadState(connectionId: connectionId, database: database, schema: schema)) {
            Task { await service.loadTables(connectionId: connectionId, database: database, schema: schema) }
        }
        if isIdle(service.routinesLoadState(connectionId: connectionId, database: database, schema: schema)) {
            Task { await service.loadRoutines(connectionId: connectionId, database: database, schema: schema) }
        }
    }

    func isIdle<Value>(_ state: MetadataLoadState<Value>) -> Bool {
        if case .idle = state { return true }
        return false
    }

    // MARK: - Selection / open

    func selectedRefs() -> [DatabaseTreeTableRef] {
        guard let outlineView else { return [] }
        return outlineView.selectedRowIndexes.compactMap {
            (outlineView.item(atRow: $0) as? DatabaseTreeNode)?.tableRef
        }
    }

    func syncSelectionToModel() {
        guard let outlineView else { return }
        let rows = lastSelection.compactMap { ref -> Int? in
            guard let node = nodeCache[DatabaseTreeNode.tableId(ref)] else { return nil }
            let row = outlineView.row(forItem: node)
            return row >= 0 ? row : nil
        }
        isSyncingSelection = true
        outlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        isSyncingSelection = false
    }

    func open(_ ref: DatabaseTreeTableRef, activateGridFocus: Bool, forceNewWindowTab: Bool = false) {
        Task { @MainActor in
            await activate(ref)
            mainCoordinator?.openTableTab(
                ref.table,
                schema: ref.schema,
                activateGridFocus: activateGridFocus,
                forceNewWindowTab: forceNewWindowTab
            )
        }
    }

    func activate(_ ref: DatabaseTreeTableRef) async {
        if ref.database != activeDatabase {
            await mainCoordinator?.switchDatabase(to: ref.database)
        }
        guard let schema = ref.schema,
              PluginManager.shared.supportsSchemaSwitching(for: databaseType),
              schema != sessionSchema else { return }
        await mainCoordinator?.switchSchema(to: schema)
    }

    /// The live session schema, not the window's toolbar mirror. A database switch
    /// moves the session schema without touching the toolbar, so comparing against
    /// the toolbar skips the switch exactly when the session needs it.
    private var sessionSchema: String? {
        DatabaseManager.shared.session(for: connectionId)?.browseSchema
    }

    func setActiveDatabase(_ database: String) {
        guard database != activeDatabase else { return }
        Task { await mainCoordinator?.switchDatabase(to: database) }
    }

    func setActiveSchema(database: String, schema: String) {
        Task { @MainActor in
            if database != activeDatabase {
                await mainCoordinator?.switchDatabase(to: database)
            }
            if schema != sessionSchema {
                await mainCoordinator?.switchSchema(to: schema)
            }
        }
    }

    func refreshDatabase(_ database: String) {
        if supportsSchemaLevel {
            Task { await service.refreshSchemas(connectionId: connectionId, database: database) }
        } else {
            Task { await service.refreshObjects(connectionId: connectionId, database: database, schema: nil) }
        }
    }

    func refreshObjects(database: String, schema: String?) {
        Task { await service.refreshObjects(connectionId: connectionId, database: database, schema: schema) }
    }

    @objc
    func handleSingleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? DatabaseTreeNode,
              let ref = node.recentTableRef else { return }
        scheduleSingleClickOpen(ref)
    }

    @objc
    func handleDoubleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? DatabaseTreeNode else { return }
        if let ref = node.tableRef ?? node.recentTableRef {
            pendingSingleClickWork?.cancel()
            pendingSingleClickWork = nil
            open(ref, activateGridFocus: true, forceNewWindowTab: true)
            return
        }
        guard node.isExpandable else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }
}

extension DatabaseTreeOutlineCoordinator: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DatabaseTreeNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? DatabaseTreeCellView
            ?? makeCell()
        cell.configure(node: node, context: rowContext(), actions: rowActions())
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? DatabaseTreeNode)?.tableRef != nil
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DatabaseTreeNode else { return }
        triggerLoad(for: node)
        if !isApplyingExpansion { recordExpansion(node, expanded: true) }
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DatabaseTreeNode else { return }
        if !isApplyingExpansion { recordExpansion(node, expanded: false) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, !isReloading else { return }
        let refs = Set(selectedRefs())
        if let added = SelectionDelta.singleAddition(old: lastSelection, new: refs) {
            if isKeyboardDrivenSelection {
                pendingSingleClickWork?.cancel()
                pendingSingleClickWork = nil
                open(added, activateGridFocus: false)
            } else {
                scheduleSingleClickOpen(added)
            }
        }
        lastSelection = refs
    }

    private var isKeyboardDrivenSelection: Bool {
        guard let outlineView, outlineView.window?.firstResponder === outlineView else { return false }
        switch NSApp.currentEvent?.type {
        case .keyDown, .keyUp:
            return true
        default:
            return false
        }
    }

    func scheduleSingleClickOpen(_ ref: DatabaseTreeTableRef) {
        pendingSingleClickWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.open(ref, activateGridFocus: false)
        }
        pendingSingleClickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
}
