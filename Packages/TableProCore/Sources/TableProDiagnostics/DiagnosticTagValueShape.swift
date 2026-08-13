//
//  DiagnosticTagValueShape.swift
//  TableProDiagnostics
//

import Foundation

/// The accepted format of a tag value, declared per key.
///
/// A single character class is not enough. Allowing dots so a plugin bundle ID fits
/// would also admit `db.internal`, and a hostname is exactly the kind of value this
/// module exists to keep out. Each key therefore accepts only the shape its own
/// values take, and `pluginIdentifier` is pinned to the plugin bundle ID prefix so
/// nothing else dotted can pass as one.
public enum DiagnosticTagValueShape: Sendable {
    case identifier
    case errorCode
    case digits
    case pluginIdentifier

    public static let pluginIdentifierPrefix = "com.TablePro."

    func accepts(_ value: String) -> Bool {
        switch self {
        case .identifier:
            return value.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "_" }
        case .errorCode:
            return value.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "-" || $0 == "_" }
        case .digits:
            return value.unicodeScalars.allSatisfy { $0 >= "0" && $0 <= "9" }
        case .pluginIdentifier:
            guard value.hasPrefix(Self.pluginIdentifierPrefix) else { return false }
            let suffix = value.dropFirst(Self.pluginIdentifierPrefix.count)
            guard !suffix.isEmpty else { return false }
            return suffix.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "." || $0 == "_" }
        }
    }

    private func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a" ... "z", "A" ... "Z", "0" ... "9":
            return true
        default:
            return false
        }
    }
}

public extension DiagnosticTagKey {
    var acceptedShape: DiagnosticTagValueShape {
        switch self {
        case .databaseType, .errorCase, .transferPhase:
            return .identifier
        case .driverErrorCode:
            return .errorCode
        case .pluginKitVersion, .attemptCount:
            return .digits
        case .pluginId:
            return .pluginIdentifier
        }
    }
}
