//
//  TransferErrorClassifier.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Decides how the engine reacts to a failed statement: retry a transient
/// failure with backoff, salvage a constraint violation row by row, or stop
/// the whole job. Vendor codes drive the decision, never message text, because
/// messages change with the server version and locale. SQLite has no error
/// codes, so it falls back to message matching.
enum TransferErrorClassifier {
    enum Category: Equatable, Sendable {
        case retryable
        case constraintViolation
        case fatal
    }

    static func classify(_ error: Error) -> Category {
        if error is CancellationError { return .fatal }
        if let pluginError = error as? any PluginDriverError {
            return classify(pluginError)
        }
        if let databaseError = error as? DatabaseError {
            switch databaseError {
            case .connectionFailed, .notConnected:
                return .retryable
            case .queryFailed, .invalidCredentials, .fileNotFound, .unsupportedOperation:
                return .fatal
            }
        }
        return .fatal
    }

    /// An object that already exists at the target, tolerated only by the
    /// constraint phase of a resumed run: indexes and foreign keys that the
    /// previous run created before it crashed collide by name on re-run.
    static func isDuplicateObject(_ error: Error) -> Bool {
        if let pluginError = error as? any PluginDriverError {
            return isDuplicateObject(pluginError)
        }
        return false
    }

    static func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
        0.25 * pow(2, Double(min(attempt, 6)))
    }

    /// Runs `body` again on a retryable failure, backing off exponentially.
    /// Cancellation and cancellation of the task interrupt the wait.
    static func withRetry<T: Sendable>(
        maxAttempts: Int = 5,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch {
                guard classify(error) == .retryable, attempt < maxAttempts else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(retryDelay(afterAttempt: attempt) * 1_000_000_000))
            }
        }
    }

    // MARK: - Vendor rules

    private static func classify(_ error: any PluginDriverError) -> Category {
        if let state = error.pluginSqlState, state.hasPrefix("08") { return .retryable }
        if let code = error.pluginErrorCode {
            if Self.mysqlRetryableCodes.contains(code) { return .retryable }
            if Self.mysqlConstraintCodes.contains(code) { return .constraintViolation }
            if Self.mysqlFatalCodes.contains(code) { return .fatal }
        }
        if let state = error.pluginSqlState {
            if Self.postgresRetryableStates.contains(state) { return .retryable }
            if state.hasPrefix("23") || state.hasPrefix("22") { return .constraintViolation }
            if state.hasPrefix("28") || state.hasPrefix("42") || state.hasPrefix("3D") { return .fatal }
        }
        let message = error.pluginErrorMessage.lowercased()
        if Self.sqliteRetryableMessages.contains(where: { message.contains($0) }) { return .retryable }
        if Self.sqliteConstraintMessages.contains(where: { message.contains($0) }) { return .constraintViolation }
        return .fatal
    }

    private static func isDuplicateObject(_ error: any PluginDriverError) -> Bool {
        if let code = error.pluginErrorCode, Self.mysqlDuplicateObjectCodes.contains(code) { return true }
        if let state = error.pluginSqlState, Self.postgresDuplicateObjectStates.contains(state) { return true }
        return error.pluginErrorMessage.lowercased().contains("already exists")
    }

    // MARK: - PostgreSQL SQLSTATE

    private static let postgresRetryableStates: Set<String> = [
        "40001", // serialization_failure
        "40P01", // deadlock_detected
        "55P03", // lock_not_available
        "57P01", // admin_shutdown
        "57P02", // crash_shutdown
        "57P03", // cannot_connect_now
        "53300", // too_many_connections
    ]

    private static let postgresDuplicateObjectStates: Set<String> = [
        "42P07", // duplicate_table
        "42710", // duplicate_object
        "42701", // duplicate_column
        "42P06", // duplicate_schema
        "42P04", // duplicate_database
    ]

    // MARK: - MySQL errno

    private static let mysqlRetryableCodes: Set<Int> = [
        1_213, // ER_LOCK_DEADLOCK
        1_205, // ER_LOCK_WAIT_TIMEOUT
        1_040, // ER_CON_COUNT_ERROR
        2_006, // CR_SERVER_GONE_ERROR
        2_013, // CR_SERVER_LOST
    ]

    private static let mysqlConstraintCodes: Set<Int> = [
        1_048, // ER_BAD_NULL_ERROR
        1_062, // ER_DUP_ENTRY
        1_264, // ER_WARN_DATA_OUT_OF_RANGE
        1_292, // ER_WRONG_VALUE
        1_366, // ER_TRUNCATED_WRONG_VALUE
        1_406, // ER_DATA_TOO_LONG
        1_451, // ER_NO_REFERENCED_ROW_2
        1_452, // ER_ROW_IS_REFERENCED_2
    ]

    private static let mysqlFatalCodes: Set<Int> = [
        1_044, // ER_DBACCESS_DENIED_ERROR
        1_045, // ER_ACCESS_DENIED_ERROR
        1_054, // ER_BAD_FIELD_ERROR
        1_064, // ER_PARSE_ERROR
        1_142, // ER_TABLEACCESS_DENIED_ERROR
        1_146, // ER_NO_SUCH_TABLE
    ]

    private static let mysqlDuplicateObjectCodes: Set<Int> = [
        1_050, // ER_TABLE_EXISTS_ERROR
        1_060, // ER_DUP_FIELDNAME
        1_061, // ER_DUP_KEYNAME
    ]

    // MARK: - SQLite (no error codes, message fallback)

    private static let sqliteRetryableMessages = [
        "database is locked",
        "database table is locked",
        "database is busy",
    ]

    private static let sqliteConstraintMessages = [
        "unique constraint failed",
        "foreign key constraint failed",
        "not null constraint failed",
        "check constraint failed",
        "datatype mismatch",
        "constraint failed",
    ]
}
