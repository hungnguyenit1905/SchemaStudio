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
        guard outlineView != nil else { return }
        isApplyingExpansion = true
        defer { isApplyingExpansion = false }
        applyExpansion(to: resolvedChildren(of: nil))
    }

    /// Restores shape only. Expanding a connection here must never start a
    /// connect: launch replays saved expansion, and connecting from that replay
    /// would fire one connect and one password sheet per remembered connection.
    /// Only `outlineViewItemWillExpand` outside this pass connects.
    private func applyExpansion(to nodes: [DatabaseTreeNode]) {
        guard let outlineView else { return }
        let searching = !searchText.isEmpty
        for node in nodes {
            switch node.kind {
            case .folder(let group):
                setExpanded(node, searching || ConnectionTreeState.shared.expandedFolderIds.contains(group.id))
                if outlineView.isItemExpanded(node) {
                    applyExpansion(to: resolvedChildren(of: node))
                }
            case .connection(let connection):
                setExpanded(node, ConnectionTreeState.shared.expandedConnectionIds.contains(connection.id))
                if outlineView.isItemExpanded(node) {
                    applyExpansionUnderConnection(node)
                }
            default:
                continue
            }
        }
    }

    private func applyExpansionUnderConnection(_ connectionNode: DatabaseTreeNode) {
        guard let outlineView else { return }
        let searching = !searchText.isEmpty
        for child in resolvedChildren(of: connectionNode) {
            if case .recentSection(let connectionId) = child.kind {
                setExpanded(child, searching || (viewModel(for: connectionId)?.isRecentsExpanded ?? true))
                continue
            }
            if case .schema = child.kind {
                applyExpansion(toSchemasOf: connectionNode, searching: searching)
                return
            }
            guard case .database(let connectionId, let metadata) = child.kind,
                  let context = context(for: connectionId) else { continue }
            let databaseKey = ConnectionDatabaseKey(connectionId: connectionId, database: metadata.name)
            let want = searching
                ? databaseMatchesSearch(context: context, metadata)
                : windowState?.expandedTreeDatabases.contains(databaseKey) ?? false
            setExpanded(child, want)
            guard outlineView.isItemExpanded(child) else { continue }
            triggerLoad(for: child)
            guard context.listsSchemasUnderDatabase else {
                restorePartitionExpansion(under: child)
                continue
            }
            applyExpansion(toSchemasOf: child, searching: searching)
        }
    }

    private func applyExpansion(toSchemasOf databaseNode: DatabaseTreeNode, searching: Bool) {
        guard let outlineView else { return }
        for schemaNode in resolvedChildren(of: databaseNode) {
            guard case .schema(let connectionId, let database, let schema) = schemaNode.kind else { continue }
            let schemaKey = ConnectionSchemaKey(connectionId: connectionId, database: database, schema: schema)
            let wantSchema = searching
                ? DatabaseTreeFilter.matches(searchText, schema)
                || schemaContentMatchesSearch(connectionId: connectionId, database: database, schema: schema)
                : windowState?.expandedTreeDatabaseSchemas.contains(schemaKey) ?? false
            setExpanded(schemaNode, wantSchema)
            if outlineView.isItemExpanded(schemaNode) {
                triggerLoad(for: schemaNode)
                restorePartitionExpansion(under: schemaNode)
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
        case .recentSection(let connectionId):
            viewModel(for: connectionId)?.isRecentsExpanded = expanded
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
        case .connection(let connection):
            loadDatabases(connectionId: connection.id)
        case .database(let connectionId, let metadata):
            guard let context = context(for: connectionId),
                  isDatabaseOpen(metadata.name, connectionId: connectionId) else { return }
            if context.listsSchemasUnderDatabase {
                if isIdle(service.schemaListState(connectionId: connectionId, database: metadata.name)) {
                    Task { await service.loadSchemas(connectionId: connectionId, database: metadata.name) }
                }
                loadExternalSchemaNames(connectionId: connectionId, database: metadata.name)
            } else {
                loadObjects(connectionId: connectionId, database: metadata.name, schema: nil)
            }
        case .schema(let connectionId, let database, let schema):
            loadObjects(connectionId: connectionId, database: database, schema: schema)
        case .table(let ref):
            loadPartitions(ref)
        case .connectionRoot, .folder, .recentSection, .recentTable, .routine, .status:
            break
        }
    }

    private func loadDatabases(connectionId: UUID) {
        guard let context = context(for: connectionId), context.isConnected else { return }
        guard !context.hasDatabaseLevel else {
            guard isIdle(service.databaseListState(for: connectionId)) else { return }
            Task { await service.loadDatabases(connectionId: connectionId, databaseType: context.databaseType) }
            return
        }
        switch context.groupingStrategy {
        case .flat:
            loadObjects(connectionId: connectionId, database: container(for: context), schema: nil)
        case .hierarchicalSchema:
            let database = container(for: context)
            if isIdle(service.schemaListState(connectionId: connectionId, database: database)) {
                Task { await service.loadSchemas(connectionId: connectionId, database: database) }
            }
        default:
            guard isIdle(service.databaseListState(for: connectionId)) else { return }
            Task {
                await service.loadDatabases(connectionId: connectionId, databaseType: context.databaseType)
            }
        }
    }

    private func loadExternalSchemaNames(connectionId: UUID, database: String) {
        guard let session = DatabaseManager.shared.session(for: connectionId),
              DatabaseManager.shared.browseDatabaseName(for: session.connection) == database,
              let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
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

    private func loadObjects(connectionId: UUID, database: String, schema: String?) {
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

    func restoreOutlineFocus() {
        guard let outlineView, let window = outlineView.window else { return }
        window.makeFirstResponder(outlineView)
    }

    func restoreOutlineFocus(for generation: UInt) {
        guard isCurrentNavigation(generation) else { return }
        restoreOutlineFocus()
    }

    func open(
        _ ref: DatabaseTreeTableRef,
        activateGridFocus: Bool,
        forceNewTab: Bool = false,
        showStructure: Bool = false
    ) {
        let generation = nextNavigationGeneration()
        switch SidebarTabRouter.route(nodeConnectionId: ref.connectionId, windowConnectionId: connectionId) {
        case .currentWindowCoordinator:
            mainCoordinator?.openTableTab(
                ref.table,
                scope: DatabaseScope(connectionId: ref.connectionId, database: ref.database, schema: ref.schema),
                showStructure: showStructure,
                activateGridFocus: activateGridFocus,
                forceNewTab: forceNewTab
            )
            guard !activateGridFocus else { return }
            DispatchQueue.main.async { [weak self] in
                self?.restoreOutlineFocus(for: generation)
            }
        case .newTabForNodeConnection:
            openInNodeConnection(ref, showStructure: showStructure)
        }
    }

    /// A node under another connection never touches this window's coordinator:
    /// `activate` would switch the wrong session's database, and `openTableTab`
    /// would bind the tab to the wrong connection. The tab group is forced
    /// shared so the new tab lands beside the tree the user clicked in, which is
    /// what `groupAllConnectionTabs` cannot express.
    private func openInNodeConnection(_ ref: DatabaseTreeTableRef, showStructure: Bool) {
        if focusExistingTab(for: ref) { return }
        let payload = EditorTabPayload(
            connectionId: ref.connectionId,
            tabType: .table,
            tableName: ref.table.name,
            databaseName: ref.database,
            schemaName: ref.schema,
            isView: !ref.table.type.allowsRowEditing,
            showStructure: showStructure
        )
        WindowManager.shared.openTab(payload: payload, tabGroup: .shared, anchor: outlineView?.window)
    }

    func focusExistingTab(for ref: DatabaseTreeTableRef) -> Bool {
        for coordinator in MainContentCoordinator.allActiveCoordinators()
            where coordinator.connectionId == ref.connectionId {
            guard let match = coordinator.tabManager.tabs.first(where: {
                $0.tabType == .table
                    && $0.tableContext.tableName == ref.table.name
                    && $0.tableContext.databaseName == ref.database
                    && $0.tableContext.schemaName == ref.schema
            }) else { continue }
            coordinator.selectTabAndFocusWindow(match.id)
            return true
        }
        return false
    }

    func refreshDatabase(_ database: String, connectionId: UUID) {
        if context(for: connectionId)?.listsSchemasUnderDatabase == true {
            Task { await service.refreshSchemas(connectionId: connectionId, database: database) }
        } else {
            Task { await service.refreshObjects(connectionId: connectionId, database: database, schema: nil) }
        }
    }

    func refreshObjects(database: String, schema: String?, connectionId: UUID) {
        Task { await service.refreshObjects(connectionId: connectionId, database: database, schema: schema) }
    }

    @objc
    func handleDoubleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? DatabaseTreeNode else { return }
        activate(node, activateGridFocus: true)
    }

    func activateSelectedNode() {
        guard let outlineView, outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? DatabaseTreeNode else { return }
        activate(node, activateGridFocus: false)
    }

    func activate(_ node: DatabaseTreeNode, activateGridFocus: Bool) {
        if let ref = node.tableRef ?? node.recentTableRef {
            openOrFocus(ref, activateGridFocus: activateGridFocus)
            return
        }
        if isOpenable(node) {
            openNode(node)
            return
        }
        guard let outlineView, isExpandable(node) else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    func openOrFocus(_ ref: DatabaseTreeTableRef, activateGridFocus: Bool) {
        if navigatesInPlace(ref.connectionId) {
            open(ref, activateGridFocus: activateGridFocus)
            return
        }
        if focusExistingTab(for: ref) { return }
        open(ref, activateGridFocus: activateGridFocus, forceNewTab: true)
    }

    private func navigatesInPlace(_ connectionId: UUID) -> Bool {
        guard let type = context(for: connectionId)?.databaseType else { return false }
        return PluginMetadataRegistry.shared.snapshot(forTypeId: type.pluginTypeId)?.navigationModel == .inPlace
    }

    func openNode(_ node: DatabaseTreeNode) {
        switch node.kind {
        case .connection(let connection):
            connect(connection)
        case .database(let connectionId, let metadata):
            openDatabase(metadata.name, connectionId: connectionId)
        default:
            return
        }
    }

    func openDatabase(_ database: String, connectionId: UUID) {
        let key = ConnectionDatabaseKey(connectionId: connectionId, database: database)
        Task { @MainActor in
            do {
                try await DatabaseManager.shared.markDatabaseOpen(database, for: connectionId)
            } catch is CancellationError {
                return
            } catch {
                AlertHelper.showErrorSheet(
                    title: String(format: String(localized: "Could not open %@"), database),
                    message: error.localizedDescription,
                    window: outlineView?.window
                )
                return
            }
            windowState?.expandedTreeDatabases.insert(key)
            refresh()
            guard let node = nodeCache[DatabaseTreeNode.databaseId(connectionId: connectionId, database: database)]
            else { return }
            setExpanded(node, true)
        }
    }

    func closeDatabase(_ database: String, connectionId: UUID) {
        let key = ConnectionDatabaseKey(connectionId: connectionId, database: database)
        Task { @MainActor in
            await DatabaseCloseFlow.closeDatabase(database, connectionId: connectionId, anchor: outlineView?.window)
            guard !DatabaseManager.shared.isDatabaseOpen(database, for: connectionId) else { return }
            windowState?.expandedTreeDatabases.remove(key)
            if let node = nodeCache[DatabaseTreeNode.databaseId(connectionId: connectionId, database: database)] {
                setExpanded(node, false)
            }
            refresh()
        }
    }
}

extension DatabaseTreeOutlineCoordinator: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DatabaseTreeNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? DatabaseTreeCellView
            ?? makeCell()
        cell.configure(node: node, context: rowContext(for: node), actions: rowActions(for: node))
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? DatabaseTreeNode else { return false }
        switch node.kind {
        case .status, .folder, .connectionRoot, .recentSection:
            return false
        default:
            return true
        }
    }

    /// The `isApplyingExpansion` guard keeps launch replay from recording expansion.
    /// Expanding only loads metadata: opening a closed node is an explicit gesture.
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DatabaseTreeNode else { return }
        triggerLoad(for: node)
        guard !isApplyingExpansion else { return }
        recordExpansion(node, expanded: true)
    }

    func adoptSelectedScope(of kind: DatabaseTreeNode.Kind) {
        guard let scope = SidebarScope.resolve(kind) else { return }
        windowState?.selectedScope = scope
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DatabaseTreeNode else { return }
        if !isApplyingExpansion { recordExpansion(node, expanded: false) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, !isReloading, let outlineView else { return }
        lastSelection = Set(selectedRefs())
        let row = outlineView.selectedRowIndexes.contains(outlineView.clickedRow)
            ? outlineView.clickedRow
            : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? DatabaseTreeNode else { return }
        adoptSelectedScope(of: node.kind)
    }
}
