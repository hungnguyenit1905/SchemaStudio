//
//  DuplicateLiveServerGateTests.swift
//  TableProTests
//
//  The duplicate gates only a real server can answer: sequences landing on the
//  right value, an unanalyzed table still copying every row, batch progress,
//  stopping in both copy modes, MySQL table options and cleanup, the cascade
//  dialog, the protocol refusing a second statement, permissions, a
//  self-referencing foreign key pointing at the copy, and row-level security.
//
//  Fixtures and connection details: DuplicateGateFixtures. Skipped unless
//  DUPLICATE_GATES=1 or the marker file exists.
//
import Foundation
@testable import SchemaStudio
import Testing

@Suite("Duplicate live server gates", .serialized)
@MainActor
struct DuplicateLiveServerGateTests {
    private let schema = DuplicateGateFixtures.postgresSchema

    // MARK: - Spec test 2

    @Test("Spec test 2: the copy holds the same rows and its sequence resumes past the last id")
    func rowsAndSequenceMatch() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = try await postgres()
        let tables = ["dup_gate_seq", "dup_gate_seq_copy"]
        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)

        try await DuplicateGateFixtures.execute(
            "CREATE TABLE dup_gate_seq (id serial PRIMARY KEY, label text NOT NULL)",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            """
            INSERT INTO dup_gate_seq (label)
            SELECT 'row ' || g FROM generate_series(1, 300) AS g
            """,
            on: connection
        )

        _ = try await DuplicateGateFixtures.duplicate(
            on: connection,
            schema: schema,
            request: DuplicateGateFixtures.request(
                schema: schema,
                source: "dup_gate_seq",
                target: "dup_gate_seq_copy"
            )
        )

        let sourceCount = try await DuplicateGateFixtures.scalar(
            "SELECT COUNT(*) FROM dup_gate_seq",
            on: connection
        )
        let copyCount = try await DuplicateGateFixtures.scalar(
            "SELECT COUNT(*) FROM dup_gate_seq_copy",
            on: connection
        )
        let copyMax = try await DuplicateGateFixtures.scalar(
            "SELECT MAX(id) FROM dup_gate_seq_copy",
            on: connection
        )
        #expect(sourceCount == copyCount)
        #expect(copyMax == "300")

        let next = try await DuplicateGateFixtures.scalar(
            "SELECT nextval(pg_get_serial_sequence('dup_gate_seq_copy', 'id'))",
            on: connection
        )
        #expect(next == "301")

        let ownSequence = try await DuplicateGateFixtures.scalar(
            "SELECT pg_get_serial_sequence('dup_gate_seq_copy', 'id') <> pg_get_serial_sequence('dup_gate_seq', 'id')",
            on: connection
        )
        #expect(DuplicateCatalogValue.isTrue(ownSequence))

        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)
    }

    // MARK: - Spec test 9

    @Test("Spec test 9: a table the planner has never counted still copies every row")
    func unanalyzedTableCopiesEveryRow() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = try await postgres()
        let tables = ["dup_gate_fresh", "dup_gate_fresh_copy"]
        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)

        try await DuplicateGateFixtures.execute(
            "CREATE TABLE dup_gate_fresh (id bigserial PRIMARY KEY, label text)",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "INSERT INTO dup_gate_fresh (label) SELECT 'row ' || g FROM generate_series(1, 2000) AS g",
            on: connection
        )

        let reltuples = try await DuplicateGateFixtures.scalar(
            "SELECT reltuples FROM pg_class WHERE relname = 'dup_gate_fresh'",
            on: connection
        )
        #expect(reltuples?.hasPrefix("-1") == true)

        _ = try await DuplicateGateFixtures.duplicate(
            on: connection,
            schema: schema,
            request: DuplicateGateFixtures.request(
                schema: schema,
                source: "dup_gate_fresh",
                target: "dup_gate_fresh_copy"
            )
        )

        let copied = try await DuplicateGateFixtures.scalar(
            "SELECT COUNT(*) FROM dup_gate_fresh_copy",
            on: connection
        )
        #expect(copied == "2000")

        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)
    }

    // MARK: - Spec test 10

    @Test("Spec test 10: a chunked copy reports rising row progress and lands every row")
    func chunkedCopyReportsProgress() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = try await postgres()
        let tables = ["dup_gate_chunk", "dup_gate_chunk_copy"]
        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)
        try await seedRows(20_000, table: "dup_gate_chunk", on: connection)

        var options = DuplicateOptions()
        options.copyMode = .chunked
        options.batchSize = 2_000

        let progress = Mutex<[Int64]>([])
        _ = try await DuplicateGateFixtures.duplicate(
            on: connection,
            schema: schema,
            request: DuplicateGateFixtures.request(
                schema: schema,
                source: "dup_gate_chunk",
                target: "dup_gate_chunk_copy",
                options: options
            ),
            onProgress: { update in
                guard let copied = update.copiedRows else { return }
                progress.withLock { $0.append(copied) }
            }
        )

        let reported = progress.withLock { $0 }
        #expect(reported.count > 2)
        #expect(reported == reported.sorted())
        #expect(reported.last == 20_000)

        let copied = try await DuplicateGateFixtures.scalar(
            "SELECT COUNT(*) FROM dup_gate_chunk_copy",
            on: connection
        )
        #expect(copied == "20000")

        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)
    }

    // MARK: - Spec test 12

    @Test("Spec test 12: stopping a chunked copy asks about the rows it already committed")
    func stoppingChunkedCopyAsksAboutCommittedRows() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = try await postgres()
        let tables = ["dup_gate_stop_chunk", "dup_gate_stop_chunk_copy"]
        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)
        try await seedRows(40_000, table: "dup_gate_stop_chunk", on: connection)

        var options = DuplicateOptions()
        options.copyMode = .chunked
        options.batchSize = 1_000

        let token = DuplicateCancellationToken()
        let asked = Mutex<Int64?>(nil)
        var hooks = DuplicateServiceHooks()
        hooks.confirmDropPartialCopy = { copiedRows in
            asked.withLock { $0 = copiedRows }
            return true
        }

        await #expect(throws: DuplicateError.cancelled) {
            _ = try await DuplicateGateFixtures.duplicate(
                on: connection,
                schema: schema,
                request: DuplicateGateFixtures.request(
                    schema: schema,
                    source: "dup_gate_stop_chunk",
                    target: "dup_gate_stop_chunk_copy",
                    options: options
                ),
                hooks: hooks,
                token: token,
                onProgress: { update in
                    guard let copied = update.copiedRows, copied > 0 else { return }
                    token.cancel()
                }
            )
        }

        let copiedRows = asked.withLock { $0 }
        #expect(copiedRows != nil)
        #expect((copiedRows ?? 0) > 0)
        #expect(try await tableExists("dup_gate_stop_chunk_copy", on: connection) == false)

        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)
    }

    // MARK: - Spec test 13

    @Test("Spec test 13: stopping an atomic copy leaves no table behind")
    func stoppingAtomicCopyRollsBack() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = try await postgres()
        let tables = ["dup_gate_stop_atomic", "dup_gate_stop_atomic_copy"]
        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)
        try await seedRows(5_000, table: "dup_gate_stop_atomic", on: connection)

        var options = DuplicateOptions()
        options.copyMode = .atomic

        let token = DuplicateCancellationToken()
        token.cancel()

        await #expect(throws: DuplicateError.cancelled) {
            _ = try await DuplicateGateFixtures.duplicate(
                on: connection,
                schema: schema,
                request: DuplicateGateFixtures.request(
                    schema: schema,
                    source: "dup_gate_stop_atomic",
                    target: "dup_gate_stop_atomic_copy",
                    options: options
                ),
                token: token
            )
        }

        #expect(try await tableExists("dup_gate_stop_atomic_copy", on: connection) == false)

        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)
    }

    // MARK: - Spec test 14

    @Test("Spec test 14: MySQL keeps the engine and collation and resets the auto-increment counter")
    func mysqlKeepsTableOptions() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = try await mysql()
        let tables = ["dup_gate_my", "dup_gate_my_copy"]
        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: nil)

        try await DuplicateGateFixtures.execute(
            """
            CREATE TABLE `dup_gate_my` (
                id BIGINT NOT NULL AUTO_INCREMENT,
                label VARCHAR(64) NOT NULL,
                PRIMARY KEY (id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            """,
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "INSERT INTO `dup_gate_my` (label) VALUES ('a'), ('b'), ('c')",
            on: connection
        )

        _ = try await DuplicateGateFixtures.duplicate(
            on: connection,
            schema: nil,
            request: DuplicateGateFixtures.request(
                schema: nil,
                source: "dup_gate_my",
                target: "dup_gate_my_copy"
            )
        )

        let facts = try await DuplicateGateFixtures.rows(
            """
            SELECT ENGINE, TABLE_COLLATION, AUTO_INCREMENT
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'dup_gate_my_copy'
            """,
            on: connection
        )
        let row = try #require(facts.first)
        #expect(row.count >= 3)
        #expect(row[0] == "InnoDB")
        #expect(row[1] == "utf8mb4_unicode_ci")
        #expect(row[2] == "4")

        let copied = try await DuplicateGateFixtures.scalar(
            "SELECT COUNT(*) FROM `dup_gate_my_copy`",
            on: connection
        )
        #expect(copied == "3")

        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: nil)
    }

    // MARK: - Spec test 15

    /// MySQL commits every DDL statement, so there is no transaction to roll back. The recovery
    /// path is the same one a failure part way takes: drop what was created. Stopping is the
    /// deterministic way to reach it, and it is the same code an error reaches.
    @Test("Spec test 15: a MySQL copy that ends part way leaves no table behind")
    func mysqlStoppedCopyIsCleanedUp() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = try await mysql()
        let tables = ["dup_gate_my_stop", "dup_gate_my_stop_copy"]
        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: nil)

        try await DuplicateGateFixtures.execute(
            """
            CREATE TABLE `dup_gate_my_stop` (
                id BIGINT NOT NULL AUTO_INCREMENT,
                label VARCHAR(64) NOT NULL,
                PRIMARY KEY (id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """,
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            """
            INSERT INTO `dup_gate_my_stop` (label)
            SELECT CONCAT('row ', n.n)
            FROM (SELECT a.N + b.N * 10 + c.N * 100 + d.N * 1000 + 1 AS n
                  FROM (SELECT 0 AS N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                        UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8
                        UNION ALL SELECT 9) a
                  CROSS JOIN (SELECT 0 AS N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
                              UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
                              UNION ALL SELECT 8 UNION ALL SELECT 9) b
                  CROSS JOIN (SELECT 0 AS N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
                              UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
                              UNION ALL SELECT 8 UNION ALL SELECT 9) c
                  CROSS JOIN (SELECT 0 AS N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
                              UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
                              UNION ALL SELECT 8 UNION ALL SELECT 9) d) n
            """,
            on: connection
        )

        var options = DuplicateOptions()
        options.batchSize = 500

        let token = DuplicateCancellationToken()
        var hooks = DuplicateServiceHooks()
        hooks.confirmDropPartialCopy = { _ in true }

        await #expect(throws: DuplicateError.cancelled) {
            _ = try await DuplicateGateFixtures.duplicate(
                on: connection,
                schema: nil,
                request: DuplicateGateFixtures.request(
                    schema: nil,
                    source: "dup_gate_my_stop",
                    target: "dup_gate_my_stop_copy",
                    options: options
                ),
                hooks: hooks,
                token: token,
                onProgress: { update in
                    guard let copied = update.copiedRows, copied > 0 else { return }
                    token.cancel()
                }
            )
        }

        let left = try await DuplicateGateFixtures.scalar(
            """
            SELECT COUNT(*) FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'dup_gate_my_stop_copy'
            """,
            on: connection
        )
        #expect(left == "0")

        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: nil)
    }

    // MARK: - Spec test 18

    @Test("Spec test 18: replacing a referenced table waits for the cascade answer")
    func cascadeDialogGuardsTheDrop() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = try await postgres()
        let tables = ["dup_gate_child", "dup_gate_parent", "dup_gate_parent_copy"]
        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)

        try await DuplicateGateFixtures.execute(
            "CREATE TABLE dup_gate_parent (id bigint PRIMARY KEY, label text)",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "INSERT INTO dup_gate_parent VALUES (1, 'one'), (2, 'two')",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "CREATE TABLE dup_gate_parent_copy (id bigint PRIMARY KEY)",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            """
            CREATE TABLE dup_gate_child (
                id bigint PRIMARY KEY,
                parent_id bigint NOT NULL
                    CONSTRAINT dup_gate_child_parent_fk REFERENCES dup_gate_parent_copy (id)
            )
            """,
            on: connection
        )

        var options = DuplicateOptions()
        options.onExists = .dropAndRecreate
        let request = DuplicateGateFixtures.request(
            schema: schema,
            source: "dup_gate_parent",
            target: "dup_gate_parent_copy",
            options: options
        )

        let listed = Mutex<[ReferencingForeignKey]>([])
        var refusing = DuplicateServiceHooks()
        refusing.confirmDropReferencedTarget = { _, referencing in
            listed.withLock { $0 = referencing }
            return false
        }

        await #expect(
            throws: DuplicateError.dropCancelled(
                target: "dup_gate_parent_copy",
                constraints: ["dup_gate_child_parent_fk on public.dup_gate_child"]
            )
        ) {
            _ = try await DuplicateGateFixtures.duplicate(
                on: connection,
                schema: schema,
                request: request,
                hooks: refusing
            )
        }

        let reported = listed.withLock { $0 }
        #expect(reported.map(\.constraintName) == ["dup_gate_child_parent_fk"])
        #expect(reported.first?.owningTable == "dup_gate_child")
        #expect(try await tableExists("dup_gate_parent_copy", on: connection))
        #expect(try await columnCount("dup_gate_parent_copy", on: connection) == 1)

        var accepting = DuplicateServiceHooks()
        accepting.confirmDropReferencedTarget = { _, _ in true }
        _ = try await DuplicateGateFixtures.duplicate(
            on: connection,
            schema: schema,
            request: request,
            hooks: accepting
        )

        #expect(try await columnCount("dup_gate_parent_copy", on: connection) == 2)
        let remainingForeignKeys = try await DuplicateGateFixtures.scalar(
            """
            SELECT COUNT(*) FROM pg_constraint
            WHERE conname = 'dup_gate_child_parent_fk'
            """,
            on: connection
        )
        #expect(remainingForeignKeys == "0")

        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)
    }

    // MARK: - Spec test 21

    @Test("Spec test 21: the server refuses a second statement on the extended protocol")
    func extendedProtocolRefusesASecondStatement() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = try await postgres()
        await DuplicateGateFixtures.dropTables(["dup_gate_protocol"], on: connection, schema: schema)
        try await DuplicateGateFixtures.execute(
            "CREATE TABLE dup_gate_protocol (id bigint PRIMARY KEY)",
            on: connection
        )

        let driver = try #require(DatabaseManager.shared.driver(for: connection.id))
        let adapter = try #require(DatabaseDriverDuplicateAdapter(driver: driver))
        var refused = false
        do {
            _ = try await adapter.runExtended("SELECT 1; DROP TABLE dup_gate_protocol")
        } catch {
            refused = true
        }
        #expect(refused)
        #expect(try await tableExists("dup_gate_protocol", on: connection))

        await DuplicateGateFixtures.dropTables(["dup_gate_protocol"], on: connection, schema: schema)
    }

    // MARK: - Spec test 25

    @Test("Spec test 25: a login without CREATE is refused before anything is created")
    func missingCreatePrivilegeIsRefused() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let owner = try await postgres()
        await DuplicateGateFixtures.dropTables(["dup_gate_perm", "dup_gate_perm_copy"], on: owner, schema: schema)
        try await DuplicateGateFixtures.execute(
            "CREATE TABLE dup_gate_perm (id bigint PRIMARY KEY)",
            on: owner
        )
        try await grantReadOnlyRole(on: owner)

        let reader = DuplicateGateFixtures.postgresReadOnlyConnection()
        try await DuplicateGateFixtures.connect(reader, password: DuplicateGateFixtures.readOnlyPassword)

        await #expect(throws: DuplicateError.missingCreatePrivilege(schema)) {
            _ = try await DuplicateGateFixtures.duplicate(
                on: reader,
                schema: schema,
                request: DuplicateGateFixtures.request(
                    schema: schema,
                    source: "dup_gate_perm",
                    target: "dup_gate_perm_copy"
                )
            )
        }
        #expect(try await tableExists("dup_gate_perm_copy", on: owner) == false)

        await DuplicateGateFixtures.dropTables(["dup_gate_perm", "dup_gate_perm_copy"], on: owner, schema: schema)
    }

    // MARK: - Spec test 26

    @Test("Spec test 26: a self-referencing foreign key points at the copy, not the source")
    func selfReferencingForeignKeyPointsAtTheCopy() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = try await postgres()
        let tables = ["dup_gate_tree", "dup_gate_tree_copy"]
        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)

        try await DuplicateGateFixtures.execute(
            """
            CREATE TABLE dup_gate_tree (
                id bigint PRIMARY KEY,
                parent_id bigint REFERENCES dup_gate_tree (id)
            )
            """,
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "INSERT INTO dup_gate_tree VALUES (1, NULL), (2, 1), (3, 2)",
            on: connection
        )

        var options = DuplicateOptions()
        options.foreignKeys = true
        _ = try await DuplicateGateFixtures.duplicate(
            on: connection,
            schema: schema,
            request: DuplicateGateFixtures.request(
                schema: schema,
                source: "dup_gate_tree",
                target: "dup_gate_tree_copy",
                options: options
            )
        )

        let targets = try await DuplicateGateFixtures.rows(
            """
            SELECT confrelid::regclass::text
            FROM pg_constraint
            WHERE conrelid = 'dup_gate_tree_copy'::regclass AND contype = 'f'
            """,
            on: connection
        )
        #expect(targets.count == 1)
        #expect(targets.first?.first == "dup_gate_tree_copy")

        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)
    }

    // MARK: - Spec test 28

    @Test("Spec test 28: row-level security warns and no policy is carried over")
    func rowLevelSecurityWarnsAndIsNotCopied() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = try await postgres()
        let tables = ["dup_gate_rls", "dup_gate_rls_copy"]
        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)

        try await DuplicateGateFixtures.execute(
            "CREATE TABLE dup_gate_rls (id bigint PRIMARY KEY, owner_name text NOT NULL)",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "INSERT INTO dup_gate_rls VALUES (1, 'a'), (2, 'b')",
            on: connection
        )
        try await DuplicateGateFixtures.execute("ALTER TABLE dup_gate_rls ENABLE ROW LEVEL SECURITY", on: connection)
        try await DuplicateGateFixtures.execute(
            "CREATE POLICY dup_gate_rls_all ON dup_gate_rls USING (true)",
            on: connection
        )

        let result = try await DuplicateGateFixtures.duplicate(
            on: connection,
            schema: schema,
            request: DuplicateGateFixtures.request(
                schema: schema,
                source: "dup_gate_rls",
                target: "dup_gate_rls_copy"
            )
        )
        #expect(result.warnings.contains(.rowLevelSecurityPoliciesNotCopied))

        let policies = try await DuplicateGateFixtures.scalar(
            "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'dup_gate_rls_copy'",
            on: connection
        )
        #expect(policies == "0")

        let enabled = try await DuplicateGateFixtures.scalar(
            "SELECT relrowsecurity FROM pg_class WHERE relname = 'dup_gate_rls_copy'",
            on: connection
        )
        #expect(!DuplicateCatalogValue.isTrue(enabled))

        await DuplicateGateFixtures.dropTables(tables, on: connection, schema: schema)
    }

    // MARK: - Setup

    private func postgres() async throws -> DatabaseConnection {
        let connection = DuplicateGateFixtures.postgresConnection()
        try await DuplicateGateFixtures.connect(connection, password: DuplicateGateFixtures.postgresPassword)
        return connection
    }

    private func mysql() async throws -> DatabaseConnection {
        let connection = DuplicateGateFixtures.mysqlConnection()
        try await DuplicateGateFixtures.connect(connection, password: DuplicateGateFixtures.mysqlPassword)
        return connection
    }

    private func seedRows(_ count: Int, table: String, on connection: DatabaseConnection) async throws {
        try await DuplicateGateFixtures.execute(
            "CREATE TABLE \(table) (id bigserial PRIMARY KEY, label text NOT NULL)",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "INSERT INTO \(table) (label) SELECT 'row ' || g FROM generate_series(1, \(count)) AS g",
            on: connection
        )
        try await DuplicateGateFixtures.execute("ANALYZE \(table)", on: connection)
    }

    /// Created here rather than in a fixtures script so the permission gate needs nothing beyond
    /// the server the other gates already use.
    private func grantReadOnlyRole(on connection: DatabaseConnection) async throws {
        try await DuplicateGateFixtures.execute(
            """
            DO $$
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ss_gate_reader') THEN
                    CREATE ROLE ss_gate_reader LOGIN PASSWORD 'reader';
                END IF;
            END
            $$
            """,
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "REVOKE CREATE ON SCHEMA \(schema) FROM ss_gate_reader",
            on: connection
        )
        try await DuplicateGateFixtures.execute("GRANT USAGE ON SCHEMA \(schema) TO ss_gate_reader", on: connection)
        try await DuplicateGateFixtures.execute("GRANT SELECT ON dup_gate_perm TO ss_gate_reader", on: connection)
    }

    // MARK: - Reads

    private func tableExists(_ name: String, on connection: DatabaseConnection) async throws -> Bool {
        let count = try await DuplicateGateFixtures.scalar(
            """
            SELECT COUNT(*)
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = '\(schema)' AND c.relname = '\(name)'
            """,
            on: connection
        )
        return count != "0"
    }

    private func columnCount(_ name: String, on connection: DatabaseConnection) async throws -> Int {
        let count = try await DuplicateGateFixtures.scalar(
            """
            SELECT COUNT(*)
            FROM information_schema.columns
            WHERE table_schema = '\(schema)' AND table_name = '\(name)'
            """,
            on: connection
        )
        return Int(count ?? "0") ?? 0
    }
}
