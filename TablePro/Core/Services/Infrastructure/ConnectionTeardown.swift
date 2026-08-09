//
//  ConnectionTeardown.swift
//  TablePro
//

import AppKit
import Foundation

/// Everything that outlives a deleted connection, torn down in one place.
///
/// Deleting a connection is the only event that ends a connection's whole
/// existence, so it is the only event allowed to drop the per-connection
/// registries. Disconnecting does not: the tree keeps showing the connection in
/// every window afterwards, and a view still holding the old state object would
/// diverge from the registry the moment either side changed.
@MainActor
internal enum ConnectionTeardown {
    /// Connections whose teardown is in flight. Closing a deleted connection's
    /// windows makes `WindowLifecycleMonitor` reach its own disconnect decision,
    /// and two disconnects for one session both clear the window-close guard
    /// before either removes the session entry: the driver gets torn down twice
    /// and whichever finishes last re-registers the state the other just
    /// dropped. Teardown owns the disconnect for these ids; the window-close
    /// path stands down.
    private static var inFlight: Set<UUID> = []

    internal static func isTearingDown(_ connectionId: UUID) -> Bool {
        inFlight.contains(connectionId)
    }

    internal static func removeConnection(_ connectionId: UUID) {
        begin(connectionId)
        Task { @MainActor in
            await finish(connectionId)
        }
    }

    /// Claims ownership of the disconnect and closes the connection's windows.
    /// Split from `finish` so the whole teardown can be awaited in a test
    /// instead of racing the detached task `removeConnection` spawns.
    internal static func begin(_ connectionId: UUID) {
        ConnectionTreeState.shared.forget(connectionId: connectionId)
        inFlight.insert(connectionId)

        for window in WindowLifecycleMonitor.shared.windows(for: connectionId) {
            window.close()
        }
    }

    internal static func finish(_ connectionId: UUID) async {
        await DatabaseManager.shared.disconnectSession(connectionId)
        SharedSidebarState.removeConnection(connectionId)
        SidebarViewModel.removeConnection(connectionId)
        inFlight.remove(connectionId)
    }

    internal static func removeConnections(_ connectionIds: some Sequence<UUID>) {
        for connectionId in connectionIds {
            removeConnection(connectionId)
        }
    }
}
