//
//  ConnectionTreeBuilder.swift
//  TablePro
//

import Foundation

enum ConnectionTreeBuilder {
    typealias NodeFactory = (String, DatabaseTreeNode.Kind) -> DatabaseTreeNode

    static let defaultNodeFactory: NodeFactory = { DatabaseTreeNode(id: $0, kind: $1) }

    static func children(
        ofFolder folderId: UUID?,
        groups: [ConnectionGroup],
        connections: [DatabaseConnection],
        searchText: String = "",
        makeNode: NodeFactory = defaultNodeFactory
    ) -> [DatabaseTreeNode] {
        let level = level(ofFolder: folderId, groups: groups, connections: connections, searchText: searchText)
        return level.map { item in
            switch item {
            case .group(let group, _):
                return makeNode(DatabaseTreeNode.folderId(group), .folder(group))
            case .connection(let connection):
                return makeNode(DatabaseTreeNode.connectionNodeId(connection.id), .connection(connection))
            }
        }
    }

    static func containsMatch(
        groups: [ConnectionGroup],
        connections: [DatabaseConnection],
        searchText: String
    ) -> Bool {
        !level(ofFolder: nil, groups: groups, connections: connections, searchText: searchText).isEmpty
    }

    private static func level(
        ofFolder folderId: UUID?,
        groups: [ConnectionGroup],
        connections: [DatabaseConnection],
        searchText: String
    ) -> [ConnectionGroupTreeNode] {
        let tree = filterGroupTree(
            buildGroupTreeIndexed(groups: groups, connections: connections),
            searchText: searchText
        )
        guard let folderId else { return tree }
        return findGroupChildren(folderId, in: tree) ?? []
    }

    private static func findGroupChildren(
        _ folderId: UUID,
        in items: [ConnectionGroupTreeNode]
    ) -> [ConnectionGroupTreeNode]? {
        for item in items {
            guard case .group(let group, let children) = item else { continue }
            if group.id == folderId { return children }
            if let found = findGroupChildren(folderId, in: children) { return found }
        }
        return nil
    }
}
