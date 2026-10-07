//
//  DatabaseOpenCloseTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Database open and close in the tree", .serialized)
@MainActor
struct DatabaseOpenCloseTests {
    private func inject(database: String = "app", open: Set<String> = []) -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: database, type: .mysql)
        var session = ConnectionSession(connection: connection)
        session.driver = MockDatabaseDriver()
        session.status = .connected
        session.openDatabases = open.union([database])
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    private func makeTree(for connection: DatabaseConnection, hasDatabaseLevel: Bool = true) -> DatabaseTreeOutlineCoordinator {
        let tree = DatabaseTreeOutlineCoordinator()
        tree.windowState = WindowSidebarState()
        tree.contextResolver = SidebarNodeContextResolver(
            connection: { $0 == connection.id ? connection : nil },
            session: { DatabaseManager.shared.session(for: $0) },
            groupingStrategy: { _ in .byDatabase },
            systemSchemas: { _ in [] },
            hasDatabaseLevel: { _ in hasDatabaseLevel }
        )
        return tree
    }

    private func databaseNode(_ connection: DatabaseConnection, _ name: String) -> DatabaseTreeNode {
        DatabaseTreeNode(
            id: DatabaseTreeNode.databaseId(connectionId: connection.id, database: name),
            kind: .database(connectionId: connection.id, metadata: .minimal(name: name))
        )
    }

    @Test("A closed database is openable, not expandable, and has no children")
    func closedDatabaseIsOpenable() {
        let connection = inject()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let tree = makeTree(for: connection)
        let node = databaseNode(connection, "reports")

        #expect(!tree.isExpandable(node))
        #expect(tree.isOpenable(node))
        #expect(tree.buildChildren(of: node).isEmpty)
    }

    @Test("An open database expands and is not offered as openable")
    func openDatabaseExpands() {
        let connection = inject(open: ["reports"])
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let tree = makeTree(for: connection)
        let node = databaseNode(connection, "reports")

        #expect(tree.isExpandable(node))
        #expect(!tree.isOpenable(node))
    }

    @Test("A connection without a session is openable, not expandable")
    func closedConnectionIsOpenable() {
        let connection = TestFixtures.makeConnection()
        let tree = makeTree(for: connection)
        let node = DatabaseTreeNode(
            id: DatabaseTreeNode.connectionNodeId(connection.id),
            kind: .connection(connection)
        )

        #expect(!tree.isExpandable(node))
        #expect(tree.isOpenable(node))
    }

    @Test("Activating a closed database opens it without touching the session default")
    func activatingOpensTheDatabase() async {
        let connection = inject()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let tree = makeTree(for: connection)

        tree.activate(databaseNode(connection, "reports"), activateGridFocus: false)
        while !DatabaseManager.shared.isDatabaseOpen("reports", for: connection.id) { await Task.yield() }

        #expect(DatabaseManager.shared.openDatabases(for: connection.id) == ["app", "reports"])
        #expect(DatabaseManager.shared.session(for: connection.id)?.resolvedBrowseDatabase == "app")
    }

    @Test("Several databases of one connection stay open together")
    func severalDatabasesStayOpen() async throws {
        let connection = inject()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await DatabaseManager.shared.markDatabaseOpen("reports", for: connection.id)
        try await DatabaseManager.shared.markDatabaseOpen("archive", for: connection.id)

        #expect(DatabaseManager.shared.openDatabases(for: connection.id) == ["app", "reports", "archive"])
    }

    @Test("Closing a database with nothing open on it closes it without a prompt")
    func quietClose() async {
        let connection = inject(open: ["reports"])
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        await DatabaseCloseFlow.closeDatabase("reports", connectionId: connection.id, anchor: nil)

        #expect(!DatabaseManager.shared.isDatabaseOpen("reports", for: connection.id))
    }

    @Test("The close flow never closes the session default database")
    func defaultDatabaseStaysOpen() async {
        let connection = inject(open: ["reports"])
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        await DatabaseCloseFlow.closeDatabase("app", connectionId: connection.id, anchor: nil)

        #expect(DatabaseManager.shared.isDatabaseOpen("app", for: connection.id))
    }

    @Test("Pending operations on a database make its close ask first")
    func pendingOperationsNeedConfirmation() {
        let impact = DatabaseCloseFlow.impact(of: [], pending: [TestFixtures.makeTableRef(name: "users")])

        #expect(impact.needsConfirmation)
        #expect(DatabaseCloseFlow.message(for: impact).contains("1"))
    }

    @Test("A database with no tabs and no pending work closes without asking")
    func nothingToLoseNeedsNoConfirmation() {
        #expect(!DatabaseCloseFlow.impact(of: [], pending: []).needsConfirmation)
    }

    @Test("Structural rows are not selectable, every node row is")
    func selectableRows() {
        let connection = TestFixtures.makeConnection()
        let tree = makeTree(for: connection)
        let outline = NSOutlineView()
        let selectable: [DatabaseTreeNode.Kind] = [
            .connection(connection),
            .database(connectionId: connection.id, metadata: .minimal(name: "app")),
            .schema(connectionId: connection.id, database: "app", schema: "public"),
            .table(TestFixtures.makeTableRef(name: "users"))
        ]
        let structural: [DatabaseTreeNode.Kind] = [
            .connectionRoot, .folder(ConnectionGroup(name: "Work")), .status(.loading), .recentSection(connectionId: connection.id)
        ]

        for kind in selectable {
            #expect(tree.outlineView(outline, shouldSelectItem: DatabaseTreeNode(id: "x", kind: kind)))
        }
        for kind in structural {
            #expect(!tree.outlineView(outline, shouldSelectItem: DatabaseTreeNode(id: "x", kind: kind)))
        }
    }

    @Test("MongoDB and Snowflake show database nodes and Snowflake lists schemas under them")
    func multiDatabaseEnginesGetDatabaseNodes() {
        let mongo = SidebarNodeContext(
            connectionId: UUID(), databaseType: .mongodb, groupingStrategy: .flat,
            systemSchemas: [], safeModeLevel: .silent, status: .connected, hasDatabaseLevel: true
        )
        let snowflake = SidebarNodeContext(
            connectionId: UUID(), databaseType: DatabaseType(rawValue: "Snowflake"), groupingStrategy: .hierarchicalSchema,
            systemSchemas: [], safeModeLevel: .silent, status: .connected, hasDatabaseLevel: true
        )

        #expect(DatabaseLevel.live.hasDatabaseLevel(.mongodb))
        #expect(!mongo.listsSchemasUnderDatabase)
        #expect(snowflake.listsSchemasUnderDatabase)
    }
}
