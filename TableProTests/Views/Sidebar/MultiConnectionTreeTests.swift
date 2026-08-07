//
//  MultiConnectionTreeTests.swift
//  TableProTests
//
//  The sidebar tree spans every saved connection, so nothing it shows may be
//  resolved from the window it happens to live in. These pin the resolution
//  rules that keep two connections from bleeding into each other.
//

import Foundation
import TableProPluginKit
import Testing
@testable import SchemaStudio

@MainActor
@Suite("Multi-connection tree")
struct MultiConnectionTreeTests {
    private func makeResolver(
        connections: [DatabaseConnection],
        sessions: [UUID: ConnectionSession] = [:],
        strategies: [DatabaseType: GroupingStrategy] = [:],
        systemSchemas: [DatabaseType: Set<String>] = [:]
    ) -> SidebarNodeContextResolver {
        SidebarNodeContextResolver(
            connection: { id in connections.first { $0.id == id } },
            session: { sessions[$0] },
            groupingStrategy: { strategies[$0] ?? .byDatabase },
            systemSchemas: { systemSchemas[$0] ?? [] }
        )
    }

    @Test("Each connection resolves its own grouping strategy and system schemas")
    func contextIsPerConnection() throws {
        let mysql = TestFixtures.makeConnection(name: "shop", type: .mysql)
        let postgres = TestFixtures.makeConnection(name: "analytics", type: .postgresql)
        let resolver = makeResolver(
            connections: [mysql, postgres],
            strategies: [.mysql: .byDatabase, .postgresql: .bySchema],
            systemSchemas: [.postgresql: ["pg_catalog"]]
        )

        let mysqlContext = try #require(resolver.context(for: mysql.id))
        let postgresContext = try #require(resolver.context(for: postgres.id))

        #expect(!mysqlContext.supportsSchemaLevel)
        #expect(postgresContext.supportsSchemaLevel)
        #expect(mysqlContext.systemSchemas.isEmpty)
        #expect(postgresContext.systemSchemas == ["pg_catalog"])
    }

    @Test("A connection with no session still resolves, as disconnected")
    func savedConnectionResolvesWithoutSession() throws {
        let saved = TestFixtures.makeConnection(name: "cold", type: .mysql)
        let resolver = makeResolver(connections: [saved])

        let context = try #require(resolver.context(for: saved.id))
        #expect(context.status == .disconnected)
        #expect(!context.isConnected)
    }

    @Test("An unknown connection resolves to nothing rather than a wrong default")
    func unknownConnectionHasNoContext() {
        let resolver = makeResolver(connections: [])
        #expect(resolver.context(for: UUID()) == nil)
    }

    @Test("Safe mode comes from the node's own connection, not a sibling")
    func safeModeIsPerConnection() throws {
        var locked = TestFixtures.makeConnection(name: "prod", type: .mysql)
        locked.safeModeLevel = .readOnly
        var open = TestFixtures.makeConnection(name: "dev", type: .mysql)
        open.safeModeLevel = .silent
        let resolver = makeResolver(connections: [locked, open])

        let lockedContext = try #require(resolver.context(for: locked.id))
        let openContext = try #require(resolver.context(for: open.id))

        #expect(lockedContext.safeModeLevel.blocksAllWrites)
        #expect(!openContext.safeModeLevel.blocksAllWrites)
    }

    // MARK: - Pending marks

    @Test("A pending truncate on one connection does not mark the same table name on another")
    func pendingMarksDoNotLeakAcrossConnections() {
        let first = UUID()
        let second = UUID()
        let context = DatabaseTreeRowContext(
            databaseType: .mysql,
            activeDatabase: "shop",
            activeSchema: nil,
            systemSchemas: [],
            pendingTruncates: [first: ["users"]],
            pendingDeletes: [first: ["orders"]]
        )

        let inFirst = TestFixtures.makeTableRef(name: "users", connectionId: first)
        let inSecond = TestFixtures.makeTableRef(name: "users", connectionId: second)
        let deleteInFirst = TestFixtures.makeTableRef(name: "orders", connectionId: first)
        let deleteInSecond = TestFixtures.makeTableRef(name: "orders", connectionId: second)

        #expect(context.isPendingTruncate(inFirst))
        #expect(!context.isPendingTruncate(inSecond))
        #expect(context.isPendingDelete(deleteInFirst))
        #expect(!context.isPendingDelete(deleteInSecond))
    }

    // MARK: - Tree shape

    @Test("Top level matches Welcome: folders first, then ungrouped connections")
    func topLevelMirrorsWelcomeOrdering() {
        let folder = ConnectionGroup(name: "Staging", sortOrder: 0)
        var grouped = TestFixtures.makeConnection(name: "inside", type: .mysql)
        grouped.groupId = folder.id
        let loose = TestFixtures.makeConnection(name: "outside", type: .mysql)

        let nodes = ConnectionTreeBuilder.children(
            ofFolder: nil,
            groups: [folder],
            connections: [grouped, loose]
        )

        #expect(nodes.count == 2)
        if case .folder(let group) = nodes[0].kind {
            #expect(group.id == folder.id)
        } else {
            Issue.record("expected the folder first")
        }
        if case .connection(let connection) = nodes[1].kind {
            #expect(connection.id == loose.id)
        } else {
            Issue.record("expected the ungrouped connection second")
        }
    }

    @Test("A folder's children are its own connections")
    func folderChildrenAreItsConnections() {
        let folder = ConnectionGroup(name: "Staging")
        var inside = TestFixtures.makeConnection(name: "inside", type: .mysql)
        inside.groupId = folder.id
        let outside = TestFixtures.makeConnection(name: "outside", type: .mysql)

        let nodes = ConnectionTreeBuilder.children(
            ofFolder: folder.id,
            groups: [folder],
            connections: [inside, outside]
        )

        #expect(nodes.count == 1)
        #expect(nodes[0].connectionId == inside.id)
    }

    @Test("Nested folders resolve to three levels")
    func nestedFoldersResolve() {
        let top = ConnectionGroup(name: "Top")
        let middle = ConnectionGroup(name: "Middle", parentId: top.id)
        let bottom = ConnectionGroup(name: "Bottom", parentId: middle.id)
        var leaf = TestFixtures.makeConnection(name: "leaf", type: .mysql)
        leaf.groupId = bottom.id
        let groups = [top, middle, bottom]

        let atBottom = ConnectionTreeBuilder.children(
            ofFolder: bottom.id, groups: groups, connections: [leaf]
        )
        #expect(atBottom.count == 1)
        #expect(atBottom[0].connectionId == leaf.id)
    }

    @Test("A connection whose folder was deleted still shows at the top level")
    func orphanedConnectionStaysVisible() {
        var orphan = TestFixtures.makeConnection(name: "orphan", type: .mysql)
        orphan.groupId = UUID()

        let nodes = ConnectionTreeBuilder.children(ofFolder: nil, groups: [], connections: [orphan])

        #expect(nodes.count == 1)
        #expect(nodes[0].connectionId == orphan.id)
    }

    // MARK: - Search

    @Test("Search matches connection and folder names with nothing expanded")
    func searchMatchesNamesFromStorage() {
        let folder = ConnectionGroup(name: "Staging")
        var inside = TestFixtures.makeConnection(name: "billing", type: .mysql)
        inside.groupId = folder.id
        let other = TestFixtures.makeConnection(name: "reporting", type: .mysql)
        let groups = [folder]
        let connections = [inside, other]

        let byConnection = ConnectionTreeBuilder.children(
            ofFolder: nil, groups: groups, connections: connections, searchText: "report"
        )
        #expect(byConnection.count == 1)
        #expect(byConnection[0].connectionId == other.id)

        let byFolder = ConnectionTreeBuilder.children(
            ofFolder: nil, groups: groups, connections: connections, searchText: "stag"
        )
        #expect(byFolder.count == 1)
        if case .folder(let group) = byFolder[0].kind {
            #expect(group.id == folder.id)
        } else {
            Issue.record("expected the folder to match by name")
        }
    }

    @Test("A search matching nothing yields an empty tree")
    func searchWithNoMatchIsEmpty() {
        let connection = TestFixtures.makeConnection(name: "billing", type: .mysql)
        let nodes = ConnectionTreeBuilder.children(
            ofFolder: nil, groups: [], connections: [connection], searchText: "zzz"
        )
        #expect(nodes.isEmpty)
    }

    @Test("Node identity is stable across rebuilds so the outline keeps its rows")
    func nodeIdentityIsStable() {
        let connection = TestFixtures.makeConnection(name: "billing", type: .mysql)
        let first = ConnectionTreeBuilder.children(ofFolder: nil, groups: [], connections: [connection])
        let second = ConnectionTreeBuilder.children(ofFolder: nil, groups: [], connections: [connection])
        #expect(first[0].id == second[0].id)
    }
}
