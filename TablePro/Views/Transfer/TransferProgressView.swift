//
//  TransferProgressView.swift
//  TablePro
//

import SwiftUI

struct TransferProgressView: View {
    let state: TransferState

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 8) {
                HStack {
                    if state.statusMessage.isEmpty {
                        Text("\(state.currentTable) (\(state.currentTableIndex)/\(state.totalTables))")
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(state.statusMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("\(state.processedRows.formatted())/\(state.totalRows.formatted()) rows")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if state.totalRows > 0 {
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .frame(maxWidth: 520)

            Text(
                "Stopping ends the transfer after the current batch. A statement already running on the server cannot be interrupted."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var progressValue: Double {
        guard state.totalRows > 0 else { return 0 }
        return min(1, Double(state.processedRows) / Double(state.totalRows))
    }
}
