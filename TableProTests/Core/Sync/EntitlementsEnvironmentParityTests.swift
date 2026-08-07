//
//  EntitlementsEnvironmentParityTests.swift
//  TableProTests
//
//  This fork ships with CloudKit sync disabled and never re-created a container of
//  its own, so the Mac app must declare no iCloud container and no environment pin.
//  Declaring one would either point at the upstream project's container or pin an
//  environment for a container that does not exist.
//

import Foundation
import Testing

@Suite("CloudKit entitlements")
struct EntitlementsEnvironmentParityTests {
    private static let environmentKey = "com.apple.developer.icloud-container-environment"
    private static let containerKey = "com.apple.developer.icloud-container-identifiers"
    private static let servicesKey = "com.apple.developer.icloud-services"

    private static let macEntitlements = "TablePro/TablePro.entitlements"
    private static let macDebugEntitlements = "TablePro/TablePro.Debug.entitlements"

    @Test("Mac app declares no CloudKit container", arguments: [macEntitlements, macDebugEntitlements])
    func macDeclaresNoContainer(path: String) throws {
        let entitlements = try entitlements(in: path)
        #expect(entitlements[Self.containerKey] == nil)
        #expect(entitlements[Self.servicesKey] == nil)
    }

    @Test("Mac app pins no CloudKit environment", arguments: [macEntitlements, macDebugEntitlements])
    func macPinsNoEnvironment(path: String) throws {
        let entitlements = try entitlements(in: path)
        #expect(entitlements[Self.environmentKey] == nil)
    }

    private func entitlements(in relativePath: String) throws -> [String: Any] {
        let url = try repoRoot().appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any], "Entitlements at \(relativePath) is not a dictionary")
    }

    private func repoRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            let marker = directory.appendingPathComponent("SchemaStudio.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw EntitlementsParityError.repoRootNotFound
    }

    private enum EntitlementsParityError: Error {
        case repoRootNotFound
    }
}
