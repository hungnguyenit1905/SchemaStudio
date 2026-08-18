//
//  GenerationGoldenTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// The reproducibility guard. A fixed profile and a fixed seed have to produce
/// the same rows for ever; anything that changes them changes user-visible
/// output and has to be a deliberate edit to the committed file.
@Suite("Generation golden output")
struct GenerationGoldenTests {
    private struct GoldenTable: Codable, Equatable {
        let table: String
        let columns: [String]
        let rows: [[String]]
    }

    private struct GoldenRun: Codable, Equatable {
        let seed: UInt64
        let tables: [GoldenTable]
    }

    private static let seed: UInt64 = 20_260_816
    private static let rowCount = 12

    private static var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Generation/golden-catalog.json")
    }

    private static func schema() -> [GenerationTable] {
        let assembler = SchemaFactsAssembler(databaseType: .postgresql)
        return [
            assembler.assemble(
                schema: "public",
                table: "authors",
                columns: [
                    PluginColumnInfo(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true),
                    PluginColumnInfo(name: "name", dataType: "varchar(40)", isNullable: false),
                    PluginColumnInfo(name: "active", dataType: "boolean", isNullable: false),
                    PluginColumnInfo(name: "rating", dataType: "numeric(4,2)", isNullable: false),
                    PluginColumnInfo(name: "joined_on", dataType: "date", isNullable: false),
                    PluginColumnInfo(name: "reference", dataType: "uuid", isNullable: false)
                ],
                foreignKeys: [],
                indexes: []
            ),
            assembler.assemble(
                schema: "public",
                table: "books",
                columns: [
                    PluginColumnInfo(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true),
                    PluginColumnInfo(name: "author_id", dataType: "bigint", isNullable: false),
                    PluginColumnInfo(name: "title", dataType: "varchar(24)", isNullable: false),
                    PluginColumnInfo(name: "shelf", dataType: "varchar(8)", isNullable: false),
                    PluginColumnInfo(name: "pages", dataType: "integer", isNullable: false),
                    PluginColumnInfo(name: "published_at", dataType: "timestamp", isNullable: false)
                ],
                foreignKeys: [
                    PluginForeignKeyInfo(
                        name: "fk_books_author",
                        column: "author_id",
                        referencedTable: "authors",
                        referencedColumn: "id",
                        referencedSchema: "public"
                    )
                ],
                indexes: []
            )
        ]
    }

    private static func profile() -> GenerationProfile {
        GenerationProfile(name: "golden-catalog", seed: seed, tables: [
            GenerationTableProfile(schema: "public", table: "authors", rowCount: rowCount, columns: [
                GenerationColumnProfile(
                    column: "id",
                    generator: "AutoIncrement",
                    params: .object(["start": .int(1), "step": .int(1)])
                ),
                GenerationColumnProfile(
                    column: "name",
                    generator: "RandomString",
                    params: .object(["minLength": .int(4), "maxLength": .int(10), "charset": .string("alphabetic")]),
                    common: CommonParams(textCase: .titlecase)
                ),
                GenerationColumnProfile(column: "active", generator: "Boolean"),
                GenerationColumnProfile(
                    column: "rating",
                    generator: "Decimal",
                    params: .object(["min": .double(1), "max": .double(5), "scale": .int(2)])
                ),
                GenerationColumnProfile(
                    column: "joined_on",
                    generator: "Date",
                    params: .object(["from": .string("2020-01-01"), "to": .string("2024-12-31")])
                ),
                GenerationColumnProfile(column: "reference", generator: "UUID")
            ]),
            GenerationTableProfile(schema: "public", table: "books", rowCount: rowCount * 2, columns: [
                GenerationColumnProfile(
                    column: "id",
                    generator: "AutoIncrement",
                    params: .object(["start": .int(100), "step": .int(1)])
                ),
                GenerationColumnProfile(column: "author_id", generator: "Reference"),
                GenerationColumnProfile(
                    column: "title",
                    generator: "LoremWords",
                    params: .object(["minWords": .int(2), "maxWords": .int(4)])
                ),
                GenerationColumnProfile(
                    column: "shelf",
                    generator: "List",
                    params: .object([
                        "values": .array([.string("A1"), .string("B2"), .string("C3"), .string("D4")])
                    ])
                ),
                GenerationColumnProfile(
                    column: "pages",
                    generator: "Integer",
                    params: .object(["min": .int(40), "max": .int(900)])
                ),
                GenerationColumnProfile(
                    column: "published_at",
                    generator: "DateTime",
                    params: .object([
                        "from": .string("2021-01-01T00:00:00Z"),
                        "to": .string("2024-12-31T23:59:59Z")
                    ])
                )
            ])
        ])
    }

    private static func run() async throws -> GoldenRun {
        let driver = FakeGenerationDriver()
        driver.preloadedValues = [
            ReferenceKey(schema: "public", table: "authors", columns: ["id"]): (1 ... 12).map { [.int(Int64($0))] }
        ]
        let plan = try GenerationPlanCompiler().compile(profile: profile(), schema: schema())
        let engine = GenerationRuntimeFixtures.engine(
            driver: driver,
            truncator: GenerationStringTruncator.forVendor(.postgresql)
        )
        _ = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))

        return GoldenRun(
            seed: seed,
            tables: driver.insertedTableOrder.map { qualified in
                let name = qualified.split(separator: ".").last.map(String.init) ?? qualified
                return GoldenTable(
                    table: qualified,
                    columns: driver.columns(for: name),
                    rows: driver.rows(for: name).map { row in row.map(\.textFallback) }
                )
            }
        )
    }

    @Test("A fixed profile and seed produce the committed output")
    func goldenOutputIsStable() async throws {
        let produced = try await Self.run()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(produced)

        if ProcessInfo.processInfo.environment["GENERATION_GOLDEN_UPDATE"] != nil {
            try FileManager.default.createDirectory(
                at: Self.goldenURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoded.write(to: Self.goldenURL)
        }

        let committed = try Data(contentsOf: Self.goldenURL)
        let expected = try JSONDecoder().decode(GoldenRun.self, from: committed)
        #expect(produced == expected)
    }

    @Test("The same profile run twice produces identical rows")
    func runsAreReproducible() async throws {
        let first = try await Self.run()
        let second = try await Self.run()
        #expect(first == second)
    }
}
