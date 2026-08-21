//
//  GenerationRunLogView.swift
//  TablePro
//

import SwiftUI

/// The run: a progress line above an append-only log.
///
/// The log is append-only on purpose. A run that warns about a column halfway
/// through and then finishes should still show that warning at the end, which a
/// status line that overwrites itself cannot do.
struct GenerationRunLogView: View {
    @Bindable var model: DataGenerationWizardModel

    private static let timeFormat: Date.FormatStyle = .dateTime
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .second(.twoDigits)

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            log
        }
    }

    private var summary: some View {
        VStack(spacing: 8) {
            HStack {
                Text(statusLine)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(model.rowsWritten.formatted()) rows")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else if model.step == .running {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.log) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.at.formatted(Self.timeFormat))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: entry.kind))
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .accessibilityIdentifier("generation.log")
            .onChange(of: model.log.count) {
                guard let last = model.log.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var statusLine: String {
        if let report = model.report {
            return report.wasCancelled
                ? String(localized: "Stopped")
                : String(
                    format: String(localized: "Finished %d rows in %.1fs"),
                    report.totalRowsWritten,
                    report.duration
                )
        }
        if model.isCancelling { return String(localized: "Stopping after the current batch\u{2026}") }
        guard !model.currentTable.isEmpty else { return String(localized: "Starting\u{2026}") }
        return model.currentTable
    }

    private var fraction: Double? {
        guard model.totalRows > 0, model.step == .running else { return nil }
        return min(1, Double(model.rowsWritten) / Double(model.totalRows))
    }

    private func color(for kind: GenerationLogEntry.Kind) -> Color {
        switch kind {
        case .info: return .primary
        case .warning: return .orange
        case .failure: return .red
        }
    }
}
