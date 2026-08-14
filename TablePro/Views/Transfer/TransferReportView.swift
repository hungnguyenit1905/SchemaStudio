//
//  TransferReportView.swift
//  TablePro
//

import SwiftUI

struct TransferReportView: View {
    let report: TransferReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let report {
                summary(report)
                Divider()
                Table(report.results) {
                    TableColumn(String(localized: "Table"), value: \.table)
                    TableColumn(String(localized: "Rows")) { result in
                        Text(result.rowsTransferred.formatted())
                    }
                    TableColumn(String(localized: "Time")) { result in
                        Text(String(format: "%.1fs", result.duration))
                    }
                    TableColumn(String(localized: "Status")) { result in
                        Text(statusText(result))
                            .foregroundStyle(statusColor(result))
                            .help(statusDetail(result))
                    }
                }
            } else {
                Text("No result to show.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func summary(_ report: TransferReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(
                format: String(localized: "%1$@ rows across %2$d table(s)"),
                report.totalRows.formatted(),
                report.results.count
            ))
            .font(.headline)

            if report.failedCount > 0 {
                Text(String(format: String(localized: "%d table(s) failed"), report.failedCount))
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if report.warningCount > 0 {
                Text(String(format: String(localized: "%d table(s) finished with warnings"), report.warningCount))
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if report.wasCancelled {
                Text("The transfer was stopped before it finished.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private func statusText(_ result: TransferTableResult) -> String {
        switch result.outcome {
        case .succeeded:
            return String(localized: "Done")
        case .warned:
            return String(localized: "Done, with warnings")
        case .failed(let message):
            return message
        case .notRun:
            return String(localized: "Not completed")
        }
    }

    private func statusDetail(_ result: TransferTableResult) -> String {
        if let message = result.errorMessage { return message }
        return result.warningMessages.joined(separator: "\n")
    }

    private func statusColor(_ result: TransferTableResult) -> Color {
        switch result.outcome {
        case .succeeded:
            return .primary
        case .warned:
            return .orange
        case .failed:
            return .red
        case .notRun:
            return .secondary
        }
    }
}
