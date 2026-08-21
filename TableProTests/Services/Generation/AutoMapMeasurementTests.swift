//
//  AutoMapMeasurementTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// Runs the auto-mapper over a real schema and prints one line per column, so the
/// mapping can be read and scored by hand. The score is recorded in
/// `plans/260816-1844-data-generation-engine/phase-06-auto-mapper.md`.
///
/// Skipped unless a server is named, so the default test run stays server-free:
///
/// `GENERATION_POSTGRES_URL=postgres://user:password@host:5432/database`
/// `GENERATION_MEASURE_SCHEMA=public`
@Suite("AutoMapper measurement", .serialized)
struct AutoMapMeasurementTests {
    @Test("Every column in a live schema maps to a generator that builds", .enabled(if: PostgresTestServer.isAvailable))
    func measureLiveSchema() async throws {
        let settings = try #require(PostgresTestServer.settings)
        let schema = ProcessInfo.processInfo.environment["GENERATION_MEASURE_SCHEMA"] ?? "public"
        let connection = DatabaseConnection(
            name: "auto-map-measurement",
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

        let adapter = try #require(driver as? PluginDriverAdapter)
        let plugin = adapter.schemaPluginDriver
        let assembler = SchemaFactsAssembler(databaseType: .postgresql)
        let tables = try await plugin.fetchTables(schema: schema)

        var mapped = 0
        var lines: [String] = []
        for table in tables {
            let assembled = assembler.assemble(
                schema: schema,
                table: table.name,
                columns: try await plugin.fetchColumns(table: table.name, schema: schema),
                foreignKeys: try await plugin.fetchForeignKeys(table: table.name, schema: schema),
                indexes: try await plugin.fetchIndexes(table: table.name, schema: schema)
            )
            for column in assembled.columns {
                let resolution = AutoMapper.resolve(column, table: assembled.name)
                let profile = GenerationColumnProfile(
                    column: column.name,
                    generator: resolution.identifier,
                    params: resolution.params,
                    common: resolution.common
                )
                let generator = try GeneratorRegistry.standard.make(
                    identifier: resolution.identifier,
                    params: profile.paramData,
                    column: column,
                    seed: 11
                )
                _ = try generator.next(row: RowContext(table: assembled.name, rowIndex: 0), index: 0)
                mapped += 1
                lines.append(
                    "\(assembled.name).\(column.name) | \(column.type.native) | \(resolution.identifier)"
                        + " | \(resolution.params.jsonText ?? "{}")"
                )
            }
        }

        print("AUTOMAP-MEASUREMENT columns=\(mapped) tables=\(tables.count)")
        for line in lines { print("AUTOMAP-ROW \(line)") }
        #expect(mapped > 0)
    }
}
