//
//  GenerationScopeStep.swift
//  TablePro
//

import SwiftUI

/// Step one: where the rows go, and how many.
///
/// The table list is in dependency order rather than alphabetical, so reading it
/// top to bottom is the order the run fills them and a parent is always above the
/// tables that point at it.
struct GenerationScopeStep: View {
    @Bindable var model: DataGenerationWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            scopePickers
            Divider()
            tableToolbar
            tableList
            footerSummary
        }
        .padding(20)
    }

    private var scopePickers: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Connection")
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: connectionBinding) {
                    Text("Choose\u{2026}").tag(UUID?.none)
                    ForEach(model.connections) { connection in
                        Text(connection.name).tag(Optional(connection.id))
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("generation.connection")
            }
            GridRow {
                Text("Database")
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: databaseBinding) {
                    ForEach(model.databases, id: \.self) { database in
                        Text(database).tag(database)
                    }
                }
                .labelsHidden()
                .disabled(model.databases.isEmpty)
                .accessibilityIdentifier("generation.database")
            }
            if !model.schemas.isEmpty {
                GridRow {
                    Text("Schema")
                        .frame(width: 90, alignment: .leading)
                    Picker("", selection: schemaBinding) {
                        ForEach(model.schemas, id: \.self) { schema in
                            Text(schema).tag(Optional(schema))
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("generation.schema")
                }
            }
            GridRow {
                Text("Rows each")
                    .frame(width: 90, alignment: .leading)
                HStack(spacing: 8) {
                    TextField("", text: $model.defaultRowCountText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityIdentifier("generation.rowCount")
                    Button(String(localized: "Apply to All")) { applyDefaultRowCount() }
                        .disabled(model.tables.isEmpty)
                    Spacer()
                    Text("Seed")
                    TextField("", text: $model.seedText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .accessibilityIdentifier("generation.seed")
                }
            }
        }
    }

    private var tableToolbar: some View {
        HStack {
            TextField(String(localized: "Search tables"), text: $model.tableSearch)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            Spacer()
            Button(String(localized: "Select All")) { setAll(true) }
                .disabled(model.visibleTables.isEmpty)
            Button(String(localized: "Select None")) { setAll(false) }
                .disabled(model.selectedTableNames.isEmpty)
        }
    }

    private var tableList: some View {
        List {
            ForEach(model.visibleTables) { table in
                HStack(spacing: 8) {
                    Toggle("", isOn: selectionBinding(for: table))
                        .labelsHidden()
                        .accessibilityIdentifier("generation.table.\(table.name)")
                    Text(table.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !table.parents.isEmpty {
                        Text(
                            String(
                                format: String(localized: "after %@"),
                                table.parents.joined(separator: ", ")
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer()
                    TextField("", text: rowCountBinding(for: table))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(!table.isSelected)
                }
            }
        }
        .overlay {
            if model.isLoadingTables {
                ProgressView()
            } else if model.tables.isEmpty {
                Text("No tables to fill here.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 200)
    }

    private var footerSummary: some View {
        HStack {
            Text(
                String(
                    format: String(localized: "%d of %d tables, %d rows"),
                    model.selectedTableNames.count,
                    model.tables.count,
                    model.tables.filter(\.isSelected).reduce(0) { $0 + $1.rowCount }
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
            if model.isLoadingScope {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var connectionBinding: Binding<UUID?> {
        Binding(
            get: { model.connectionId },
            set: { id in Task { await model.select(connectionId: id) } }
        )
    }

    private var databaseBinding: Binding<String> {
        Binding(
            get: { model.database },
            set: { database in Task { await model.select(database: database) } }
        )
    }

    private var schemaBinding: Binding<String?> {
        Binding(
            get: { model.schema },
            set: { schema in Task { await model.select(schema: schema) } }
        )
    }

    private func selectionBinding(for table: GenerationTableSelection) -> Binding<Bool> {
        Binding(
            get: { model.tables.first { $0.name == table.name }?.isSelected ?? false },
            set: { model.setSelected($0, for: table.name) }
        )
    }

    private func rowCountBinding(for table: GenerationTableSelection) -> Binding<String> {
        Binding(
            get: { String(model.tables.first { $0.name == table.name }?.rowCount ?? 0) },
            set: { model.setRowCount(Int($0) ?? 0, for: table.name) }
        )
    }

    private func setAll(_ isSelected: Bool) {
        for table in model.visibleTables {
            model.setSelected(isSelected, for: table.name)
        }
    }

    private func applyDefaultRowCount() {
        let rowCount = Int(model.defaultRowCountText) ?? 0
        for table in model.tables {
            model.setRowCount(rowCount, for: table.name)
        }
    }
}
