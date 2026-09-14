//
//  GenerationBulkLoadTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Generation bulk load")
struct GenerationBulkLoadTests {
    private static func schema() -> [GenerationTable] {
        [
            GenerationPlanningFixtures.table("events", columns: [
                GenerationRuntimeFixtures.textColumn("name"),
                GenerationRuntimeFixtures.integerColumn("weight")
            ])
        ]
    }

    private static func plan(rows: Int = 5_000) throws -> GenerationPlan {
        let profile = GenerationPlanningFixtures.profile(tables: [
            GenerationPlanningFixtures.tableProfile(
                "events",
                rowCount: rows,
                columns: [
                    GenerationRuntimeFixtures.columnProfile("name", generator: "RandomString"),
                    GenerationRuntimeFixtures.columnProfile("weight", generator: "Integer")
                ]
            )
        ])
        return try GenerationRuntimeFixtures.plan(profile: profile, schema: schema())
    }

    private static func run(driver: FakeGenerationDriver, plan: GenerationPlan) async throws -> GenerationReport? {
        let engine = GenerationRuntimeFixtures.engine(driver: driver)
        let events = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))
        return GenerationRuntimeFixtures.report(in: events)
    }

    @Test("A target that declares bulk load gets every row through the bulk writer")
    func bulkPathIsUsedWhenDeclared() async throws {
        let driver = FakeGenerationDriver()
        driver.supportsBulkLoad = true
        let plan = try Self.plan()

        let report = try #require(await Self.run(driver: driver, plan: plan))

        let writer = try #require(driver.bulkWriters.first)
        #expect(driver.bulkWriters.count == 1)
        #expect(writer.rowCount == 5_000)
        #expect(writer.didFinish)
        #expect(!writer.didAbort)
        #expect(report.totalRowsWritten == 5_000)
        #expect(driver.rows(for: "events").count == 5_000)
    }

    @Test("A target without bulk load still writes every row through prepared batches")
    func preparedFallbackStillWrites() async throws {
        let driver = FakeGenerationDriver()
        let plan = try Self.plan()

        let report = try #require(await Self.run(driver: driver, plan: plan))

        #expect(driver.bulkWriters.isEmpty)
        #expect(driver.bulkWriterRequests.isEmpty)
        #expect(report.totalRowsWritten == 5_000)
        #expect(driver.rows(for: "events").count == 5_000)
    }

    @Test("A driver that claims bulk load and hands back nothing falls back mid-table")
    func missingWriterDowngrades() async throws {
        let driver = FakeGenerationDriver()
        driver.supportsBulkLoad = true
        driver.handsBackBulkWriter = false
        let plan = try Self.plan()

        let report = try #require(await Self.run(driver: driver, plan: plan))

        #expect(driver.bulkWriterRequests.count == 1)
        #expect(driver.bulkWriters.isEmpty)
        #expect(report.totalRowsWritten == 5_000)
        #expect(driver.rows(for: "events").count == 5_000)
    }

    @Test("A bulk stream is torn down when the run fails")
    func failureAbortsTheStream() async throws {
        let driver = FakeGenerationDriver()
        driver.supportsBulkLoad = true
        driver.failsBulkWrites = true
        let plan = try Self.plan()
        let engine = GenerationRuntimeFixtures.engine(driver: driver)

        await #expect(throws: Error.self) {
            _ = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))
        }

        let writer = try #require(driver.bulkWriters.first)
        #expect(writer.didAbort)
        #expect(!writer.didFinish)
    }

    @Test("A bulk stream that fails at finish is still torn down")
    func finishFailureAbortsTheStream() async throws {
        let driver = FakeGenerationDriver()
        driver.supportsBulkLoad = true
        driver.failsBulkFinish = true
        let plan = try Self.plan()
        let engine = GenerationRuntimeFixtures.engine(driver: driver)

        await #expect(throws: Error.self) {
            _ = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))
        }

        let writer = try #require(driver.bulkWriters.first)
        #expect(writer.didAbort)
        #expect(!writer.didFinish)
    }

    /// The rows a `COPY` streamed are discarded by the abort, so a checkpoint that
    /// counted them would make the resumed run skip rows that never landed.
    @Test("An interrupted bulk load records no progress to resume from")
    func interruptedBulkLoadRecordsNoProgress() async throws {
        let store = GenerationRuntimeFixtures.checkpointStore()
        let driver = FakeGenerationDriver()
        driver.supportsBulkLoad = true
        driver.failsBulkWritesAfterChunks = 1
        let plan = try Self.plan(rows: 200_000)
        let engine = GenerationEngine(driver: driver, checkpoints: store)

        await #expect(throws: Error.self) {
            _ = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))
        }

        let writer = try #require(driver.bulkWriters.first)
        #expect(writer.chunkCount == 1)
        #expect(writer.didAbort)
        #expect(await store.load(jobId: GenerationCheckpointStore.jobId(for: plan)).isEmpty)
    }

    @Test("A bulk table records its progress once, after the stream ended")
    func bulkLoadCheckpointsOnlyOnCompletion() async throws {
        let store = GenerationRuntimeFixtures.checkpointStore()
        let driver = FakeGenerationDriver()
        driver.supportsBulkLoad = true
        let plan = try Self.plan(rows: 200_000)
        let engine = GenerationEngine(driver: driver, checkpoints: store)

        _ = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))

        let writer = try #require(driver.bulkWriters.first)
        #expect(writer.chunkCount > 1)
        #expect(writer.didFinish)
        // Cleared by the finished run, which is the only checkpoint state a
        // completed bulk table should leave behind.
        #expect(await store.load(jobId: GenerationCheckpointStore.jobId(for: plan)).isEmpty)
    }

    @Test("The route rules bulk load out when the engine needs the keys back")
    func harvestForcesPreparedBatches() {
        let decision = GenerationBulkLoadRoute.resolve(
            supportsBulkLoad: true,
            supportsLocalInfile: true,
            requiresLocalInfile: false,
            continueOnError: false,
            harvestRequired: true,
            isResumedMidTable: false
        )
        #expect(decision.strategy == .preparedBatch)
        #expect(decision.reason == .harvestRequired)
    }

    @Test("The route rules bulk load out for a table that is resuming")
    func resumeForcesPreparedBatches() {
        let decision = GenerationBulkLoadRoute.resolve(
            supportsBulkLoad: true,
            supportsLocalInfile: true,
            requiresLocalInfile: false,
            continueOnError: false,
            harvestRequired: false,
            isResumedMidTable: true
        )
        #expect(decision.strategy == .preparedBatch)
        #expect(decision.reason == .resumedMidTable)
    }

    @Test("A server with local infile off falls back silently")
    func localInfileDisabledFallsBack() {
        let decision = GenerationBulkLoadRoute.resolve(
            supportsBulkLoad: true,
            supportsLocalInfile: false,
            requiresLocalInfile: true,
            continueOnError: false,
            harvestRequired: false,
            isResumedMidTable: false
        )
        #expect(decision.strategy == .preparedBatch)
        #expect(decision.reason == .localInfileDisabled)
    }

    @Test("Row-level error isolation falls back, because a bulk stream fails whole")
    func continueOnErrorFallsBack() {
        let decision = GenerationBulkLoadRoute.resolve(
            supportsBulkLoad: true,
            supportsLocalInfile: true,
            requiresLocalInfile: false,
            continueOnError: true,
            harvestRequired: false,
            isResumedMidTable: false
        )
        #expect(decision.strategy == .preparedBatch)
        #expect(decision.reason == .rowErrorIsolation)
    }

    @Test("A driver with no bulk path reports why")
    func noBulkWriterIsReported() {
        let decision = GenerationBulkLoadRoute.resolve(
            supportsBulkLoad: false,
            supportsLocalInfile: nil,
            requiresLocalInfile: false,
            continueOnError: false,
            harvestRequired: false,
            isResumedMidTable: false
        )
        #expect(decision.strategy == .preparedBatch)
        #expect(decision.reason == .noBulkWriter)
    }

    @Test("Bulk load is chosen when nothing rules it out")
    func bulkIsChosen() {
        let decision = GenerationBulkLoadRoute.resolve(
            supportsBulkLoad: true,
            supportsLocalInfile: nil,
            requiresLocalInfile: false,
            continueOnError: false,
            harvestRequired: false,
            isResumedMidTable: false
        )
        #expect(decision.strategy == .bulk)
        #expect(decision.reason == nil)
    }

    /// The documented ceilings: PostgreSQL 65535 bind parameters, SQL Server 2100,
    /// SQLite 32766, MySQL's packet in bytes. A prepared batch is cut by whichever
    /// ceiling it reaches first; a bulk stream carries no parameters at all.
    @Test("A prepared batch is cut by the vendor's parameter ceiling")
    func preparedBatchSizeFollowsTheVendorCeiling() {
        let cases = [
            (maxBinds: 65_535, columns: 15, expectedRows: 4_369),
            (maxBinds: 2_100, columns: 15, expectedRows: 140),
            (maxBinds: 32_766, columns: 4, expectedRows: 8_191),
        ]
        for testCase in cases {
            var splitter = TransferBatchSplitter(
                maxBytes: 1 << 30,
                maxBindParameters: testCase.maxBinds,
                columnCount: testCase.columns
            )
            let row = Array(repeating: PluginCellValue.int(1), count: testCase.columns)

            var buffered = 0
            while case .buffered = splitter.append(row, estimatedBytes: 8 * testCase.columns) {
                buffered += 1
            }
            #expect(buffered == testCase.expectedRows)
        }
    }

    @Test("A driver reporting nil limits on an MSSQL-typed connection splits at 2,100 parameters")
    func nilLimitsFallBackToTheVendorCeiling() async throws {
        let driver = FakeGenerationDriver()
        driver.reportsNilLimits = true
        let plan = try Self.plan(rows: 10_000)
        let engine = GenerationRuntimeFixtures.engine(driver: driver, databaseType: .mssql)

        _ = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))

        // "name" and "weight" are two columns, so 2,100 bind parameters allow
        // 1,050 rows per batch: fewer batches would mean the fallback used
        // PostgreSQL's ceiling instead of MSSQL's.
        let batchSizes = driver.batches.filter { $0.table.table == "events" }.map { $0.rows.count }
        #expect(batchSizes.allSatisfy { $0 <= 1_050 })
        #expect(batchSizes.contains(1_050))
    }

    @Test("A bulk chunk is cut by bytes alone")
    func bulkChunkIgnoresParameterCeiling() async throws {
        let driver = FakeGenerationDriver()
        driver.supportsBulkLoad = true
        let plan = try Self.plan(rows: 5_000)

        _ = try await Self.run(driver: driver, plan: plan)

        // 900 bind parameters over two columns caps a prepared batch at 450 rows,
        // which would take 12 batches; the bulk stream carries no parameters, so
        // bytes are the only ceiling and it takes far fewer chunks.
        let writer = try #require(driver.bulkWriters.first)
        #expect(writer.chunkCount < 12)
        #expect(writer.rowCount == 5_000)
    }
}
