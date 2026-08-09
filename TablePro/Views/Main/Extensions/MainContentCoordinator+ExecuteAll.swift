//
//  MainContentCoordinator+ExecuteAll.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func runAllStatements() {
        queryExecutionCoordinator.runAllStatements()
    }

    func dispatchStatements(_ statements: [String], tabIndex index: Int, bypassRowLimit: Bool = false) {
        queryExecutionCoordinator.dispatchStatements(statements, tabIndex: index, bypassRowLimit: bypassRowLimit)
    }

    func dispatchParameterizedStatements(
        _ statements: [String],
        parameters: [QueryParameter],
        tabIndex index: Int,
        bypassRowLimit: Bool = false
    ) {
        queryExecutionCoordinator.dispatchParameterizedStatements(
            statements,
            parameters: parameters,
            tabIndex: index,
            bypassRowLimit: bypassRowLimit
        )
    }
}
