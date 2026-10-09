//
//  KeychainHelper.swift
//  TablePro
//

import Foundation
import os
import Security

enum KeychainResult: Sendable, Equatable {
    case found(Data)
    case notFound
    case locked
    case userCancelled
    case authFailed
    case error(OSStatus)
}

enum KeychainStringResult: Sendable, Equatable {
    case found(String)
    case notFound
    case locked
    case userCancelled
    case authFailed
    case error(OSStatus)
}

protocol KeychainStoring: Sendable {
    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool
    func readStringResult(forKey key: String) -> KeychainStringResult
    func delete(forKey key: String)
}

final class KeychainHelper: KeychainStoring {
    static let shared = KeychainHelper(
        backend: KeychainBackendResolver.resolve(entitlements: ProcessKeychainEntitlements())
    )
    static let passwordSyncEnabledKey = "com.SchemaStudio.keychainPasswordSyncEnabled"

    private static let service = "com.SchemaStudio"
    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "KeychainHelper")

    private static let accessGroupSuffix = ".com.SchemaStudio.shared"
    private static let teamPrefixedGroupPattern = #"^[A-Z0-9]{10}\..+"#

    private let primary: any KeychainDataStore
    private let legacy: (any KeychainDataStore)?
    private let isPasswordSyncEnabled: @Sendable () -> Bool

    init(
        primary: any KeychainDataStore,
        legacy: (any KeychainDataStore)?,
        isPasswordSyncEnabled: @escaping @Sendable () -> Bool = KeychainHelper.passwordSyncPreference
    ) {
        self.primary = primary
        self.legacy = legacy
        self.isPasswordSyncEnabled = isPasswordSyncEnabled
    }

    convenience init(backend: KeychainBackend) {
        let stores = Self.makeStores(for: backend)
        self.init(primary: stores.primary, legacy: stores.legacy)
        Self.logger.notice("Keychain backend: \(String(describing: backend), privacy: .public)")
    }

    static func makeStores(
        for backend: KeychainBackend
    ) -> (primary: any KeychainDataStore, legacy: (any KeychainDataStore)?) {
        switch backend {
        case .dataProtection:
            let primary = SecItemKeychainStore(
                service: service,
                useDataProtection: true,
                accessGroup: resolveAccessGroup()
            )
            let legacy = SecItemKeychainStore(service: service, useDataProtection: false, accessGroup: nil)
            return (primary, legacy)
        case .file:
            return (SecItemKeychainStore(service: service, useDataProtection: false, accessGroup: nil), nil)
        }
    }

    private static func resolveAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String] else { return nil }
        let candidate = groups.first { $0.hasSuffix(accessGroupSuffix) } ?? groups.first
        guard let candidate,
              candidate.range(of: teamPrefixedGroupPattern, options: .regularExpression) != nil else { return nil }
        return candidate
    }

    @Sendable
    private static func passwordSyncPreference() -> Bool {
        UserDefaults.standard.bool(forKey: passwordSyncEnabledKey)
    }

    // MARK: - Data API

    @discardableResult
    func write(_ data: Data, forKey key: String) -> Bool {
        guard primary.write(data, forKey: key, synchronizable: isPasswordSyncEnabled()) else { return false }
        legacy?.delete(forKey: key)
        return true
    }

    func read(forKey key: String) -> KeychainResult {
        let primaryResult = primary.read(forKey: key)
        guard primaryResult == .notFound, let legacy else { return primaryResult }

        let legacyResult = legacy.read(forKey: key)
        guard case .found(let data) = legacyResult else { return legacyResult }

        migrate(data, forKey: key, from: legacy)
        return legacyResult
    }

    func delete(forKey key: String) {
        primary.delete(forKey: key)
        legacy?.delete(forKey: key)
    }

    // MARK: - String Convenience

    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            Self.logger.error("UTF-8 encode failed for '\(key, privacy: .public)'")
            return false
        }
        return write(data, forKey: key)
    }

    func readString(forKey key: String) -> String? {
        if case .found(let value) = readStringResult(forKey: key) {
            return value
        }
        return nil
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        switch read(forKey: key) {
        case .found(let data):
            guard let value = String(data: data, encoding: .utf8) else {
                Self.logger.error("UTF-8 decode failed for '\(key, privacy: .public)'")
                return .error(errSecDecode)
            }
            return .found(value)
        case .notFound: return .notFound
        case .locked: return .locked
        case .userCancelled: return .userCancelled
        case .authFailed: return .authFailed
        case .error(let status): return .error(status)
        }
    }

    // MARK: - Private

    private func migrate(_ data: Data, forKey key: String, from legacy: any KeychainDataStore) {
        guard primary.write(data, forKey: key, synchronizable: isPasswordSyncEnabled()) else {
            Self.logger.error("Keychain migration write failed for '\(key, privacy: .public)'; legacy item kept")
            return
        }
        legacy.delete(forKey: key)
        Self.logger.notice("Migrated '\(key, privacy: .public)' from the file keychain")
    }
}
