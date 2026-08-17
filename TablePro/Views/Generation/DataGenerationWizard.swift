//
//  DataGenerationWizard.swift
//  TablePro
//

import SwiftUI

struct DataGenerationWizard: View {
    @Binding var isPresented: Bool
    var preselectedScope: DatabaseScope?

    @State private var model = DataGenerationWizardModel()
    @State private var showStopConfirmation = false
    @State private var showParentPrompt = false
    @State private var showPreview = false

    var body: some View {
        WizardShell(
            title: String(localized: "Generate Data"),
            stepDescription: stepDescription,
            errorMessage: model.step == .running ? nil : model.errorMessage
        ) {
            content
        } footer: {
            footerButtons
        }
        .task {
            await model.loadConnections(preselectedScope: preselectedScope)
        }
        .onDisappear {
            model.tearDown()
        }
        .onExitCommand {
            requestClose()
        }
        .sheet(isPresented: $showPreview) {
            GenerationPreviewSheet(model: model, isPresented: $showPreview)
        }
        .alert(String(localized: "Stop generating?"), isPresented: $showStopConfirmation) {
            Button(String(localized: "Keep Running"), role: .cancel) {}
            Button(String(localized: "Stop"), role: .destructive) { model.cancelRun() }
        } message: {
            Text("Generating stops after the current batch. Rows already written stay in the database.")
        }
        .alert(String(localized: "Fill the parent tables too?"), isPresented: $showParentPrompt) {
            Button(String(localized: "Add Parents")) {
                model.tickUntickedParents()
                advanceToColumns()
            }
            Button(String(localized: "Continue Without Them")) {
                advanceToColumns()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(parentPromptMessage)
        }
    }

    private var stepDescription: String {
        switch model.step {
        case .scope:
            return String(localized: "Step 1 of 3: pick the database and the tables to fill")
        case .columns:
            return String(localized: "Step 2 of 3: review the generator for each column")
        case .options:
            return String(localized: "Step 3 of 3: choose how the rows are written")
        case .running:
            return String(localized: "Generating")
        case .report:
            return String(localized: "Result")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .scope:
            GenerationScopeStep(model: model)
        case .columns:
            GenerationColumnGrid(model: model)
        case .options:
            GenerationOptionsStep(model: model)
        case .running:
            GenerationRunLogView(model: model)
        case .report:
            GenerationRunLogView(model: model)
        }
    }

    @ViewBuilder private var footerButtons: some View {
        switch model.step {
        case .scope:
            Button(String(localized: "Cancel")) { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Next")) { requestColumns() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedTableNames.isEmpty)
                .accessibilityIdentifier("generation.next")
        case .columns:
            Button(String(localized: "Back")) { model.step = .scope }
            Button(String(localized: "Preview")) {
                showPreview = true
                Task { await model.loadPreview() }
            }
            .accessibilityIdentifier("generation.preview")
            Button(String(localized: "Cancel")) { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Next")) { model.step = .options }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("generation.next")
        case .options:
            Button(String(localized: "Back")) { model.step = .columns }
            Button(String(localized: "Cancel")) { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Generate")) {
                Task { await model.start() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canStart)
            .accessibilityIdentifier("generation.start")
        case .running:
            Button(String(localized: "Stop")) { showStopConfirmation = true }
                .disabled(model.isCancelling)
        case .report:
            Button(String(localized: "Done")) { isPresented = false }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("generation.done")
        }
    }

    private var parentPromptMessage: String {
        let parents = model.untickedParents
        let names = parents.prefix(3).joined(separator: ", ")
        let suffix = parents.count > 3
            ? String(format: String(localized: " and %d more"), parents.count - 3)
            : ""
        return String(
            format: String(
                localized: """
                %@%@ hold the rows the tables you picked point at. Without them those foreign keys \
                stay empty, or the run stops because there is nothing to point at.
                """
            ),
            names,
            suffix
        )
    }

    private func requestColumns() {
        guard model.untickedParents.isEmpty else {
            showParentPrompt = true
            return
        }
        advanceToColumns()
    }

    private func advanceToColumns() {
        model.buildProfile()
        model.step = .columns
    }

    private func requestClose() {
        guard model.step != .running else {
            showStopConfirmation = true
            return
        }
        isPresented = false
    }
}
