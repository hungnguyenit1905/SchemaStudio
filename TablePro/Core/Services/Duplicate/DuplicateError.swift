//
//  DuplicateError.swift
//  TablePro
//

import Foundation

enum DuplicateError: LocalizedError, Sendable, Hashable {
    case unsupportedDatabase(String)
    case sourceMissing(String)
    case sourceNotATable(String)
    case partitionedSource(String)
    case targetExists(String)
    case missingCreatePrivilege(String)
    case missingSelectPrivilege(String)
    case unsafeRowFilter
    case invalidRowFilter(String)
    case invalidTargetName(DuplicateTargetNameError)
    case sourceChangedDuringSetup
    case cancelled
    /// Carries the statement that failed so the message can show it verbatim, which is what makes
    /// a server error actionable.
    case statementFailed(sql: String, serverMessage: String)
    case cleanupFailed(target: String, command: String, serverMessage: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDatabase(let name):
            return String(
                format: String(localized: "Duplicating a table is not supported for %@ yet."),
                name
            )
        case .sourceMissing(let table):
            return String(format: String(localized: "Table '%@' no longer exists."), table)
        case .sourceNotATable(let table):
            return String(format: String(localized: "'%@' is not a table."), table)
        case .partitionedSource(let table):
            return String(
                format: String(localized: "Duplicating partitioned tables is not supported yet. '%@' is partitioned."),
                table
            )
        case .targetExists(let name):
            return String(format: String(localized: "'%@' already exists in the target schema."), name)
        case .missingCreatePrivilege(let schema):
            return String(format: String(localized: "You do not have CREATE permission on '%@'."), schema)
        case .missingSelectPrivilege(let table):
            return String(format: String(localized: "You do not have SELECT permission on '%@'."), table)
        case .unsafeRowFilter:
            return String(
                localized: "The row filter cannot contain a semicolon or a comment marker."
            )
        case .invalidRowFilter(let serverMessage):
            return String(format: String(localized: "The row filter is not valid SQL. %@"), serverMessage)
        case .invalidTargetName(let reason):
            return reason.message
        case .sourceChangedDuringSetup:
            return String(
                localized: "The source table changed while this was being set up. Review the options and try again."
            )
        case .cancelled:
            return String(localized: "Duplicate cancelled.")
        case .statementFailed(let sql, let serverMessage):
            return String(
                format: String(localized: "%1$@\n\nFailed statement:\n%2$@"),
                serverMessage,
                sql
            )
        case .cleanupFailed(let target, let command, let serverMessage):
            return String(
                format: String(
                    localized: """
                    %1$@

                    '%2$@' was left behind and could not be removed. Run this to clean up:
                    %3$@
                    """
                ),
                serverMessage,
                target,
                command
            )
        }
    }
}
