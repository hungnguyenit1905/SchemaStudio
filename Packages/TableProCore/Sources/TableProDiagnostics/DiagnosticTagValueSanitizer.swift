//
//  DiagnosticTagValueSanitizer.swift
//  TableProDiagnostics
//

import Foundation

/// Rejects any tag value that could carry user data.
///
/// Every value a diagnostic event carries passes through here, checked against the
/// shape its own key declares. The accepted shapes are narrow on purpose: an error
/// message, a connection string, a SQL statement, a file path, and a hostname all
/// fail every shape, so a call site cannot leak one even by mistake.
public enum DiagnosticTagValueSanitizer {
    public static let placeholder = "invalid"
    public static let maxLength = 64

    public static func sanitize(_ value: String, for key: DiagnosticTagKey) -> String {
        isValid(value, for: key) ? value : placeholder
    }

    public static func isValid(_ value: String, for key: DiagnosticTagKey) -> Bool {
        let utf8Count = value.utf8.count
        guard utf8Count > 0, utf8Count <= maxLength else { return false }
        return key.acceptedShape.accepts(value)
    }
}
