//
//  TransferModePlanner.swift
//  TablePro
//

import Foundation

enum TransferStep: Sendable, Hashable {
    case dropTargetTable
    case dropTargetTypes
    case createTargetTypes
    case createTargetTable
    case truncateTarget
    case transferRows
    case createIndexes
    case createForeignKeys
    case resetSequences
    case failMissingTarget
}

enum TransferModePlanner {
    static func plan(mode: TransferMode, options: TransferOptions, targetExists: Bool) -> [TransferStep] {
        switch mode {
        case .copy:
            var steps: [TransferStep] = []
            if targetExists {
                steps.append(.dropTargetTable)
                steps.append(.dropTargetTypes)
            }
            steps.append(.createTargetTypes)
            steps.append(.createTargetTable)
            steps.append(contentsOf: dataAndConstraintSteps(includeConstraints: true))
            return steps
        case .emptyThenTransfer:
            if targetExists {
                return [.truncateTarget] + dataAndConstraintSteps(includeConstraints: false)
            }
            guard options.createTargetIfNotExists else { return [.failMissingTarget] }
            return [.createTargetTypes, .createTargetTable] + dataAndConstraintSteps(includeConstraints: true)
        }
    }

    /// A table that already exists at the target keeps the indexes and foreign
    /// keys it has: re-creating them would collide on name and the user asked
    /// to replace rows, not structure.
    private static func dataAndConstraintSteps(includeConstraints: Bool) -> [TransferStep] {
        guard includeConstraints else { return [.transferRows, .resetSequences] }
        return [.transferRows, .createIndexes, .createForeignKeys, .resetSequences]
    }
}
