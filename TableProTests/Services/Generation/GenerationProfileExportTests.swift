//
//  GenerationProfileExportTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("GenerationProfileExporter")
struct GenerationProfileExportTests {
    private let secrets = [
        "db.internal.example.com",
        "10.0.0.7",
        "5432",
        "postgres",
        "hunter2",
        "postgresql://",
        "A1B2C3D4-0000-0000-0000-00000000BEEF"
    ]

    private func profile() -> GenerationProfile {
        GenerationProfile(
            name: "nightly seed",
            seed: 11_223_344,
            tables: [
                GenerationTableProfile(
                    schema: "public",
                    table: "users",
                    rowCount: 500,
                    emptyFirst: true,
                    columns: [
                        GenerationColumnProfile(column: "email", generator: "Email"),
                        GenerationColumnProfile(
                            column: "age",
                            generator: "Integer",
                            params: .object(["min": .int(18), "max": .int(80)]),
                            common: CommonParams(nullPercent: 5, unique: true)
                        )
                    ]
                )
            ],
            scope: GenerationProfileScope(connectionName: "Nightly Fixtures", database: "shop", schema: "public")
        )
    }

    @Test("An exported profile decodes back to the same profile")
    func roundTrips() throws {
        let original = profile()
        let data = try GenerationProfileExporter.export(original)
        #expect(try GenerationProfileExporter.importProfile(from: data) == original)
    }

    /// The hazard this whole format exists to avoid: a profile attached to a bug
    /// report must be safe to read. Scanning the bytes catches a field added
    /// later that a round-trip test would not.
    @Test("The exported bytes carry no host, port, user, password or connection id")
    func carriesNoCredentials() throws {
        let data = try GenerationProfileExporter.export(profile())
        let text = try #require(String(data: data, encoding: .utf8)).lowercased()

        for secret in secrets {
            #expect(!text.contains(secret.lowercased()), "exported profile leaked \(secret)")
        }
        for key in ["host", "port", "password", "username", "connectionid", "sslmode", "sshconfig"] {
            #expect(!text.contains("\"\(key)\""), "exported profile carries a \(key) field")
        }
    }

    @Test("A profile exported without a scope carries no connection name at all")
    func scopeIsOptional() throws {
        var scopeless = profile()
        scopeless.scope = nil
        let text = try #require(String(data: try GenerationProfileExporter.export(scopeless), encoding: .utf8))
        #expect(!text.contains("nightly fixtures"))
        #expect(!text.lowercased().contains("\"scope\""))
    }

    @Test("A profile exported before the Sort option was removed still imports")
    func staleSortOrderKeyStillImports() throws {
        let json = """
        {
            "version": 1,
            "name": "legacy",
            "seed": 7,
            "tables": [
                {
                    "table": "users",
                    "rowCount": 10,
                    "columns": [
                        {
                            "column": "email",
                            "generator": "Email",
                            "common": {
                                "nullPercent": 0,
                                "blankPercent": 0,
                                "unique": false,
                                "prefix": "",
                                "suffix": "",
                                "textCase": "unchanged",
                                "sortOrder": "descending"
                            }
                        }
                    ]
                }
            ]
        }
        """
        let imported = try GenerationProfileExporter.importProfile(from: Data(json.utf8))
        #expect(imported.tables.first?.columns.first?.common == CommonParams())
    }

    @Test("Importing a profile saved by a newer version is refused, not half-read")
    func newerVersionIsRefused() throws {
        let json = """
        {"version": 99, "name": "future", "seed": 1, "tables": []}
        """
        #expect(throws: GenerationError.unsupportedProfileVersion(found: 99, supported: 1)) {
            try GenerationProfileExporter.importProfile(from: Data(json.utf8))
        }
    }

    @Test("A profile written to disk reads back from disk")
    func writesAndReadsAFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try GenerationProfileExporter.write(profile(), to: url)
        #expect(try GenerationProfileExporter.read(from: url) == profile())
    }

    @Test("A name that cannot be a file name still produces one")
    func suggestedFileNameIsUsable() {
        let awkward = GenerationProfile(name: "shop/nightly:run", seed: 0, tables: [])
        #expect(GenerationProfileExporter.suggestedFileName(for: awkward) == "shop-nightly-run.json")
        #expect(GenerationProfileExporter.suggestedFileName(for: GenerationProfile(
            name: "  ",
            seed: 0,
            tables: []
        )) == "profile.json")
    }
}
