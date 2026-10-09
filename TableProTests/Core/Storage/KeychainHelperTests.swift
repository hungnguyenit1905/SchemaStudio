//
//  KeychainHelperTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("KeychainHelper")
struct KeychainHelperTests {
    private let helper = KeychainHelper.shared

    @Test("writeString and readString round trip")
    func writeAndReadStringRoundTrip() {
        let key = "test.string.roundtrip.\(UUID().uuidString)"
        defer { helper.delete(forKey: key) }

        let saved = helper.writeString("hello", forKey: key)
        #expect(saved)

        let loaded = helper.readString(forKey: key)
        #expect(loaded == "hello")
    }

    @Test("write and read Data round trip")
    func writeAndReadDataRoundTrip() {
        let key = "test.data.roundtrip.\(UUID().uuidString)"
        defer { helper.delete(forKey: key) }

        let payload = Data([0x00, 0x01, 0x02, 0xFF])
        let saved = helper.write(payload, forKey: key)
        #expect(saved)

        let result = helper.read(forKey: key)
        #expect(result == .found(payload))
    }

    @Test("delete removes item; subsequent read returns notFound")
    func deleteRemovesItem() {
        let key = "test.delete.\(UUID().uuidString)"
        defer { helper.delete(forKey: key) }

        _ = helper.writeString("temporary", forKey: key)
        helper.delete(forKey: key)

        #expect(helper.read(forKey: key) == .notFound)
        #expect(helper.readString(forKey: key) == nil)
    }

    @Test("write overwrites existing value")
    func writeOverwritesExistingValue() {
        let key = "test.upsert.\(UUID().uuidString)"
        defer { helper.delete(forKey: key) }

        _ = helper.writeString("first", forKey: key)
        _ = helper.writeString("second", forKey: key)

        #expect(helper.readString(forKey: key) == "second")
    }

    @Test("read returns notFound for missing key")
    func readReturnsNotFoundForMissingKey() {
        let key = "test.missing.\(UUID().uuidString)"
        #expect(helper.read(forKey: key) == .notFound)
        #expect(helper.readString(forKey: key) == nil)
        #expect(helper.readStringResult(forKey: key) == .notFound)
    }

    @Test("readStringResult exposes found case")
    func readStringResultExposesFound() {
        let key = "test.stringresult.\(UUID().uuidString)"
        defer { helper.delete(forKey: key) }

        _ = helper.writeString("payload", forKey: key)
        #expect(helper.readStringResult(forKey: key) == .found("payload"))
    }

    @Test("password sync flag defaults to false when unset")
    func passwordSyncFlagDefaultsFalse() {
        let defaultsKey = KeychainHelper.passwordSyncEnabledKey
        let previous = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: defaultsKey)
        #expect(UserDefaults.standard.bool(forKey: defaultsKey) == false)
    }
}

@Suite("KeychainHelper store fallback")
struct KeychainHelperFallbackTests {
    private let primary = InMemoryKeychainDataStore()
    private let legacy = InMemoryKeychainDataStore()
    private let key = "com.SchemaStudio.password.test"

    private func makeHelper(legacy: InMemoryKeychainDataStore?) -> KeychainHelper {
        KeychainHelper(primary: primary, legacy: legacy, isPasswordSyncEnabled: { false })
    }

    @Test("item only in legacy is read, moved to primary, and removed from legacy")
    func legacyItemMigratesOnRead() {
        legacy.seed("secret", forKey: key)
        let helper = makeHelper(legacy: legacy)

        #expect(helper.readStringResult(forKey: key) == .found("secret"))
        #expect(primary.contains(key))
        #expect(!legacy.contains(key))
        #expect(helper.readStringResult(forKey: key) == .found("secret"))
    }

    @Test("primary wins when both stores hold the item and legacy is not read")
    func primaryWinsOverLegacy() {
        primary.seed("new", forKey: key)
        legacy.seed("old", forKey: key)
        let helper = makeHelper(legacy: legacy)

        #expect(helper.readStringResult(forKey: key) == .found("new"))
        #expect(legacy.readCount == 0)
    }

    @Test("missing in both stores is notFound")
    func missingInBothIsNotFound() {
        let helper = makeHelper(legacy: legacy)
        #expect(helper.read(forKey: key) == .notFound)
    }

    @Test("legacy read failures are reported as-is and delete nothing", arguments: [
        KeychainResult.locked,
        KeychainResult.userCancelled,
        KeychainResult.authFailed,
        KeychainResult.error(errSecIO)
    ])
    func legacyFailureIsNotNotFound(failure: KeychainResult) {
        legacy.seed("secret", forKey: key)
        legacy.failReads(with: failure)
        let helper = makeHelper(legacy: legacy)

        #expect(helper.read(forKey: key) == failure)
        #expect(legacy.contains(key))
        #expect(!primary.contains(key))
        #expect(legacy.deleteCount == 0)
    }

    @Test("primary read failure is returned without consulting legacy")
    func primaryFailureSkipsLegacy() {
        primary.failReads(with: .authFailed)
        legacy.seed("secret", forKey: key)
        let helper = makeHelper(legacy: legacy)

        #expect(helper.read(forKey: key) == .authFailed)
        #expect(legacy.readCount == 0)
    }

    @Test("delete removes the item from both stores")
    func deleteClearsBothStores() {
        primary.seed("a", forKey: key)
        legacy.seed("b", forKey: key)
        let helper = makeHelper(legacy: legacy)

        helper.delete(forKey: key)

        #expect(!primary.contains(key))
        #expect(!legacy.contains(key))
        #expect(helper.read(forKey: key) == .notFound)
    }

    @Test("write removes the stale legacy copy")
    func writeRemovesLegacyCopy() {
        legacy.seed("old", forKey: key)
        let helper = makeHelper(legacy: legacy)

        #expect(helper.writeString("new", forKey: key))

        #expect(primary.contains(key))
        #expect(!legacy.contains(key))
    }

    @Test("failed write keeps the legacy copy")
    func failedWriteKeepsLegacyCopy() {
        legacy.seed("old", forKey: key)
        primary.failWrites()
        let helper = makeHelper(legacy: legacy)

        #expect(!helper.writeString("new", forKey: key))
        #expect(legacy.contains(key))
    }

    @Test("failed migration write keeps the legacy item and still returns it")
    func failedMigrationKeepsLegacy() {
        legacy.seed("secret", forKey: key)
        primary.failWrites()
        let helper = makeHelper(legacy: legacy)

        #expect(helper.readStringResult(forKey: key) == .found("secret"))
        #expect(legacy.contains(key))
        #expect(legacy.deleteCount == 0)
    }

    @Test("without a legacy store only primary is used")
    func noLegacyStoreUsesPrimaryOnly() {
        let helper = makeHelper(legacy: nil)

        #expect(helper.read(forKey: key) == .notFound)
        #expect(helper.writeString("value", forKey: key))
        #expect(helper.readStringResult(forKey: key) == .found("value"))
        helper.delete(forKey: key)
        #expect(helper.read(forKey: key) == .notFound)
        #expect(legacy.readCount == 0)
        #expect(legacy.writeCount == 0)
        #expect(legacy.deleteCount == 0)
    }
}
