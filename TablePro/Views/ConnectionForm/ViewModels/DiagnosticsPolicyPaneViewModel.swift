import Foundation

@Observable
@MainActor
final class DiagnosticsPolicyPaneViewModel {
    var isEnabled = false
    var statementTimeoutSeconds = 15
    var totalRunBudgetSeconds = 60
    var statementLimit = 12
    var rowLimit = 500
    var cacheTTLSeconds = 900
    var coordinator: WeakCoordinatorRef?

    var validationIssues: [String] {
        guard let error = policy.validationError else { return [] }
        return [error]
    }

    private var policy: DiagnosticPolicy {
        DiagnosticPolicy(
            isEnabled: isEnabled,
            statementTimeoutSeconds: statementTimeoutSeconds,
            totalRunBudgetSeconds: totalRunBudgetSeconds,
            statementLimit: statementLimit,
            rowLimit: rowLimit,
            cacheTTLSeconds: cacheTTLSeconds
        )
    }

    func load(from connection: DatabaseConnection) {
        let policy = connection.diagnosticPolicy
        isEnabled = policy.isEnabled
        statementTimeoutSeconds = policy.statementTimeoutSeconds
        totalRunBudgetSeconds = policy.totalRunBudgetSeconds
        statementLimit = policy.statementLimit
        rowLimit = policy.rowLimit
        cacheTTLSeconds = policy.cacheTTLSeconds
    }

    func policy(for databaseType: DatabaseType) -> DiagnosticPolicy {
        guard databaseType.supportsDatabaseDiagnostics else { return .disabled }
        return policy
    }
}
