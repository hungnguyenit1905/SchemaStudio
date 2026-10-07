import SwiftUI

struct DiagnosticsPolicyPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        Form {
            if coordinator.network.type.supportsDatabaseDiagnostics {
                Section {
                    Toggle(String(localized: "Enable read-only diagnostics"), isOn: $coordinator.diagnostics.isEnabled)
                } footer: {
                    Text(
                        String(
                            localized: "Diagnostics use dedicated connections and registered read-only statements. Read-only database accounts remain recommended."
                        )
                    )
                }

                if coordinator.diagnostics.isEnabled {
                    Section(String(localized: "Limits")) {
                        Stepper(
                            String(
                                format: String(localized: "Statement timeout: %d seconds"),
                                coordinator.diagnostics.statementTimeoutSeconds
                            ),
                            value: $coordinator.diagnostics.statementTimeoutSeconds,
                            in: DiagnosticPolicy.minimumStatementTimeoutSeconds ... DiagnosticPolicy
                                .maximumStatementTimeoutSeconds
                        )
                        Stepper(
                            String(
                                format: String(localized: "Run budget: %d seconds"),
                                coordinator.diagnostics.totalRunBudgetSeconds
                            ),
                            value: $coordinator.diagnostics.totalRunBudgetSeconds,
                            in: DiagnosticPolicy.minimumRunBudgetSeconds ... DiagnosticPolicy.maximumRunBudgetSeconds
                        )
                        Stepper(
                            String(
                                format: String(localized: "Statement limit: %d"),
                                coordinator.diagnostics.statementLimit
                            ),
                            value: $coordinator.diagnostics.statementLimit,
                            in: DiagnosticPolicy.minimumStatementLimit ... DiagnosticPolicy.maximumStatementLimit
                        )
                        Stepper(
                            String(format: String(localized: "Row limit: %d"), coordinator.diagnostics.rowLimit),
                            value: $coordinator.diagnostics.rowLimit,
                            in: DiagnosticPolicy.minimumRowLimit ... DiagnosticPolicy.maximumRowLimit
                        )
                        Stepper(
                            String(
                                format: String(localized: "Cache duration: %d seconds"),
                                coordinator.diagnostics.cacheTTLSeconds
                            ),
                            value: $coordinator.diagnostics.cacheTTLSeconds,
                            in: DiagnosticPolicy.minimumCacheTTLSeconds ... DiagnosticPolicy.maximumCacheTTLSeconds
                        )
                    }
                }
            } else {
                ContentUnavailableView(
                    String(localized: "Diagnostics Unavailable"),
                    systemImage: "stethoscope",
                    description: Text(
                        String(localized: "Database diagnostics are available for PostgreSQL and MySQL connections.")
                    )
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
