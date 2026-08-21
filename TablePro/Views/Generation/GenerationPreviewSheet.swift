//
//  GenerationPreviewSheet.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// The rows the run will write, drawn by the run's own code with the run's own
/// seed. Nothing here re-implements generation, so what is on screen is what lands
/// in the database.
struct GenerationPreviewSheet: View {
    @Bindable var model: DataGenerationWizardModel
    @Binding var isPresented: Bool

    @State private var tableName: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(for: selectedTable)
            Divider()
            footer
        }
        .frame(width: 720, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preview")
                    .font(.title3.weight(.semibold))
                Text(
                    String(
                        format: String(localized: "The first rows of the run, seed %@"),
                        model.seedText
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if model.preview != nil {
                Picker("", selection: tableBinding) {
                    ForEach(model.preview?.tables ?? [], id: \.table) { table in
                        Text(table.table).tag(Optional(table.table))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private func body(for table: GenerationPreviewTable?) -> some View {
        if model.isPreparingPreview {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let table {
            VStack(alignment: .leading, spacing: 6) {
                if table.drawsFromGeneratedParent {
                    Label(
                        String(
                            localized: """
                            This table points at a table the same run fills, so the run draws these keys \
                            from rows that do not exist yet. The values here come from the rows already \
                            in the database.
                            """
                        ),
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                grid(for: table)
            }
        } else {
            Text(model.errorMessage ?? String(localized: "Nothing to preview yet."))
                .foregroundStyle(
                    model.errorMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
        }
    }

    private func grid(for table: GenerationPreviewTable) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(table.columns, id: \.self) { column in
                        Text(column)
                            .font(.caption.weight(.semibold))
                            .frame(width: 140, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))

                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            Text(Self.text(for: value))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 140, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                        }
                    }
                    Divider()
                }
            }
            .padding(.horizontal, 10)
        }
        .accessibilityIdentifier("generation.previewGrid")
    }

    private var footer: some View {
        HStack {
            if let count = selectedTable?.rows.count {
                Text(String(format: String(localized: "%d rows shown"), count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Regenerate")) {
                Task { await model.loadPreview() }
            }
            Button(String(localized: "Done")) { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var selectedTable: GenerationPreviewTable? {
        guard let preview = model.preview else { return nil }
        return preview.tables.first { $0.table == tableName } ?? preview.tables.first
    }

    private var tableBinding: Binding<String?> {
        Binding(get: { selectedTable?.table }, set: { tableName = $0 })
    }

    /// A null reads as `NULL` rather than as an empty cell, so a column that is
    /// mostly empty is legible at a glance.
    private static func text(for value: PluginCellValue) -> String {
        guard case .null = value else { return value.textFallback }
        return "NULL"
    }
}
