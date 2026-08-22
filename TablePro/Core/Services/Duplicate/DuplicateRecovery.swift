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
    static func dropStatement(target: DuplicateTableRef, quoting: DuplicateSQLQuoting) -> DuplicateStatement {
        let name: String
        if let schema = target.schema, !schema.isEmpty {
            name = "\(quoting.identifier(schema)).\(quoting.identifier(target.name))"
        } else {
            name = quoting.identifier(target.name)
        }
        return DuplicateStatement(kind: .dropTarget, sql: "DROP TABLE IF EXISTS \(name)")
    }
}
