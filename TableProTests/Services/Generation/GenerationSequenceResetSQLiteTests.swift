//
//  GenerationSequenceResetSQLiteTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// The `setval` gate, over a real database: after a run writes its own keys into a
/// sequence-backed column, the application's next plain insert has to succeed.
/// Skipping the reset is what leaves a generated database unusable, and the symptom
/// is a duplicate key on the very next insert rather than anything the run reports.
@Suite("Generation sequence reset against SQLite")
struct GenerationSequenceResetSQLiteTests {
    private static let ddl = """
    CREATE TABLE tickets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL
    );
    """

    private static func schema() -> [GenerationTable] {
        [
            SchemaFactsAssembler(databaseType: .sqlite).assemble(
                schema: nil,
                table: "tickets",
                columns: [
                    PluginColumnInfo(
                        name: "id",
                        dataType: "integer",
                        isNullable: false,
                        isPrimaryKey: true,
                        identityKind: .byDefault,
                        checkExpressions: []
                    ),
                    PluginColumnInfo(name: "code", dataType: "text", isNullable: false)
                ],
                foreignKeys: [],
                indexes: []
            )
        ]
    }

    /// The keys are written by hand rather than left to the server, which is the
    /// only case the reset exists for.
    private static func profile(rows: Int) -> GenerationProfile {
        GenerationProfile(name: "sqlite-sequence", seed: 4_242, tables: [
            GenerationTableProfile(table: "tickets", rowCount: rows, columns: [
                GenerationColumnProfile(
                    column: "id",
                    generator: "Integer",
                    params: .object(["min": .int(1), "max": .int(rows)])
                ),
                GenerationColumnProfile(
                    column: "code",
                    generator: "RandomString",
                    params: .object(["minLength": .int(8), "maxLength": .int(8)])
                )
            ])
        ])
    }

    private static func run(rows: Int) async throws -> SQLiteGenerationTestDriver {
        let driver = try SQLiteGenerationTestDriver()
        try driver.execute(ddl)
        let plan = try GenerationPlanCompiler().compile(profile: profile(rows: rows), schema: schema())
        let engine = GenerationRuntimeFixtures.engine(
            driver: driver,
            truncator: GenerationStringTruncator.forVendor(.sqlite),
            maxBindParameters: 32_766
        )
        _ = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))
        return driver
    }

    @Test("A plain insert succeeds after the run wrote its own keys")
    func plainInsertSucceedsAfterExplicitKeys() async throws {
        let driver = try await Self.run(rows: 50)
        #expect(try driver.scalar("SELECT COUNT(*) FROM tickets") == 50)

        try driver.execute("INSERT INTO tickets (code) VALUES ('afterwards')")

        #expect(try driver.scalar("SELECT COUNT(*) FROM tickets") == 51)
        #expect(try driver.scalar("SELECT COUNT(DISTINCT id) FROM tickets") == 51)
        #expect(try driver.scalar("SELECT COUNT(*) FROM tickets WHERE code = 'afterwards' AND id > 50") == 1)
    }

    @Test("The written keys fill the range exactly once")
    func explicitKeysAreDistinct() async throws {
        let driver = try await Self.run(rows: 50)
        #expect(try driver.scalar("SELECT MIN(id) FROM tickets") == 1)
        #expect(try driver.scalar("SELECT MAX(id) FROM tickets") == 50)
    }

    @Test("The sequence is reset after the transaction commits, never inside it")
    func resetHappensAfterTheCommit() async throws {
        let fake = FakeGenerationDriver()
        let plan = try GenerationPlanCompiler().compile(profile: Self.profile(rows: 5), schema: Self.schema())
        _ = try await GenerationRuntimeFixtures.collect(
            GenerationRuntimeFixtures.engine(
                driver: fake,
                options: GenerationRunOptions(singleTransaction: true)
            ).run(plan: plan)
        )
        #expect(fake.transactionCalls == ["begin", "commit"])
        #expect(fake.sequenceResets.map(\.column) == ["id"])
        #expect(fake.callOrder.firstIndex(of: "commit") ?? .max < (fake.callOrder.firstIndex(of: "resetSequence") ?? -1))
    }

    @Test("A run that fails leaves no sequence reset behind, because it wrote nothing")
    func failedRunDoesNotReset() async throws {
        let fake = FakeGenerationDriver()
        fake.failInsertsFor = ["tickets"]
        let plan = try GenerationPlanCompiler().compile(profile: Self.profile(rows: 5), schema: Self.schema())
        _ = try? await GenerationRuntimeFixtures.collect(
            GenerationRuntimeFixtures.engine(
                driver: fake,
                options: GenerationRunOptions(singleTransaction: true)
            ).run(plan: plan)
        )
        #expect(fake.sequenceResets.isEmpty)
        #expect(fake.transactionCalls.contains("rollback"))
    }

    @Test("The sequence is reset for a column the run wrote, and left alone otherwise")
    func resetOnlyForWrittenKeys() async throws {
        let fake = FakeGenerationDriver()
        let plan = try GenerationPlanCompiler().compile(profile: Self.profile(rows: 5), schema: Self.schema())
        _ = try await GenerationRuntimeFixtures.collect(
            GenerationRuntimeFixtures.engine(driver: fake).run(plan: plan)
        )
        #expect(fake.sequenceResets.map(\.column) == ["id"])

        let serverFilled = GenerationProfile(name: "server", seed: 1, tables: [
            GenerationTableProfile(table: "tickets", rowCount: 5, columns: [
                GenerationColumnProfile(column: "id", generator: "Default"),
                GenerationColumnProfile(column: "code", generator: "RandomString")
            ])
        ])
        let quiet = FakeGenerationDriver()
        _ = try await GenerationRuntimeFixtures.collect(
            GenerationRuntimeFixtures.engine(driver: quiet).run(
                plan: try GenerationPlanCompiler().compile(profile: serverFilled, schema: Self.schema())
            )
        )
        #expect(quiet.sequenceResets.isEmpty)
    }
}
