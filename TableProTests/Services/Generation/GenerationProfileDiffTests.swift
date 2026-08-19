//
//  GenerationProfileDiffTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

private typealias Fixtures = GenerationPlanningFixtures

@Suite("GenerationProfileDiff")
struct GenerationProfileDiffTests {
    private func schema(emailType: String = "varchar(255)", extraColumn: PluginColumnInfo? = nil) -> [GenerationTable] {
        var columns = [
            Fixtures.identityColumn(),
            PluginColumnInfo(name: "email", dataType: emailType, isNullable: false)
        ]
        if let extraColumn {
            columns.append(extraColumn)
        }
        return [Fixtures.table("users", columns: columns)]
    }

    private func profile(columns: [GenerationColumnProfile]) -> GenerationProfile {
        GenerationProfile(
            name: "users",
            seed: 1,
            tables: [
                GenerationTableProfile(schema: "public", table: "users", rowCount: 10, columns: columns)
            ]
        )
    }

    private func diff(_ profile: GenerationProfile, _ schema: [GenerationTable]) -> GenerationProfileDiff {
        GenerationProfileDiff(reconciliation: GenerationProfileReconciler().reconcile(profile, against: schema))
    }

    @Test("An unchanged schema produces an empty diff")
    func unchangedSchemaIsEmpty() {
        let profile = profile(columns: [
            GenerationColumnProfile(column: "id", generator: "AutoIncrement"),
            GenerationColumnProfile(column: "email", generator: "Email")
        ])
        #expect(diff(profile, schema()).isEmpty)
    }

    @Test("A column the profile knows and the table no longer has reads as removed")
    func droppedColumn() {
        let profile = profile(columns: [
            GenerationColumnProfile(column: "id", generator: "AutoIncrement"),
            GenerationColumnProfile(column: "email", generator: "Email"),
            GenerationColumnProfile(column: "nickname", generator: "Username")
        ])
        let entries = diff(profile, schema()).entries(ofKind: .columnRemoved)
        #expect(entries.map(\.column) == ["nickname"])
        #expect(entries.first?.table == "public.users")
    }

    @Test("A column the table gained reads as added")
    func addedColumn() {
        let profile = profile(columns: [
            GenerationColumnProfile(column: "id", generator: "AutoIncrement"),
            GenerationColumnProfile(column: "email", generator: "Email")
        ])
        let live = schema(extraColumn: PluginColumnInfo(name: "city", dataType: "varchar(80)", isNullable: true))
        let entries = diff(profile, live).entries(ofKind: .columnAdded)
        #expect(entries.map(\.column) == ["city"])
    }

    @Test("A table the profile knows and the database no longer has reads as removed")
    func droppedTable() {
        let profile = GenerationProfile(
            name: "two",
            seed: 1,
            tables: [
                GenerationTableProfile(schema: "public", table: "users", rowCount: 10, columns: []),
                GenerationTableProfile(schema: "public", table: "invoices", rowCount: 10, columns: [])
            ]
        )
        let entries = diff(profile, schema()).entries(ofKind: .tableRemoved)
        #expect(entries.map(\.table) == ["public.invoices"])
    }

    @Test("A column its generator no longer fits reads as a generator change")
    func retypedColumn() {
        let profile = profile(columns: [
            GenerationColumnProfile(column: "id", generator: "AutoIncrement"),
            GenerationColumnProfile(
                column: "email",
                generator: "List",
                params: .object(["values": .array([])])
            )
        ])
        let entries = diff(profile, schema()).entries(ofKind: .generatorChanged)
        #expect(entries.map(\.column) == ["email"])
        #expect(entries.first?.message.isEmpty == false)
    }

    @Test("Every entry carries a message and a stable identity")
    func entriesAreIdentifiable() {
        let profile = profile(columns: [
            GenerationColumnProfile(column: "id", generator: "AutoIncrement"),
            GenerationColumnProfile(column: "email", generator: "Email"),
            GenerationColumnProfile(column: "nickname", generator: "Username")
        ])
        let live = schema(extraColumn: PluginColumnInfo(name: "city", dataType: "varchar(80)", isNullable: true))
        let entries = diff(profile, live).entries

        #expect(entries.count == 2)
        #expect(entries.allSatisfy { !$0.message.isEmpty })
        #expect(Set(entries.map(\.id)).count == entries.count)
    }
}
