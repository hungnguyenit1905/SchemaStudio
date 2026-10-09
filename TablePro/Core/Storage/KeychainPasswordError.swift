//
//  KeychainPasswordError.swift
//  TablePro
//

import Foundation

enum KeychainPasswordError: LocalizedError, Equatable {
    case keychainLocked
    case accessDenied
    case readFailed(OSStatus)
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .keychainLocked:
            return String(
                localized: "The Keychain is locked, so the saved password can't be read. Unlock it and try again."
            )
        case .accessDenied:
            return String(
                localized: "Access to the saved password in the Keychain was denied. Allow access when macOS asks, or enter the password again in the connection settings."
            )
        case .readFailed(let status):
            return String(
                format: String(
                    localized: "Can't read the saved password from the Keychain (error %d). Enter it again in the connection settings."
                ),
                status
            )
        case .saveFailed:
            return String(
                localized: "The password could not be saved to the Keychain. Check Keychain Access, then try again."
            )
        }
    }
}

extension KeychainStringResult {
    func passwordOrThrow() throws -> String {
        switch self {
        case .found(let value):
            return value
        case .notFound:
            return ""
        case .locked:
            throw KeychainPasswordError.keychainLocked
        case .userCancelled, .authFailed:
            throw KeychainPasswordError.accessDenied
        case .error(let status):
            throw KeychainPasswordError.readFailed(status)
        }
    }
}
