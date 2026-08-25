//
//  DuplicateTableOptionsPane.swift
//  TablePro
//

import SwiftUI

struct DuplicateTableOptionsPane: View {
    @Bindable var model: DuplicateTableSheetModel
    let source: String

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Source table"), value: source)

                if model.showsTargetSchema {
                    Picker(String(localized: "Target schema"), selection: $model.targetSchema) {
                        ForEach(model.schemas, id: \.self) { schema in
                            Text(schema).tag(schema)
                        }
                    }
                    .onChange(of: model.targetSchema) {
                        Task { await model.targetSchemaChanged() }
                    }
                }

                TextField(String(localized: "New table name"), text: $model.name)
                if let nameError = model.nameError {
                    Text(nameError.message)
                        .font(.callout)
                        .foregroundStyle(.red)
                } else if model.nameCollides {
                    Text("A table with this name already exists. Pick Drop and recreate below to replace it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker(String(localized: "Copy"), selection: $model.mode) {
                    Text("Duplicate structure only").tag(DuplicateMode.structureOnly)
                    Text("Duplicate structure and data").tag(DuplicateMode.structureAndData)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section {
                DisclosureGroup(isExpanded: $model.isAdvancedExpanded) {
                    DuplicateAdvancedOptionsSection(model: model)
                } label: {
                    Text("Advanced options")
                }
            }

            if !model.warnings.isEmpty || model.showsSharedConnectionNote {
                Section {
                    ForEach(model.warnings, id: \.self) { warning in
                        Label(warning.message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(warning.isBlocking ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                    if model.showsSharedConnectionNote {
                        Label(
                            String(
                                localized: """
                                This connection has no separate worker connection, so the copy blocks \
                                the connection's other tabs while it runs.
                                """
                            ),
                            systemImage: "info.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
