//
//  TransferPreview.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct TransferTablePlan: Sendable, Identifiable {
    let table: String
    let structure: TransferTableStructure
    let targetExists: Bool
    let steps: [TransferStep]
    let extraTargetColumns: [String]

    /// How each primary key value has to be written into a chunk predicate,
    /// read from the source column's declared type.
    let keyLiteralKinds: [String: TransferKeyLiteralKind]

    /// Warnings discovered during preflight itself, outside the structure
    /// builder (e.g. an external foreign key the drop step bypassed).
    let additionalWarnings: [TransferStructureWarning]

    init(
        table: String,
        structure: TransferTableStructure,
        targetExists: Bool,
        steps: [TransferStep],
        extraTargetColumns: [String],
        keyLiteralKinds: [String: TransferKeyLiteralKind] = [:],
        additionalWarnings: [TransferStructureWarning] = []
    ) {
        self.table = table
        self.structure = structure
        self.targetExists = targetExists
        self.steps = steps
        self.extraTargetColumns = extraTargetColumns
        self.keyLiteralKinds = keyLiteralKinds
        self.additionalWarnings = additionalWarnings
    }

    var id: String { table }

    var warnings: [TransferStructureWarning] { structure.warnings + additionalWarnings }
}

struct TransferPreflightFailure: Sendable, Identifiable, Hashable {
    let table: String
    let message: String

    var id: String { table }
}

struct TransferTargetCapabilities: Sendable {
    let limits: PluginServerLimits?
    let constraintDisable: PluginConstraintDisableCapability
}

struct TransferPreview: Sendable {
    let plans: [TransferTablePlan]
    let failures: [TransferPreflightFailure]
    let targetCapabilities: TransferTargetCapabilities

    var tablesToDrop: [String] {
        plans.filter { $0.steps.contains(.dropTargetTable) }.map(\.table)
    }

    var plansWithWarnings: [TransferTablePlan] {
        plans.filter { !$0.warnings.isEmpty || !$0.extraTargetColumns.isEmpty }
    }

    var isClean: Bool { failures.isEmpty }
}
