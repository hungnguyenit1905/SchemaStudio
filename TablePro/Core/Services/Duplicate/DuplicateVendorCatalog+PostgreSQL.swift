//
//  DuplicateVendorCatalog+PostgreSQL.swift
//  TablePro
//

import Foundation

/// PostgreSQL catalog SQL written here because no driver requirement exposes it: sequence
/// attributes including `CACHE`, the table's own comment, whether row-level security is on,
/// whether the current user owns the table, and whether it is partitioned.
struct PostgreSqlDuplicateCatalog: DuplicateVendorCatalog {
    var identifierPolicy: TransferIdentifierPolicy { TransferIdentifierPolicy.policy(for: .postgresql) }

    // MARK: - Facts

    /// `relkind = 'p'` is a partitioned table. `relrowsecurity` is the flag, not the policy list:
    /// the policies themselves are never copied, so only the flag matters here.
    static func factsSQL(_ source: DuplicateTableRef, quoting: DuplicateSQLQuoting) -> String {
        let literal = quoting.stringLiteral(quoting.qualified(source))
        return """
        SELECT obj_description(c.oid, 'pg_class'),
               c.relrowsecurity,
               pg_get_userbyid(c.relowner) = current_user,
               c.relkind = 'p'
        FROM pg_class c
        WHERE c.oid = \(literal)::regclass
        """
    }

    func facts(_ source: DuplicateTableRef, driver: any DuplicateDriving) async throws -> DuplicateTableFacts {
        let rows = try await driver.runSimple(Self.factsSQL(source, quoting: driver.quoting))
        guard let row = rows.first, row.count >= 4 else {
            throw DuplicateError.sourceMissing(source.name)
        }
        return DuplicateTableFacts(
            comment: row[0].flatMap { $0.isEmpty ? nil : $0 },
            hasRowLevelSecurity: DuplicateCatalogValue.isTrue(row[1]),
            isOwner: DuplicateCatalogValue.isTrue(row[2]),
            isPartitioned: DuplicateCatalogValue.isTrue(row[3])
        )
    }

    // MARK: - Sequences

    /// `pg_sequences` carries `cache_size`, which the driver's own `fetchDependentSequences` does
    /// not read and could not report anyway: it returns a rendered `CREATE SEQUENCE` string built
    /// around the source's name.
    static func sequenceAttributesSQL(_ source: DuplicateTableRef, quoting: DuplicateSQLQuoting) -> String {
        let literal = quoting.stringLiteral(quoting.qualified(source))
        return """
        SELECT a.attname,
               s.sequencename,
               s.increment_by,
               s.min_value,
               s.max_value,
               s.cache_size,
               s.cycle
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_sequences s ON s.schemaname = n.nspname
             AND s.sequencename = pg_get_serial_sequence(\(literal), a.attname)::regclass::text
        WHERE c.oid = \(literal)::regclass
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND a.attidentity = ''
        """
    }

    func sequenceAttributes(
        _ source: DuplicateTableRef,
        driver: any DuplicateDriving
    ) async throws -> [String: DuplicateSequenceAttributes] {
        let rows = try await driver.runSimple(Self.sequenceAttributesSQL(source, quoting: driver.quoting))
        return Self.sequenceAttributes(from: rows)
    }

    static func sequenceAttributes(from rows: [[String?]]) -> [String: DuplicateSequenceAttributes] {
        var result: [String: DuplicateSequenceAttributes] = [:]
        for row in rows where row.count >= 7 {
            guard let column = row[0], let name = row[1], !column.isEmpty, !name.isEmpty else { continue }
            result[column] = DuplicateSequenceAttributes(
                name: name,
                increment: row[2] ?? "1",
                minValue: row[3] ?? "1",
                maxValue: row[4] ?? "9223372036854775807",
                cache: row[5] ?? "1",
                cycle: DuplicateCatalogValue.isTrue(row[6])
            )
        }
        return result
    }

    // MARK: - Preflight

    static func targetExistsSQL(_ request: DuplicateTableRequest, quoting: DuplicateSQLQuoting) -> String {
        let schema = request.targetSchema ?? "public"
        return """
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = \(quoting.stringLiteral(schema))
          AND c.relname = \(quoting.stringLiteral(request.targetName))
        LIMIT 1
        """
    }

    func targetIsTaken(_ request: DuplicateTableRequest, driver: any DuplicateDriving) async throws -> Bool {
        try await !driver.runSimple(Self.targetExistsSQL(request, quoting: driver.quoting)).isEmpty
    }

    static func privilegesSQL(_ request: DuplicateTableRequest, quoting: DuplicateSQLQuoting) -> String {
        let schema = request.targetSchema ?? "public"
        let source = quoting.qualified(request.source)
        return """
        SELECT has_schema_privilege(current_user, \(quoting.stringLiteral(schema)), 'CREATE'),
               has_table_privilege(current_user, \(quoting.stringLiteral(source)), 'SELECT')
        """
    }

    func missingPrivilege(
        _ request: DuplicateTableRequest,
        driver: any DuplicateDriving
    ) async throws -> DuplicateError? {
        let rows = try await driver.runSimple(Self.privilegesSQL(request, quoting: driver.quoting))
        guard let row = rows.first, row.count >= 2 else { return nil }
        guard DuplicateCatalogValue.isTrue(row[0]) else {
            return .missingCreatePrivilege(request.targetSchema ?? "public")
        }
        guard DuplicateCatalogValue.isTrue(row[1]) else {
            return .missingSelectPrivilege(request.source.name)
        }
        return nil
    }
}

/// PostgreSQL renders a boolean as `t` or `f` in text format, but a driver that maps it to a
/// Swift `Bool` first hands back `true`. Both spellings are accepted so the reader does not
/// depend on which path the value took.
enum DuplicateCatalogValue {
    static func isTrue(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == "t" || value == "1" || value.lowercased() == "true"
    }
}
