//
//  DatabaseSessionLifecycleTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@MainActor
private final class OpenerSpy {
    var calls: [DatabaseScope] = []
    var drivers: [MockDatabaseDriver] = []
    var gate: CheckedContinuation<Void, Never>?
    var holdsOpen = false

    func open(_ scope: DatabaseScope) async throws -> DatabaseDriver {
        calls.append(scope)
        if holdsOpen {
            await withCheckedContinuation { gate = $0 }
        }
        let driver = MockDatabaseDriver()
        drivers.append(driver)
        return driver
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@Suite("Database session lifecycle", .serialized)
@MainActor
struct DatabaseSessionLifecycleTests {
    private let manager = DatabaseManager.shared

    private func inject(type: DatabaseType = .postgresql, database: String = "app") -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: database, type: type)
        var session = ConnectionSession(connection: connection)
        session.driver = MockDatabaseDriver()
        session.status = .connected
        session.openDatabases = [database]
        manager.injectSession(session, for: connection.id)
        return connection
    }

    private func withSpy(_ spy: OpenerSpy, _ body: () async throws -> Void) async rethrows {
        let original = manager.databaseDriverOpener
        manager.databaseDriverOpener = { try await spy.open($0) }
        defer { manager.databaseDriverOpener = original }
        try await body()
    }

    private func scope(_ connection: DatabaseConnection, _ database: String) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: database, schema: nil)
    }

    @Test("Opening a non-default PostgreSQL database gives it one driver and marks it open")
    func openingCreatesOneDriver() async throws {
        let connection = inject()
        defer { manager.removeSession(for: connection.id) }
        let spy = OpenerSpy()

        try await withSpy(spy) {
            try await manager.markDatabaseOpen("reports", for: connection.id)
            try await manager.markDatabaseOpen("reports", for: connection.id)
        }
        defer { manager.closeAllDatabaseSessions(for: connection.id) }

        #expect(spy.calls == [scope(connection, "reports")])
        #expect(manager.isDatabaseOpen("reports", for: connection.id))
        #expect(manager.databaseDriver(for: "reports", connectionId: connection.id) === spy.drivers.first)
    }

    @Test("Two quick opens share one driver")
    func concurrentOpensShareOneDriver() async throws {
        let connection = inject()
        defer { manager.removeSession(for: connection.id) }
        let spy = OpenerSpy()
        spy.holdsOpen = true

        try await withSpy(spy) {
            async let first = manager.openDatabaseSession("reports", for: connection.id)
            async let second = manager.openDatabaseSession("reports", for: connection.id)
            while spy.gate == nil { await Task.yield() }
            spy.release()
            let (a, b) = try await (first, second)
            #expect(a === b)
        }
        defer { manager.closeAllDatabaseSessions(for: connection.id) }

        #expect(spy.calls.count == 1)
    }

    @Test("A late open whose database was closed discards its own driver")
    func lateOpenAfterCloseIsDiscarded() async throws {
        let connection = inject()
        defer { manager.removeSession(for: connection.id) }
        let spy = OpenerSpy()
        spy.holdsOpen = true

        await withSpy(spy) {
            let open = Task { try await manager.openDatabaseSession("reports", for: connection.id) }
            while spy.gate == nil { await Task.yield() }
            manager.closeDatabaseSession("reports", for: connection.id)
            spy.release()
            await #expect(throws: (any Error).self) { try await open.value }
        }

        #expect(manager.databaseDriver(for: "reports", connectionId: connection.id) == nil)
        #expect(spy.drivers.first?.disconnectCallCount == 1)
    }

    @Test("User SQL on an open database reuses that database's driver across runs")
    func runsShareOneDriver() async throws {
        let connection = inject()
        defer { manager.removeSession(for: connection.id) }
        let spy = OpenerSpy()
        let reports = scope(connection, "reports")

        try await withSpy(spy) {
            try await manager.markDatabaseOpen("reports", for: connection.id)
            let route = manager.executionRoute(for: reports)
            #expect(route == .databaseSession)
            let first = try await manager.withScopedDriver(scope: reports, route: route) { ObjectIdentifier($0) }
            let second = try await manager.withScopedDriver(scope: reports, route: route) { ObjectIdentifier($0) }
            #expect(first == second)
        }
        defer { manager.closeAllDatabaseSessions(for: connection.id) }

        #expect(spy.calls.count == 1)
        #expect(manager.session(for: connection.id)?.resolvedBrowseDatabase == "app")
    }

    @Test("A closed database refuses to run instead of opening a hidden driver")
    func closedDatabaseIsUnavailable() async {
        let connection = inject()
        defer { manager.removeSession(for: connection.id) }
        let spy = OpenerSpy()
        let reports = scope(connection, "reports")

        guard case .unavailable(let message) = manager.executionRoute(for: reports) else {
            Issue.record("expected a closed database to be unavailable")
            return
        }
        #expect(message.contains("reports"))
        await withSpy(spy) {
            await #expect(throws: DatabaseError.self) {
                try await manager.withScopedDriver(scope: reports, route: .databaseSession) { _ in }
            }
        }
        #expect(spy.calls.isEmpty)
    }

    @Test("MCP runs a database the user has not opened on a pooled connection")
    func externalCallersUseThePool() {
        let connection = inject()
        defer { manager.removeSession(for: connection.id) }

        #expect(manager.externalExecutionRoute(for: scope(connection, "reports")) == .pooled)
        #expect(manager.externalExecutionRoute(for: scope(connection, "app")) == .sessionDriver)
    }

    @Test("A caller that joined an open cancelled by Close gets no driver")
    func joinedOpenAfterCloseFails() async {
        let connection = inject()
        defer { manager.removeSession(for: connection.id) }
        let spy = OpenerSpy()
        spy.holdsOpen = true

        await withSpy(spy) {
            let first = Task { try await manager.openDatabaseSession("reports", for: connection.id) }
            while spy.gate == nil { await Task.yield() }
            let second = Task { try await manager.openDatabaseSession("reports", for: connection.id) }
            await Task.yield()
            manager.closeDatabaseSession("reports", for: connection.id)
            spy.release()
            await #expect(throws: (any Error).self) { try await first.value }
            await #expect(throws: (any Error).self) { try await second.value }
        }

        #expect(manager.databaseDriver(for: "reports", connectionId: connection.id) == nil)
    }

    @Test("A tab on another database does not borrow the default database's schema")
    func otherDatabaseKeepsItsOwnSchema() {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        var session = ConnectionSession(connection: connection)
        session.driver = MockDatabaseDriver()
        session.browseSchema = "sales"
        manager.injectSession(session, for: connection.id)
        defer { manager.removeSession(for: connection.id) }

        #expect(manager.resolvedScope(database: "reports", schema: nil, for: connection.id)?.schema == nil)
        #expect(manager.resolvedScope(database: "app", schema: nil, for: connection.id)?.schema == "sales")
    }

    @Test("The default database never gets a second driver")
    func defaultDatabaseUsesTheSessionDriver() async throws {
        let connection = inject()
        defer { manager.removeSession(for: connection.id) }
        let spy = OpenerSpy()

        try await withSpy(spy) {
            try await manager.markDatabaseOpen("app", for: connection.id)
        }

        #expect(spy.calls.isEmpty)
        #expect(manager.executionRoute(for: scope(connection, "app")) == .sessionDriver)
    }

    @Test("Closing the default database is refused")
    func defaultDatabaseIsNotClosable() async {
        let connection = inject()
        defer { manager.removeSession(for: connection.id) }

        await #expect(throws: DatabaseError.self) {
            try await manager.closeDatabase("app", for: connection.id)
        }
        #expect(manager.isDatabaseOpen("app", for: connection.id))
    }

    @Test("Closing a database disconnects its driver and marks it closed")
    func closingDisconnectsTheDriver() async throws {
        let connection = inject()
        defer { manager.removeSession(for: connection.id) }
        let spy = OpenerSpy()

        try await withSpy(spy) {
            try await manager.markDatabaseOpen("reports", for: connection.id)
            try await manager.closeDatabase("reports", for: connection.id)
        }

        #expect(!manager.isDatabaseOpen("reports", for: connection.id))
        #expect(manager.databaseDriver(for: "reports", connectionId: connection.id) == nil)
        #expect(spy.drivers.first?.disconnectCallCount == 1)
    }

    @Test("A database with a running query cannot be closed")
    func busyDatabaseIsNotClosable() async throws {
        let connection = inject()
        defer { manager.removeSession(for: connection.id) }
        let spy = OpenerSpy()

        try await withSpy(spy) {
            let driver = try await manager.openDatabaseSession("reports", for: connection.id)
            manager.runningDrivers[connection.id, default: [:]][UUID()] = RunningDriver(driver: driver, owner: nil)
        }
        defer {
            manager.runningDrivers.removeValue(forKey: connection.id)
            manager.closeAllDatabaseSessions(for: connection.id)
        }

        await #expect(throws: DatabaseError.self) {
            try await manager.closeDatabase("reports", for: connection.id)
        }
    }

    @Test("Disconnect closes every database driver of the connection")
    func disconnectClosesDatabaseDrivers() async throws {
        let connection = inject()
        let spy = OpenerSpy()

        try await withSpy(spy) {
            try await manager.markDatabaseOpen("reports", for: connection.id)
            try await manager.markDatabaseOpen("archive", for: connection.id)
        }
        await manager.disconnectSession(connection.id)

        #expect(manager.databaseDriverCount(for: connection.id) == 0)
        #expect(spy.drivers.allSatisfy { $0.disconnectCallCount == 1 })
    }

    @Test("Rebuilding after a reconnect replaces each database driver")
    func rebuildReplacesDrivers() async throws {
        let connection = inject()
        defer { manager.removeSession(for: connection.id) }
        let spy = OpenerSpy()

        try await withSpy(spy) {
            try await manager.markDatabaseOpen("reports", for: connection.id)
            manager.rebuildDatabaseSessions(for: connection.id)
            while spy.calls.count < 2 { await Task.yield() }
            while manager.databaseDriver(for: "reports", connectionId: connection.id) == nil { await Task.yield() }
        }
        defer { manager.closeAllDatabaseSessions(for: connection.id) }

        #expect(spy.drivers.first?.disconnectCallCount == 1)
        #expect(manager.databaseDriver(for: "reports", connectionId: connection.id) === spy.drivers.last)
    }

    @Test("Stop cancels only the queries the window started")
    func stopIsScopedToItsOwner() throws {
        let connection = inject()
        defer {
            manager.runningDrivers.removeValue(forKey: connection.id)
            manager.removeSession(for: connection.id)
        }
        let mine = MockDatabaseDriver()
        let theirs = MockDatabaseDriver()
        let myWindow = UUID()
        manager.runningDrivers[connection.id] = [
            UUID(): RunningDriver(driver: mine, owner: myWindow),
            UUID(): RunningDriver(driver: theirs, owner: UUID())
        ]

        try manager.cancelRunningQuery(for: connection.id, owner: myWindow)

        #expect(mine.cancelQueryCallCount == 1)
        #expect(theirs.cancelQueryCallCount == 0)
    }

    @Test("An engine that cannot pool keeps one database per connection")
    func enginesThatCannotPoolRefuseASecondDatabase() async {
        let connection = inject(type: .pglite)
        defer { manager.removeSession(for: connection.id) }

        await #expect(throws: DatabaseError.self) {
            try await manager.markDatabaseOpen("reports", for: connection.id)
        }
        #expect(!manager.isDatabaseOpen("reports", for: connection.id))
    }
}
