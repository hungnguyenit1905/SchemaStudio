//
//  DataTransferWizard.swift
//  TablePro
//

import SwiftUI

struct DataTransferWizard: View {
    @Binding var isPresented: Bool
    var preselectedScope: DatabaseScope?

    @State private var model = DataTransferWizardModel()
    @State private var showCloseConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await model.loadConnections(preselectedScope: preselectedScope)
        }
        .onDisappear {
            model.tearDown()
        }
        .onExitCommand {
            requestClose()
        }
        .alert(String(localized: "Stop the transfer?"), isPresented: $showCloseConfirmation) {
            Button(String(localized: "Keep Running"), role: .cancel) {}
            Button(String(localized: "Stop"), role: .destructive) { model.cancelRun() }
        } message: {
            Text("The transfer stops after the current batch. Rows already written stay at the target.")
        }
        .alert(
            String(localized: "Resume the transfer?"),
            isPresented: $model.resumePromptShown
        ) {
            Button(String(localized: "Resume")) {
                Task { await model.run(resume: true) }
            }
            Button(String(localized: "Start Over")) {
                Task { await model.run(resume: false) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                model.resumePromptShown = false
            }
        } message: {
            Text(resumeMessage)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Data Transfer")
                .font(.title3.weight(.semibold))
            Text(stepDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var stepDescription: String {
        switch model.step {
        case .endpoints:
            return String(localized: "Step 1 of 3: pick the source and the target")
        case .tables:
            return String(localized: "Step 2 of 3: pick the tables to transfer")
        case .options:
            return String(localized: "Step 3 of 3: pick the mode and review the checks")
        case .running:
            return String(localized: "Transferring")
        case .report:
            return String(localized: "Result")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .endpoints:
            TransferEndpointStep(model: model)
        case .tables:
            TransferTablesStep(model: model)
        case .options:
            TransferOptionsStep(model: model)
        case .running:
            TransferProgressView(state: model.service.state)
        case .report:
            TransferReportView(report: model.report)
        }
    }

    private var footer: some View {
        HStack {
            if let errorMessage = model.errorMessage, model.step != .running {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer()

            footerButtons
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var footerButtons: some View {
        switch model.step {
        case .endpoints:
            Button(String(localized: "Cancel")) { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Next")) {
                Task {
                    model.step = .tables
                    await model.loadTables()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.endpointProblem != nil)
        case .tables:
            Button(String(localized: "Back")) { model.step = .endpoints }
            Button(String(localized: "Cancel")) { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Next")) {
                Task {
                    model.step = .options
                    await model.loadPreview()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectedTables.isEmpty)
        case .options:
            Button(String(localized: "Back")) { model.step = .tables }
            Button(String(localized: "Cancel")) { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Start")) {
                Task { await model.start() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)
        case .running:
            Button(String(localized: "Stop")) { showCloseConfirmation = true }
                .disabled(model.service.state.isCancelling)
        case .report:
            Button(String(localized: "Done")) { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var canStart: Bool {
        guard !model.isPreparingPreview, let preview = model.preview else { return false }
        guard !preview.plans.isEmpty else { return false }
        return preview.isClean || model.options.continueOnError
    }

    private var resumeMessage: String {
        let tables = model.resumedTableNames
        guard !tables.isEmpty else {
            return String(
                localized: "A previous transfer for these tables did not finish. Resume where it stopped, or start over."
            )
        }
        let names = tables.prefix(3).joined(separator: ", ")
        let suffix = tables.count > 3 ? String(format: String(localized: " and %d more"), tables.count - 3) : ""
        return String(
            format: String(
                localized: "A previous transfer left progress for %@%@. Resume from where it stopped, or start over."
            ),
            names,
            suffix
        )
    }

    private func requestClose() {
        guard model.step != .running else {
            showCloseConfirmation = true
            return
        }
        isPresented = false
    }
}
