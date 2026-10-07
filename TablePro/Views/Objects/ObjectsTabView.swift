//
//  ObjectsTabView.swift
//  TablePro
//

import SwiftUI

struct ObjectsTabView: View {
    @Bindable var viewModel: ObjectsTabViewModel
    weak var coordinator: MainContentCoordinator?

    @State private var selection: Set<ObjectsTabViewModel.Row.ID> = []
    @State private var sortOrder = [KeyPathComparator(\ObjectsTabViewModel.Row.name)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { viewModel.loadIfNeeded() }
        .onChange(of: viewModel.scope) { _, _ in
            selection = []
            viewModel.loadIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(viewModel.scopeTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Picker(String(localized: "Show"), selection: $viewModel.filter) {
                ForEach(ObjectsTabViewModel.Filter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        switch viewModel.content {
        case .rows(let rows):
            objectsTable(rows.sorted(using: sortOrder))
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .closed(let database):
            ContentUnavailableView {
                Label(String(format: String(localized: "%@ is closed"), database), systemImage: "cylinder")
            } actions: {
                Button(String(localized: "Open")) { viewModel.openDatabase() }
            }
        case .failed(let message):
            ContentUnavailableView(
                String(localized: "Could not load objects"),
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .nothing:
            ContentUnavailableView(
                String(localized: "Select a connection, database or schema in the sidebar"),
                systemImage: "sidebar.left"
            )
        }
    }

    private func objectsTable(_ rows: [ObjectsTabViewModel.Row]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(String(localized: "Name"), value: \.name)
            TableColumn(String(localized: "Type"), value: \.typeName)
                .width(min: 80, ideal: 110)
            TableColumn(String(localized: "Rows"), value: \.sortableRowCount) { row in
                Text(row.rowCount.map { $0.formatted() } ?? "")
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 90)
            TableColumn(String(localized: "Size"), value: \.sortableSize) { row in
                Text(row.size ?? "")
            }
            .width(min: 60, ideal: 90)
            TableColumn(String(localized: "Comment"), value: \.sortableComment) { row in
                Text(row.comment ?? "")
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: ObjectsTabViewModel.Row.ID.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                Button(String(localized: "Open")) { activate(row) }
            }
        } primaryAction: { ids in
            guard let row = rows.first(where: { ids.contains($0.id) }) else { return }
            activate(row)
        }
        .accessibilityIdentifier("objects-table")
    }

    private func activate(_ row: ObjectsTabViewModel.Row) {
        if let scope = viewModel.drillScope(for: row) {
            viewModel.windowState.selectedScope = scope
            return
        }
        guard let ref = viewModel.tableRef(for: row), let coordinator else { return }
        let scope = DatabaseScope(connectionId: ref.connectionId, database: ref.database, schema: ref.schema)
        guard ref.connectionId == coordinator.connectionId else {
            coordinator.openTabInCurrentWindow(EditorTabPayload(
                connectionId: ref.connectionId,
                tabType: .table,
                tableName: ref.table.name,
                databaseName: ref.database,
                schemaName: ref.schema,
                isView: !ref.table.type.allowsRowEditing
            ))
            return
        }
        coordinator.openTableTab(ref.table, scope: scope, activateGridFocus: true, forceNewTab: true)
    }
}
