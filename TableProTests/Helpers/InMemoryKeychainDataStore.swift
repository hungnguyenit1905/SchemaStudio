//
//  InMemoryKeychainDataStore.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio

final class InMemoryKeychainDataStore: KeychainDataStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var readFailure: KeychainResult?
    private var writesSucceed = true
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var deleteCount = 0

    func failReads(with result: KeychainResult) {
        lock.lock()
        defer { lock.unlock() }
        readFailure = result
    }

    func failWrites() {
        lock.lock()
        defer { lock.unlock() }
        writesSucceed = false
    }

    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return items[key] != nil
    }

    func seed(_ value: String, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        items[key] = Data(value.utf8)
    }

    func read(forKey key: String) -> KeychainResult {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        if let readFailure { return readFailure }
        guard let data = items[key] else { return .notFound }
        return .found(data)
    }

    func write(_ data: Data, forKey key: String, synchronizable: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        writeCount += 1
        guard writesSucceed else { return false }
        items[key] = data
        return true
    }

    func delete(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        deleteCount += 1
        items[key] = nil
    }
}
