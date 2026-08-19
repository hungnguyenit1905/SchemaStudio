//
//  GenerationProfileStorageTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("GenerationProfileStorage")
struct GenerationProfileStorageTests {
    private func makeStorage() -> (GenerationProfileStorage, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("generation-profiles-\(UUID().uuidString)", isDirectory: true)
        return (GenerationProfileStorage(directory: directory), directory)
    }

    private func profile(named name: String = "nightly") -> GenerationProfile {
        GenerationProfile(
            name: name,
            seed: 42,
            tables: [
                GenerationTableProfile(
                    schema: "public",
                    table: "users",
                    rowCount: 250,
                    columns: [
                        GenerationColumnProfile(column: "email", generator: "Email"),
                        GenerationColumnProfile(
                            column: "age",
                            generator: "Integer",
                            params: .object(["min": .int(18), "max": .int(80)]),
                            common: CommonParams(nullPercent: 10)
                        )
                    ]
                )
            ],
            scope: GenerationProfileScope(connectionName: "Local", database: "shop", schema: "public")
        )
    }

    @Test("A saved profile comes back exactly as it went in")
    func roundTrips() async throws {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }

        let saved = try #require(await storage.save(profile()))
        let loaded = try #require(await storage.load(id: saved.id))

        #expect(loaded.profile == profile())
        #expect(loaded.id == saved.id)
    }

    @Test("Saving under the same id replaces the profile instead of adding one")
    func savingSameIdReplaces() async throws {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }

        let saved = try #require(await storage.save(profile(named: "first")))
        _ = await storage.save(profile(named: "renamed"), id: saved.id)

        let all = await storage.list()
        #expect(all.count == 1)
        #expect(all.first?.profile.name == "renamed")
    }

    @Test("The list is newest first")
    func listIsNewestFirst() async throws {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)
        _ = await storage.save(profile(named: "older"), at: old)
        _ = await storage.save(profile(named: "newer"), at: recent)

        let all = await storage.list()
        #expect(all.map(\.profile.name) == ["newer", "older"])
    }

    @Test("A file that no longer decodes is skipped, and the rest still list")
    func unreadableFileIsSkipped() async throws {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = await storage.save(profile(named: "good"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))

        let all = await storage.list()
        #expect(all.map(\.profile.name) == ["good"])
    }

    @Test("Deleting removes only that profile")
    func deleteRemovesOne() async throws {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try #require(await storage.save(profile(named: "first")))
        _ = await storage.save(profile(named: "second"))

        await storage.delete(id: first.id)

        let all = await storage.list()
        #expect(all.map(\.profile.name) == ["second"])
        #expect(await storage.load(id: first.id) == nil)
    }
}
