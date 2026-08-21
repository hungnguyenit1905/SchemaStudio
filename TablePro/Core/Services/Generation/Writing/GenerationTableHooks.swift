//
//  GenerationTableHooks.swift
//  TablePro
//

import Foundation

/// The work that happens around a table's row loop rather than inside it:
/// emptying it first, and turning foreign key checks off for the run.
///
/// The destructive refusal lives here, not in the wizard, so a UI path that
/// forgets to disable the option still cannot empty a locked-down connection.
actor GenerationTableHooks {
    private let driver: any GenerationDriver
    private var inboundForeignKeys: [GenerationTableReference: Bool] = [:]
    private(set) var foreignKeyChecksDisabled = false

    init(driver: any GenerationDriver) {
        self.driver = driver
    }

    /// Runs before anything is written, so a refused run fails with an empty
    /// database rather than a half-filled one.
    func preflight(plan: GenerationPlan) throws {
        guard driver.blocksDestructiveOperations else { return }
        guard let blocked = plan.tables.first(where: \.emptyFirst) else { return }
        throw GenerationError.destructiveOperationBlocked(table: blocked.qualifiedName)
    }

    func emptyTable(_ table: TablePlan) async throws {
        guard table.emptyFirst else { return }
        guard !driver.blocksDestructiveOperations else {
            throw GenerationError.destructiveOperationBlocked(table: table.qualifiedName)
        }
        let hasInbound = try await hasInboundForeignKeys(table.reference)
        try await driver.emptyTable(table.reference, allowsTruncate: !hasInbound)
    }

    func disableForeignKeyChecks() async throws {
        guard !foreignKeyChecksDisabled else { return }
        try await driver.setForeignKeyChecks(enabled: false)
        foreignKeyChecksDisabled = true
    }

    /// Called from the success, throw and cancel paths alike. `defer` cannot
    /// `await`, so every exit path calls this explicitly and it has to be safe to
    /// call twice.
    func restoreForeignKeyChecks() async {
        guard foreignKeyChecksDisabled else { return }
        foreignKeyChecksDisabled = false
        try? await driver.setForeignKeyChecks(enabled: true)
    }

    private func hasInboundForeignKeys(_ table: GenerationTableReference) async throws -> Bool {
        if let known = inboundForeignKeys[table] { return known }
        let resolved = try await driver.hasInboundForeignKeys(table: table)
        inboundForeignKeys[table] = resolved
        return resolved
    }
}
