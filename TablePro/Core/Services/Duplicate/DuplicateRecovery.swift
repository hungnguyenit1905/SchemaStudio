//
//  DuplicateRecovery.swift
//  TablePro
//

import Foundation

enum DuplicateRecoveryAction: Sendable, Hashable {
    /// Everything ran inside one transaction, so undoing it is free and complete.
    case rollback
    /// Objects are already committed. One `DROP TABLE` removes the table and, with it, its indexes
    /// and any sequence owned by its columns.
    case dropTarget
    /// Rows are already committed and the user has not said whether to keep them.
    case askBeforeDropping
}

/// Decides what to undo after a fatal failure or a cancel. Pure so the whole matrix is testable
/// without a server.
///
/// The distinction that matters: a rollback is only available while a transaction is still open.
/// Chunked mode commits every batch and MySQL commits every DDL statement, so in both cases the
/// only way back is to drop what was created.
enum DuplicateRecovery {
    static func action(
        supportsTransactionalDDL: Bool,
        copyMode: DuplicateCopyMode,
        hasCommittedRows: Bool
    ) -> DuplicateRecoveryAction {
        guard supportsTransactionalDDL, copyMode != .chunked else {
            return hasCommittedRows ? .askBeforeDropping : .dropTarget
        }
        return .rollback
    }

    /// Kept as a statement so it goes through the same executor, history and error handling as
    /// everything else rather than being a side channel.
    ///
    /// One statement is enough at both vendors and there is no ledger to replay backwards: the
    /// only object either builder creates before the copy is the table itself, and dropping it
    /// takes its indexes and any sequence owned by its columns with it. Never write `CASCADE`
    /// here; MySQL parses it and then does nothing, which reads as a working cleanup that is not.
    static func dropStatement(target: DuplicateTableRef, quoting: DuplicateSQLQuoting) -> DuplicateStatement {
        DuplicateStatement(kind: .dropTarget, sql: "DROP TABLE IF EXISTS \(quoting.qualified(target))")
    }
}
