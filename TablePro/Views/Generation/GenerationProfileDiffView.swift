//
//  GenerationProfileDiffView.swift
//  TablePro
//

import SwiftUI

/// What loading this profile would change, as a list to read before the run
/// rather than warnings scrolling past in the log.
struct GenerationProfileDiffView: View {
    let diff: GenerationProfileDiff
    var onApply: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            entries
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("The database changed since this profile was saved")
                .font(.title3.weight(.semibold))
            Text("Loading it applies the changes below.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var entries: some View {
        List(diff.entries) { entry in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(for: entry.kind))
                    .foregroundStyle(color(for: entry.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.kind.title)
                        .font(.callout.weight(.medium))
                    Text(entry.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Load Anyway")) { onApply() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("generation.profile.applyDiff")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func icon(for kind: GenerationProfileDiffEntry.Kind) -> String {
        switch kind {
        case .tableRemoved, .columnRemoved: return "minus.circle.fill"
        case .columnAdded: return "plus.circle.fill"
        case .generatorChanged: return "arrow.triangle.2.circlepath"
        }
    }

    private func color(for kind: GenerationProfileDiffEntry.Kind) -> Color {
        switch kind {
        case .tableRemoved, .columnRemoved: return .red
        case .columnAdded: return .green
        case .generatorChanged: return .orange
        }
    }
}
