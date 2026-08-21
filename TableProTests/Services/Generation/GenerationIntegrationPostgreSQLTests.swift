//
//  GenerationIntegrationPostgreSQLTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// A live PostgreSQL server, named by environment. Absent the variable the whole
/// suite is skipped, so the default `xcodebuild test` run stays server-free.
///
/// `GENERATION_POSTGRES_URL=postgres://user:password@host:5432/database`
enum PostgresTestServer {
    struct Settings {
        let host: String
        let port: Int
        let database: String
        let username: String
        let password: String
    }

    static let settings: Settings? = {
        guard let raw = ProcessInfo.processInfo.environment["GENERATION_POSTGRES_URL"],
              let url = URLComponents(string: raw),
              let host = url.host
        else { return nil }
        let database = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !database.isEmpty else { return nil }
        return Settings(
            host: host,
            port: url.port ?? 5_432,
            database: database,
            username: url.user ?? NSUserName(),
            password: url.password ?? ""
        )
    }()

    static var isAvailable: Bool { settings != nil }
}

@Suite("Generation against PostgreSQL", .serialized)
struct GenerationIntegrationPostgreSQLTests {
    private static let schemaName = "generation_acceptance"

    private static var ddl: String {
        """
        DROP SCHEMA IF EXISTS \(schemaName) CASCADE;
        CREATE SCHEMA \(schemaName);
        CREATE TABLE \(schemaName).regions (
            country varchar(2) NOT NULL,
            code varchar(8) NOT NULL,
            name varchar(64) NOT NULL,
            PRIMARY KEY (country, code)
        );
        CREATE TABLE \(schemaName).customers (
            id bigserial PRIMARY KEY,
            email varchar(120) NOT NULL UNIQUE,
            status varchar(16) NOT NULL,
            created_at date NOT NULL DEFAULT '1970-01-01'
        );
        CREATE TABLE \(schemaName).stores (
            id bigserial PRIMARY KEY,
            country varchar(2) NOT NULL,
            region_code varchar(8) NOT NULL,
            slug varchar(32) NOT NULL,
            CONSTRAINT stores_region_fk FOREIGN KEY (country, region_code)
                REFERENCES \(schemaName).regions (country, code),
            CONSTRAINT stores_slug_unique UNIQUE (country, slug)
        );
        CREATE TABLE \(schemaName).orders (
            id bigserial PRIMARY KEY,
            customer_id bigint NOT NULL REFERENCES \(schemaName).customers (id),
            store_id bigint NOT NULL REFERENCES \(schemaName).stores (id),
            total numeric(10,2) NOT NULL
        );
        CREATE TABLE \(schemaName).shipments (
            id bigserial PRIMARY KEY,
            order_id bigint NOT NULL REFERENCES \(schemaName).orders (id),
            carrier varchar(32) NOT NULL
        );
        """
    }

    private static func profile(rows: Int) -> GenerationProfile {
        GenerationProfile(
            name: "postgres-acceptance",
            seed: 20_260_817,
            tables: [
                GenerationTableProfile(
                    schema: schemaName,
                    table: "regions",
                    rowCount: rows,
                    columns: [
                        GenerationRuntimeFixtures.columnProfile(
                            "country",
                            generator: "List",
                            params: .object(["values": .array([.string("VN"), .string("SG"), .string("JP")])])
                        ),
                        GenerationRuntimeFixtures.columnProfile("code", generator: "RandomString"),
                        GenerationRuntimeFixtures.columnProfile("name", generator: "LoremWords")
                    ]
                ),
                GenerationTableProfile(
                    schema: schemaName,
                    table: "customers",
                    rowCount: rows,
                    columns: [
                        GenerationRuntimeFixtures.columnProfile("email", generator: "RandomString"),
                        GenerationRuntimeFixtures.columnProfile(
                            "status",
                            generator: "List",
                            params: .object(["values": .array([.string("active"), .string("closed")])])
                        ),
                        GenerationRuntimeFixtures.columnProfile(
                            "created_at",
                            generator: "Fixed",
                            params: .object(["value": .string("2024-05-01")])
                        )
                    ]
                ),
                GenerationTableProfile(
                    schema: schemaName,
                    table: "stores",
                    rowCount: rows,
                    columns: [
                        GenerationRuntimeFixtures.columnProfile("slug", generator: "RandomString")
                    ]
                ),
                GenerationTableProfile(
                    schema: schemaName,
                    table: "orders",
                    rowCount: rows * 2,
                    columns: [
                        GenerationRuntimeFixtures.columnProfile("total", generator: "Decimal")
                    ]
                ),
                GenerationTableProfile(
                    schema: schemaName,
                    table: "shipments",
                    rowCount: rows * 2,
                    columns: [
                        GenerationRuntimeFixtures.columnProfile("carrier", generator: "LoremWords")
                    ]
                )
            ]
        )
    }

    private static func loadSchema(
        adapter: PluginDriverAdapter,
        tables: [String]
    ) async throws -> [GenerationTable] {
        let assembler = SchemaFactsAssembler(databaseType: .postgresql)
        let plugin = adapter.schemaPluginDriver
        var loaded: [GenerationTable] = []
        for table in tables {
            loaded.append(
                assembler.assemble(
                    schema: schemaName,
                    table: table,
                    columns: try await plugin.fetchColumns(table: table, schema: schemaName),
                    foreignKeys: try await plugin.fetchForeignKeys(table: table, schema: schemaName),
                    indexes: try await plugin.fetchIndexes(table: table, schema: schemaName)
                )
            )
        }
        return loaded
    }

    private static func connect() async throws -> (DatabaseDriver, PluginDriverAdapter, PluginGenerationDriver) {
        let settings = try #require(PostgresTestServer.settings)
        let connection = DatabaseConnection(
            name: "generation-acceptance",
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
        let adapter = try #require(driver as? PluginDriverAdapter)
        let generationDriver = try #require(
            PluginGenerationDriver(driver: driver, databaseType: .postgresql, schema: schemaName)
        )
        return (driver, adapter, generationDriver)
    }

    private static func scalar(_ driver: DatabaseDriver, _ sql: String) async throws -> Int {
        let result = try await driver.execute(query: sql)
        guard let first = result.rows.first?.first else { return 0 }
        return Int(first.textFallback) ?? 0
    }

    @Test(
        "The P1 acceptance run: 100k rows into a five-table schema with foreign keys",
        .enabled(if: PostgresTestServer.isAvailable, "GENERATION_POSTGRES_URL is not set")
    )
    func acceptanceRunAtScale() async throws {
        let (driver, adapter, generationDriver) = try await Self.connect()

        for statement in Self.ddl.split(separator: ";")
            where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try await driver.execute(query: String(statement))
        }

        let schema = try await Self.loadSchema(
            adapter: adapter,
            tables: ["regions", "customers", "stores", "orders", "shipments"]
        )
        let plan = try GenerationPlanCompiler().compile(profile: Self.profile(rows: 20_000), schema: schema)
        let engine = GenerationRuntimeFixtures.engine(
            driver: generationDriver,
            truncator: GenerationStringTruncator.forVendor(.postgresql)
        )
        let events = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))
        let report = try #require(GenerationRuntimeFixtures.report(in: events))

        #expect(report.totalRowsWritten == 140_000)
        #expect(try await Self.scalar(driver, "SELECT COUNT(*) FROM \(Self.schemaName).orders") == 40_000)
        #expect(try await Self.scalar(driver, "SELECT COUNT(*) FROM \(Self.schemaName).customers") == 20_000)
        #expect(
            try await Self.scalar(
                driver,
                "SELECT COUNT(*) FROM \(Self.schemaName).customers WHERE email IS NULL OR status IS NULL"
            ) == 0
        )
        #expect(
            try await Self.scalar(
                driver,
                "SELECT COUNT(DISTINCT email) FROM \(Self.schemaName).customers"
            ) == 20_000
        )
        #expect(
            try await Self.scalar(
                driver,
                """
                SELECT COUNT(*) FROM \(Self.schemaName).orders o
                LEFT JOIN \(Self.schemaName).customers c ON o.customer_id = c.id
                WHERE c.id IS NULL
                """
            ) == 0
        )
        #expect(
            try await Self.scalar(
                driver,
                """
                SELECT COUNT(*) FROM \(Self.schemaName).stores s
                LEFT JOIN \(Self.schemaName).regions r
                    ON s.country = r.country AND s.region_code = r.code
                WHERE r.country IS NULL
                """
            ) == 0
        )

        _ = try await driver.execute(query: "DROP SCHEMA \(Self.schemaName) CASCADE")
        driver.disconnect()
    }
}
