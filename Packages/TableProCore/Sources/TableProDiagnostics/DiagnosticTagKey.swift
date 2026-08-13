//
//  DiagnosticTagKey.swift
//  TableProDiagnostics
//

import Foundation

/// The closed vocabulary of tags a diagnostic event may carry.
///
/// There is deliberately no key for a host, port, username, database name, table
/// name, SQL statement, or file path. A fact that does not fit one of these keys
/// does not get reported.
public enum DiagnosticTagKey: String, Sendable, CaseIterable {
    case databaseType = "database_type"
    case errorCase = "error_case"
    case driverErrorCode = "driver_error_code"
    case pluginId = "plugin_id"
    case pluginKitVersion = "plugin_kit_version"
    case transferPhase = "transfer_phase"
    case attemptCount = "attempt_count"
}
