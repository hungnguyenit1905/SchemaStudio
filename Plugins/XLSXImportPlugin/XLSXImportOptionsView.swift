//
//  XLSXImportOptionsView.swift
//  XLSXImportPlugin
//

import SwiftUI
import TableProPluginKit

struct XLSXImportOptionsView: View {
    let plugin: XLSXImportPlugin

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                if plugin.sheetSelection.hasChoice {
                    GridRow {
                        Text("Sheet:")
                            .gridColumnAlignment(.trailing)
                        Picker("", selection: sheetBinding) {
                            ForEach(plugin.sheetSelection.sheetNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 170)
                        .help("Choose which sheet in the workbook to import.")
                    }
                }

                GridRow {
                    Text("On error:")
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: Bindable(plugin).settings.errorHandling) {
                        Text("Stop and Rollback").tag(ImportErrorHandling.stopAndRollback)
                        Text("Stop and Commit").tag(ImportErrorHandling.stopAndCommit)
                        Text("Skip and Continue").tag(ImportErrorHandling.skipAndContinue)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 170)
                }

                GridRow {
                    Text("NULL text:")
                    TextField("", text: Bindable(plugin).settings.nullString, prompt: Text(verbatim: "\\N"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .help("An extra value that should be imported as NULL, for example \\N.")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("First row is a header", isOn: Bindable(plugin).settings.hasHeaderRow)
                    .help("Use the first row as column names. Turn off to import every row as data.")

                Toggle("Trim leading and trailing spaces", isOn: Bindable(plugin).settings.trimWhitespace)

                Toggle("Treat empty values as NULL", isOn: Bindable(plugin).settings.emptyAsNull)
                    .help("Insert NULL for empty cells instead of an empty string.")

                Toggle("Wrap in transaction (BEGIN/COMMIT)", isOn: Bindable(plugin).settings.wrapInTransaction)
                    .disabled(plugin.settings.errorHandling == .skipAndContinue)
                    .help(plugin.settings.errorHandling == .skipAndContinue
                        ? String(localized: "Not available in skip-and-continue mode")
                        :
                        String(
                            localized: "Insert all rows in a single transaction. If any row fails, all changes are rolled back."
                        ))

                Toggle("Delete existing rows before import", isOn: Bindable(plugin).settings.deleteExistingRows)
                    .help("Remove every row from the target table before inserting the imported rows.")
            }
        }
        .font(.system(size: 13))
    }

    private var sheetBinding: Binding<String> {
        Binding(
            get: { plugin.sheetSelection.selectedSheetName ?? "" },
            set: { plugin.selectSheet($0) }
        )
    }
}
