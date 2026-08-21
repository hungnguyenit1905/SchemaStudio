//
//  GenerationPreviewTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// The phase's load-bearing test: what the preview shows has to be what the run
/// writes. A preview that drifts from the result is worse than no preview, so this
/// compares them value by value rather than by shape.
@Suite("Generation preview")
struct GenerationPreviewTests {
    private typealias Fixtures = GenerationPlanningFixtures

    private static func schema() -> [GenerationTable] {
        [
            Fixtures.table(
                "customers",
                columns: [
                    Fixtures.identityColumn(),
                    PluginColumnInfo(name: "email", dataType: "varchar(64)", isNullable: false),
                    PluginColumnInfo(name: "status", dataType: "varchar(16)", isNullable: false),
                    PluginColumnInfo(name: "score", dataType: "integer", isNullable: false),
                    PluginColumnInfo(name: "joined_at", dataType: "timestamp", isNullable: false)
                ]
            )
        ]
    }

    private static func profile(rows: Int) -> GenerationProfile {
        GenerationProfile(name: "preview", seed: 987_654, tables: [
            GenerationTableProfile(schema: "public", table: "customers", rowCount: rows, columns: [
                GenerationColumnProfile(column: "id", generator: "Default"),
                GenerationColumnProfile(
                    column: "email",
                    generator: "RandomString",
                    params: .object(["minLength": .int(8), "maxLength": .int(16)]),
                    common: CommonParams(unique: true, suffix: "@example.com")
                ),
                GenerationColumnProfile(
                    column: "status",
                    generator: "List",
                    params: .object(["values": .array([.string("active"), .string("closed")])])
                ),
                GenerationColumnProfile(
                    column: "score",
                    generator: "Integer",
                    params: .object(["min": .int(1), "max": .int(1_000)])
                ),
                GenerationColumnProfile(
                    column: "joined_at",
                    generator: "DateTime",
                    params: .object([
                        "from": .string("2024-01-01T00:00:00Z"),
                        "to": .string("2024-12-31T23:59:59Z")
                    ])
                )
            ])
        ])
    }

    private static func text(_ rows: [[PluginCellValue]]) -> [[String]] {
        rows.map { $0.map(\.textFallback) }
    }

    @Test("The previewed rows are the rows the run writes, value for value")
    func previewMatchesTheRun() async throws {
        let schema = Self.schema()
        let plan = try GenerationPlanCompiler().compile(profile: Self.profile(rows: 500), schema: schema)

        let sink = FakeGenerationDriver()
        _ = try await GenerationRuntimeFixtures.collect(
            GenerationRuntimeFixtures.engine(driver: sink).run(plan: plan)
        )
        let written = sink.rows(for: "customers")

        let previewed = try await GenerationPreviewService(driver: FakeGenerationDriver())
            .preview(plan: plan, rowsPerTable: 20)

        let table = try #require(previewed.tables.first)
        #expect(table.rows.count == 20)
        #expect(written.count == 500)
        #expect(Self.text(table.rows) == Self.text(Array(written.prefix(20))))
        #expect(table.columns == sink.columns(for: "customers"))
        #expect(!table.drawsFromGeneratedParent)
    }

    @Test("Asking for more rows does not change the rows already shown")
    func previewIsStableAcrossSizes() async throws {
        let plan = try GenerationPlanCompiler().compile(profile: Self.profile(rows: 500), schema: Self.schema())
        let service = GenerationPreviewService(driver: FakeGenerationDriver())

        let small = try await service.preview(plan: plan, rowsPerTable: 5)
        let large = try await service.preview(plan: plan, rowsPerTable: 40)
        let smallRows = try #require(small.tables.first?.rows)
        let largeRows = try #require(large.tables.first?.rows)

        #expect(Self.text(smallRows) == Self.text(Array(largeRows.prefix(5))))
    }

    @Test("A preview never writes, empties, or resets anything")
    func previewIsReadOnly() async throws {
        let profile = GenerationProfile(name: "preview", seed: 5, tables: [
            GenerationTableProfile(
                schema: "public",
                table: "customers",
                rowCount: 100,
                emptyFirst: true,
                columns: [
                    GenerationColumnProfile(column: "id", generator: "Default"),
                    GenerationColumnProfile(column: "email", generator: "RandomString"),
                    GenerationColumnProfile(column: "status", generator: "LoremWords"),
                    GenerationColumnProfile(column: "score", generator: "Integer"),
                    GenerationColumnProfile(column: "joined_at", generator: "DateTime")
                ]
            )
        ])
        let plan = try GenerationPlanCompiler().compile(profile: profile, schema: Self.schema())
        let driver = FakeGenerationDriver()

        _ = try await GenerationPreviewService(driver: driver).preview(plan: plan, rowsPerTable: 10)

        #expect(driver.batches.isEmpty)
        #expect(driver.emptied.isEmpty)
        #expect(driver.sequenceResets.isEmpty)
        #expect(driver.updates.isEmpty)
        #expect(driver.transactionCalls.isEmpty)
    }

    @Test("A preview of more rows than the run will write stops at the run's count")
    func previewNeverExceedsTheRowCount() async throws {
        let plan = try GenerationPlanCompiler().compile(profile: Self.profile(rows: 3), schema: Self.schema())
        let preview = try await GenerationPreviewService(driver: FakeGenerationDriver())
            .preview(plan: plan, rowsPerTable: 50)
        #expect(preview.tables.first?.rows.count == 3)
    }

    /// The strategy governs a composite foreign key's pool. A single-column
    /// `Reference` draws from its own stream and ignores it, in the run as much as in
    /// the preview, so this asserts the case where the option is real.
    @Test("The preview draws composite parents the way the run's own options say to")
    func previewHonoursTheReferenceStrategy() async throws {
        let schema = [
            Fixtures.table(
                "stores",
                columns: [
                    PluginColumnInfo(name: "country", dataType: "varchar(2)", isNullable: false),
                    PluginColumnInfo(name: "region_code", dataType: "varchar(8)", isNullable: false)
                ],
                foreignKeys: [
                    PluginForeignKeyInfo(
                        name: "stores_region_fk",
                        localColumns: ["country", "region_code"],
                        referencedTable: "regions",
                        referencedColumns: ["country", "code"],
                        referencedSchema: "public"
                    )
                ]
            )
        ]
        let profile = GenerationProfile(name: "strategy", seed: 4_321, tables: [
            GenerationTableProfile(schema: "public", table: "stores", rowCount: 6, columns: [
                GenerationColumnProfile(column: "country", generator: "RandomString"),
                GenerationColumnProfile(column: "region_code", generator: "RandomString")
            ])
        ])
        let plan = try GenerationPlanCompiler().compile(profile: profile, schema: schema)

        func drawn(strategy: ReferenceStrategy) async throws -> [String] {
            let driver = FakeGenerationDriver()
            driver.preloadedValues[
                ReferenceKey(schema: "public", table: "regions", columns: ["country", "code"])
            ] = (1 ... 6).map { [PluginCellValue.text("C\($0)"), PluginCellValue.text("R\($0)")] }
            let preview = try await GenerationPreviewService(
                driver: driver,
                options: GenerationRunOptions(referenceStrategy: strategy)
            ).preview(plan: plan, rowsPerTable: 6)
            return (preview.tables.first?.rows ?? []).map { row in
                row.map(\.textFallback).joined(separator: "|")
            }
        }

        let inTurn = try await drawn(strategy: .roundRobin)
        let oneEach = try await drawn(strategy: .oneToOne)

        #expect(inTurn == ["C1|R1", "C2|R2", "C3|R3", "C4|R4", "C5|R5", "C6|R6"])
        #expect(Set(oneEach).count == 6, "one row each has to use every parent exactly once")
        #expect(inTurn != (try await drawn(strategy: .random)) || Set(inTurn).count == 6)
    }

    @Test("A table drawing on a parent that is also being generated says so")
    func generatedParentIsFlagged() async throws {
        let schema = Fixtures.shopSchema
        let profile = Fixtures.autoProfile(for: schema, rowCount: 10)
        let plan = try GenerationPlanCompiler().compile(profile: profile, schema: schema)
        let driver = FakeGenerationDriver()
        driver.preloadedValues[
            ReferenceKey(schema: "public", table: "customers", columns: ["id"])
        ] = [[.int(1)], [.int(2)]]
        driver.preloadedValues[
            ReferenceKey(schema: "public", table: "orders", columns: ["id"])
        ] = [[.int(1)], [.int(2)]]

        let preview = try await GenerationPreviewService(driver: driver).preview(plan: plan, rowsPerTable: 4)

        let customers = try #require(preview.tables.first { $0.table == "public.customers" })
        let orders = try #require(preview.tables.first { $0.table == "public.orders" })
        #expect(!customers.drawsFromGeneratedParent)
        #expect(orders.drawsFromGeneratedParent)
    }

    @Test("The same seed previews the same rows, a different seed does not")
    func previewFollowsTheSeed() async throws {
        func rows(seed: UInt64) async throws -> [[String]] {
            var profile = Self.profile(rows: 50)
            profile.seed = seed
            let plan = try GenerationPlanCompiler().compile(profile: profile, schema: Self.schema())
            let preview = try await GenerationPreviewService(driver: FakeGenerationDriver())
                .preview(plan: plan, rowsPerTable: 10)
            return Self.text(preview.tables.first?.rows ?? [])
        }
        let first = try await rows(seed: 1)
        #expect(try await first == rows(seed: 1))
        #expect(try await first != rows(seed: 2))
    }

    @Test("Previewing one table gives the same rows as previewing the whole plan")
    func singleTablePreviewMatches() async throws {
        let plan = try GenerationPlanCompiler().compile(profile: Self.profile(rows: 100), schema: Self.schema())
        let service = GenerationPreviewService(driver: FakeGenerationDriver())
        let table = try #require(plan.tables.first)

        let whole = try await service.preview(plan: plan, rowsPerTable: 7)
        let single = try await service.preview(table: table, plan: plan, rowsPerTable: 7)

        #expect(Self.text(single.rows) == Self.text(whole.tables.first?.rows ?? []))
    }
}
