//
//  DatabaseTreeView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct DatabaseTreeTableRef: Hashable, Identifiable {
    let connectionId: UUID
    let database: String
    let schema: String?
    let table: TableInfo

    var id: String {
        "\(connectionId.uuidString)|\(database)|\(schema ?? "")|\(table.id)"
    }

    static func == (lhs: DatabaseTreeTableRef, rhs: DatabaseTreeTableRef) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct DatabaseTreeRoutineRef: Identifiable {
    let connectionId: UUID
    let database: String
    let schema: String?
    let routine: RoutineInfo

    var id: String {
        "\(connectionId.uuidString)|\(database)|\(schema ?? "")|\(routine.id)"
    }
}

struct DatabaseTreeView: View {
    @Bindable private var treeService = DatabaseTreeMetadataService.shared

    let connectionId: UUID
    let databaseType: DatabaseType
    let viewModel: SidebarViewModel
    let windowState: WindowSidebarState
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>
    let coordinator: MainContentCoordinator?
    let sidebarState: SharedSidebarState

    @State private var searchText: String = ""

    private var activeDatabase: String? {
        let name = coordinator?.toolbarState.currentDatabase ?? ""
        return name.isEmpty ? nil : name
    }

    private var activeSchema: String? {
        coordinator?.toolbarState.currentSchema
    }

    private var isConnected: Bool {
        DatabaseManager.shared.session(for: connectionId)?.status == .connected
    }

    private var connectionToken: String {
        isConnected ? "connected" : "down"
    }

    /// The tree spans every saved connection, so it always renders. Per-connection
    /// loading, empty and error states are status rows under their own connection
    /// node; gating the whole outline on one connection would hide the others.
    var body: some View {
        outline
        .task(id: connectionToken) {
            await treeService.loadDatabases(connectionId: connectionId, databaseType: databaseType)
        }
        .task(id: viewModel.searchText) {
            let live = viewModel.searchText
            guard !live.isEmpty else { searchText = ""; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            searchText = live
        }
    }

    private var outline: some View {
        DatabaseTreeOutlineView(
            connectionId: connectionId,
            databaseType: databaseType,
            coordinator: coordinator,
            windowState: windowState,
            sidebarState: sidebarState,
            viewModel: viewModel,
            pendingTruncates: [connectionId: pendingTruncates],
            pendingDeletes: [connectionId: pendingDeletes],
            searchText: searchText,
            connectionToken: connectionToken,
            activeDatabase: activeDatabase,
            activeSchema: activeSchema
        )
    }
}
