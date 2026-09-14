//
//  GenerationCheckpointTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Generation checkpoints")
struct GenerationCheckpointTests {
    private static func schema() -> [GenerationTable] {
        [
            GenerationPlanningFixtures.table("customers", columns: [
                GenerationRuntimeFixtures.integerColumn("id", primaryKey: true),
                GenerationRuntimeFixtures.textColumn("email"),
                GenerationRuntimeFixtures.integerColumn("visits")
            ])
        ]
    }

    private static func profile(rows: Int, emptyFirst: Bool = false) -> GenerationProfile {
        GenerationPlanningFixtures.profile(tables: [
            GenerationPlanningFixtures.tableProfile(
                "customers",
                rowCount: rows,
                emptyFirst: emptyFirst,
                columns: [
                    GenerationRuntimeFixtures.columnProfile("id", generator: "AutoIncrement"),
                    GenerationRuntimeFixtures.columnProfile("email", generator: "RandomString"),
                    GenerationRuntimeFixtures.columnProfile("visits", generator: "Integer")
                ]
            )
        ])
    }

    private static func plan(rows: Int, emptyFirst: Bool = false) throws -> GenerationPlan {
        try GenerationRuntimeFixtures.plan(profile: profile(rows: rows, emptyFirst: emptyFirst), schema: schema())
    }

    private static func run(
        plan: GenerationPlan,
        driver: FakeGenerationDriver,
        store: GenerationCheckpointStore,
        cancelAfterBatches: Int? = nil,
        options: GenerationRunOptions = GenerationRunOptions()
    ) async throws -> [GenerationEvent] {
        let engine = GenerationEngine(driver: driver, options: options, checkpoints: store)
        if let cancelAfterBatches {
            driver.onInsert = { [engine] batches in
                guard batches == cancelAfterBatches else { return }
                await engine.cancel()
            }
        }
        var events: [GenerationEvent] = []
        for try await event in engine.run(plan: plan) {
            events.append(event)
        }
        return events
    }

    private static func texts(_ driver: FakeGenerationDriver) -> [String] {
        driver.rows(for: "customers").map { row in row.map(\.textFallback).joined(separator: "|") }
    }

    @Test("A resumed run produces exactly the output of an uninterrupted run")
    func resumeMatchesUninterruptedRun() async throws {
        let rows = 8_000
        let uninterrupted = FakeGenerationDriver()
        _ = try await Self.run(
            plan: try Self.plan(rows: rows),
            driver: uninterrupted,
            store: GenerationRuntimeFixtures.checkpointStore()
        )

        let store = GenerationRuntimeFixtures.checkpointStore()
        let plan = try Self.plan(rows: rows)
        let first = FakeGenerationDriver()
        _ = try await Self.run(plan: plan, driver: first, store: store, cancelAfterBatches: 2)

        let checkpoint = try #require(
            await store.resumePoint(jobId: GenerationCheckpointStore.jobId(for: plan), table: "public.customers")
        )
        #expect(checkpoint.rowsWritten == Self.texts(first).count)
        #expect(checkpoint.rowsWritten > 0)
        #expect(checkpoint.rowsWritten < rows)
        #expect(!checkpoint.isComplete)

        let resumed = FakeGenerationDriver()
        let events = try await Self.run(plan: plan, driver: resumed, store: store)

        #expect(Self.texts(first) + Self.texts(resumed) == Self.texts(uninterrupted))
        let report = try #require(GenerationRuntimeFixtures.report(in: events))
        #expect(report.tables.first?.rowsWritten == rows)
    }

    @Test("A resumed run writes no row twice")
    func resumeDoesNotDuplicateRows() async throws {
        let store = GenerationRuntimeFixtures.checkpointStore()
        let plan = try Self.plan(rows: 6_000)
        let first = FakeGenerationDriver()
        _ = try await Self.run(plan: plan, driver: first, store: store, cancelAfterBatches: 2)
        let resumed = FakeGenerationDriver()
        _ = try await Self.run(plan: plan, driver: resumed, store: store)

        let all = Self.texts(first) + Self.texts(resumed)
        #expect(all.count == 6_000)
        #expect(Set(all).count == all.count)
    }

    @Test("A checkpoint tracks what continueOnError consumed, not just what the server accepted")
    func continueOnErrorChecksPointConsumedRows() async throws {
        let store = GenerationRuntimeFixtures.checkpointStore()
        let plan = try Self.plan(rows: 10_000)
        var options = GenerationRunOptions()
        options.continueOnError = true
        let driver = FakeGenerationDriver()
        driver.failInsertsOnAttempt = [2]

        let events = try await Self.run(plan: plan, driver: driver, store: store, cancelAfterBatches: 3, options: options)

        let checkpoint = try #require(
            await store.resumePoint(jobId: GenerationCheckpointStore.jobId(for: plan), table: "public.customers")
        )
        let rowsWritten = Self.texts(driver).count
        #expect(checkpoint.rowsWritten > rowsWritten, "the checkpoint has to be ahead of what the server accepted")
        #expect(!checkpoint.isComplete)
        #expect(GenerationRuntimeFixtures.batchFailures(in: events).count == 1)

        let resumed = FakeGenerationDriver()
        _ = try await Self.run(plan: plan, driver: resumed, store: store)

        let all = Self.texts(driver) + Self.texts(resumed)
        #expect(Set(all).count == all.count, "no row is written twice")
        #expect(all.count < Self.rows(for: plan), "the batch continueOnError skipped is never retried by a resume")
    }

    private static func rows(for plan: GenerationPlan) -> Int {
        plan.tables.first?.rowCount ?? 0
    }

    @Test("A table the profile empties first always starts over")
    func emptyFirstTableIgnoresItsCheckpoint() async throws {
        let store = GenerationRuntimeFixtures.checkpointStore()
        let plan = try Self.plan(rows: 2_000, emptyFirst: true)
        await store.record(
            jobId: GenerationCheckpointStore.jobId(for: plan),
            entry: GenerationCheckpoint(table: "public.customers", rowsWritten: 1_500)
        )
        let driver = FakeGenerationDriver()

        let events = try await Self.run(plan: plan, driver: driver, store: store)

        #expect(driver.emptied.count == 1)
        #expect(driver.rows(for: "customers").count == 2_000)
        let report = try #require(GenerationRuntimeFixtures.report(in: events))
        #expect(report.tables.first?.rowsWritten == 2_000)
    }

    @Test("A completed emptyFirst table is skipped, not re-emptied, on a resumed run")
    func completedEmptyFirstTableIsNeverReEmptied() async throws {
        let store = GenerationRuntimeFixtures.checkpointStore()
        let plan = try Self.plan(rows: 2_000, emptyFirst: true)
        await store.record(
            jobId: GenerationCheckpointStore.jobId(for: plan),
            entry: GenerationCheckpoint(table: "public.customers", rowsWritten: 2_000, isComplete: true)
        )
        let driver = FakeGenerationDriver()

        let events = try await Self.run(plan: plan, driver: driver, store: store)

        #expect(driver.emptied.isEmpty)
        #expect(driver.rows(for: "customers").isEmpty)
        let report = try #require(GenerationRuntimeFixtures.report(in: events))
        #expect(report.totalRowsWritten == 2_000)
    }

    @Test("A table that finished is skipped rather than written twice")
    func completedTableIsSkipped() async throws {
        let store = GenerationRuntimeFixtures.checkpointStore()
        let plan = try Self.plan(rows: 2_000)
        await store.record(
            jobId: GenerationCheckpointStore.jobId(for: plan),
            entry: GenerationCheckpoint(table: "public.customers", rowsWritten: 2_000, isComplete: true)
        )
        let driver = FakeGenerationDriver()

        let events = try await Self.run(plan: plan, driver: driver, store: store)

        #expect(driver.rows(for: "customers").isEmpty)
        #expect(driver.emptied.isEmpty)
        let report = try #require(GenerationRuntimeFixtures.report(in: events))
        #expect(report.totalRowsWritten == 2_000)
    }

    @Test("A reference pool still feeds the rows written after a resume")
    func referencePoolSurvivesResume() async throws {
        let schema = [
            GenerationPlanningFixtures.table("customers", columns: [
                GenerationRuntimeFixtures.integerColumn("id", primaryKey: true)
            ]),
            GenerationPlanningFixtures.table(
                "orders",
                columns: [
                    GenerationRuntimeFixtures.integerColumn("id", primaryKey: true),
                    GenerationRuntimeFixtures.integerColumn("customer_id")
                ],
                foreignKeys: [GenerationPlanningFixtures.foreignKey(from: "customer_id", to: "customers")]
            )
        ]
        let profile = GenerationPlanningFixtures.profile(tables: [
            GenerationPlanningFixtures.tableProfile(
                "customers",
                rowCount: 4,
                columns: [GenerationRuntimeFixtures.columnProfile("id", generator: "AutoIncrement")]
            ),
            GenerationPlanningFixtures.tableProfile(
                "orders",
                rowCount: 5_000,
                columns: [
                    GenerationRuntimeFixtures.columnProfile("id", generator: "AutoIncrement"),
                    GenerationRuntimeFixtures.columnProfile("customer_id", generator: "Reference")
                ]
            )
        ])
        let plan = try GenerationRuntimeFixtures.plan(profile: profile, schema: schema)
        let keys: [ReferenceKey: [[PluginCellValue]]] = [
            ReferenceKey(schema: "public", table: "customers", columns: ["id"]): [
                [.int(1)], [.int(2)], [.int(3)], [.int(4)]
            ]
        ]
        let store = GenerationRuntimeFixtures.checkpointStore()

        let first = FakeGenerationDriver()
        first.preloadedValues = keys
        _ = try await Self.run(plan: plan, driver: first, store: store, cancelAfterBatches: 3)
        let resumed = FakeGenerationDriver()
        resumed.preloadedValues = keys
        _ = try await Self.run(plan: plan, driver: resumed, store: store)

        let parents = Set([1, 2, 3, 4].map(Int64.init))
        let written = (first.rows(for: "orders") + resumed.rows(for: "orders"))
        #expect(written.count == 5_000)
        #expect(written.allSatisfy { row in row.last.flatMap { Int64($0.textFallback) }.map(parents.contains) == true })
    }

    @Test("A plan edited between runs does not resume onto the old one")
    func editedPlanGetsItsOwnJob() async throws {
        let small = try Self.plan(rows: 100)
        let large = try Self.plan(rows: 200)
        let sameAsSmall = try Self.plan(rows: 100)
        #expect(GenerationCheckpointStore.jobId(for: small) != GenerationCheckpointStore.jobId(for: large))
        #expect(GenerationCheckpointStore.jobId(for: small) == GenerationCheckpointStore.jobId(for: sameAsSmall))
    }

    @Test("A single-transaction run records nothing to resume onto")
    func singleTransactionRunsAreNotResumable() async throws {
        let store = GenerationRuntimeFixtures.checkpointStore()
        let plan = try Self.plan(rows: 4_000)
        var options = GenerationRunOptions()
        options.singleTransaction = true
        let driver = FakeGenerationDriver()

        _ = try await Self.run(plan: plan, driver: driver, store: store, cancelAfterBatches: 2, options: options)

        let entries = await store.load(jobId: GenerationCheckpointStore.jobId(for: plan))
        #expect(entries.isEmpty)
    }

    @Test("The same plan against two different scopes gets two different job ids")
    func differentScopesGetDifferentJobIds() throws {
        let profile = Self.profile(rows: 100)
        let schema = Self.schema()
        let devScope = DatabaseScope(connectionId: UUID(), database: "dev", schema: "public")
        let prodScope = DatabaseScope(connectionId: devScope.connectionId, database: "prod", schema: "public")

        let dev = try GenerationPlanCompiler().compile(profile: profile, schema: schema, scope: devScope)
        let prod = try GenerationPlanCompiler().compile(profile: profile, schema: schema, scope: prodScope)

        #expect(GenerationCheckpointStore.jobId(for: dev) != GenerationCheckpointStore.jobId(for: prod))
    }

    @Test("Editing a generator's params changes the job id, even with the identifier unchanged")
    func editedGeneratorParamsGetTheirOwnJob() throws {
        let schema = Self.schema()
        var original = Self.profile(rows: 100)
        original.tables[0].columns[1] = GenerationRuntimeFixtures.columnProfile(
            "email",
            generator: "RandomString",
            params: .object(["minLength": .int(4), "maxLength": .int(8)])
        )
        var edited = original
        edited.tables[0].columns[1] = GenerationRuntimeFixtures.columnProfile(
            "email",
            generator: "RandomString",
            params: .object(["minLength": .int(20), "maxLength": .int(40)])
        )

        let originalPlan = try GenerationPlanCompiler().compile(profile: original, schema: schema)
        let editedPlan = try GenerationPlanCompiler().compile(profile: edited, schema: schema)

        #expect(GenerationCheckpointStore.jobId(for: originalPlan) != GenerationCheckpointStore.jobId(for: editedPlan))
    }

    @Test("Changing nothing keeps the job id stable, since it is persisted as a filename")
    func unchangedPlanKeepsTheSameJobId() throws {
        let scope = DatabaseScope(connectionId: UUID(), database: "dev", schema: "public")
        let first = try GenerationPlanCompiler().compile(profile: Self.profile(rows: 100), schema: Self.schema(), scope: scope)
        let second = try GenerationPlanCompiler().compile(profile: Self.profile(rows: 100), schema: Self.schema(), scope: scope)

        #expect(GenerationCheckpointStore.jobId(for: first) == GenerationCheckpointStore.jobId(for: second))
    }

    @Test("A finished run leaves no checkpoint behind")
    func finishedRunClearsCheckpoints() async throws {
        let store = GenerationRuntimeFixtures.checkpointStore()
        let plan = try Self.plan(rows: 3_000)
        _ = try await Self.run(plan: plan, driver: FakeGenerationDriver(), store: store)

        #expect(await store.load(jobId: GenerationCheckpointStore.jobId(for: plan)).isEmpty)
    }
}
