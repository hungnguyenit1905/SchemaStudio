//
//  GenerationPerformanceTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// Counts rows and throws them away, so the number this suite reports is the
/// engine's own cost: row building, batching and the writer, with no driver,
/// no serialization and no network in it.
private final class CountingGenerationDriver: GenerationDriver, @unchecked Sendable {
    private(set) var rowsAccepted = 0
    private(set) var batches = 0

    func serverLimits() async throws -> PluginServerLimits? {
        PluginServerLimits(maxPacketBytes: 4_194_304, maxBindParameters: 65_535)
    }

    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
    func setForeignKeyChecks(enabled: Bool) async throws {}

    func hasInboundForeignKeys(table: GenerationTableReference) async throws -> Bool { false }

    func emptyTable(_ table: GenerationTableReference, allowsTruncate: Bool) async throws {}

    func insert(
        table: GenerationTableReference,
        columns: [String],
        rows: [[PluginCellValue]],
        harvestColumns: [String]
    ) async throws -> [[PluginCellValue]]? {
        rowsAccepted += rows.count
        batches += 1
        return nil
    }

    func update(
        table: GenerationTableReference,
        setColumns: [String],
        keyColumns: [String],
        assignments: [[PluginCellValue]]
    ) async throws {}

    func loadDistinctValues(key: ReferenceKey, limit: Int) async throws -> [[PluginCellValue]] { [] }
}

/// The engine's throughput budget. The 100k case runs in every test run and
/// fails on a regression; the 1M cases are named by environment because one
/// needs a server and the other allocates for a few seconds.
///
/// `GENERATION_MEASURE=1` runs the 1M-row engine measurement.
/// `GENERATION_POSTGRES_URL=postgres://user:password@host:5432/database` runs the
/// 1M-row PostgreSQL measurement.
///
/// Numbers are recorded in
/// `plans/260816-1844-data-generation-engine/phase-11-scale-and-bulk-load.md`.
@Suite("Generation performance", .serialized)
struct GenerationPerformanceTests {
    /// Fifteen columns, which is the shape the phase budget is written against.
    private static func wideSchema() -> [GenerationTable] {
        [
            GenerationPlanningFixtures.table("wide", columns: [
                GenerationRuntimeFixtures.integerColumn("id", primaryKey: true),
                GenerationRuntimeFixtures.textColumn("first_name"),
                GenerationRuntimeFixtures.textColumn("last_name"),
                GenerationRuntimeFixtures.textColumn("email", length: 120),
                GenerationRuntimeFixtures.textColumn("city"),
                GenerationRuntimeFixtures.textColumn("country", length: 2),
                GenerationRuntimeFixtures.textColumn("phone", length: 32),
                GenerationRuntimeFixtures.textColumn("slug", length: 40),
                GenerationRuntimeFixtures.textColumn("status", length: 16),
                GenerationRuntimeFixtures.textColumn("note", length: 200),
                GenerationRuntimeFixtures.integerColumn("visits"),
                GenerationRuntimeFixtures.integerColumn("score"),
                PluginColumnInfo(name: "total", dataType: "numeric(10,2)", isNullable: false),
                PluginColumnInfo(name: "created_at", dataType: "date", isNullable: false),
                PluginColumnInfo(name: "is_active", dataType: "boolean", isNullable: false)
            ])
        ]
    }

    private static func wideProfile(rows: Int) -> GenerationProfile {
        GenerationPlanningFixtures.profile(tables: [
            GenerationPlanningFixtures.tableProfile(
                "wide",
                rowCount: rows,
                columns: [
                    GenerationRuntimeFixtures.columnProfile("id", generator: "AutoIncrement"),
                    GenerationRuntimeFixtures.columnProfile("first_name", generator: "FirstName"),
                    GenerationRuntimeFixtures.columnProfile("last_name", generator: "LastName"),
                    GenerationRuntimeFixtures.columnProfile("email", generator: "Email"),
                    GenerationRuntimeFixtures.columnProfile("city", generator: "City"),
                    GenerationRuntimeFixtures.columnProfile("country", generator: "CountryCode"),
                    GenerationRuntimeFixtures.columnProfile("phone", generator: "PhoneNumber"),
                    GenerationRuntimeFixtures.columnProfile("slug", generator: "Username"),
                    GenerationRuntimeFixtures.columnProfile(
                        "status",
                        generator: "List",
                        params: .object(["values": .array([.string("active"), .string("closed")])])
                    ),
                    GenerationRuntimeFixtures.columnProfile("note", generator: "LoremWords"),
                    GenerationRuntimeFixtures.columnProfile("visits", generator: "Integer"),
                    GenerationRuntimeFixtures.columnProfile("score", generator: "Integer"),
                    GenerationRuntimeFixtures.columnProfile("total", generator: "Decimal"),
                    GenerationRuntimeFixtures.columnProfile("created_at", generator: "Date"),
                    GenerationRuntimeFixtures.columnProfile("is_active", generator: "Boolean")
                ]
            )
        ])
    }

    private static func measure(rows: Int) async throws -> (seconds: Double, rowsWritten: Int) {
        let driver = CountingGenerationDriver()
        let plan = try GenerationRuntimeFixtures.plan(profile: wideProfile(rows: rows), schema: wideSchema())
        let engine = GenerationRuntimeFixtures.engine(driver: driver)

        let startedAt = Date()
        let events = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))
        let seconds = Date().timeIntervalSince(startedAt)

        let report = try #require(GenerationRuntimeFixtures.report(in: events))
        return (seconds, report.totalRowsWritten)
    }

    /// The budget, not the measurement: a Debug build writes 100k rows over
    /// fifteen columns in about 6s on an M-series Mac, and CI runs Debug on
    /// slower hardware with other suites alongside. 20s catches the kind of
    /// regression this phase exists to prevent (a per-row `DateFormatter`, a
    /// re-allocated row buffer, a linear unique scan) without failing on a busy
    /// machine. The Release figure is roughly a tenth of the Debug one, which is
    /// the number the phase target is written against.
    private static let hundredThousandRowBudget: TimeInterval = 20

    private static var measuresMillionRows: Bool {
        ProcessInfo.processInfo.environment["GENERATION_MEASURE"] == "1"
    }

    @Test("One hundred thousand rows over fifteen columns stay inside the budget")
    func hundredThousandRows() async throws {
        let measured = try await Self.measure(rows: 100_000)

        print("GENERATION-PERF rows=100000 columns=15 seconds=\(String(format: "%.2f", measured.seconds))")
        #expect(measured.rowsWritten == 100_000)
        #expect(measured.seconds < Self.hundredThousandRowBudget)
    }

    @Test("A million rows report their engine-side cost", .enabled(if: measuresMillionRows))
    func millionRowsThroughTheEngine() async throws {
        let measured = try await Self.measure(rows: 1_000_000)

        print("GENERATION-PERF rows=1000000 columns=15 seconds=\(String(format: "%.2f", measured.seconds))")
        #expect(measured.rowsWritten == 1_000_000)
    }

    /// The phase target: 1M rows into a 15-column PostgreSQL table under 90s,
    /// through whichever path the route picks (`COPY` where the server allows it).
    @Test(
        "A million rows land in PostgreSQL inside the phase target",
        .enabled(if: PostgresTestServer.isAvailable && measuresMillionRows)
    )
    func millionRowsIntoPostgreSQL() async throws {
        let schemaName = "generation_performance"
        let settings = try #require(PostgresTestServer.settings)
        let connection = DatabaseConnection(
            name: "generation-performance",
            host: settings.host,
            port: settings.port,
            database: settings.database,
            username: settings.username,
            type: .postgresql
        )
        let driver = try await DatabaseDriverFactory.createDriver(
            for: connection,
            passwordOverride: settings.password,
            awaitPlugins: true
        )
        try await driver.connect()
        defer { driver.disconnect() }

        _ = try await driver.execute(query: "DROP SCHEMA IF EXISTS \(schemaName) CASCADE")
        _ = try await driver.execute(query: "CREATE SCHEMA \(schemaName)")
        _ = try await driver.execute(
            query: """
            CREATE TABLE \(schemaName).wide (
                id bigserial PRIMARY KEY,
                first_name varchar(64) NOT NULL,
                last_name varchar(64) NOT NULL,
                email varchar(120) NOT NULL,
                city varchar(64) NOT NULL,
                country varchar(2) NOT NULL,
                phone varchar(32) NOT NULL,
                slug varchar(40) NOT NULL,
                status varchar(16) NOT NULL,
                note varchar(200) NOT NULL,
                visits bigint NOT NULL,
                score bigint NOT NULL,
                total numeric(10,2) NOT NULL,
                created_at date NOT NULL,
                is_active boolean NOT NULL
            )
            """
        )

        let adapter = try #require(driver as? PluginDriverAdapter)
        let plugin = adapter.schemaPluginDriver
        let schema = [
            SchemaFactsAssembler(databaseType: .postgresql).assemble(
                schema: schemaName,
                table: "wide",
                columns: try await plugin.fetchColumns(table: "wide", schema: schemaName),
                foreignKeys: [],
                indexes: try await plugin.fetchIndexes(table: "wide", schema: schemaName)
            )
        ]
        var profile = Self.wideProfile(rows: 1_000_000)
        profile = GenerationProfile(
            name: profile.name,
            seed: profile.seed,
            tables: profile.tables.map { table in
                GenerationTableProfile(
                    schema: schemaName,
                    table: table.table,
                    rowCount: table.rowCount,
                    emptyFirst: table.emptyFirst,
                    columns: table.columns
                )
            }
        )
        let generationDriver = try #require(
            PluginGenerationDriver(driver: driver, databaseType: .postgresql, schema: schemaName)
        )
        let plan = try GenerationRuntimeFixtures.plan(profile: profile, schema: schema)
        let engine = GenerationRuntimeFixtures.engine(driver: generationDriver)

        let startedAt = Date()
        let events = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))
        let seconds = Date().timeIntervalSince(startedAt)

        let report = try #require(GenerationRuntimeFixtures.report(in: events))
        let count = try await driver.execute(query: "SELECT COUNT(*) FROM \(schemaName).wide")
        print("GENERATION-PERF target=postgresql rows=1000000 seconds=\(String(format: "%.2f", seconds))")

        #expect(report.totalRowsWritten == 1_000_000)
        #expect(count.rows.first?.first?.textFallback == "1000000")
        #expect(seconds < 90)

        _ = try await driver.execute(query: "DROP SCHEMA IF EXISTS \(schemaName) CASCADE")
    }
}
