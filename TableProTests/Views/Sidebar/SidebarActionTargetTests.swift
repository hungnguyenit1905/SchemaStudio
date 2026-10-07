//
//  SidebarActionTargetTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Sidebar action target", .serialized)
@MainActor
struct SidebarActionTargetTests {
    private func inject(_ connection: DatabaseConnection, safeMode: SafeModeLevel) {
        var session = ConnectionSession(connection: connection)
        session.driver = MockDatabaseDriver()
        session.status = .connected
        session.safeModeLevel = safeMode
        DatabaseManager.shared.injectSession(session, for: connection.id)
    }

    private func makeHost(_ connection: DatabaseConnection) -> MainContentCoordinator {
        SessionStateFactory.create(connection: connection, payload: nil).coordinator
    }

    @Test("Safe mode comes from the node's connection, not the host window")
    func safeModeFollowsNodeConnection() {
        let host = makeHost(TestFixtures.makeConnection(name: "Host"))
        defer { host.teardown() }
        let locked = TestFixtures.makeConnection(name: "Locked", type: .postgresql)
        inject(locked, safeMode: .readOnly)
        defer { DatabaseManager.shared.removeSession(for: locked.id) }

        let action = SidebarActionTarget(
            scope: DatabaseScope(connectionId: locked.id, database: "app", schema: nil),
            host: host
        )

        #expect(action.isReadOnly)
        #expect(action.databaseType == .postgresql)
    }

    @Test("A writable node stays writable inside a read-only host")
    func writableNodeInReadOnlyHost() {
        var hostConnection = TestFixtures.makeConnection(name: "Host")
        hostConnection.safeModeLevel = .readOnly
        let host = makeHost(hostConnection)
        defer { host.teardown() }
        let writable = TestFixtures.makeConnection(name: "Open")
        inject(writable, safeMode: .silent)
        defer { DatabaseManager.shared.removeSession(for: writable.id) }

        let action = SidebarActionTarget(
            scope: DatabaseScope(connectionId: writable.id, database: "app", schema: nil),
            host: host
        )

        #expect(!action.isReadOnly)
    }

    @Test("A node on the host's own connection uses the host's live safe mode")
    func hostConnectionUsesHostSafeMode() {
        var hostConnection = TestFixtures.makeConnection(name: "Host")
        hostConnection.safeModeLevel = .readOnly
        let host = makeHost(hostConnection)
        defer { host.teardown() }

        let action = SidebarActionTarget(
            scope: DatabaseScope(connectionId: hostConnection.id, database: "other", schema: nil),
            host: host
        )

        #expect(action.isReadOnly)
        #expect(action.coordinator === host)
    }

    @Test("A scoped connection carries the node's database")
    func connectionScopedToDatabase() {
        let connection = TestFixtures.makeConnection(database: "app")
        inject(connection, safeMode: .silent)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let action = SidebarActionTarget(
            scope: DatabaseScope(connectionId: connection.id, database: "reports", schema: nil),
            host: nil
        )

        #expect(action.connectionScoped(to: "reports")?.database == "reports")
        #expect(action.connectionScoped(to: "reports")?.id == connection.id)
    }

    @Test("New work in a window follows its selected scope on the same connection")
    func newWorkScopeFollowsSelection() {
        let connection = TestFixtures.makeConnection(database: "app")
        let host = makeHost(connection)
        defer { host.teardown() }

        host.windowSidebarState.selectedScope = SidebarScope(
            connectionId: connection.id,
            database: "reports",
            schema: "sales"
        )

        #expect(host.newWorkScope == DatabaseScope(connectionId: connection.id, database: "reports", schema: "sales"))
    }

    @Test("A selected scope on another connection does not retarget this window's new work")
    func newWorkScopeIgnoresForeignSelection() {
        let connection = TestFixtures.makeConnection(database: "app")
        let host = makeHost(connection)
        defer { host.teardown() }

        host.windowSidebarState.selectedScope = SidebarScope(connectionId: UUID(), database: "reports")

        #expect(host.newWorkScope.connectionId == connection.id)
        #expect(host.newWorkScope.database != "reports")
    }
}
