//
//  GenerationIntegrationSQLiteTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Generation against SQLite")
struct GenerationIntegrationSQLiteTests {
    private static let ddl = """
    CREATE TABLE customers (
        id INTEGER PRIMARY KEY,
        email TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('active', 'closed')),
        manager_id INTEGER REFERENCES customers(id),
        created_at TEXT NOT NULL DEFAULT '2020-01-01'
    );
    CREATE TABLE regions (
        country TEXT NOT NULL,
        code TEXT NOT NULL,
        name TEXT NOT NULL,
        PRIMARY KEY (country, code)
    );
    CREATE TABLE stores (
        id INTEGER PRIMARY KEY,
        country TEXT NOT NULL,
        region_code TEXT NOT NULL,
        slug TEXT NOT NULL,
        slug_upper TEXT GENERATED ALWAYS AS (upper(slug)) VIRTUAL,
        FOREIGN KEY (country, region_code) REFERENCES regions(country, code),
        UNIQUE (country, slug)
    );
    CREATE TABLE orders (
        id INTEGER PRIMARY KEY,
        customer_id INTEGER NOT NULL REFERENCES customers(id),
        store_id INTEGER REFERENCES stores(id),
        primary_shipment_id INTEGER REFERENCES shipments(id)
    );
    CREATE TABLE shipments (
        id INTEGER PRIMARY KEY,
        order_id INTEGER NOT NULL REFERENCES orders(id)
    );
    """

    private static func schema() -> [GenerationTable] {
        let assembler = SchemaFactsAssembler(databaseType: .sqlite)
        return [
            assembler.assemble(
                schema: nil,
                table: "customers",
                columns: [
                    identity("id"),
                    PluginColumnInfo(name: "email", dataType: "text", isNullable: false),
                    PluginColumnInfo(
                        name: "status",
                        dataType: "text",
                        isNullable: false,
                        checkExpressions: ["status IN ('active', 'closed')"]
                    ),
                    PluginColumnInfo(name: "manager_id", dataType: "integer", isNullable: true),
                    PluginColumnInfo(
                        name: "created_at",
                        dataType: "text",
                        isNullable: false,
                        defaultValue: "'2020-01-01'"
                    )
                ],
                foreignKeys: [
                    PluginForeignKeyInfo(
                        name: "fk_customers_manager",
                        column: "manager_id",
                        referencedTable: "customers",
                        referencedColumn: "id"
                    )
                ],
                indexes: []
            ),
            assembler.assemble(
                schema: nil,
                table: "regions",
                columns: [
                    PluginColumnInfo(name: "country", dataType: "text", isNullable: false, isPrimaryKey: true),
                    PluginColumnInfo(name: "code", dataType: "text", isNullable: false, isPrimaryKey: true),
                    PluginColumnInfo(name: "name", dataType: "text", isNullable: false)
                ],
                foreignKeys: [],
                indexes: []
            ),
            assembler.assemble(
                schema: nil,
                table: "stores",
                columns: [
                    identity("id"),
                    PluginColumnInfo(name: "country", dataType: "text", isNullable: false),
                    PluginColumnInfo(name: "region_code", dataType: "text", isNullable: false),
                    PluginColumnInfo(name: "slug", dataType: "text", isNullable: false),
                    PluginColumnInfo(name: "slug_upper", dataType: "text", isNullable: true, isGenerated: true)
                ],
                foreignKeys: [
                    PluginForeignKeyInfo(
                        name: "fk_stores_region",
                        localColumns: ["country", "region_code"],
                        referencedTable: "regions",
                        referencedColumns: ["country", "code"]
                    )
                ],
                indexes: [
                    PluginIndexInfo(
                        name: "uq_stores_country_slug",
                        columns: ["country", "slug"],
                        isUnique: true,
                        isPrimary: false
                    )
                ]
            ),
            assembler.assemble(
                schema: nil,
                table: "orders",
                columns: [
                    identity("id"),
                    PluginColumnInfo(name: "customer_id", dataType: "integer", isNullable: false),
                    PluginColumnInfo(name: "store_id", dataType: "integer", isNullable: true),
                    PluginColumnInfo(name: "primary_shipment_id", dataType: "integer", isNullable: true)
                ],
                foreignKeys: [
                    PluginForeignKeyInfo(
                        name: "fk_orders_customer",
                        column: "customer_id",
                        referencedTable: "customers",
                        referencedColumn: "id"
                    ),
                    PluginForeignKeyInfo(
                        name: "fk_orders_store",
                        column: "store_id",
                        referencedTable: "stores",
                        referencedColumn: "id"
                    ),
                    PluginForeignKeyInfo(
                        name: "fk_orders_shipment",
                        column: "primary_shipment_id",
                        referencedTable: "shipments",
                        referencedColumn: "id"
                    )
                ],
                indexes: []
            ),
            assembler.assemble(
                schema: nil,
                table: "shipments",
                columns: [
                    identity("id"),
                    PluginColumnInfo(name: "order_id", dataType: "integer", isNullable: false)
                ],
                foreignKeys: [
                    PluginForeignKeyInfo(
                        name: "fk_shipments_order",
                        column: "order_id",
                        referencedTable: "orders",
                        referencedColumn: "id"
                    )
                ],
                indexes: []
            )
        ]
    }

    private static func identity(_ name: String) -> PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: "integer",
            isNullable: false,
            isPrimaryKey: true,
            identityKind: .always,
            checkExpressions: []
        )
    }

    private static func profile(rows: Int) -> GenerationProfile {
        GenerationProfile(name: "sqlite-integration", seed: 20_260_816, tables: [
            GenerationTableProfile(table: "customers", rowCount: rows, columns: [
                GenerationColumnProfile(column: "id", generator: "Default"),
                GenerationColumnProfile(
                    column: "email",
                    generator: "RandomString",
                    params: .object(["minLength": .int(8), "maxLength": .int(12)]),
                    common: CommonParams(unique: true, suffix: "@example.com")
                ),
                GenerationColumnProfile(
                    column: "status",
                    generator: "List",
                    params: .object(["values": .array([.string("active"), .string("closed")])])
                ),
                GenerationColumnProfile(column: "manager_id", generator: "Reference"),
                GenerationColumnProfile(
                    column: "created_at",
                    generator: "Fixed",
                    params: .object(["value": .string("2024-05-01")])
                )
            ]),
            GenerationTableProfile(table: "regions", rowCount: rows, columns: [
                GenerationColumnProfile(
                    column: "country",
                    generator: "List",
                    params: .object(["values": .array([.string("VN"), .string("US"), .string("JP")])])
                ),
                GenerationColumnProfile(
                    column: "code",
                    generator: "RandomString",
                    params: .object(["minLength": .int(6), "maxLength": .int(6), "charset": .string("uppercase")]),
                    common: CommonParams(unique: true)
                ),
                GenerationColumnProfile(
                    column: "name",
                    generator: "LoremWords",
                    params: .object(["minWords": .int(1), "maxWords": .int(3)])
                )
            ]),
            GenerationTableProfile(table: "stores", rowCount: rows, columns: [
                GenerationColumnProfile(column: "id", generator: "Default"),
                GenerationColumnProfile(
                    column: "country",
                    generator: "Fixed",
                    params: .object(["value": .string("placeholder")])
                ),
                GenerationColumnProfile(
                    column: "region_code",
                    generator: "Fixed",
                    params: .object(["value": .string("placeholder")])
                ),
                GenerationColumnProfile(
                    column: "slug",
                    generator: "RandomString",
                    params: .object(["minLength": .int(10), "maxLength": .int(10), "charset": .string("lowercase")]),
                    common: CommonParams(unique: true)
                ),
                GenerationColumnProfile(column: "slug_upper", generator: "Default")
            ]),
            GenerationTableProfile(table: "orders", rowCount: rows * 2, columns: [
                GenerationColumnProfile(column: "id", generator: "Default"),
                GenerationColumnProfile(column: "customer_id", generator: "Reference"),
                GenerationColumnProfile(column: "store_id", generator: "Reference"),
                GenerationColumnProfile(column: "primary_shipment_id", generator: "Reference")
            ]),
            GenerationTableProfile(table: "shipments", rowCount: rows * 2, columns: [
                GenerationColumnProfile(column: "id", generator: "Default"),
                GenerationColumnProfile(column: "order_id", generator: "Reference")
            ])
        ])
    }

    private static func run(rows: Int) async throws -> (SQLiteGenerationTestDriver, GenerationReport) {
        let driver = try SQLiteGenerationTestDriver()
        try driver.execute(ddl)
        let plan = try GenerationPlanCompiler().compile(profile: profile(rows: rows), schema: schema())
        let engine = GenerationRuntimeFixtures.engine(
            driver: driver,
            truncator: GenerationStringTruncator.forVendor(.sqlite),
            maxBindParameters: 32_766
        )
        let events = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))
        let report = try #require(GenerationRuntimeFixtures.report(in: events))
        return (driver, report)
    }

    @Test("Every table gets exactly the rows the profile asked for")
    func rowCountsMatch() async throws {
        let (driver, report) = try await Self.run(rows: 50)

        #expect(try driver.scalar("SELECT COUNT(*) FROM customers") == 50)
        #expect(try driver.scalar("SELECT COUNT(*) FROM regions") == 50)
        #expect(try driver.scalar("SELECT COUNT(*) FROM stores") == 50)
        #expect(try driver.scalar("SELECT COUNT(*) FROM orders") == 100)
        #expect(try driver.scalar("SELECT COUNT(*) FROM shipments") == 100)
        #expect(report.totalRowsWritten == 350)
    }

    @Test("Required columns are never left empty")
    func requiredColumnsAreFilled() async throws {
        let (driver, _) = try await Self.run(rows: 50)

        #expect(try driver.scalar("SELECT COUNT(*) FROM customers WHERE email IS NULL OR status IS NULL") == 0)
        #expect(try driver.scalar("SELECT COUNT(*) FROM regions WHERE country IS NULL OR code IS NULL") == 0)
        #expect(try driver.scalar("SELECT COUNT(*) FROM stores WHERE country IS NULL OR region_code IS NULL") == 0)
        #expect(try driver.scalar("SELECT COUNT(*) FROM orders WHERE customer_id IS NULL") == 0)
    }

    @Test("No row points at a parent that does not exist")
    func noOrphanForeignKeys() async throws {
        let (driver, _) = try await Self.run(rows: 50)

        #expect(try driver.query("PRAGMA foreign_key_check").isEmpty)
        #expect(
            try driver.scalar(
                """
                SELECT COUNT(*) FROM orders o
                LEFT JOIN customers c ON o.customer_id = c.id
                WHERE c.id IS NULL
                """
            ) == 0
        )
        #expect(
            try driver.scalar(
                """
                SELECT COUNT(*) FROM stores s
                LEFT JOIN regions r ON s.country = r.country AND s.region_code = r.code
                WHERE r.country IS NULL
                """
            ) == 0
        )
    }

    @Test("A composite unique constraint is not violated")
    func uniqueConstraintsHold() async throws {
        let (driver, _) = try await Self.run(rows: 50)

        #expect(
            try driver.scalar("SELECT COUNT(*) FROM (SELECT country, slug FROM stores GROUP BY country, slug)") == 50
        )
        #expect(try driver.scalar("SELECT COUNT(DISTINCT email) FROM customers") == 50)
    }

    @Test("A server-assigned column keeps its own value")
    func serverAssignedColumnsAreUntouched() async throws {
        let (driver, _) = try await Self.run(rows: 50)

        #expect(try driver.scalar("SELECT COUNT(*) FROM stores WHERE slug_upper != upper(slug)") == 0)
        #expect(try driver.scalar("SELECT COUNT(DISTINCT id) FROM customers") == 50)
    }

    @Test("A defaulted column takes the generated value, not the default")
    func defaultedColumnTakesGeneratedValue() async throws {
        let (driver, _) = try await Self.run(rows: 20)

        #expect(try driver.scalar("SELECT COUNT(*) FROM customers WHERE created_at = '2024-05-01'") == 20)
    }

    @Test("A cycle is broken on the first pass and filled on the second")
    func cycleIsBrokenThenFilled() async throws {
        let (driver, _) = try await Self.run(rows: 20)

        #expect(try driver.scalar("SELECT COUNT(*) FROM shipments WHERE order_id IS NULL") == 0)
        #expect(try driver.scalar("SELECT COUNT(*) FROM orders WHERE primary_shipment_id IS NULL") == 0)
        #expect(
            try driver.scalar(
                """
                SELECT COUNT(*) FROM orders o
                LEFT JOIN shipments s ON s.id = o.primary_shipment_id
                WHERE o.primary_shipment_id IS NOT NULL AND s.id IS NULL
                """
            ) == 0
        )
    }

    @Test("A self-reference is filled with other rows' keys, never a row's own")
    func selfReferenceIsFilledOnTheSecondPass() async throws {
        let (driver, _) = try await Self.run(rows: 20)

        #expect(try driver.scalar("SELECT COUNT(*) FROM customers WHERE manager_id IS NULL") == 0)
        #expect(try driver.scalar("SELECT COUNT(*) FROM customers WHERE manager_id = id") == 0)
        #expect(
            try driver.scalar(
                """
                SELECT COUNT(*) FROM customers c
                LEFT JOIN customers m ON m.id = c.manager_id
                WHERE c.manager_id IS NOT NULL AND m.id IS NULL
                """
            ) == 0
        )
    }

    @Test("An append-only second pass never touches rows this run did not create")
    func secondPassLeavesPreexistingRowsUntouched() async throws {
        let driver = try SQLiteGenerationTestDriver()
        try driver.execute(Self.ddl)
        try driver.execute(
            """
            INSERT INTO customers (id, email, status, manager_id, created_at) VALUES
            (1, 'seed1@example.com', 'active', 1, '2020-01-01'),
            (2, 'seed2@example.com', 'active', 1, '2020-01-01'),
            (3, 'seed3@example.com', 'active', 2, '2020-01-01')
            """
        )

        let profile = GenerationProfile(name: "append", seed: 20_260_913, tables: [
            GenerationTableProfile(table: "customers", rowCount: 2, columns: [
                GenerationColumnProfile(column: "id", generator: "Default"),
                GenerationColumnProfile(
                    column: "email",
                    generator: "RandomString",
                    params: .object(["minLength": .int(8), "maxLength": .int(12)]),
                    common: CommonParams(unique: true, suffix: "@example.com")
                ),
                GenerationColumnProfile(
                    column: "status",
                    generator: "List",
                    params: .object(["values": .array([.string("active"), .string("closed")])])
                ),
                GenerationColumnProfile(column: "manager_id", generator: "Reference"),
                GenerationColumnProfile(
                    column: "created_at",
                    generator: "Fixed",
                    params: .object(["value": .string("2024-05-01")])
                )
            ])
        ])
        let plan = try GenerationPlanCompiler().compile(profile: profile, schema: Self.schema())
        let engine = GenerationRuntimeFixtures.engine(
            driver: driver,
            truncator: GenerationStringTruncator.forVendor(.sqlite),
            maxBindParameters: 32_766
        )
        _ = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))

        #expect(try driver.scalar("SELECT COUNT(*) FROM customers") == 5)
        let seedManagerIds = try driver.query("SELECT manager_id FROM customers WHERE id IN (1, 2, 3) ORDER BY id")
            .map(\.first?.textFallback)
        #expect(seedManagerIds == ["1", "1", "2"])
        #expect(
            try driver.scalar(
                "SELECT COUNT(*) FROM customers WHERE id NOT IN (1, 2, 3) AND manager_id IS NULL"
            ) == 0
        )
    }

    @Test("The P1 acceptance run: 100k rows into a five-table schema with foreign keys")
    func acceptanceRunAtScale() async throws {
        let (driver, report) = try await Self.run(rows: 20_000)

        #expect(report.totalRowsWritten == 140_000)
        #expect(try driver.scalar("SELECT COUNT(*) FROM orders") == 40_000)
        #expect(try driver.query("PRAGMA foreign_key_check").isEmpty)
        #expect(try driver.scalar("SELECT COUNT(*) FROM customers WHERE email IS NULL") == 0)
        #expect(try driver.scalar("SELECT COUNT(DISTINCT email) FROM customers") == 20_000)
    }

    @Test("A plain insert still works after the run")
    func plainInsertSucceedsAfterwards() async throws {
        let (driver, _) = try await Self.run(rows: 20)

        try driver.execute("INSERT INTO customers (email, status) VALUES ('after@example.com', 'active')")
        #expect(try driver.scalar("SELECT COUNT(*) FROM customers") == 21)
    }
}
