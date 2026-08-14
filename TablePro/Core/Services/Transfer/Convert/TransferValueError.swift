//
//  TransferValueError.swift
//  TablePro
//

import Foundation

/// What went wrong inside a value conversion, with no idea which row it came
/// from. `TransferRowConverter` adds the table, the column and the primary key
/// before the failure leaves the row loop.
enum TransferValueFault: Error, Sendable, Hashable {
    case outOfRange
    case invalidJson
    case precisionLoss
    case negativeIntoUnsigned
    case zeroDateInNotNull
    case invalidBoolean
}

/// Every case names the row by its primary key instead of carrying the value
/// that failed. The user can query the row; a log or a report that quotes cell
/// contents leaks their data.
enum TransferValueError: LocalizedError, Sendable, Hashable {
    case outOfRange(table: String, column: String, primaryKey: String)
    case invalidJson(table: String, column: String, primaryKey: String)
    case precisionLoss(table: String, column: String, primaryKey: String)
    case negativeIntoUnsigned(table: String, column: String, primaryKey: String)
    case zeroDateInNotNull(table: String, column: String, primaryKey: String)
    case invalidBoolean(table: String, column: String, primaryKey: String)

    init(fault: TransferValueFault, table: String, column: String, primaryKey: String) {
        switch fault {
        case .outOfRange:
            self = .outOfRange(table: table, column: column, primaryKey: primaryKey)
        case .invalidJson:
            self = .invalidJson(table: table, column: column, primaryKey: primaryKey)
        case .precisionLoss:
            self = .precisionLoss(table: table, column: column, primaryKey: primaryKey)
        case .negativeIntoUnsigned:
            self = .negativeIntoUnsigned(table: table, column: column, primaryKey: primaryKey)
        case .zeroDateInNotNull:
            self = .zeroDateInNotNull(table: table, column: column, primaryKey: primaryKey)
        case .invalidBoolean:
            self = .invalidBoolean(table: table, column: column, primaryKey: primaryKey)
        }
    }

    var errorDescription: String? {
        switch self {
        case .outOfRange(let table, let column, let primaryKey):
            return message(
                String(localized: "Column '%1$@' of table '%2$@' holds a value the target cannot store. Row: %3$@."),
                table,
                column,
                primaryKey
            )
        case .invalidJson(let table, let column, let primaryKey):
            return message(
                String(localized: "Column '%1$@' of table '%2$@' does not hold valid JSON. Row: %3$@."),
                table,
                column,
                primaryKey
            )
        case .precisionLoss(let table, let column, let primaryKey):
            return message(
                String(localized: "Column '%1$@' of table '%2$@' needs more digits than the target column has. Row: %3$@."),
                table,
                column,
                primaryKey
            )
        case .negativeIntoUnsigned(let table, let column, let primaryKey):
            return message(
                String(localized: "Column '%1$@' of table '%2$@' holds a negative value in an unsigned column. Row: %3$@."),
                table,
                column,
                primaryKey
            )
        case .zeroDateInNotNull(let table, let column, let primaryKey):
            return message(
                String(localized: "Column '%1$@' of table '%2$@' holds a zero date and does not allow null. Row: %3$@."),
                table,
                column,
                primaryKey
            )
        case .invalidBoolean(let table, let column, let primaryKey):
            return message(
                String(localized: "Column '%1$@' of table '%2$@' holds a value that is not a boolean. Row: %3$@."),
                table,
                column,
                primaryKey
            )
        }
    }

    private func message(_ format: String, _ table: String, _ column: String, _ primaryKey: String) -> String {
        String(format: format, column, table, primaryKey)
    }
}
