//
//  DuplicateTableSheet.swift
//  TablePro
//

import SwiftUI

/// Copies one table in place. Immediate execution rather than a pending change the user saves,
/// because the run needs progress and a Stop of its own.
struct DuplicateTableSheet: View {
    private enum Pane: Hashable {
        case options
        case preview
    }

    @Binding var isPresented: Bool
    let scope: DatabaseScope
    let databaseType: DatabaseType
    let source: DuplicateTableRef
    let onCompleted: (DuplicateResult) -> Void

    @State private var model: DuplicateTableSheetModel?
    @State private var pane: Pane = .options
    @State private var unavailableMessage: String?

    var body: some View {
        WizardShell(
            title: String(localized: "Duplicate Table"),
            stepDescription: stepDescription,
            errorMessage: unavailableMessage ?? model?.errorMessage
        ) {
            content
        } footer: {
            footer
        }
        .task { await start() }
        .onDisappear { model?.tearDown() }
        .onExitCommand {
            guard model?.phase != .running else { return }
            isPresented = false
        }
        .alert(
            String(localized: "Stop the duplicate?"),
            isPresented: Binding(
                get: { model?.stopConfirmationShown ?? false },
                set: { model?.stopConfirmationShown = $0 }
            )
        ) {
            Button(String(localized: "Keep Running"), role: .cancel) {}
            Button(String(localized: "Stop"), role: .destructive) { model?.confirmStop() }
        } message: {
            Text("The new table is rolled back. The source table is not touched.")
        }
    }

    // MARK: - Chrome

    private var stepDescription: String {
        guard let model else {
            return String(localized: "Reading the source table")
        }
        switch model.phase {
        case .loading:
            return String(localized: "Reading the source table")
        case .options, .failed:
            return String(
                format: String(localized: "Copying %@ into the same database"),
                qualified(source)
            )
        case .running:
            return String(localized: "Duplicating")
        }
    }

    @ViewBuilder private var content: some View {
        if let model, model.phase == .running {
            WizardProgressView(
                statusLine: model.statusLine,
                isStatusSecondary: false,
                rowCount: model.estimatedRowCount,
                progressFraction: model.progressFraction,
                footnote: model.progressFootnote
            )
        } else if let model, model.phase != .loading {
            TabView(selection: $pane) {
                DuplicateTableOptionsPane(model: model, source: qualified(source))
                    .tabItem { Text("Options") }
                    .tag(Pane.options)
                DuplicateSqlPreviewPane(model: model)
                    .tabItem { Text("Preview SQL") }
                    .tag(Pane.preview)
            }
            .padding(12)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var footer: some View {
        if let model, model.phase == .running {
            Button(String(localized: "Stop")) { model.requestStop() }
        } else {
            Button(String(localized: "Cancel")) { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Duplicate")) { Task { await duplicate() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model?.canDuplicate != true)
        }
    }

    // MARK: - Actions

    private func start() async {
        guard model == nil else { return }
        guard DuplicatePlanBuilder.builder(for: databaseType) != nil else {
            unavailableMessage = DuplicateError.unsupportedDatabase(databaseType.rawValue).localizedDescription
            return
        }
        guard let environment = DuplicateSheetEnvironment.live(
            scope: scope,
            databaseType: databaseType,
            source: source
        ) else {
            unavailableMessage = DuplicateError.unsupportedDatabase(databaseType.rawValue).localizedDescription
            return
        }
        let created = DuplicateTableSheetModel(
            source: source,
            databaseType: databaseType,
            environment: environment
        )
        model = created
        await created.load()
    }

    private func duplicate() async {
        guard let model, let result = await model.duplicate() else { return }
        isPresented = false
        onCompleted(result)
    }

    private func qualified(_ table: DuplicateTableRef) -> String {
        guard let schema = table.schema, !schema.isEmpty else { return table.name }
        return "\(schema).\(table.name)"
    }
}
