//
//  DuplicateStatement+Classification.swift
//  TablePro
//

import Foundation

/// Both switches are exhaustive on purpose: no `default:`. A new `Kind` case must not be able to
/// reach the executor without someone deciding whether it carries the user's row filter and
/// whether failing it should discard the copy. The compiler is the only reliable place to force
/// that decision; a hand-set flag on each statement is a decision that can be forgotten.
extension DuplicateStatement {
    /// Statements whose text embeds the raw filter the user typed. They must reach the server
    /// through the extended query protocol, which refuses to run more than one statement per
    /// request, instead of the simple protocol, which does not.
    var carriesRowFilter: Bool {
        switch kind {
        case .validateRowFilter, .copyData:
            return true
        case .createTable, .tableComment, .harvestIndexes, .dropIndex, .createSequence,
             .setColumnDefault, .ownSequence, .replayIndex, .resetSequence, .resetAutoIncrement,
             .addForeignKey, .analyze, .dropTarget, .dropReferencingForeignKey:
            return false
        }
    }

    var severity: Severity {
        switch kind {
        case .analyze, .tableComment, .resetAutoIncrement:
            return .bestEffort
        case .validateRowFilter, .createTable, .harvestIndexes, .dropIndex, .createSequence,
             .setColumnDefault, .ownSequence, .copyData, .replayIndex, .resetSequence,
             .addForeignKey, .dropTarget, .dropReferencingForeignKey:
            return .fatal
        }
    }
}
