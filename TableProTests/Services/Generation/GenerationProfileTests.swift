//
//  GenerationProfileTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("GenerationProfile")
struct GenerationProfileTests {
    private typealias Fixtures = GenerationPlanningFixtures

    private func decode(_ json: String) throws -> GenerationProfile {
        try JSONDecoder().decode(GenerationProfile.self, from: Data(json.utf8))
    }

    private static let fixtureJson = """
    {
      "version": 1,
      "name": "shop",
      "seed": 99,
      "tables": [
        {
          "schema": "public",
          "table": "customers",
          "rowCount": 500,
          "emptyFirst": true,
          "columns": [
            {"column": "id", "generator": "Default"},
            {
              "column": "email",
              "generator": "RandomString",
              "params": {"minLength": 5, "maxLength": 40, "charset": "alphanumeric"},
              "common": {"unique": true, "nullPercent": 0}
            }
          ]
        }
      ]
    }
    """

    @Test("A profile decodes from its saved form")
    func decodesFixture() throws {
        let profile = try decode(Self.fixtureJson)
        #expect(profile.name == "shop")
        #expect(profile.seed == 99)
        #expect(profile.tables.count == 1)

        let table = try #require(profile.tables.first)
        #expect(table.table == "customers")
        #expect(table.rowCount == 500)
        #expect(table.emptyFirst)

        let email = try #require(table.column(named: "email"))
        #expect(email.generator == "RandomString")
        #expect(email.common.unique)
    }

    @Test("Heterogeneous params survive a decode and re-encode")
    func paramsRoundTrip() throws {
        let profile = try decode(Self.fixtureJson)
        let encoded = try JSONEncoder().encode(profile)
        let again = try JSONDecoder().decode(GenerationProfile.self, from: encoded)
        #expect(again == profile)

        let email = try #require(again.tables.first?.column(named: "email"))
        #expect(email.params.objectValue?["minLength"] == .int(5))
        #expect(email.params.objectValue?["charset"] == .string("alphanumeric"))
    }

    @Test("Params reach the generator as the bytes it decodes")
    func paramDataFeedsTheGenerator() throws {
        let profile = try decode(Self.fixtureJson)
        let email = try #require(profile.tables.first?.column(named: "email"))
        let column = GeneratorTestFixtures.column(name: "email", dataType: "varchar(255)")
        let generator = try GeneratorRegistry.standard.make(
            identifier: email.generator,
            params: email.paramData,
            column: column,
            seed: 1
        )
        let value = try #require(try generator.next(row: GeneratorTestFixtures.rowContext(), index: 0).asText)
        #expect((5...40).contains(value.count))
    }

    @Test("Keys a saved profile omits fall back to their defaults")
    func omittedKeysUseDefaults() throws {
        let profile = try decode(#"{"name":"minimal","tables":[{"table":"t","columns":[{"column":"c","generator":"Null"}]}]}"#)
        #expect(profile.version == GenerationProfile.currentVersion)
        #expect(profile.seed == 0)
        let table = try #require(profile.tables.first)
        #expect(table.rowCount == 0)
        #expect(!table.emptyFirst)
        #expect(table.schema == nil)
        let column = try #require(table.columns.first)
        #expect(column.common == .none)
        #expect(column.params == .object([:]))
    }

    @Test("A profile from a newer format is refused with a legible error")
    func newerVersionIsRefused() {
        #expect(
            throws: GenerationError.unsupportedProfileVersion(
                found: 99,
                supported: GenerationProfile.currentVersion
            )
        ) {
            _ = try self.decode(#"{"version":99,"name":"future","tables":[]}"#)
        }
    }

    @Test("A profile with no version reads as version 1")
    func missingVersionReadsAsOne() throws {
        let profile = try decode(#"{"name":"old","tables":[]}"#)
        #expect(profile.version == 1)
    }
}

@Suite("GenerationProfileReconciler")
struct GenerationProfileReconcilerTests {
    private typealias Fixtures = GenerationPlanningFixtures

    private func schema(customerColumns: [PluginColumnInfo]) -> [GenerationTable] {
        [Fixtures.table("customers", columns: customerColumns)]
    }

    private var savedProfile: GenerationProfile {
        Fixtures.profile(tables: [
            Fixtures.tableProfile("customers", columns: [
                GenerationColumnProfile(column: "id", generator: "Default"),
                GenerationColumnProfile(
                    column: "nickname",
                    generator: "RandomString",
                    params: .object(["minLength": .int(2), "maxLength": .int(8)])
                )
            ])
        ])
    }

    @Test("A dropped column is removed with a warning, not a crash")
    func droppedColumn() {
        let live = schema(customerColumns: [Fixtures.identityColumn()])
        let result = GenerationProfileReconciler().reconcile(savedProfile, against: live)
        #expect(result.profile.tables.first?.columns.map(\.column) == ["id"])
        #expect(result.changes.contains(.columnDropped(table: "public.customers", column: "nickname")))
        #expect(result.changes.allSatisfy { !$0.message.isEmpty })
    }

    @Test("A new column is auto-mapped and flagged for the UI")
    func addedColumn() throws {
        let live = schema(customerColumns: [
            Fixtures.identityColumn(),
            PluginColumnInfo(name: "nickname", dataType: "varchar(32)"),
            PluginColumnInfo(name: "signed_up_at", dataType: "timestamp")
        ])
        let result = GenerationProfileReconciler().reconcile(savedProfile, against: live)
        #expect(result.profile.tables.first?.columns.map(\.column) == ["id", "nickname", "signed_up_at"])
        #expect(result.addedColumns == ["public.customers.signed_up_at"])
        let added = try #require(result.profile.tables.first?.column(named: "signed_up_at"))
        #expect(added.generator == DateTimeGenerator.identifier)
    }

    @Test("A retyped column keeps its generator when the generator still fits")
    func retypedButCompatible() {
        let live = schema(customerColumns: [
            Fixtures.identityColumn(),
            PluginColumnInfo(name: "nickname", dataType: "varchar(8)")
        ])
        let result = GenerationProfileReconciler().reconcile(savedProfile, against: live)
        #expect(result.profile.tables.first?.column(named: "nickname")?.generator == "RandomString")
        #expect(result.changes.isEmpty)
    }

    @Test("A retyped column downgrades to the type fallback with a warning")
    func retypedIncompatible() throws {
        let saved = Fixtures.profile(tables: [
            Fixtures.tableProfile("customers", columns: [
                GenerationColumnProfile(
                    column: "tier",
                    generator: "List",
                    params: .object(["values": .array([])])
                )
            ])
        ])
        let live = schema(customerColumns: [PluginColumnInfo(name: "tier", dataType: "integer")])
        let result = GenerationProfileReconciler().reconcile(saved, against: live)
        let tier = try #require(result.profile.tables.first?.column(named: "tier"))
        #expect(tier.generator == IntegerGenerator.identifier)
        #expect(result.changes.count == 1)
        let message = try #require(result.changes.first?.message)
        #expect(message.contains("List"))
        #expect(message.contains("Integer"))
    }

    @Test("A generator that is no longer installed downgrades rather than failing")
    func uninstalledGeneratorDowngrades() throws {
        let saved = Fixtures.profile(tables: [
            Fixtures.tableProfile("customers", columns: [
                GenerationColumnProfile(column: "nickname", generator: "VietnameseName")
            ])
        ])
        let live = schema(customerColumns: [PluginColumnInfo(name: "nickname", dataType: "varchar(32)")])
        let result = GenerationProfileReconciler().reconcile(saved, against: live)
        #expect(result.profile.tables.first?.column(named: "nickname")?.generator == LoremWordsGenerator.identifier)
        #expect(result.changes.count == 1)
    }

    @Test("A dropped table is removed from the profile with a warning")
    func droppedTable() {
        let result = GenerationProfileReconciler().reconcile(savedProfile, against: [])
        #expect(result.profile.tables.isEmpty)
        #expect(result.changes == [.tableDropped(table: "public.customers")])
    }

    @Test("A profile that still matches its schema reports no changes")
    func unchangedSchemaIsQuiet() {
        let live = schema(customerColumns: [
            Fixtures.identityColumn(),
            PluginColumnInfo(name: "nickname", dataType: "varchar(32)")
        ])
        let result = GenerationProfileReconciler().reconcile(savedProfile, against: live)
        #expect(!result.hasChanges)
        #expect(result.addedColumns.isEmpty)
    }
}
