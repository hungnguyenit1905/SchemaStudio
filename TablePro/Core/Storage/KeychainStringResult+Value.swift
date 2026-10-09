//
//  KeychainStringResult+Value.swift
//  TablePro
//

import Foundation
import os

extension KeychainStringResult {
    /// Maps a Keychain read to its string value, returning nil for every
    /// non-fatal outcome and logging the recoverable failures under `label`.
    func value(label: String, logger: Logger) -> String? {
        logFailure(label: label, logger: logger)
        if case .found(let value) = self {
            return value
        }
        return nil
    }

    func logFailure(label: String, logger: Logger) {
        switch self {
        case .found, .notFound:
            return
        case .locked:
            logger.warning("\(label, privacy: .public) unavailable: Keychain locked")
        case .userCancelled:
            logger.notice("\(label, privacy: .public) prompt cancelled")
        case .authFailed:
            logger.warning("\(label, privacy: .public) auth failed")
        case .error(let status):
            logger.error("\(label, privacy: .public) read error \(status)")
        }
    }
}
