//
//  DiagnosticEvent.swift
//  TableProDiagnostics
//

import Foundation

public enum DiagnosticLevel: String, Sendable {
    case warning
    case error
}

/// A non-fatal event the app reports to the crash reporter.
///
/// The type has no field that holds free text. An event is an identifier plus tags
/// drawn from a closed key vocabulary, and every value is sanitized on the way in,
/// so a call site cannot leak a driver message even by mistake.
public struct DiagnosticEvent: Equatable, Sendable {
    public let id: DiagnosticEventID
    public let level: DiagnosticLevel
    public let tags: [DiagnosticTagKey: String]

    public init(
        id: DiagnosticEventID,
        level: DiagnosticLevel = .error,
        tags: [DiagnosticTagKey: String] = [:]
    ) {
        self.id = id
        self.level = level
        self.tags = tags.reduce(into: [:]) { result, entry in
            result[entry.key] = DiagnosticTagValueSanitizer.sanitize(entry.value, for: entry.key)
        }
    }
}
