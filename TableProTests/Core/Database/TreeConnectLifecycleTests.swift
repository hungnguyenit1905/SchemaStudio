//
//  TreeConnectLifecycleTests.swift
//  TableProTests
//
//  A session used to live and die with its windows. The sidebar tree now shows
//  every saved connection in every window, so it holds sessions too, and a
//  connect can start from a node instead of from opening a connection. These
//  pin the rules that split apart as a result: what keeps a session alive, what
//  a disconnect is allowed to throw away, and how the tree learns that the
//  saved connection list changed.
//

import AppKit
import Foundation
import TableProPluginKit
import Testing

@testable import SchemaStudio

@Suite("Tree connect lifecycle")
@MainActor
struct TreeConnectLifecycleTests {
    // MARK: - What keeps a session alive

    @Test("Closing the last tab of a connection still expanded in the tree keeps its session")
    func expandedConnectionSurvivesItsLastTab() {
        let shouldDisconnect = WindowCloseDisconnectPolicy.shouldDisconnect(
            hasRemainingWindowsForConnection: false,
            isExpandedInTree: true,
            hasAnyRemainingWindow: true
        )

        #expect(shouldDisconnect == false)
    }

    @Test("Closing the last tab of a collapsed connection disconnects it as before")
    func collapsedConnectionDisconnectsOnItsLastTab() {
        let shouldDisconnect = WindowCloseDisconnectPolicy.shouldDisconnect(
            hasRemainingWindowsForConnection: false,
            isExpandedInTree: false,
            hasAnyRemainingWindow: true
        )

        #expect(shouldDisconnect)
    }

    @Test("A connection with windows left is never disconnected, expanded or not")
    func remainingWindowsAlwaysHoldTheSession() {
        for expanded in [true, false] {
            #expect(
                WindowCloseDisconnectPolicy.shouldDisconnect(
                    hasRemainingWindowsForConnection: true,
                    isExpandedInTree: expanded,
                    hasAnyRemainingWindow: true
                ) == false
            )
        }
    }

    /// Without this the expansion set outlives the tree that justified it: the
    /// last editor window closes, no sidebar is left on screen, and a remembered
    /// id holds a session the user can neither see nor close.
    @Test("An expanded connection still disconnects when no editor window is left to draw the tree")
    func lastWindowOfAllEndsTheSession() {
        let shouldDisconnect = WindowCloseDisconnectPolicy.shouldDisconnect(
            hasRemainingWindowsForConnection: false,
            isExpandedInTree: true,
            hasAnyRemainingWindow: false
        )

        #expect(shouldDisconnect)
    }

    // MARK: - Launch does not connect

    @Test("Remembered expansion survives a restart")
    func launchRestoresTheRememberedShape() {
        let defaults = UserDefaults(suiteName: "TreeConnectLifecycleTests.launch")!
        defaults.removePersistentDomain(forName: "TreeConnectLifecycleTests.launch")
        defer { defaults.removePersistentDomain(forName: "TreeConnectLifecycleTests.launch") }

        let remembered = (0 ..< 8).map { _ in UUID() }
        let seed = ConnectionTreeState(defaults: defaults)
        seed.expandedConnectionIds = Set(remembered)

        let restored = ConnectionTreeState(defaults: defaults)

        #expect(restored.expandedConnectionIds == Set(remembered))
    }

    /// Replaying saved expansion runs through the same delegate callback a user
    /// expand does. Only the `isApplyingExpansion` flag separates them, so this
    /// drives the callback directly: without the guard, opening the app with
    /// eight remembered connections fires eight connects and queues eight
    /// password sheets.
    @Test("Replaying saved expansion starts no connect")
    func restoringExpansionDoesNotConnect() {
        let coordinator = DatabaseTreeOutlineCoordinator()
        let connections = (0 ..< 8).map { TestFixtures.makeConnection(name: "Remembered \($0)") }
        defer {
            for connection in connections {
                DatabaseManager.shared.removeSession(for: connection.id)
            }
        }

        coordinator.isApplyingExpansion = true
        for connection in connections {
            coordinator.outlineViewItemWillExpand(expansionNotification(for: connection))
        }

        for connection in connections {
            #expect(DatabaseManager.shared.activeSessions[connection.id] == nil)
            #expect(ConnectionTreeState.shared.expandedConnectionIds.contains(connection.id) == false)
        }
    }

    private func expansionNotification(for connection: DatabaseConnection) -> Notification {
        let node = DatabaseTreeNode(
            id: DatabaseTreeNode.connectionNodeId(connection.id),
            kind: .connection(connection)
        )
        return Notification(
            name: NSOutlineView.itemWillExpandNotification,
            object: nil,
            userInfo: ["NSObject": node]
        )
    }

    // MARK: - Connect failures

    @Test("A recorded connect failure is readable per connection and cleared on retry")
    func connectFailureRoundTrips() {
        let defaults = UserDefaults(suiteName: "TreeConnectLifecycleTests.failure")!
        defaults.removePersistentDomain(forName: "TreeConnectLifecycleTests.failure")
        defer { defaults.removePersistentDomain(forName: "TreeConnectLifecycleTests.failure") }

        let state = ConnectionTreeState(defaults: defaults)
        let failing = UUID()
        let healthy = UUID()

        state.recordConnectFailure(failing, message: "Access denied for user 'root'")

        #expect(state.connectFailures[failing] == "Access denied for user 'root'")
        #expect(state.connectFailures[healthy] == nil)

        state.clearConnectFailure(failing)

        #expect(state.connectFailures[failing] == nil)
    }

    /// A message from a previous launch describes a state the user cannot act
    /// on, so it must not come back with the expansion set.
    @Test("A connect failure does not survive a restart while the expansion does")
    func connectFailureIsNotPersisted() {
        let defaults = UserDefaults(suiteName: "TreeConnectLifecycleTests.failurePersistence")!
        defaults.removePersistentDomain(forName: "TreeConnectLifecycleTests.failurePersistence")
        defer { defaults.removePersistentDomain(forName: "TreeConnectLifecycleTests.failurePersistence") }

        let connectionId = UUID()
        let state = ConnectionTreeState(defaults: defaults)
        state.expandedConnectionIds = [connectionId]
        state.recordConnectFailure(connectionId, message: "Connection refused")

        let restored = ConnectionTreeState(defaults: defaults)

        #expect(restored.expandedConnectionIds == [connectionId])
        #expect(restored.connectFailures.isEmpty)
    }

    /// Reconnecting from the welcome window or through the health monitor never
    /// touches the tree's record, so a live session has to retire the message.
    /// Otherwise the row stays red and offers a retry over a working connection.
    @Test("A live session hides a stale connect failure")
    func liveSessionRetiresTheFailure() {
        let coordinator = DatabaseTreeOutlineCoordinator()
        let connection = TestFixtures.makeConnection(name: "Recovered")
        ConnectionTreeState.shared.recordConnectFailure(connection.id, message: "Connection refused")
        defer {
            ConnectionTreeState.shared.clearConnectFailure(connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }

        #expect(coordinator.connectFailure(for: connection.id) == "Connection refused")

        var session = ConnectionSession(connection: connection)
        session.driver = MockDatabaseDriver()
        DatabaseManager.shared.injectSession(session, for: connection.id)

        #expect(coordinator.connectFailure(for: connection.id) == nil)
    }

    /// Teardown owns the disconnect for a connection being deleted. Letting the
    /// window-close path run its own would put two disconnects on one session,
    /// and the one that finishes last re-registers the state the other dropped.
    @Test("A connection being torn down suppresses the window-close disconnect")
    func teardownOwnsTheDisconnect() async {
        let connectionId = UUID()

        #expect(ConnectionTeardown.isTearingDown(connectionId) == false)

        ConnectionTeardown.begin(connectionId)

        #expect(ConnectionTeardown.isTearingDown(connectionId))

        await ConnectionTeardown.finish(connectionId)

        #expect(ConnectionTeardown.isTearingDown(connectionId) == false)
    }

    /// The failure this guards: teardown removes the registry entry, then a
    /// second disconnect arriving late calls into the sidebar state and a
    /// get-or-create lookup silently re-registers it under a deleted id.
    @Test("A late second disconnect does not re-register a deleted connection's sidebar state")
    func teardownLeavesNoSidebarStateBehind() async {
        let connection = TestFixtures.makeConnection(name: "Deleted")
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        _ = SharedSidebarState.forConnection(connection.id)

        ConnectionTeardown.begin(connection.id)
        await ConnectionTeardown.finish(connection.id)

        #expect(SharedSidebarState.existing(connection.id) == nil)
        #expect(DatabaseManager.shared.activeSessions[connection.id] == nil)

        await DatabaseManager.shared.disconnectSession(connection.id)

        #expect(SharedSidebarState.existing(connection.id) == nil)
    }

    @Test("Forgetting a connection drops its expansion and its failure together")
    func forgetClearsEverythingForTheConnection() {
        let defaults = UserDefaults(suiteName: "TreeConnectLifecycleTests.forget")!
        defaults.removePersistentDomain(forName: "TreeConnectLifecycleTests.forget")
        defer { defaults.removePersistentDomain(forName: "TreeConnectLifecycleTests.forget") }

        let state = ConnectionTreeState(defaults: defaults)
        let removed = UUID()
        let kept = UUID()
        state.expandedConnectionIds = [removed, kept]
        state.recordConnectFailure(removed, message: "Timed out")

        state.forget(connectionId: removed)

        #expect(state.expandedConnectionIds == [kept])
        #expect(state.connectFailures[removed] == nil)
    }

    // MARK: - The selected scope is per window

    @Test("Selecting a node in one window leaves another window's scope alone")
    func selectedScopeDoesNotBleedAcrossWindows() {
        let connection = TestFixtures.makeConnection(name: "Picked in A")
        let windowA = WindowSidebarState()
        let windowB = WindowSidebarState()
        let treeInA = DatabaseTreeOutlineCoordinator()
        treeInA.windowState = windowA
        let treeInB = DatabaseTreeOutlineCoordinator()
        treeInB.windowState = windowB

        treeInA.adoptSelectedScope(of: .connection(connection))

        #expect(windowA.selectedScope == SidebarScope(connectionId: connection.id))
        #expect(windowB.selectedScope == nil)
        #expect(treeInB.windowState?.selectedScope == nil)
    }

    @Test("Expanding a connection does not change the window's scope")
    func expansionLeavesTheScopeAlone() {
        let connection = TestFixtures.makeConnection(name: "Expanded")
        var session = ConnectionSession(connection: connection)
        session.driver = MockDatabaseDriver()
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let window = WindowSidebarState()
        let previous = SidebarScope(connectionId: UUID(), database: "kept")
        window.selectedScope = previous
        let tree = DatabaseTreeOutlineCoordinator()
        tree.windowState = window

        tree.outlineViewItemWillExpand(expansionNotification(for: connection))
        defer { ConnectionTreeState.shared.forget(connectionId: connection.id) }

        #expect(window.selectedScope == previous)
    }

    @Test("A tree drops its selected scope once that connection no longer resolves")
    func deletedConnectionStopsBeingTheSelectedScope() {
        let coordinator = DatabaseTreeOutlineCoordinator()
        let windowState = WindowSidebarState()
        let deleted = UUID()
        coordinator.windowState = windowState
        windowState.selectedScope = SidebarScope(connectionId: deleted, database: "app")
        coordinator.contextResolver = SidebarNodeContextResolver(
            connection: { _ in nil },
            session: { _ in nil },
            groupingStrategy: { _ in .byDatabase },
            systemSchemas: { _ in [] }
        )

        coordinator.attach(outlineView: NSOutlineView())
        coordinator.refresh()

        #expect(windowState.selectedScope == nil)
    }

    // MARK: - Disconnect keeps the tree's state

    /// The connection stays in every window's tree after a disconnect, so its
    /// sidebar state has to stay with it. Dropping the registry entry strands
    /// whichever view still holds the old instance and loses what the user typed.
    @Test("Disconnect keeps the sidebar state so recent tables and search text survive a reconnect")
    func disconnectPreservesSidebarState() async {
        let connection = TestFixtures.makeConnection(name: "Reconnect me")
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer {
            DatabaseManager.shared.removeSession(for: connection.id)
            SharedSidebarState.removeConnection(connection.id)
        }

        let before = SharedSidebarState.forConnection(connection.id)
        before.searchText = "orders"

        await DatabaseManager.shared.disconnectSession(connection.id)

        let after = SharedSidebarState.forConnection(connection.id)
        #expect(after === before)
        #expect(after.searchText == "orders")
    }

    @Test("Disconnect drops the key tree so it cannot leak into the next session")
    func disconnectClearsSessionBoundState() async {
        let connection = TestFixtures.makeConnection(name: "Redis", type: .redis)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer {
            DatabaseManager.shared.removeSession(for: connection.id)
            SharedSidebarState.removeConnection(connection.id)
        }

        let state = SharedSidebarState.forConnection(connection.id)
        state.redisKeyTreeViewModel = RedisKeyTreeViewModel()

        await DatabaseManager.shared.disconnectSession(connection.id)

        #expect(SharedSidebarState.forConnection(connection.id).redisKeyTreeViewModel == nil)
    }

    // MARK: - Connection list sync

    @Test("Adding a connection notifies with the new record already on disk")
    func addNotifiesAfterPersisting() {
        let storage = makeScratchStorage()
        let connection = TestFixtures.makeConnection(name: "Added")

        let seen = withNotification {
            storage.addConnection(connection)
        }

        #expect(seen)
        #expect(storage.loadConnections().contains { $0.id == connection.id })
    }

    @Test("Editing a connection notifies with the edit already on disk")
    func updateNotifiesAfterPersisting() {
        let storage = makeScratchStorage()
        var connection = TestFixtures.makeConnection(name: "Before")
        storage.addConnection(connection)
        connection.name = "After"

        let seen = withNotification {
            storage.updateConnection(connection)
        }

        #expect(seen)
        #expect(storage.loadConnection(id: connection.id)?.name == "After")
    }

    @Test("Deleting a connection notifies and forgets it in the tree")
    func deleteNotifiesAndForgetsTreeState() {
        let storage = makeScratchStorage()
        let connection = TestFixtures.makeConnection(name: "Doomed")
        storage.addConnection(connection)
        ConnectionTreeState.shared.expandedConnectionIds.insert(connection.id)
        defer { ConnectionTreeState.shared.forget(connectionId: connection.id) }

        let seen = withNotification {
            storage.deleteConnection(connection)
        }

        #expect(seen)
        #expect(storage.loadConnection(id: connection.id) == nil)
        #expect(ConnectionTreeState.shared.expandedConnectionIds.contains(connection.id) == false)
    }

    // MARK: - Helpers

    private func makeScratchStorage() -> ConnectionStorage {
        let suite = "TreeConnectLifecycleTests.storage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        return ConnectionStorage(fileURL: fileURL, userDefaults: defaults, keychain: InMemoryKeychain())
    }

    private func withNotification(_ body: () -> Void) -> Bool {
        var received = false
        let observer = NotificationCenter.default.addObserver(
            forName: .connectionsDidChange, object: nil, queue: nil
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        body()
        return received
    }
}
