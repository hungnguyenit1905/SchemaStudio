//
//  SidebarView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import SwiftUI
import TableProPluginKit

struct SidebarView: View {
    @State private var viewModel: SidebarViewModel
    @State private var favoriteTables: Set<FavoriteTablesStorage.FavoriteEntry> = []
    @State private var settingsManager = AppSettingsManager.shared
    @State private var showDatabaseFilter: Bool = false

    private var schemaService: SchemaService { SchemaService.shared }

    var sidebarState: SharedSidebarState
    var windowState: WindowSidebarState
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>

    var onDoubleClick: ((TableInfo) -> Void)?
    var connectionId: UUID
    private weak var coordinator: MainContentCoordinator?

    private var tables: [TableInfo] {
        schemaService.tables(for: connectionId)
    }

    private var routines: [RoutineInfo] {
        schemaService.routines(for: connectionId)
    }

    private var groupingStrategy: GroupingStrategy {
        PluginManager.shared.databaseGroupingStrategy(for: viewModel.databaseType)
    }

    private var supportsSchemaFooter: Bool {
        PluginManager.shared.supportsSchemaSwitching(for: viewModel.databaseType)
            && groupingStrategy != .hierarchicalSchema
    }

    init(
        sidebarState: SharedSidebarState,
        windowState: WindowSidebarState,
        onDoubleClick: ((TableInfo) -> Void)? = nil,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        databaseType: DatabaseType,
        connectionId: UUID,
        coordinator: MainContentCoordinator? = nil
    ) {
        self.sidebarState = sidebarState
        self.windowState = windowState
        self.onDoubleClick = onDoubleClick
        _pendingTruncates = pendingTruncates
        _pendingDeletes = pendingDeletes
        let selectedBinding = Binding(
            get: { windowState.selectedTables },
            set: { windowState.selectedTables = $0 }
        )
        let vm = SidebarViewModel.shared(
            connectionId: connectionId,
            databaseType: databaseType,
            selectedTables: selectedBinding,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            tableOperationOptions: tableOperationOptions
        )
        vm.searchText = sidebarState.searchText
        if databaseType == .redis, let existingVM = sidebarState.redisKeyTreeViewModel {
            vm.redisKeyTreeViewModel = existingVM
        }
        _viewModel = State(wrappedValue: vm)
        self.connectionId = connectionId
        self.coordinator = coordinator
    }

    // MARK: - Body

    var body: some View {
        Group {
            switch sidebarState.selectedSidebarTab {
            case .tables:
                VStack(spacing: 0) {
                    tablesContent
                    tablesBottomBar
                }
            case .favorites:
                if let coordinator {
                    FavoritesTabView(
                        connectionId: connectionId,
                        sharedSidebarState: sidebarState,
                        tables: tables,
                        coordinator: coordinator
                    )
                } else {
                    Color.clear
                }
            }
        }
        .onChange(of: sidebarState.searchText) { _, newValue in
            viewModel.searchText = newValue
        }
        .onAppear {
            coordinator?.sidebarViewModel = viewModel
            if let driver = DatabaseManager.shared.driver(for: connectionId),
               coordinator?.toolbarState.databaseVersion == nil {
                coordinator?.toolbarState.databaseVersion = driver.serverVersion
            }
        }
        .sheet(isPresented: $viewModel.showOperationDialog) {
            if let operationType = viewModel.pendingOperationType {
                let dialogTables = viewModel.pendingOperationTables
                if let firstTable = dialogTables.first {
                    TableOperationDialog(
                        isPresented: $viewModel.showOperationDialog,
                        tableName: firstTable,
                        tableCount: dialogTables.count,
                        operationType: operationType,
                        databaseType: viewModel.databaseType
                    ) { options in
                        viewModel.confirmOperation(options: options)
                    }
                }
            }
        }
    }

    // MARK: - Tables Content

    private var tablesContent: some View {
        databaseTreeContent
    }

    // MARK: - Bottom Bar

    private var tablesBottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                createObjectMenu
                databaseFilterButton
                DelayedProgressIndicator(isActive: schemaService.isRefreshing(connectionId: connectionId))
                    .accessibilityLabel(String(localized: "Refreshing"))
                Spacer()
                if supportsSchemaFooter {
                    SchemaPickerControl(
                        connectionId: connectionId,
                        databaseType: viewModel.databaseType,
                        coordinator: coordinator
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var isDatabaseFilterActive: Bool {
        !sidebarState.databaseFilterSelected.isEmpty
    }

    private var databaseFilterSelectionBinding: Binding<Set<String>> {
        Binding(
            get: { sidebarState.databaseFilterSelected },
            set: { sidebarState.databaseFilterSelected = $0 }
        )
    }

    private var databaseFilterButton: some View {
        Button {
            showDatabaseFilter = true
        } label: {
            Image(systemName: isDatabaseFilterActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .foregroundStyle(isDatabaseFilterActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Filter databases"))
        .accessibilityIdentifier("sidebar-database-filter")
        .popover(isPresented: $showDatabaseFilter) {
            DatabaseTreeFilterPopover(
                connectionId: connectionId,
                selectedDatabases: databaseFilterSelectionBinding
            )
        }
    }

    private var createObjectMenu: some View {
        Menu {
            Button(String(localized: "New Table")) { coordinator?.createNewTable() }
            Button(String(localized: "New View")) { coordinator?.createView() }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Create a new table or view"))
        .disabled(coordinator?.safeModeLevel.blocksAllWrites ?? true)
        .accessibilityIdentifier("sidebar-create-table")
    }

    @ViewBuilder
    private var databaseTreeContent: some View {
        DatabaseTreeView(
            connectionId: connectionId,
            databaseType: viewModel.databaseType,
            viewModel: viewModel,
            windowState: windowState,
            pendingTruncates: $pendingTruncates,
            pendingDeletes: $pendingDeletes,
            coordinator: coordinator,
            sidebarState: sidebarState
        )
    }

    // MARK: - Table List

    // MARK: - Section View

}

// MARK: - Preview

#Preview {
    SidebarView(
        sidebarState: SharedSidebarState(),
        windowState: WindowSidebarState(),
        pendingTruncates: .constant([]),
        pendingDeletes: .constant([]),
        tableOperationOptions: .constant([:]),
        databaseType: .mysql,
        connectionId: UUID()
    )
    .frame(width: 250, height: 400)
}
