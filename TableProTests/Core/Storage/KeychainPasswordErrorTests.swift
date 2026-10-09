//
//  KeychainPasswordErrorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("KeychainPasswordError")
struct KeychainPasswordErrorTests {
    @Test("found returns the stored password")
    func foundReturnsPassword() throws {
        #expect(try KeychainStringResult.found("s3cret").passwordOrThrow() == "s3cret")
    }

    @Test("notFound returns an empty password for passwordless connections")
    func notFoundReturnsEmpty() throws {
        #expect(try KeychainStringResult.notFound.passwordOrThrow() == "")
    }

    @Test("locked throws keychainLocked")
    func lockedThrows() {
        #expect(throws: KeychainPasswordError.keychainLocked) {
            try KeychainStringResult.locked.passwordOrThrow()
        }
    }

    @Test("userCancelled and authFailed throw accessDenied", arguments: [
        KeychainStringResult.userCancelled,
        KeychainStringResult.authFailed
    ])
    func deniedThrows(result: KeychainStringResult) {
        #expect(throws: KeychainPasswordError.accessDenied) {
            try result.passwordOrThrow()
        }
    }

    @Test("error throws readFailed carrying the status")
    func errorThrowsReadFailed() {
        #expect(throws: KeychainPasswordError.readFailed(errSecIO)) {
            try KeychainStringResult.error(errSecIO).passwordOrThrow()
        }
    }

    @Test("every case has a non-empty description")
    func descriptionsAreNonEmpty() {
        let errors: [KeychainPasswordError] = [.keychainLocked, .accessDenied, .readFailed(errSecIO), .saveFailed]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test("readFailed description includes the status code")
    func readFailedDescriptionIncludesStatus() {
        let description = KeychainPasswordError.readFailed(errSecIO).errorDescription ?? ""
        #expect(description.contains("\(errSecIO)"))
    }

    @Test("ConnectionStorage password write reports the keychain result")
    @MainActor
    func savePasswordReportsResult() throws {
        let defaults = try #require(UserDefaults(suiteName: "KeychainPasswordErrorTests.\(UUID().uuidString)"))
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let storage = ConnectionStorage(fileURL: fileURL, userDefaults: defaults, keychain: InMemoryKeychain())
        let id = UUID()

        #expect(storage.savePassword("pw", for: id))
        #expect(storage.loadPasswordResult(for: id) == .found("pw"))

        storage.deletePassword(for: id)
        #expect(storage.loadPasswordResult(for: id) == .notFound)
    }
}
