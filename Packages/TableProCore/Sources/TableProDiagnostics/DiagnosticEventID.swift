//
//  DiagnosticEventID.swift
//  TableProDiagnostics
//

import Foundation

/// The closed vocabulary of non-fatal events the app is allowed to report.
///
/// A call site picks one of these instead of writing a message, so no error text
/// from a driver can reach the crash reporter. Adding a case is a deliberate act.
public enum DiagnosticEventID: String, Sendable, CaseIterable {
    case connectFailed = "connect_failed"
    case connectCompletedAfterCancel = "connect_completed_after_cancel"
    case pluginLoadFailed = "plugin_load_failed"
    case transferAborted = "transfer_aborted"
    case reconnectExhausted = "reconnect_exhausted"
}
