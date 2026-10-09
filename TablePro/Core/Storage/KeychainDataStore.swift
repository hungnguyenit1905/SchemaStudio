//
//  KeychainDataStore.swift
//  TablePro
//

import Foundation
import os
import Security

protocol KeychainDataStore: Sendable {
    func read(forKey key: String) -> KeychainResult
    func write(_ data: Data, forKey key: String, synchronizable: Bool) -> Bool
    func delete(forKey key: String)
}

struct SecItemKeychainStore: KeychainDataStore {
    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "KeychainDataStore")

    let service: String
    let useDataProtection: Bool
    let accessGroup: String?

    func write(_ data: Data, forKey key: String, synchronizable: Bool) -> Bool {
        let accessible = accessibility(forSync: synchronizable)

        var addQuery = baseQuery(forKey: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = accessible
        if synchronizable {
            addQuery[kSecAttrSynchronizable as String] = true
        }

        var status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecDuplicateItem {
            var search = baseQuery(forKey: key)
            search[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrSynchronizable as String: synchronizable,
                kSecAttrAccessible as String: accessible
            ]
            status = SecItemUpdate(search as CFDictionary, attributes as CFDictionary)
        }

        if status != errSecSuccess {
            log(status: status, operation: "write", key: key)
            return false
        }
        return true
    }

    func read(forKey key: String) -> KeychainResult {
        var query = baseQuery(forKey: key)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            if let data = result as? Data {
                return .found(data)
            }
            return .notFound
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            Self.logger.warning("Keychain locked (before first unlock) for '\(key, privacy: .public)'")
            return .locked
        case errSecUserCanceled:
            Self.logger.notice("Keychain prompt cancelled for '\(key, privacy: .public)'")
            return .userCancelled
        case errSecAuthFailed:
            Self.logger.warning("Keychain auth failed for '\(key, privacy: .public)'")
            return .authFailed
        default:
            log(status: status, operation: "read", key: key)
            return .error(status)
        }
    }

    func delete(forKey key: String) {
        var query = baseQuery(forKey: key)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            log(status: status, operation: "delete", key: key)
        }
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func accessibility(forSync synchronizable: Bool) -> CFString {
        synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    private func log(status: OSStatus, operation: String, key: String) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        Self.logger.error(
            "Keychain \(operation, privacy: .public) failed for '\(key, privacy: .public)': \(message, privacy: .public)"
        )
    }
}
