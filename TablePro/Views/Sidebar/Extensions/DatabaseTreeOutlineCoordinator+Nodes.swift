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
        case .recentSection:
            return recentTableRefs().map {
                self.node(id: DatabaseTreeNode.recentTableId($0), kind: .recentTable($0))
            }
        case .database(_, let metadata):
            return supportsSchemaLevel
                ? schemaNodes(database: metadata.name)
                : objectNodes(database: metadata.name, schema: nil)
        case .schema(_, let database, let schema):
            return objectNodes(database: database, schema: schema)
        case .table(let ref):
            return ref.table.type == .partitionedTable ? partitionNodes(of: ref) : []
        case .connectionRoot, .folder, .connection, .recentTable, .routine, .status:
            return []
        }
    }

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

    private func rootNodes() -> [DatabaseTreeNode] {
        var nodes: [DatabaseTreeNode] = []
        if !recentTableRefs().isEmpty {
            nodes.append(node(
                id: DatabaseTreeNode.recentSectionId(connectionId: connectionId),
                kind: .recentSection(connectionId: connectionId)
            ))
        }
        let visible = DatabaseTreeVisibility.visible(
            databases: service.databases(for: connectionId),
            selected: sidebarState?.databaseFilterSelected ?? [],
            activeDatabase: mainCoordinator?.browseDatabaseName ?? activeDatabase
        )
        let matched = searchText.isEmpty ? visible : visible.filter { databaseMatchesSearch($0) }
        var seen = Set<String>()
        nodes += matched
            .filter { seen.insert($0.id).inserted }
            .map {
                node(
                    id: DatabaseTreeNode.databaseId(connectionId: connectionId, database: $0.name),
                    kind: .database(connectionId: connectionId, metadata: $0)
                )
            }
        return nodes
    }

    private func recentTableRefs() -> [DatabaseTreeTableRef] {
        guard let sidebarState, AppSettingsManager.shared.general.showRecentTables else { return [] }
        let database = mainCoordinator?.browseDatabaseName ?? activeDatabase ?? ""
        return sidebarState.recentEntries(inDatabase: database).compactMap { entry -> DatabaseTreeTableRef? in
            if !searchText.isEmpty, !DatabaseTreeFilter.matches(searchText, entry.name) { return nil }
            return DatabaseTreeTableRef(
                connectionId: connectionId, database: database, schema: entry.schema, table: entry.tableInfo
            )
        }
    }

    private func schemaNodes(database: String) -> [DatabaseTreeNode] {
        let parentId = DatabaseTreeNode.databaseId(connectionId: connectionId, database: database)
        switch service.schemaListState(connectionId: connectionId, database: database) {
        case .idle, .loading:
            return [statusNode(parentId: parentId, status: .loading)]
        case .failed(let message):
            return [statusNode(parentId: parentId, status: .error(message))]
        case .loaded(let schemas):
            let visible = DatabaseTreeFilter.visibleSchemas(
                schemas,
                systemSchemas: systemSchemas,
                searchText: searchText,
                contentMatches: { schemaContentMatchesSearch(database: database, schema: $0) }
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

    private func objectNodes(database: String, schema: String?) -> [DatabaseTreeNode] {
        let parentId = schema
            .map { DatabaseTreeNode.schemaId(connectionId: connectionId, database: database, schema: $0) }
            ?? DatabaseTreeNode.databaseId(connectionId: connectionId, database: database)
        switch service.tablesLoadState(connectionId: connectionId, database: database, schema: schema) {
        case .idle, .loading:
            return [statusNode(parentId: parentId, status: .loading)]
        case .failed(let message):
            return [statusNode(parentId: parentId, status: .error(message))]
        case .loaded:
            return loadedObjectNodes(database: database, schema: schema, parentId: parentId)
        }
    }

    private func loadedObjectNodes(database: String, schema: String?, parentId: String) -> [DatabaseTreeNode] {
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

    // MARK: - Search

    func databaseMatchesSearch(_ metadata: DatabaseMetadata) -> Bool {
        if DatabaseTreeFilter.matches(searchText, metadata.name) { return true }
        if case .loaded(let schemas) = service.schemaListState(connectionId: connectionId, database: metadata.name) {
            if schemas.contains(where: { DatabaseTreeFilter.matches(searchText, $0) }) { return true }
            for schema in schemas where schemaContentMatchesSearch(database: metadata.name, schema: schema) {
                return true
            }
        }
        return schemaContentMatchesSearch(database: metadata.name, schema: nil)
    }

    func schemaContentMatchesSearch(database: String, schema: String?) -> Bool {
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
