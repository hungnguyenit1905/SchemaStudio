//
//  AffectedRowEstimate.swift
//  TablePro
//

import Foundation

internal enum AffectedRowEstimate: Equatable, Sendable {
    case exact(Int)
    case wholeTable(Int?)
    case undetermined(UndeterminedReason)

    internal enum UndeterminedReason: Equatable, Sendable {
        case notACountableStatement
        case couldNotDetermine
    }
}
