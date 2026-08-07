//
//  SidebarViewModel+Session.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

extension SidebarViewModel {
    /// Resolves the view model for any connection the tree shows, not just the
    /// one the window is bound to. Pending table operations are read and written
    /// straight through that connection's own session, so an action taken on a
    /// node can never land on a different connection's session.
    @MainActor
    static func forConnection(
        _ connectionId: UUID,
        databaseType: DatabaseType,
        selectedTables: Binding<Set<DatabaseTreeTableRef>>
    ) -> SidebarViewModel {
        shared(
            connectionId: connectionId,
            databaseType: databaseType,
            selectedTables: selectedTables,
            pendingTruncates: sessionBinding(
                connectionId, get: { $0.pendingTruncates }, set: { $0.pendingTruncates = $1 }, defaultValue: []
            ),
            pendingDeletes: sessionBinding(
                connectionId, get: { $0.pendingDeletes }, set: { $0.pendingDeletes = $1 }, defaultValue: []
            ),
            tableOperationOptions: sessionBinding(
                connectionId,
                get: { $0.tableOperationOptions },
                set: { $0.tableOperationOptions = $1 },
                defaultValue: [:]
            )
        )
    }

    @MainActor
    private static func sessionBinding<Value>(
        _ connectionId: UUID,
        get: @escaping (ConnectionSession) -> Value,
        set: @escaping (inout ConnectionSession, Value) -> Void,
        defaultValue: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let session = DatabaseManager.shared.activeSessions[connectionId] else { return defaultValue }
                return get(session)
            },
            set: { newValue in
                DatabaseManager.shared.updateSession(connectionId) { session in
                    set(&session, newValue)
                }
            }
        )
    }
}
