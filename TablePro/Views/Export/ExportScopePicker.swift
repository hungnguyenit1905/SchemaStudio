//
//  ExportScopePicker.swift
//  TablePro
//

import SwiftUI

struct ExportScopePicker: View {
    let availability: ExportScopeAvailability
    @Binding var scope: ExportRowScope

    var body: some View {
        HStack(spacing: 4) {
            ForEach(availability.options) { option in
                Button {
                    scope = option.scope
                } label: {
                    Text(label(for: option))
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(scope == option.scope ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(scope == option.scope ? Color.accentColor : Color.secondary.opacity(0.3))
                )
                .disabled(!option.isEnabled)
                .opacity(option.isEnabled ? 1 : 0.4)
                .accessibilityAddTraits(scope == option.scope ? .isSelected : [])
            }
        }
    }

    private func label(for option: ExportScopeOption) -> String {
        guard let count = option.count else { return name(for: option.scope) }
        return String(format: String(localized: "%1$@ (%2$@)"), name(for: option.scope), count.formatted())
    }

    private func name(for scope: ExportRowScope) -> String {
        switch scope {
        case .allRows: return String(localized: "All rows")
        case .displayedRows: return String(localized: "Filtered rows")
        case .selectedRows: return String(localized: "Selected rows")
        }
    }
}
