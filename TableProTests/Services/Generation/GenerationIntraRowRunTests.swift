//
//  GenerationIntraRowRunTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// The intra-row generators through the whole engine, because their whole point
/// is the relationship between two columns of the same written row: a unit test
/// on one generator cannot show that the column it reads was generated first.
@Suite("Intra-row generation")
struct GenerationIntraRowRunTests {
    private static func eventsSchema() -> [GenerationTable] {
        [
            GenerationPlanningFixtures.table("events", columns: [
                PluginColumnInfo(name: "created_at", dataType: "timestamp", isNullable: false),
                PluginColumnInfo(name: "updated_at", dataType: "timestamp", isNullable: false),
                GenerationRuntimeFixtures.textColumn("first_name"),
                GenerationRuntimeFixtures.textColumn("last_name"),
                GenerationRuntimeFixtures.textColumn("email"),
                GenerationRuntimeFixtures.textColumn("status", nullable: true)
            ])
        ]
    }

    private static func eventsProfile(rowCount: Int, statusQuery: String? = nil) -> GenerationProfile {
        var columns = [
            GenerationRuntimeFixtures.columnProfile(
                "created_at",
                generator: "DateTime",
                params: .object(["from": .string("2020-01-01T00:00:00Z"), "to": .string("2024-12-31T23:59:59Z")])
            ),
            GenerationRuntimeFixtures.columnProfile(
                "updated_at",
                generator: "RelativeDateTime",
                params: .object([
                    "baseColumn": .string("created_at"),
                    "unit": .string("minute"),
                    "offsetMin": .int(0),
                    "offsetMax": .int(20_000)
                ])
            ),
            GenerationRuntimeFixtures.columnProfile(
                "first_name",
                generator: "FirstName",
                params: .object(["locale": .string("vi_VN")])
            ),
            GenerationRuntimeFixtures.columnProfile(
                "last_name",
                generator: "LastName",
                params: .object(["locale": .string("vi_VN")])
            ),
            GenerationRuntimeFixtures.columnProfile(
                "email",
                generator: "Expression",
                params: .object([
                    "template": .string("{{first_name}}.{{last_name}}@example.com"),
                    "slugify": .bool(true)
                ])
            )
        ]
        if let statusQuery {
            columns.append(
                GenerationRuntimeFixtures.columnProfile(
                    "status",
                    generator: "SQLQuery",
                    params: .object(["query": .string(statusQuery)])
                )
            )
        }
        return GenerationPlanningFixtures.profile(tables: [
            GenerationPlanningFixtures.tableProfile("events", rowCount: rowCount, columns: columns)
        ])
    }

    private static func values(_ driver: FakeGenerationDriver, column: String) throws -> [PluginCellValue] {
        let columns = driver.columns(for: "events")
        let position = try #require(columns.firstIndex(of: column))
        return driver.rows(for: "events").map { $0[position] }
    }

    @Test("An updated_at built as an offset never lands before its created_at, over 10k rows")
    func updatedNeverPrecedesCreated() async throws {
        let driver = FakeGenerationDriver()
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.eventsProfile(rowCount: 10_000),
            schema: Self.eventsSchema()
        )

        _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))

        let created = try Self.values(driver, column: "created_at")
        let updated = try Self.values(driver, column: "updated_at")
        #expect(created.count == 10_000)
        #expect(updated.count == 10_000)
        var moved = 0
        for (before, after) in zip(created, updated) {
            guard case let .timestamp(start) = before, case let .timestamp(end) = after else {
                Issue.record("expected timestamps, got \(before) and \(after)")
                continue
            }
            #expect(end >= start)
            if end > start { moved += 1 }
        }
        #expect(moved > 9_000)
    }

    @Test("An email template reads the names written into the same row")
    func templateReadsItsRow() async throws {
        let driver = FakeGenerationDriver()
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.eventsProfile(rowCount: 200),
            schema: Self.eventsSchema()
        )

        _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))

        let firstNames = try Self.values(driver, column: "first_name").map(\.textFallback)
        let lastNames = try Self.values(driver, column: "last_name").map(\.textFallback)
        let emails = try Self.values(driver, column: "email").map(\.textFallback)
        #expect(emails.count == 200)
        for (index, email) in emails.enumerated() {
            let expected = AsciiSlug.joined(firstNames[index], separator: ".")
                + "." + AsciiSlug.joined(lastNames[index], separator: ".")
                + "@example.com"
            #expect(email == expected)
            #expect(email.allSatisfy { $0.isASCII })
        }
    }

    @Test("A query runs once for the whole table, before any row is built")
    func queryRunsOncePerTable() async throws {
        let driver = FakeGenerationDriver()
        let query = "SELECT status FROM statuses"
        driver.preloadedQueryValues = [
            SqlQuerySource(query: query, column: nil): [.text("new"), .text("paid"), .text("shipped")]
        ]
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.eventsProfile(rowCount: 500, statusQuery: query),
            schema: Self.eventsSchema()
        )

        _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))

        #expect(driver.queriesRun.count == 1)
        let statuses = try Self.values(driver, column: "status").map(\.textFallback)
        #expect(statuses.count == 500)
        #expect(Set(statuses) == ["new", "paid", "shipped"])
    }

    @Test("A query that returns nothing leaves a nullable column empty and warns")
    func emptyQueryDegradesOnANullableColumn() async throws {
        let driver = FakeGenerationDriver()
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.eventsProfile(rowCount: 10, statusQuery: "SELECT status FROM statuses"),
            schema: Self.eventsSchema()
        )

        let events = try await GenerationRuntimeFixtures.collect(
            GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan)
        )

        let statuses = try Self.values(driver, column: "status")
        #expect(statuses.allSatisfy { $0.isNull })
        let warnings = events.compactMap { event -> String? in
            guard case let .warning(message) = event else { return nil }
            return message
        }
        #expect(warnings.contains { $0.contains("status") })
    }

    @Test("A query that returns nothing fails the run when the column cannot be null")
    func emptyQueryFailsOnARequiredColumn() async throws {
        let driver = FakeGenerationDriver()
        let schema = [
            GenerationPlanningFixtures.table("events", columns: [
                GenerationRuntimeFixtures.textColumn("status")
            ])
        ]
        let profile = GenerationPlanningFixtures.profile(tables: [
            GenerationPlanningFixtures.tableProfile("events", rowCount: 5, columns: [
                GenerationRuntimeFixtures.columnProfile(
                    "status",
                    generator: "SQLQuery",
                    params: .object(["query": .string("SELECT status FROM statuses")])
                )
            ])
        ])
        let plan = try GenerationRuntimeFixtures.plan(profile: profile, schema: schema)

        await #expect(throws: GenerationError.queryValuesUnavailable(table: "public.events", column: "status")) {
            _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))
        }
    }

    @Test("The preview draws the same rows the run writes")
    func previewMatchesTheRun() async throws {
        let driver = FakeGenerationDriver()
        let query = "SELECT status FROM statuses"
        driver.preloadedQueryValues = [
            SqlQuerySource(query: query, column: nil): [.text("new"), .text("paid")]
        ]
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.eventsProfile(rowCount: 40, statusQuery: query),
            schema: Self.eventsSchema()
        )

        let preview = try await GenerationPreviewService(driver: driver).preview(plan: plan, rowsPerTable: 5)
        _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))

        let written = driver.rows(for: "events").prefix(5)
        #expect(Array(preview.tables[0].rows) == Array(written))
    }
}
