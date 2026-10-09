//
//  KeychainBackendResolverTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("KeychainBackendResolver")
struct KeychainBackendResolverTests {
    private struct StubEntitlements: KeychainEntitlementReading {
        let granted: Set<String>

        func hasValue(forEntitlement entitlement: String) -> Bool {
            granted.contains(entitlement)
        }
    }

    @Test("application-identifier selects the data protection keychain")
    func applicationIdentifierSelectsDataProtection() {
        let entitlements = StubEntitlements(granted: ["com.apple.application-identifier"])
        #expect(KeychainBackendResolver.resolve(entitlements: entitlements) == .dataProtection)
    }

    @Test("no entitlements selects the file keychain")
    func noEntitlementsSelectsFile() {
        let entitlements = StubEntitlements(granted: [])
        #expect(KeychainBackendResolver.resolve(entitlements: entitlements) == .file)
    }

    @Test("keychain-access-groups alone selects the file keychain")
    func accessGroupsAloneSelectsFile() {
        let entitlements = StubEntitlements(granted: ["keychain-access-groups"])
        #expect(KeychainBackendResolver.resolve(entitlements: entitlements) == .file)
    }

    @Test("file backend has no legacy store")
    func fileBackendHasNoLegacyStore() {
        let stores = KeychainHelper.makeStores(for: .file)
        #expect(stores.legacy == nil)
    }

    @Test("data protection backend falls back to the file keychain")
    func dataProtectionBackendHasLegacyStore() {
        let stores = KeychainHelper.makeStores(for: .dataProtection)
        let primary = stores.primary as? SecItemKeychainStore
        let legacy = stores.legacy as? SecItemKeychainStore
        #expect(primary?.useDataProtection == true)
        #expect(legacy?.useDataProtection == false)
        #expect(legacy?.accessGroup == nil)
    }
}
