//
//  GenerationColumnGrid.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// Step two: what each column will hold.
///
/// The grid on the left is the whole table's columns with the generator the mapper
/// picked; the panel on the right is that generator's own settings, drawn from its
/// `ParamSchema`. A column the server fills is shown but not editable, because the
/// run leaves it out of the insert entirely.
struct GenerationColumnGrid: View {
    @Bindable var model: DataGenerationWizardModel

    var body: some View {
        AutosavingSplitView(
            autosaveName: "GenerationColumnGrid",
            isVertical: true,
            primaryMinimum: 380,
            secondaryMinimum: 260
        ) {
            columnsPane
        } secondary: {
            settingsPane
        }
    }

    private var columnsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            tablePicker
            columnList
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var tablePicker: some View {
        Picker("", selection: tableBinding) {
            ForEach(model.profile.tables, id: \.table) { table in
                Text("\(table.table) (\(table.rowCount))").tag(Optional(table.table))
            }
        }
        .labelsHidden()
        .accessibilityIdentifier("generation.columnTable")
    }

    private var columnList: some View {
        List(selection: $model.selectedColumnName) {
            Section {
                ForEach(columns, id: \.column) { column in
                    row(for: column)
                        .tag(column.column)
                }
            } header: {
                HStack {
                    Text("Column").frame(width: 130, alignment: .leading)
                    Text("Type").frame(width: 110, alignment: .leading)
                    Text("Generator")
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func row(for columnProfile: GenerationColumnProfile) -> some View {
        let facts = model.column(columnProfile.column, inTable: tableName)
        let isReadOnly = model.isReadOnly(column: columnProfile.column, inTable: tableName)
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(columnProfile.column)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let facts, !facts.isNullable {
                    Text("required")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 130, alignment: .leading)

            Text(facts?.type.native ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)

            if isReadOnly {
                Text("Filled by the server")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: generatorBinding(for: columnProfile)) {
                    ForEach(GeneratorRegistry.standard.identifiers, id: \.self) { identifier in
                        Text(identifier).tag(identifier)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("generation.generator.\(columnProfile.column)")
            }

            Spacer()

            ForEach(model.warnings(forColumn: columnProfile.column), id: \.self) { warning in
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(warning.message)
            }
        }
    }

    private var settingsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let column = selectedColumn {
                    Text(column.column)
                        .font(.headline)
                    if model.isReadOnly(column: column.column, inTable: tableName) {
                        Text("The server fills this column, so the run leaves it out.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        GenerationParamForm(
                            schema: GeneratorRegistry.standard.paramSchema(for: column.generator) ?? .empty,
                            params: paramsBinding(for: column)
                        )
                        Divider()
                        commonSection(for: column)
                    }
                } else {
                    Text("Pick a column to change how it is filled.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func commonSection(for column: GenerationColumnProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Every generator")
                .font(.subheadline.weight(.semibold))
            HStack {
                Text("Nulls, percent").frame(width: 150, alignment: .leading)
                TextField("", text: nullPercentBinding(for: column))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }
            Toggle(String(localized: "Never repeat a value"), isOn: uniqueBinding(for: column))
            HStack {
                Text("Prefix").frame(width: 150, alignment: .leading)
                TextField("", text: affixBinding(for: column, isPrefix: true))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Suffix").frame(width: 150, alignment: .leading)
                TextField("", text: affixBinding(for: column, isPrefix: false))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Bindings

    private var tableName: String { model.selectedTableName ?? "" }

    private var columns: [GenerationColumnProfile] { model.columns(ofTable: tableName) }

    private var selectedColumn: GenerationColumnProfile? {
        columns.first { $0.column == model.selectedColumnName } ?? columns.first
    }

    private var tableBinding: Binding<String?> {
        Binding(
            get: { model.selectedTableName },
            set: { table in
                model.selectedTableName = table
                model.selectedColumnName = model.columns(ofTable: table ?? "").first?.column
            }
        )
    }

    private func generatorBinding(for column: GenerationColumnProfile) -> Binding<String> {
        Binding(
            get: { column.generator },
            set: { model.setGenerator($0, forColumn: column.column, inTable: tableName) }
        )
    }

    private func paramsBinding(for column: GenerationColumnProfile) -> Binding<JSONValue> {
        Binding(
            get: { model.columns(ofTable: tableName).first { $0.column == column.column }?.params ?? .object([:]) },
            set: { model.setParams($0, forColumn: column.column, inTable: tableName) }
        )
    }

    private func nullPercentBinding(for column: GenerationColumnProfile) -> Binding<String> {
        Binding(
            get: { String(current(column).common.nullPercent) },
            set: { text in
                var common = current(column).common
                common.nullPercent = max(0, min(100, Int(text) ?? 0))
                model.setCommon(common, forColumn: column.column, inTable: tableName)
            }
        )
    }

    private func uniqueBinding(for column: GenerationColumnProfile) -> Binding<Bool> {
        Binding(
            get: { current(column).common.unique },
            set: { isUnique in
                var common = current(column).common
                common.unique = isUnique
                model.setCommon(common, forColumn: column.column, inTable: tableName)
            }
        )
    }

    private func affixBinding(for column: GenerationColumnProfile, isPrefix: Bool) -> Binding<String> {
        Binding(
            get: { isPrefix ? current(column).common.prefix : current(column).common.suffix },
            set: { text in
                var common = current(column).common
                if isPrefix {
                    common.prefix = text
                } else {
                    common.suffix = text
                }
                model.setCommon(common, forColumn: column.column, inTable: tableName)
            }
        )
    }

    private func current(_ column: GenerationColumnProfile) -> GenerationColumnProfile {
        model.columns(ofTable: tableName).first { $0.column == column.column } ?? column
    }
}
