//
//  ConnectionDatabasesPane.swift
//  TablePro
//

import SwiftUI

struct ConnectionDatabasesPane: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        @Bindable var model = coordinator.databases
        Form {
            Section {
                Toggle(String(localized: "Use a custom database list"), isOn: $model.useCustomList)
            } footer: {
                Text(
                    String(
                        localized: "When on, the sidebar shows only the checked databases. Databases set to Auto Open are opened each time you connect."
                    )
                )
            }

            Section(String(localized: "Databases")) {
                Table($model.rows, selection: $model.selection) {
                    TableColumn(String(localized: "Name")) { $row in
                        Text(row.name)
                    }
                    TableColumn(String(localized: "Show")) { $row in
                        Toggle(String(localized: "Show"), isOn: $row.isShown)
                            .labelsHidden()
                            .disabled(!model.useCustomList)
                    }
                    .width(56)
                    TableColumn(String(localized: "Auto Open")) { $row in
                        Toggle(String(localized: "Auto Open"), isOn: $row.opensAutomatically)
                            .labelsHidden()
                    }
                    .width(80)
                }
                .frame(minHeight: 200)

                HStack(spacing: 8) {
                    TextField(String(localized: "Database name"), text: $model.newDatabaseName)
                        .onSubmit { model.addDatabase() }
                    Button {
                        model.addDatabase()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help(String(localized: "Add a database to the list"))
                    .disabled(model.newDatabaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        model.removeSelected()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help(String(localized: "Remove the selected databases from the list"))
                    .disabled(model.selection.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .task { await coordinator.loadLiveDatabases() }
    }
}
