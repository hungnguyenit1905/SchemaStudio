//
//  GenerationIntegrationMySQLTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// A live MySQL server, named by environment. Absent the variable the whole suite
/// is skipped, so the default `xcodebuild test` run stays server-free.
///
/// `GENERATION_MYSQL_URL=mysql://user:password@host:3306/database`
enum MySQLTestServer {
    struct Settings {
        let host: String
        let port: Int
        let database: String
        let username: String
        let password: String
    }

    static let settings: Settings? = {
        guard let raw = ProcessInfo.processInfo.environment["GENERATION_MYSQL_URL"],
              let url = URLComponents(string: raw),
              let host = url.host
        else { return nil }
        let database = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !database.isEmpty else { return nil }
        return Settings(
            host: host,
            port: url.port ?? 3_306,
            database: database,
            username: url.user ?? "root",
            password: url.password ?? ""
        )
    }()

    static var isAvailable: Bool { settings != nil }
}

/// MySQL is the third vendor, and it is here for what it does differently rather
/// than to repeat the P1 acceptance run: `AUTO_INCREMENT` instead of a sequence,
/// a case-insensitive collation by default, and unique keys the server enforces
/// case-blind.
@Suite("Generation against MySQL", .serialized)
struct GenerationIntegrationMySQLTests {
    private static let tickets = "generation_tickets"
    private static let staff = "generation_staff"

    private static var ddl: [String] {
        [
            "DROP TABLE IF EXISTS \(staff)",
            "DROP TABLE IF EXISTS \(tickets)",
            """
            CREATE TABLE \(tickets) (
                id BIGINT NOT NULL AUTO_INCREMENT,
                code VARCHAR(16) NOT NULL,
                region VARCHAR(2) NOT NULL,
                label VARCHAR(32) COLLATE utf8mb4_general_ci NOT NULL,
                PRIMARY KEY (id),
                UNIQUE KEY tickets_code_key (code),
                UNIQUE KEY tickets_region_label_key (region, label)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """,
            """
            CREATE TABLE \(staff) (
                id BIGINT NOT NULL AUTO_INCREMENT,
                manager_id BIGINT NULL,
                PRIMARY KEY (id),
                CONSTRAINT staff_manager_fk FOREIGN KEY (manager_id) REFERENCES \(staff) (id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """
        ]
    }

    /// `id` is written by hand, which is the case the sequence reset exists for:
    /// MySQL would otherwise keep handing out keys the table already holds.
    private static func profile(rows: Int) -> GenerationProfile {
        GenerationProfile(
            name: "mysql-acceptance",
            seed: 20_260_817,
            tables: [
                GenerationTableProfile(
                    table: tickets,
                    rowCount: rows,
                    columns: [
                        GenerationRuntimeFixtures.columnProfile(
                            "id",
                            generator: "Integer",
                            params: .object(["min": .int(1), "max": .int(rows)])
                        ),
                        GenerationRuntimeFixtures.columnProfile(
                            "code",
                            generator: "RandomString",
                            params: .object(["minLength": .int(12), "maxLength": .int(16)])
                        ),
                        GenerationRuntimeFixtures.columnProfile(
                            "region",
                            generator: "List",
                            params: .object(["values": .array([.string("VN"), .string("SG"), .string("JP")])])
                        ),
                        GenerationRuntimeFixtures.columnProfile(
                            "label",
                            generator: "RandomString",
                            params: .object(["minLength": .int(10), "maxLength": .int(16)])
                        )
                    ]
                ),
                GenerationTableProfile(
                    table: staff,
                    rowCount: rows,
                    columns: [
                        GenerationRuntimeFixtures.columnProfile("manager_id", generator: "Reference")
                    ]
                )
            ]
        )
    }

    @Test(
        "Unique keys, a case-insensitive collation, a self-reference and AUTO_INCREMENT all survive a run",
        .enabled(if: MySQLTestServer.isAvailable, "GENERATION_MYSQL_URL is not set")
    )
    func acceptanceRun() async throws {
        let (driver, adapter, generationDriver) = try await Self.connect()
        for statement in Self.ddl {
            _ = try await driver.execute(query: statement)
        }

        let schema = try await Self.loadSchema(adapter: adapter, tables: [Self.tickets, Self.staff])
        let plan = try GenerationPlanCompiler().compile(profile: Self.profile(rows: 2_000), schema: schema)
        let engine = GenerationRuntimeFixtures.engine(
            driver: generationDriver,
            truncator: GenerationStringTruncator.forVendor(.mysql)
        )
        let events = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))
        let report = try #require(GenerationRuntimeFixtures.report(in: events))

        #expect(report.totalRowsWritten == 4_000)
        #expect(try await Self.scalar(driver, "SELECT COUNT(*) FROM \(Self.tickets)") == 2_000)
        #expect(try await Self.scalar(driver, "SELECT COUNT(DISTINCT code) FROM \(Self.tickets)") == 2_000)
        #expect(
            try await Self.scalar(
                driver,
                "SELECT COUNT(*) FROM (SELECT region, label FROM \(Self.tickets) GROUP BY region, label) t"
            ) == 2_000
        )
        #expect(try await Self.scalar(driver, "SELECT COUNT(*) FROM \(Self.staff) WHERE manager_id IS NULL") == 0)
        #expect(try await Self.scalar(driver, "SELECT COUNT(*) FROM \(Self.staff) WHERE manager_id = id") == 0)
        #expect(
            try await Self.scalar(
                driver,
                """
                SELECT COUNT(*) FROM \(Self.staff) s
                LEFT JOIN \(Self.staff) m ON m.id = s.manager_id
                WHERE s.manager_id IS NOT NULL AND m.id IS NULL
                """
            ) == 0
        )

        _ = try await driver.execute(
            query: "INSERT INTO \(Self.tickets) (code, region, label) VALUES ('afterwards', 'VN', 'afterwards')"
        )
        #expect(try await Self.scalar(driver, "SELECT COUNT(*) FROM \(Self.tickets)") == 2_001)
        #expect(try await Self.scalar(driver, "SELECT COUNT(DISTINCT id) FROM \(Self.tickets)") == 2_001)

        for statement in ["DROP TABLE \(Self.staff)", "DROP TABLE \(Self.tickets)"] {
            _ = try await driver.execute(query: statement)
        }
        driver.disconnect()
    }

    private static func loadSchema(
        adapter: PluginDriverAdapter,
        tables: [String]
    ) async throws -> [GenerationTable] {
        let assembler = SchemaFactsAssembler(databaseType: .mysql)
        let plugin = adapter.schemaPluginDriver
        var loaded: [GenerationTable] = []
        for table in tables {
            loaded.append(
                assembler.assemble(
                    schema: nil,
                    table: table,
                    columns: try await plugin.fetchColumns(table: table, schema: nil),
                    foreignKeys: try await plugin.fetchForeignKeys(table: table, schema: nil),
                    indexes: try await plugin.fetchIndexes(table: table, schema: nil)
                )
            )
        }
        return loaded
    }

    private static func connect() async throws -> (DatabaseDriver, PluginDriverAdapter, PluginGenerationDriver) {
        let settings = try #require(MySQLTestServer.settings)
        let connection = DatabaseConnection(
            name: "generation-mysql-acceptance",
            host: settings.host,
            port: settings.port,
            database: settings.database,
            username: settings.username,
            type: .mysql
        )
        let driver = try await DatabaseDriverFactory.createDriver(
            for: connection,
            passwordOverride: settings.password,
            awaitPlugins: true
        )
        try await driver.connect()
        let adapter = try #require(driver as? PluginDriverAdapter)
        let generationDriver = try #require(
            PluginGenerationDriver(driver: driver, databaseType: .mysql)
        )
        return (driver, adapter, generationDriver)
    }

    private static func scalar(_ driver: DatabaseDriver, _ sql: String) async throws -> Int {
        let result = try await driver.execute(query: sql)
        guard let first = result.rows.first?.first else { return 0 }
        return Int(first.textFallback) ?? 0
    }
}
