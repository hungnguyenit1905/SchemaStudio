//
//  DatabaseTreeOutlineCoordinator+Nodes.swift
//  TablePro
//

import AppKit
import Observation
import TableProPluginKit

extension DatabaseTreeOutlineCoordinator {
    func resolvedChildren(of item: Any?) -> [DatabaseTreeNode] {
        let key = (item as? DatabaseTreeNode)?.id ?? ""
        if let cached = childrenCache[key] { return cached }
        let built = buildChildren(of: item as? DatabaseTreeNode)
        childrenCache[key] = built
        return built
    }

    func buildChildren(of node: DatabaseTreeNode?) -> [DatabaseTreeNode] {
        guard let node else { return rootNodes() }
        switch node.kind {
        case .connectionRoot:
            return folderChildren(of: nil)
        case .folder(let group):
            return folderChildren(of: group.id)
        case .connection(let connection):
            return connectionChildren(connection)
        case .recentSection(let connectionId):
            return recentTableRefs(connectionId: connectionId).map {
                self.node(id: DatabaseTreeNode.recentTableId($0), kind: .recentTable($0))
            }
        case .database(let connectionId, let metadata):
            guard let context = context(for: connectionId) else { return [] }
            return context.supportsSchemaLevel
                ? schemaNodes(context: context, database: metadata.name)
                : objectNodes(context: context, database: metadata.name, schema: nil)
        case .schema(let connectionId, let database, let schema):
            guard let context = context(for: connectionId) else { return [] }
            return objectNodes(context: context, database: database, schema: schema)
        case .table(let ref):
            return ref.table.type == .partitionedTable ? partitionNodes(of: ref) : []
        case .recentTable, .routine, .status:
            return []
        }
    }

    // MARK: - Connection level

    func context(for connectionId: UUID) -> SidebarNodeContext? {
        if let cached = contextCache[connectionId] { return cached }
        guard let resolved = contextResolver.context(for: connectionId) else { return nil }
        contextCache[connectionId] = resolved
        return resolved
    }

    private func rootNodes() -> [DatabaseTreeNode] {
        folderChildren(of: nil)
    }

    private func folderChildren(of folderId: UUID?) -> [DatabaseTreeNode] {
        ConnectionTreeBuilder.children(
            ofFolder: folderId,
            groups: GroupStorage.shared.loadGroups(),
            connections: ConnectionStorage.shared.loadConnections(),
            searchText: searchText,
            makeNode: { [weak self] id, kind in
                self?.node(id: id, kind: kind) ?? DatabaseTreeNode(id: id, kind: kind)
            }
        )
    }

    /// A connection that has no session yet renders a single status row. The
    /// connect itself is driven from the expansion handler, never from here:
    /// building children must stay free of side effects so a reload cannot
    /// trigger a second connect attempt.
    private func connectionChildren(_ connection: DatabaseConnection) -> [DatabaseTreeNode] {
        let connectionId = connection.id
        let parentId = DatabaseTreeNode.connectionNodeId(connectionId)
        guard let context = context(for: connectionId) else {
            return [statusNode(parentId: parentId, status: .empty)]
        }

        switch context.status {
        case .disconnected:
            return [statusNode(parentId: parentId, status: .loading)]
        case .connecting:
            return [statusNode(parentId: parentId, status: .loading)]
        case .error(let message):
            return [statusNode(parentId: parentId, status: .error(message))]
        case .connected:
            break
        }

        var nodes: [DatabaseTreeNode] = []
        if !recentTableRefs(connectionId: connectionId).isEmpty {
            nodes.append(node(
                id: DatabaseTreeNode.recentSectionId(connectionId: connectionId),
                kind: .recentSection(connectionId: connectionId)
            ))
        }
        nodes += databaseNodes(context: context)
        if nodes.isEmpty {
            switch service.databaseListState(for: connectionId) {
            case .idle, .loading: return [statusNode(parentId: parentId, status: .loading)]
            case .failed(let message): return [statusNode(parentId: parentId, status: .error(message))]
            case .loaded: return [statusNode(parentId: parentId, status: .empty)]
            }
        }
        return nodes
    }

    private func databaseNodes(context: SidebarNodeContext) -> [DatabaseTreeNode] {
        let connectionId = context.connectionId
        let visible = DatabaseTreeVisibility.visible(
            databases: service.databases(for: connectionId),
            selected: sidebarState(for: connectionId)?.databaseFilterSelected ?? [],
            activeDatabase: activeDatabase(for: connectionId)
        )
        let matched = searchText.isEmpty ? visible : visible.filter { databaseMatchesSearch(context: context, $0) }
        var seen = Set<String>()
        return matched
            .filter { seen.insert($0.id).inserted }
            .map {
                node(
                    id: DatabaseTreeNode.databaseId(connectionId: connectionId, database: $0.name),
                    kind: .database(connectionId: connectionId, metadata: $0)
                )
            }
    }

    // MARK: - Object level

    private func partitionNodes(of ref: DatabaseTreeTableRef) -> [DatabaseTreeNode] {
        let parentId = DatabaseTreeNode.tableId(ref)
        let state = service.partitionsLoadState(
            connectionId: ref.connectionId, database: ref.database, schema: ref.schema, table: ref.table.name
        )
        switch state {
        case .idle, .loading:
            return [statusNode(parentId: parentId, status: .loading)]
        case .failed(let message):
            return [statusNode(parentId: parentId, status: .error(message))]
        case .loaded(let partitions):
            if partitions.isEmpty { return [statusNode(parentId: parentId, status: .empty)] }
            return partitions.map { partition in
                let childRef = DatabaseTreeTableRef(
                    connectionId: ref.connectionId, database: ref.database, schema: ref.schema, table: partition
                )
                return node(id: DatabaseTreeNode.tableId(childRef), kind: .table(childRef))
            }
        }
    }

    private func recentTableRefs(connectionId: UUID) -> [DatabaseTreeTableRef] {
        guard let sidebarState = sidebarState(for: connectionId),
              AppSettingsManager.shared.general.showRecentTables else { return [] }
        let database = activeDatabase(for: connectionId) ?? ""
        return sidebarState.recentEntries(inDatabase: database).compactMap { entry -> DatabaseTreeTableRef? in
            if !searchText.isEmpty, !DatabaseTreeFilter.matches(searchText, entry.name) { return nil }
            return DatabaseTreeTableRef(
                connectionId: connectionId, database: database, schema: entry.schema, table: entry.tableInfo
            )
        }
    }

    private func schemaNodes(context: SidebarNodeContext, database: String) -> [DatabaseTreeNode] {
        let connectionId = context.connectionId
        let parentId = DatabaseTreeNode.databaseId(connectionId: connectionId, database: database)
        switch service.schemaListState(connectionId: connectionId, database: database) {
        case .idle, .loading:
            return [statusNode(parentId: parentId, status: .loading)]
        case .failed(let message):
            return [statusNode(parentId: parentId, status: .error(message))]
        case .loaded(let schemas):
            let visible = DatabaseTreeFilter.visibleSchemas(
                schemas,
                systemSchemas: context.systemSchemas,
                searchText: searchText,
                contentMatches: { schemaContentMatchesSearch(connectionId: connectionId, database: database, schema: $0) }
            )
            if visible.isEmpty { return [statusNode(parentId: parentId, status: .empty)] }
            return visible.map {
                node(
                    id: DatabaseTreeNode.schemaId(connectionId: connectionId, database: database, schema: $0),
                    kind: .schema(connectionId: connectionId, database: database, schema: $0)
                )
            }
        }
    }

    private func objectNodes(
        context: SidebarNodeContext,
        database: String,
        schema: String?
    ) -> [DatabaseTreeNode] {
        let connectionId = context.connectionId
        let parentId = schema
            .map { DatabaseTreeNode.schemaId(connectionId: connectionId, database: database, schema: $0) }
            ?? DatabaseTreeNode.databaseId(connectionId: connectionId, database: database)
        switch service.tablesLoadState(connectionId: connectionId, database: database, schema: schema) {
        case .idle, .loading:
            return [statusNode(parentId: parentId, status: .loading)]
        case .failed(let message):
            return [statusNode(parentId: parentId, status: .error(message))]
        case .loaded:
            return loadedObjectNodes(
                connectionId: connectionId, database: database, schema: schema, parentId: parentId
            )
        }
    }

    private func loadedObjectNodes(
        connectionId: UUID,
        database: String,
        schema: String?,
        parentId: String
    ) -> [DatabaseTreeNode] {
        let tables = DatabaseTreeFilter.filteredTables(
            service.tables(connectionId: connectionId, database: database, schema: schema), searchText: searchText
        )
        let routines = DatabaseTreeFilter.filteredRoutines(
            service.routines(connectionId: connectionId, database: database, schema: schema), searchText: searchText
        )
        let routinesState = service.routinesLoadState(connectionId: connectionId, database: database, schema: schema)

        guard !tables.isEmpty || !routines.isEmpty else {
            switch routinesState {
            case .failed(let message): return [statusNode(parentId: parentId, status: .error(message))]
            case .loaded: return [statusNode(parentId: parentId, status: .empty)]
            case .idle, .loading: return [statusNode(parentId: parentId, status: .loading)]
            }
        }

        var nodes: [DatabaseTreeNode] = tables.map { table in
            let ref = DatabaseTreeTableRef(
                connectionId: connectionId, database: database, schema: schema, table: table
            )
            return node(id: DatabaseTreeNode.tableId(ref), kind: .table(ref))
        }
        nodes += routines.map { routine in
            let ref = DatabaseTreeRoutineRef(
                connectionId: connectionId, database: database, schema: schema, routine: routine
            )
            return node(id: DatabaseTreeNode.routineId(ref), kind: .routine(ref))
        }
        if case .failed(let message) = routinesState {
            nodes.append(statusNode(parentId: parentId, status: .error(message)))
        }
        return nodes
    }

    func statusNode(parentId: String, status: DatabaseTreeNode.Status) -> DatabaseTreeNode {
        node(id: DatabaseTreeNode.statusId(parentId: parentId, status: status), kind: .status(status))
    }

    // MARK: - Per-connection lookups

    func sidebarState(for connectionId: UUID) -> SharedSidebarState? {
        SharedSidebarState.forConnection(connectionId)
    }

    /// The browse database of the connection itself, not of the window hosting
    /// the tree. Only the window's own connection may fall back to the toolbar.
    func activeDatabase(for connectionId: UUID) -> String? {
        if let session = DatabaseManager.shared.activeSessions[connectionId] {
            let name = DatabaseManager.shared.browseDatabaseName(for: session.connection)
            if !name.isEmpty { return name }
        }
        guard connectionId == self.connectionId else { return nil }
        return mainCoordinator?.browseDatabaseName ?? activeDatabase
    }

    // MARK: - Search

    func databaseMatchesSearch(context: SidebarNodeContext, _ metadata: DatabaseMetadata) -> Bool {
        let connectionId = context.connectionId
        if DatabaseTreeFilter.matches(searchText, metadata.name) { return true }
        if case .loaded(let schemas) = service.schemaListState(connectionId: connectionId, database: metadata.name) {
            if schemas.contains(where: { DatabaseTreeFilter.matches(searchText, $0) }) { return true }
            for schema in schemas where schemaContentMatchesSearch(
                connectionId: connectionId, database: metadata.name, schema: schema
            ) {
                return true
            }
        }
        return schemaContentMatchesSearch(connectionId: connectionId, database: metadata.name, schema: nil)
    }

    func schemaContentMatchesSearch(connectionId: UUID, database: String, schema: String?) -> Bool {
        if let schema, DatabaseTreeFilter.matches(searchText, schema) { return true }
        let tables = service.tables(connectionId: connectionId, database: database, schema: schema)
        if tables.contains(where: { DatabaseTreeFilter.matches(searchText, $0.name) }) { return true }
        let routines = service.routines(connectionId: connectionId, database: database, schema: schema)
        return routines.contains { DatabaseTreeFilter.matches(searchText, $0.name) }
    }
}

extension DatabaseTreeOutlineCoordinator: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        resolvedChildren(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        resolvedChildren(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? DatabaseTreeNode)?.isExpandable ?? false
    }
}
