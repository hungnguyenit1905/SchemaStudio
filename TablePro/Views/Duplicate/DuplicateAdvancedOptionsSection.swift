//
//  DuplicateAdvancedOptionsSection.swift
//  TablePro
//

import SwiftUI

/// Constraints are one switch rather than the two the dialog sketch drew: PostgreSQL's `LIKE`
/// carries CHECK constraints and the primary and unique keys under a single
/// `INCLUDING CONSTRAINTS`, so splitting them would offer a control the engine cannot honour.
struct DuplicateAdvancedOptionsSection: View {
    @Bindable var model: DuplicateTableSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Indexes", isOn: $model.options.indexes)
            Toggle("Primary key, unique keys and check constraints", isOn: $model.options.constraints)
            Toggle("Foreign keys", isOn: $model.options.foreignKeys)
            Toggle("Default values", isOn: $model.options.defaults)
            Toggle("Identity and auto increment", isOn: $model.options.identity)
            Toggle("Generated columns", isOn: $model.options.generated)
            Toggle("Comments", isOn: $model.options.comments)
            Toggle("Table options", isOn: $model.options.tableOptions)

            Divider()

            TextField(String(localized: "Row filter (WHERE)"), text: $model.rowFilter)
                .disabled(!model.isRowSelectionEnabled)
            if let problem = model.rowFilterProblem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            TextField(String(localized: "Limit rows"), text: $model.limitText, prompt: Text("All rows"))
                .disabled(!model.isRowSelectionEnabled)
            if let problem = model.limitProblem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Picker(String(localized: "If the target exists"), selection: $model.options.onExists) {
                Text("Cancel").tag(DuplicateExistsPolicy.cancel)
                Text("Drop and recreate").tag(DuplicateExistsPolicy.dropAndRecreate)
            }
            .pickerStyle(.radioGroup)
            if let warning = model.replaceWarning {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
