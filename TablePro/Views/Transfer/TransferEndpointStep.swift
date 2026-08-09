//
//  TransferEndpointStep.swift
//  TablePro
//

import SwiftUI

struct TransferEndpointStep: View {
    @Bindable var model: DataTransferWizardModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            endpointColumn(
                title: String(localized: "Source"),
                selection: model.source,
                connections: model.connections,
                onConnection: { id in Task { await model.selectSourceConnection(id) } },
                onDatabase: { name in Task { await model.selectSourceDatabase(name) } },
                onSchema: { model.source.schema = $0 }
            )

            Divider()

            endpointColumn(
                title: String(localized: "Target"),
                selection: model.target,
                connections: model.targetCandidates(),
                onConnection: { id in Task { await model.selectTargetConnection(id) } },
                onDatabase: { name in Task { await model.selectTargetDatabase(name) } },
                onSchema: { model.target.schema = $0 }
            )
        }
        .overlay(alignment: .bottom) {
            if let problem = model.endpointProblem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
    }

    private func endpointColumn(
        title: String,
        selection: DataTransferWizardModel.EndpointSelection,
        connections: [DatabaseConnection],
        onConnection: @escaping (UUID?) -> Void,
        onDatabase: @escaping (String) -> Void,
        onSchema: @escaping (String?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            Picker(String(localized: "Connection"), selection: Binding(
                get: { selection.connectionId },
                set: { onConnection($0) }
            )) {
                Text("None").tag(UUID?.none)
                ForEach(connections) { connection in
                    Text(connection.name).tag(UUID?.some(connection.id))
                }
            }

            if let connection = model.connection(for: selection.connectionId) {
                if model.usesDatabaseList(connection.type), !selection.databases.isEmpty {
                    Picker(String(localized: "Database"), selection: Binding(
                        get: { selection.database },
                        set: { onDatabase($0) }
                    )) {
                        ForEach(selection.databases, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }

                if model.usesSchemas(connection.type), !selection.schemas.isEmpty {
                    Picker(String(localized: "Schema"), selection: Binding(
                        get: { selection.schema },
                        set: { onSchema($0) }
                    )) {
                        ForEach(selection.schemas, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                }
            }

            if selection.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if let errorMessage = selection.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
