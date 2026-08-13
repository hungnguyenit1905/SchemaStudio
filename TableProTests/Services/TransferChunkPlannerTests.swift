import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("TransferChunkPlanner")
struct TransferChunkPlannerTests {
    private func planner(
        table: String = "users",
        schema: String? = nil,
        primaryKey: [String],
        comparison: TransferChunkPlanner.Comparison = .rowConstructor,
        chunkSize: Int = 1_000
    ) -> TransferChunkPlanner {
        let qualified = schema.map { "\"\($0)\".\"\(table)\"" } ?? "\"\(table)\""
        return TransferChunkPlanner(
            qualifiedTable: qualified,
            primaryKeyColumns: primaryKey,
            chunkSize: chunkSize,
            comparison: comparison,
            quoteIdentifier: { "\"\($0)\"" },
            escapeStringLiteral: { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
        )
    }

    @Test("a single numeric primary key paginates by that column")
    func singleNumericPrimaryKey() {
        let sql = planner(primaryKey: ["id"]).chunkQuery(after: nil)
        #expect(sql == "SELECT * FROM \"users\" ORDER BY \"id\" ASC LIMIT 1000")
    }

    @Test("a resume cursor adds a keyset predicate after the last key")
    func resumeCursorAddsPredicate() {
        let cursor = TransferChunkCursor(lastKey: ["42"], rowsDone: 42)
        let sql = planner(primaryKey: ["id"]).chunkQuery(after: cursor)
        #expect(sql == "SELECT * FROM \"users\" WHERE \"id\" > 42 ORDER BY \"id\" ASC LIMIT 1000")
    }

    @Test("a text key is quoted back as a string literal")
    func textKeyIsQuoted() {
        let cursor = TransferChunkCursor(lastKey: ["'abc'"], rowsDone: 1)
        let sql = planner(primaryKey: ["slug"]).chunkQuery(after: cursor)
        #expect(sql == "SELECT * FROM \"users\" WHERE \"slug\" > '''abc''' ORDER BY \"slug\" ASC LIMIT 1000")
    }

    @Test("a composite key uses a row constructor on MySQL and PostgreSQL")
    func compositeKeyRowConstructor() {
        let cursor = TransferChunkCursor(lastKey: ["10", "2024-01-02"], rowsDone: 10)
        let sql = planner(primaryKey: ["tenant", "created_at"]).chunkQuery(after: cursor)
        #expect(sql ==
            "SELECT * FROM \"users\" WHERE (\"tenant\", \"created_at\") > (10, '2024-01-02') "
            + "ORDER BY \"tenant\" ASC, \"created_at\" ASC LIMIT 1000")
    }

    @Test("a composite key on SQLite spells the tuple comparison out")
    func compositeKeyTupleOr() {
        let cursor = TransferChunkCursor(lastKey: ["10", "abc"], rowsDone: 10)
        let sql = planner(
            primaryKey: ["tenant", "slug"],
            comparison: .tupleOr
        ).chunkQuery(after: cursor)
        #expect(sql ==
            "SELECT * FROM \"users\" WHERE (\"tenant\" > 10 OR (\"tenant\" = 10 AND \"slug\" > 'abc')) "
            + "ORDER BY \"tenant\" ASC, \"slug\" ASC LIMIT 1000")
    }

    @Test("a three-column key builds the full chain of equality predicates")
    func tripleKeyTupleOr() {
        let cursor = TransferChunkCursor(lastKey: ["1", "2", "3"], rowsDone: 3)
        let sql = planner(primaryKey: ["a", "b", "c"], comparison: .tupleOr).chunkQuery(after: cursor)
        #expect(sql ==
            "SELECT * FROM \"users\" WHERE (\"a\" > 1 OR (\"a\" = 1 AND \"b\" > 2) "
            + "OR (\"a\" = 1 AND \"b\" = 2 AND \"c\" > 3)) "
            + "ORDER BY \"a\" ASC, \"b\" ASC, \"c\" ASC LIMIT 1000")
    }

    @Test("a table without a primary key reads the whole table in one pass")
    func tableWithoutPrimaryKey() {
        let sql = planner(primaryKey: []).chunkQuery(after: TransferChunkCursor(lastKey: ["1"], rowsDone: 1))
        #expect(sql == "SELECT * FROM \"users\"")
    }

    @Test("a UUID primary key still chunks by keyset, only parallelism is off")
    func uuidPrimaryKeyStillChunks() {
        let cursor = TransferChunkCursor(lastKey: ["1f3a2b4c-0000-0000-0000-000000000001"], rowsDone: 1)
        let sql = planner(primaryKey: ["id"]).chunkQuery(after: cursor)
        #expect(sql ==
            "SELECT * FROM \"users\" WHERE \"id\" > '1f3a2b4c-0000-0000-0000-000000000001' "
            + "ORDER BY \"id\" ASC LIMIT 1000")
    }

    @Test("a schema-qualified table keeps its qualification")
    func schemaQualifiedTable() {
        let sql = planner(schema: "public", primaryKey: ["id"]).chunkQuery(after: nil)
        #expect(sql == "SELECT * FROM \"public\".\"users\" ORDER BY \"id\" ASC LIMIT 1000")
    }

    @Test("a partition upper bound caps a chunked read")
    func partitionUpperBound() {
        let cursor = TransferChunkCursor(lastKey: ["10"], rowsDone: 10)
        let sql = planner(primaryKey: ["id"]).chunkQuery(after: cursor, upperBound: "1000")
        #expect(sql == "SELECT * FROM \"users\" WHERE \"id\" > 10 AND \"id\" <= 1000 ORDER BY \"id\" ASC LIMIT 1000")
    }

    @Test("a partition's first chunk starts at the lower bound carried in the cursor")
    func partitionFirstChunkStartsAtLowerBound() {
        let cursor = TransferChunkCursor(lastKey: ["1000"], rowsDone: 0)
        let sql = planner(primaryKey: ["id"]).chunkQuery(after: cursor, upperBound: "2000")
        #expect(sql == "SELECT * FROM \"users\" WHERE \"id\" > 1000 AND \"id\" <= 2000 ORDER BY \"id\" ASC LIMIT 1000")
    }

    @Test("a partition with no upper bound reads to the end of the table")
    func partitionWithoutUpperBound() {
        let cursor = TransferChunkCursor(lastKey: ["2000"], rowsDone: 0)
        let sql = planner(primaryKey: ["id"]).chunkQuery(after: cursor)
        #expect(sql == "SELECT * FROM \"users\" WHERE \"id\" > 2000 ORDER BY \"id\" ASC LIMIT 1000")
    }

    @Test("the cursor after a chunk is the last row's key with a running total")
    func nextCursorTakesLastRow() {
        let rows: [[PluginCellValue]] = [
            [.text("1"), .text("alice")],
            [.text("2"), .text("bob")],
        ]
        let cursor = planner(primaryKey: ["id"]).nextCursor(
            after: rows,
            headerColumns: ["id", "name"],
            previous: TransferChunkCursor(lastKey: ["0"], rowsDone: 5)
        )
        #expect(cursor?.lastKey == ["2"])
        #expect(cursor?.rowsDone == 7)
    }

    @Test("an empty chunk produces no cursor")
    func emptyChunkHasNoCursor() {
        let cursor = planner(primaryKey: ["id"]).nextCursor(
            after: [],
            headerColumns: ["id", "name"],
            previous: TransferChunkCursor(lastKey: ["2"], rowsDone: 5)
        )
        #expect(cursor == nil)
    }

    @Test("a chunk whose primary key column is missing from the header yields no cursor")
    func missingKeyColumnYieldsNoCursor() {
        let rows: [[PluginCellValue]] = [[.text("1")]]
        let cursor = planner(primaryKey: ["id"]).nextCursor(
            after: rows,
            headerColumns: ["name"],
            previous: nil
        )
        #expect(cursor == nil)
    }

    @Test("estimated row counts of -1 and 0 mean unknown, not empty, for parallelism")
    func parallelismGateTreatsUnknownAsOff() {
        #expect(TransferParallelism.shouldParallelize(estimatedRows: nil, threshold: 100_000) == false)
        #expect(TransferParallelism.shouldParallelize(estimatedRows: -1, threshold: 100_000) == false)
        #expect(TransferParallelism.shouldParallelize(estimatedRows: 0, threshold: 100_000) == false)
        #expect(TransferParallelism.shouldParallelize(estimatedRows: 99_999, threshold: 100_000) == false)
        #expect(TransferParallelism.shouldParallelize(estimatedRows: 100_000, threshold: 100_000) == true)
    }
}
