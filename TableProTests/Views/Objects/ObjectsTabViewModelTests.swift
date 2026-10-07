//
//  ObjectsTabViewModelTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Objects tab", .serialized)
@MainActor
struct ObjectsTabViewModelTests {
    private func inject(_ connection: DatabaseConnection, open: Set<String> = []) {
        var session = ConnectionSession(connection: connection)
        session.driver = MockDatabaseDriver()
        session.status = .connected
        session.openDatabases = open.union([connection.database])
        DatabaseManager.shared.injectSession(session, for: connection.id)
    }

    private func resolver(for connection: DatabaseConnection, grouping: GroupingStrategy = .byDatabase) -> SidebarNodeContextResolver {
        SidebarNodeContextResolver(
            connection: { $0 == connection.id ? connection : nil },
            session: { DatabaseManager.shared.session(for: $0) },
            groupingStrategy: { _ in grouping },
            systemSchemas: { _ in [] },
            hasDatabaseLevel: { _ in true }
        )
    }

    private func makeModel(
        _ connection: DatabaseConnection,
        window: WindowSidebarState? = nil,
        grouping: GroupingStrategy = .byDatabase
    ) -> ObjectsTabViewModel {
        ObjectsTabViewModel(
            connectionId: connection.id,
            windowState: window ?? WindowSidebarState(),
            fallbackScope: SidebarScope(connectionId: connection.id, database: connection.database),
            contextResolver: resolver(for: connection, grouping: grouping)
        )
    }

    @Test("The tab follows the window's selected scope")
    func followsSelection() {
        let connection = TestFixtures.makeConnection(name: "Shop", database: "app")
        let window = WindowSidebarState()
        let model = makeModel(connection, window: window)

        #expect(model.scope == SidebarScope(connectionId: connection.id, database: "app"))
        window.selectedScope = SidebarScope(connectionId: connection.id, database: "reports", schema: "sales")

        #expect(model.scope.database == "reports")
        #expect(model.scopeTitle == "Shop · reports · sales")
    }

    @Test("A closed database offers to open it")
    func closedDatabaseShowsOpen() async throws {
        let connection = TestFixtures.makeConnection(database: "app")
        inject(connection)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let window = WindowSidebarState()
        window.selectedScope = SidebarScope(connectionId: connection.id, database: "reports")
        let model = makeModel(connection, window: window)

        #expect(model.content == .closed(database: "reports"))

        model.openDatabase()
        while !DatabaseManager.shared.isDatabaseOpen("reports", for: connection.id) { await Task.yield() }
        #expect(model.content != .closed(database: "reports"))
    }

    @Test("A disconnected connection has nothing to list")
    func disconnectedHasNothing() {
        let connection = TestFixtures.makeConnection()
        let model = makeModel(connection)

        #expect(model.content == .nothing)
    }

    @Test("Activating a database or schema row drills into it")
    func drillsIntoContainers() {
        let connection = TestFixtures.makeConnection(database: "app")
        let window = WindowSidebarState()
        window.selectedScope = SidebarScope(connectionId: connection.id, database: "app")
        let model = makeModel(connection, window: window)
        let database = ObjectsTabViewModel.Row(
            id: "db", name: "reports", kind: .database, typeName: "", rowCount: nil, size: nil, comment: nil
        )
        let schema = ObjectsTabViewModel.Row(
            id: "schema", name: "sales", kind: .schema, typeName: "", rowCount: nil, size: nil, comment: nil
        )

        #expect(model.drillScope(for: database) == SidebarScope(connectionId: connection.id, database: "reports"))
        #expect(model.drillScope(for: schema) == SidebarScope(connectionId: connection.id, database: "app", schema: "sales"))
    }

    @Test("Activating a table row opens it on the tab's own scope")
    func tableRowsCarryTheirScope() {
        let connection = TestFixtures.makeConnection(database: "app")
        inject(connection, open: ["reports"])
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let window = WindowSidebarState()
        window.selectedScope = SidebarScope(connectionId: connection.id, database: "reports", schema: "sales")
        let model = makeModel(connection, window: window)
        let table = TableInfo(name: "orders", type: .table, rowCount: 12, schema: nil)
        let row = ObjectsTabViewModel.Row(
            id: "t", name: "orders", kind: .table(table), typeName: "Table", rowCount: 12, size: nil, comment: nil
        )

        let ref = model.tableRef(for: row)

        #expect(ref?.database == "reports")
        #expect(ref?.schema == "sales")
        #expect(model.drillScope(for: row) == nil)
    }

    @Test("At most one Objects tab per window")
    func oneObjectsTabPerWindow() {
        let tabManager = QueryTabManager()

        tabManager.addObjectsTab(databaseName: "app")
        tabManager.addObjectsTab(databaseName: "reports")

        #expect(tabManager.tabs.filter { $0.tabType == .objects }.count == 1)
        #expect(tabManager.tabs.first?.title == "Objects")
    }

    @Test("The Objects tab title is Objects")
    func windowTitle() {
        let connection = TestFixtures.makeConnection(name: "Shop")
        let tab = QueryTab(title: "Objects", tabType: .objects)

        let title = WindowTitleResolver.resolveTitle(
            tab: tab,
            connection: connection,
            connectionName: "",
            queryLanguageName: nil
        )

        #expect(title == "Objects")
    }
}
