//
//  DataTransferService+Preflight.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

extension DataTransferService {
    /// Nothing here writes. DDL does not roll back, so a run that drops a
    /// target table and only then discovers the source is unreadable has
    /// destroyed data with no way back. Every failure that can be known in
    /// advance is found here, before the first statement runs.
    func runPreflight(
        selections: [TransferTableSelection],
        source: TransferDriverContext,
        target: TransferDriverContext,
        mode: TransferMode,
        options: TransferOptions
    ) async throws -> TransferPreview {
        let targetTables = try await target.fetchTableNames()
        let selectedTables = Set(selections.map(\.table))
        let inbound = mode == .copy ? try await inboundForeignKeys(at: target) : [:]

        let limits = try? await target.serverLimits()
        let constraintDisable = await target.constraintDisableCapability()
        if constraintDisable == .notPermitted {
            Self.logger.warning("Target cannot disable constraint checks; drops and truncates may run slower")
        }

        let keepsDescendingIndex = TransferIndexDirectionSupport.keepsDescendingIndex(
            targetType: target.databaseType,
            version: target.serverVersion
        )

        var plans: [TransferTablePlan] = []
        var failures: [TransferPreflightFailure] = []

        for selection in selections {
            do {
                let plan = try await preflightTable(
                    selection.table,
                    source: source,
                    target: target,
                    mode: mode,
                    options: options,
                    targetExists: targetTables.contains(selection.table),
                    selectedTables: selectedTables,
                    inboundForeignKeys: inbound,
                    constraintDisable: constraintDisable,
                    keepsDescendingIndex: keepsDescendingIndex
                )
                plans.append(plan)
            } catch {
                failures.append(
                    TransferPreflightFailure(table: selection.table, message: error.localizedDescription)
                )
            }
        }

        return TransferPreview(
            plans: plans,
            failures: failures,
            targetCapabilities: TransferTargetCapabilities(limits: limits, constraintDisable: constraintDisable)
        )
    }

    private func preflightTable(
        _ table: String,
        source: TransferDriverContext,
        target: TransferDriverContext,
        mode: TransferMode,
        options: TransferOptions,
        targetExists: Bool,
        selectedTables: Set<String>,
        inboundForeignKeys: [String: [String]],
        constraintDisable: PluginConstraintDisableCapability,
        keepsDescendingIndex: Bool
    ) async throws -> TransferTablePlan {
        let columns = try await source.fetchColumns(table: table)
        guard !columns.isEmpty else { throw TransferError.structureUnavailable(table) }

        let indexes = try await source.fetchIndexes(table: table)
        let foreignKeys = try await source.fetchForeignKeys(table: table)
        let mapper = TransferTypeMapper(sourceType: source.databaseType, targetType: target.databaseType)
        let structure = TransferStructureBuilder.build(
            table: table,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            targetSchema: target.schema,
            mapper: mapper.isSameDialect ? nil : mapper,
            keepsDescendingIndex: keepsDescendingIndex
        )

        let steps = TransferModePlanner.plan(mode: mode, options: options, targetExists: targetExists)
        if steps.contains(.failMissingTarget) { throw TransferError.missingTargetTable(table) }

        if steps.contains(.createTargetTable), target.createTableStatement(structure.definition) == nil {
            throw TransferError.createTableUnsupported(table)
        }

        var additionalWarnings: [TransferStructureWarning] = []
        if steps.contains(.dropTargetTable) {
            let blocking = (inboundForeignKeys[table] ?? []).filter { reference in
                !selectedTables.contains(referencingTable(in: reference))
            }
            switch Self.resolveDropBlock(table: table, blocking: blocking, constraintDisable: constraintDisable) {
            case .clear:
                break
            case .blocked:
                throw TransferError.blockingForeignKeys(table: table, references: blocking)
            case .warned(let warning):
                additionalWarnings.append(warning)
            }
        }

        var extraTargetColumns: [String] = []
        if steps.contains(.truncateTarget) {
            extraTargetColumns = try await validateTargetColumns(
                table: table,
                structure: structure,
                target: target
            )
        }

        return TransferTablePlan(
            table: table,
            structure: structure,
            targetExists: targetExists,
            steps: steps,
            extraTargetColumns: extraTargetColumns,
            keyLiteralKinds: TransferChunkPlanner.keyLiteralKinds(
                columns: columns,
                primaryKeyColumns: structure.primaryKeyColumns,
                databaseType: source.databaseType
            ),
            additionalWarnings: additionalWarnings
        )
    }

    enum TransferDropBlockOutcome: Equatable {
        case clear
        case blocked
        case warned(TransferStructureWarning)
    }

    /// `runStructurePhase` already disables `FOREIGN_KEY_CHECKS` around the
    /// real DROP, so a target that confirmed it supports the toggle does not
    /// need preflight to block on a reference outside the selection. Any
    /// other capability keeps the strict block, since the drop would fail.
    static func resolveDropBlock(
        table: String,
        blocking: [String],
        constraintDisable: PluginConstraintDisableCapability
    ) -> TransferDropBlockOutcome {
        guard !blocking.isEmpty else { return .clear }
        guard constraintDisable == .supported else { return .blocked }
        return .warned(.externalForeignKeyDropped(table: table, references: blocking))
    }

    /// Truncating a table whose columns do not cover the source destroys the
    /// old rows and then fails to write the new ones, so the check runs before
    /// any statement. Extra columns at the target are fine, they take their
    /// default, but the user is told about them.
    private func validateTargetColumns(
        table: String,
        structure: TransferTableStructure,
        target: TransferDriverContext
    ) async throws -> [String] {
        let targetColumns = try await target.fetchColumns(table: table)
        guard !targetColumns.isEmpty else { throw TransferError.structureUnavailable(table) }

        let required = structure.writableColumns
        let missing = Self.missingTargetColumns(required: required, targetColumns: targetColumns)
        guard missing.isEmpty else {
            throw TransferError.targetColumnsMissing(table: table, columns: missing)
        }
        return Self.unmatchedTargetColumns(required: required, targetColumns: targetColumns)
    }

    /// A generated column is never written, so it is not required at the
    /// target either.
    static func missingTargetColumns(required: [String], targetColumns: [PluginColumnInfo]) -> [String] {
        let names = Set(targetColumns.map(\.name))
        return required.filter { !names.contains($0) }
    }

    static func unmatchedTargetColumns(required: [String], targetColumns: [PluginColumnInfo]) -> [String] {
        let requiredNames = Set(required)
        return targetColumns
            .filter { !requiredNames.contains($0.name) && !$0.isGenerated }
            .map(\.name)
    }

    /// `DROP TABLE` fails when a table outside the selection still points at
    /// it, and a cascade would take objects the user never chose, so the run
    /// stops here and names the constraint instead.
    private func inboundForeignKeys(at target: TransferDriverContext) async throws -> [String: [String]] {
        let all = try await target.fetchAllForeignKeys()
        var inbound: [String: [String]] = [:]
        for (table, foreignKeys) in all {
            for foreignKey in foreignKeys where foreignKey.referencedTable != table {
                inbound[foreignKey.referencedTable, default: []].append("\(table).\(foreignKey.name)")
            }
        }
        return inbound.mapValues { Array(Set($0)).sorted() }
    }

    private func referencingTable(in reference: String) -> String {
        String(reference.prefix { $0 != "." })
    }
}
