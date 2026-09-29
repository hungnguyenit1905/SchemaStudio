import Foundation
import Testing

@testable import SchemaStudio

@Suite("Database Connection Diagnostic Policy")
struct DatabaseConnectionDiagnosticPolicyTests {
    @Test("New and legacy connections keep diagnostics disabled")
    func defaultsToDisabled() throws {
        let connection = DatabaseConnection(name: "Local")
        #expect(connection.diagnosticPolicy == .disabled)

        let encoded = try JSONEncoder().encode(connection)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "diagnosticPolicy")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: legacyData)

        #expect(decoded.diagnosticPolicy == .disabled)
    }

    @Test("Diagnostic policy survives connection coding")
    func roundTripPreservesPolicy() throws {
        let policy = DiagnosticPolicy(
            isEnabled: true,
            statementTimeoutSeconds: 10,
            totalRunBudgetSeconds: 45,
            statementLimit: 8,
            rowLimit: 250,
            cacheTTLSeconds: 600
        )
        let connection = DatabaseConnection(name: "PostgreSQL", type: .postgresql, diagnosticPolicy: policy)

        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: JSONEncoder().encode(connection))

        #expect(decoded.diagnosticPolicy == policy)
    }

    @Test("Diagnostic policy rejects unsafe limits")
    func validatesLimits() {
        let excessiveTimeout = DiagnosticPolicy(statementTimeoutSeconds: 61)
        let inconsistentBudget = DiagnosticPolicy(statementTimeoutSeconds: 30, totalRunBudgetSeconds: 20)

        #expect(excessiveTimeout.isValid == false)
        #expect(inconsistentBudget.isValid == false)
    }

    @Test("Invalid policies decode and encode as disabled")
    func invalidPoliciesAreDisabledAtCodingBoundary() throws {
        let invalid = DiagnosticPolicy(isEnabled: true, statementTimeoutSeconds: 0)
        let encoded = try JSONEncoder().encode(invalid)
        let decoded = try JSONDecoder().decode(DiagnosticPolicy.self, from: encoded)
        let persistedInvalid = try JSONSerialization.data(withJSONObject: [
            "isEnabled": true,
            "statementTimeoutSeconds": 0,
            "totalRunBudgetSeconds": 60,
            "statementLimit": 12,
            "rowLimit": 500,
            "cacheTTLSeconds": 900,
        ])
        let decodedPersistedInvalid = try JSONDecoder().decode(DiagnosticPolicy.self, from: persistedInvalid)

        #expect(decoded == .disabled)
        #expect(decodedPersistedInvalid == .disabled)
    }
}
