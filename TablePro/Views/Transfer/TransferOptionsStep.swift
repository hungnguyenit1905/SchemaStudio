//
//  TransferOptionsStep.swift
//  TablePro
//

import SwiftUI

struct TransferOptionsStep: View {
    @Bindable var model: DataTransferWizardModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            settings
                .frame(width: 320)
            Divider()
            checks
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(String(localized: "Mode"), selection: $model.mode) {
                ForEach(TransferMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: model.mode) {
                Task { await model.loadPreview() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(String(localized: "Create target table if it does not exist"), isOn: createTargetBinding)
                Toggle(String(localized: "Use a single transaction"), isOn: $model.options.useSingleTransaction)
                Text(
                    "Each table gets its own transaction. Statements that create or drop tables stay outside it, because most engines commit those on their own."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle(String(localized: "Continue when a table fails"), isOn: $model.options.continueOnError)
                Divider()
                parallelTableStepper
                Divider()
                inTableStepper
            }

            Spacer()
        }
        .padding(20)
    }

    private var parallelTableStepper: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Parallel tables")
                    .font(.callout)
                Text("Copies several tables at once. Needs its own connections, capped by the pool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Stepper(value: $model.options.parallelTables, in: 1 ... 3) {
                Text("\(model.options.parallelTables)")
                    .frame(minWidth: 24)
            }
        }
    }

    private var inTableStepper: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Parallel reads inside one table")
                    .font(.callout)
                Text("Splits a large numeric primary key into ranges. Only runs past one million estimated rows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Stepper(value: $model.options.inTableParallelism, in: 1 ... 4) {
                Text("\(model.options.inTableParallelism)")
                    .frame(minWidth: 24)
            }
        }
    }

    private var createTargetBinding: Binding<Bool> {
        Binding(
            get: { model.options.createTargetIfNotExists },
            set: { newValue in
                model.options.createTargetIfNotExists = newValue
                Task { await model.loadPreview() }
            }
        )
    }

    @ViewBuilder private var checks: some View {
        if model.isPreparingPreview {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview = model.preview {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !preview.failures.isEmpty {
                        section(
                            title: String(localized: "Cannot be transferred"),
                            tint: .red,
                            lines: preview.failures.map { "\($0.table): \($0.message)" }
                        )
                    }

                    if !preview.tablesToDrop.isEmpty {
                        section(
                            title: String(localized: "Will be dropped and recreated at the target"),
                            tint: .orange,
                            lines: preview.tablesToDrop
                        )
                    }

                    if !preview.plansWithWarnings.isEmpty {
                        section(
                            title: String(localized: "Structure that is not carried over"),
                            tint: .orange,
                            lines: warningLines(preview)
                        )
                    }

                    if preview.failures.isEmpty, preview.plansWithWarnings.isEmpty {
                        Text("All selected tables passed the checks.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } else {
            Text("The checks could not run.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func warningLines(_ preview: TransferPreview) -> [String] {
        preview.plansWithWarnings.flatMap { plan -> [String] in
            var lines = plan.warnings.map { "\(plan.table): \($0.message)" }
            if !plan.extraTargetColumns.isEmpty {
                lines.append(String(
                    format: String(localized: "%@: target keeps its own columns %@, which take their default."),
                    plan.table,
                    plan.extraTargetColumns.joined(separator: ", ")
                ))
            }
            return lines
        }
    }

    private func section(title: String, tint: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(tint)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
