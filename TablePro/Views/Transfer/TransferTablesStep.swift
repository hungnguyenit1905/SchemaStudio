//
//  TransferTablesStep.swift
//  TablePro
//

import SwiftUI

struct TransferTablesStep: View {
    @Bindable var model: DataTransferWizardModel

    /// The shared tree renders per-table option columns for an export format.
    /// Transfer has no such options, and an unknown format id is what turns
    /// them off without changing the shared view.
    private let optionlessFormatId = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.isLoadingTables {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.tableItems.first?.tables.isEmpty ?? true {
                Text("No tables found in this database.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ExportTableTreeView(databaseItems: filteredBinding, formatId: optionlessFormatId)
            }
            Divider()
            summary
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField(String(localized: "Search"), text: $model.tableSearch)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Button(String(localized: "Select All")) { model.setAllTablesSelected(true) }
            Button(String(localized: "Select None")) { model.setAllTablesSelected(false) }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var summary: some View {
        HStack {
            Text(String(
                format: String(localized: "%d table(s) selected"),
                model.selectedTables.count
            ))
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()

            if estimatedRows > 0 {
                Text(String(
                    format: String(localized: "about %@ rows"),
                    estimatedRows.formatted()
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var estimatedRows: Int {
        model.selectedTables.reduce(0) { $0 + (model.rowCounts[$1.table] ?? 0) }
    }

    /// Searching narrows what the tree shows, so an edit has to land back on
    /// the unfiltered list or a hidden table would lose its selection.
    private var filteredBinding: Binding<[ExportDatabaseItem]> {
        Binding(
            get: { model.filteredTableItems },
            set: { updated in
                var selection: [String: Bool] = [:]
                var expansion: [String: Bool] = [:]
                for item in updated {
                    expansion[item.name] = item.isExpanded
                    for table in item.tables {
                        selection[table.name] = table.isSelected
                    }
                }
                for itemIndex in model.tableItems.indices {
                    if let isExpanded = expansion[model.tableItems[itemIndex].name] {
                        model.tableItems[itemIndex].isExpanded = isExpanded
                    }
                    for tableIndex in model.tableItems[itemIndex].tables.indices {
                        let name = model.tableItems[itemIndex].tables[tableIndex].name
                        guard let isSelected = selection[name] else { continue }
                        model.tableItems[itemIndex].tables[tableIndex].isSelected = isSelected
                    }
                }
            }
        )
    }
}
