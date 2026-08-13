//
//  DiagnosticEventFactory.swift
//  TablePro
//

import Foundation
import TableProDiagnostics

/// The only place that turns an app error into a reportable event.
///
/// Every mapping takes a typed value and emits the name of the enum case, never
/// its associated value. `DatabaseError.connectionFailed(String)` carries the raw
/// driver text, which names the host, the user, and sometimes the statement, so
/// the payload is dropped here and only `connectionFailed` survives.
enum DiagnosticEventFactory {
    static func connectFailed(type: DatabaseType, error: Error) -> DiagnosticEvent {
        DiagnosticEvent(
            id: .connectFailed,
            tags: [
                .databaseType: slug(for: type),
                .errorCase: errorCase(for: error)
            ]
        )
    }

    static func connectCompletedAfterCancel(type: DatabaseType) -> DiagnosticEvent {
        DiagnosticEvent(
            id: .connectCompletedAfterCancel,
            level: .warning,
            tags: [.databaseType: slug(for: type)]
        )
    }

    static func pluginLoadFailed(bundleId: String?, error: Error) -> DiagnosticEvent {
        var tags: [DiagnosticTagKey: String] = [.errorCase: errorCase(for: error)]
        if let bundleId {
            tags[.pluginId] = bundleId
        }
        return DiagnosticEvent(id: .pluginLoadFailed, tags: tags)
    }

    static func transferAborted(type: DatabaseType, error: Error) -> DiagnosticEvent {
        DiagnosticEvent(
            id: .transferAborted,
            tags: [
                .databaseType: slug(for: type),
                .errorCase: errorCase(for: error)
            ]
        )
    }

    static func reconnectStillFailing(attempt: Int) -> DiagnosticEvent {
        DiagnosticEvent(
            id: .reconnectStillFailing,
            level: .warning,
            tags: [.attemptCount: String(attempt)]
        )
    }

    /// Database type names are display strings ("SQL Server", "Cloudflare D1"), so
    /// they are folded into an identifier. This takes a `DatabaseType`, not a
    /// `String`, so no message can be laundered into a valid tag through it.
    static func slug(for type: DatabaseType) -> String {
        let folded = type.rawValue.lowercased().unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a" ... "z", "0" ... "9":
                return Character(scalar)
            default:
                return "_"
            }
        }
        return String(folded)
    }

    static func errorCase(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let databaseError = error as? DatabaseError { return name(of: databaseError) }
        if let pluginError = error as? PluginError { return name(of: pluginError) }
        if let transferError = error as? TransferError { return name(of: transferError) }
        return "unknown"
    }

    private static func name(of error: DatabaseError) -> String {
        switch error {
        case .connectionFailed: return "connectionFailed"
        case .queryFailed: return "queryFailed"
        case .invalidCredentials: return "invalidCredentials"
        case .fileNotFound: return "fileNotFound"
        case .notConnected: return "notConnected"
        case .unsupportedOperation: return "unsupportedOperation"
        }
    }

    private static func name(of error: PluginError) -> String {
        switch error {
        case .invalidBundle: return "invalidBundle"
        case .signatureInvalid: return "signatureInvalid"
        case .checksumMismatch: return "checksumMismatch"
        case .incompatibleVersion: return "incompatibleVersion"
        case .pluginOutdated: return "pluginOutdated"
        case .cannotUninstallBuiltIn: return "cannotUninstallBuiltIn"
        case .notFound: return "notFound"
        case .registryUnreachable: return "registryUnreachable"
        case .noCompatibleBinary: return "noCompatibleBinary"
        case .installFailed: return "installFailed"
        case .pluginConflict: return "pluginConflict"
        case .appVersionTooOld: return "appVersionTooOld"
        case .downloadFailed: return "downloadFailed"
        case .pluginNotInstalled: return "pluginNotInstalled"
        case .pluginUpdateUnavailable: return "pluginUpdateUnavailable"
        case .incompatibleWithCurrentApp: return "incompatibleWithCurrentApp"
        case .invalidDescriptor: return "invalidDescriptor"
        }
    }

    private static func name(of error: TransferError) -> String {
        switch error {
        case .noTablesSelected: return "noTablesSelected"
        case .differentDatabaseTypes: return "differentDatabaseTypes"
        case .sameEndpoint: return "sameEndpoint"
        case .targetIsReadOnly: return "targetIsReadOnly"
        case .noPluginDriver: return "noPluginDriver"
        case .structureUnavailable: return "structureUnavailable"
        case .createTableUnsupported: return "createTableUnsupported"
        case .missingTargetTable: return "missingTargetTable"
        case .targetColumnsMissing: return "targetColumnsMissing"
        case .blockingForeignKeys: return "blockingForeignKeys"
        case .emptyColumnMapping: return "emptyColumnMapping"
        case .columnMappingIncomplete: return "columnMappingIncomplete"
        case .preflightFailed: return "preflightFailed"
        }
    }
}
