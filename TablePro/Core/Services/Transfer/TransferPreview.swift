//
//  TransferPreview.swift
//  TablePro
//

import Foundation

struct TransferTablePlan: Sendable, Identifiable {
    let table: String
    let structure: TransferTableStructure
    let targetExists: Bool
    let steps: [TransferStep]
    let extraTargetColumns: [String]

    var id: String { table }

    var warnings: [TransferStructureWarning] { structure.warnings }
}

struct TransferPreflightFailure: Sendable, Identifiable, Hashable {
    let table: String
    let message: String

    var id: String { table }
}

struct TransferPreview: Sendable {
    let plans: [TransferTablePlan]
    let failures: [TransferPreflightFailure]

    var tablesToDrop: [String] {
        plans.filter { $0.steps.contains(.dropTargetTable) }.map(\.table)
    }

    var plansWithWarnings: [TransferTablePlan] {
        plans.filter { !$0.warnings.isEmpty || !$0.extraTargetColumns.isEmpty }
    }

    var isClean: Bool { failures.isEmpty }
}
