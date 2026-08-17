//
//  TransferProgressView.swift
//  TablePro
//

import SwiftUI

struct TransferProgressView: View {
    let state: TransferState

    var body: some View {
        WizardProgressView(
            statusLine: statusLine,
            isStatusSecondary: !state.statusMessage.isEmpty,
            rowCount: state.processedRows,
            progressFraction: state.progressFraction,
            footnote: String(
                localized: """
                Stopping ends the transfer after the current batch. A statement already running on the \
                server cannot be interrupted.
                """
            )
        )
    }

    private var statusLine: String {
        guard state.statusMessage.isEmpty else { return state.statusMessage }
        return "\(state.currentTable) (\(state.currentTableIndex)/\(state.totalTables))"
    }
}
