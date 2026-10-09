//
//  KeychainBackend.swift
//  TablePro
//

import Foundation
import Security

enum KeychainBackend: Sendable, Equatable {
    case dataProtection
    case file
}

protocol KeychainEntitlementReading: Sendable {
    func hasValue(forEntitlement entitlement: String) -> Bool
}

struct ProcessKeychainEntitlements: KeychainEntitlementReading {
    func hasValue(forEntitlement entitlement: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) != nil
    }
}

enum KeychainBackendResolver {
    static let applicationIdentifierEntitlement = "com.apple.application-identifier"
    static let accessGroupsEntitlement = "keychain-access-groups"

    static func resolve(entitlements: any KeychainEntitlementReading) -> KeychainBackend {
        let grantsDataProtection = entitlements.hasValue(forEntitlement: applicationIdentifierEntitlement)
            || entitlements.hasValue(forEntitlement: accessGroupsEntitlement)
        return grantsDataProtection ? .dataProtection : .file
    }
}
