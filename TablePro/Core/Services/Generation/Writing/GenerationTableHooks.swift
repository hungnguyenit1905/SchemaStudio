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
    private var triggersDisabled: Set<GenerationTableReference> = []

    init(driver: any GenerationDriver) {
        self.driver = driver
    }

    /// Runs before anything is written, so a refused run fails with an empty
    /// database rather than a half-filled one.
    func preflight(plan: GenerationPlan) throws {
        guard !driver.blocksAllWrites else {
            throw GenerationError.safeModeBlocksWrites
        }
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
    /// call twice. The flag only clears once the server confirms the checks are
    /// back on: a connection that failed to restore them is not safe to hand
    /// back to the pool with checking silently off, so `foreignKeyChecksDisabled`
    /// stays true and the caller learns about it instead of the failure being
    /// swallowed.
    func restoreForeignKeyChecks() async -> GenerationWarning? {
        guard foreignKeyChecksDisabled else { return nil }
        do {
            try await driver.setForeignKeyChecks(enabled: true)
            foreignKeyChecksDisabled = false
            return nil
        } catch {
            return GenerationWarning(
                column: "",
                message: String(
                    format: String(
                        localized: "Foreign key checks could not be turned back on: %@. This connection will be reconnected before it is used again."
                    ),
                    error.localizedDescription
                )
            )
        }
    }

    /// Turns triggers off for one table only, right before its rows are
    /// written. Unlike foreign key checks, which cover the whole run, this is
    /// scoped per table: it comes back on as soon as that table finishes
    /// rather than staying off for every table the run still has to write.
    /// Both an unsupported engine and a failed statement come back as a
    /// warning rather than a thrown error, so a table the engine cannot help
    /// with still gets its rows written, just with triggers left on.
    func disableTriggers(for table: TablePlan) async -> GenerationWarning? {
        do {
            guard try await driver.setTriggerChecks(table: table.reference, enabled: false) else {
                return GenerationWarning(
                    column: "",
                    message: String(
                        format: String(
                            localized: "Triggers on %@ cannot be disabled by this engine. Rows are written with triggers on."
                        ),
                        table.qualifiedName
                    )
                )
            }
            triggersDisabled.insert(table.reference)
            return nil
        } catch {
            return GenerationWarning(
                column: "",
                message: String(
                    format: String(
                        localized: "Triggers on %@ could not be disabled: %@. Rows are written with triggers on."
                    ),
                    table.qualifiedName,
                    error.localizedDescription
                )
            )
        }
    }

    /// Called from the success and throw paths alike, and never clears the
    /// "disabled" record until the server confirms triggers are back on: a
    /// table left with triggers off is worse than foreign key checks left off
    /// on a pooled session, because it survives the connection.
    func restoreTriggers(for table: TablePlan) async -> GenerationWarning? {
        guard triggersDisabled.contains(table.reference) else { return nil }
        do {
            _ = try await driver.setTriggerChecks(table: table.reference, enabled: true)
            triggersDisabled.remove(table.reference)
            return nil
        } catch {
            return GenerationWarning(
                column: "",
                message: String(
                    format: String(
                        localized: "Triggers on %@ could not be turned back on: %@. Re-enable them by hand."
                    ),
                    table.qualifiedName,
                    error.localizedDescription
                )
            )
        }
    }

    private func hasInboundForeignKeys(_ table: GenerationTableReference) async throws -> Bool {
        if let known = inboundForeignKeys[table] { return known }
        let resolved = try await driver.hasInboundForeignKeys(table: table)
        inboundForeignKeys[table] = resolved
        return resolved
    }
}
