//
//  DuplicateIntrospector.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Reads everything the builder needs about the source table.
///
/// Structured reads reuse the plugin driver. The rest is PostgreSQL catalog SQL written here
/// because no driver requirement exposes it: sequence attributes including `CACHE`, the table's
/// own comment, whether row-level security is on, whether the current user owns the table, and
/// whether it is partitioned.
struct DuplicateIntrospector: Sendable {
    let driver: any DuplicateDriving

    func introspect(_ source: DuplicateTableRef) async throws -> DuplicateTableIntrospection {
        let columns = try await driver.fetchColumns(table: source.name, schema: source.schema)
        let indexes = try await driver.fetchIndexes(table: source.name, schema: source.schema)
        let foreignKeys = try await driver.fetchForeignKeys(table: source.name, schema: source.schema)
        let rowCount = try await driver.fetchApproximateRowCount(table: source.name, schema: source.schema)

        let facts = try await tableFacts(source)
        let sequences = try await sequenceAttributes(source, columns: columns)

        return DuplicateTableIntrospection(
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            sequencesByColumn: sequences,
            tableComment: facts.comment,
            estimatedRowCount: rowCount.map(Int64.init),
            hasRowLevelSecurity: facts.hasRowLevelSecurity,
            isOwner: facts.isOwner,
            isPartitioned: facts.isPartitioned
        )
    }

    // MARK: - Table facts

    struct TableFacts: Sendable, Hashable {
        let comment: String?
        let hasRowLevelSecurity: Bool
        let isOwner: Bool
        let isPartitioned: Bool
    }

    /// `relkind = 'p'` is a partitioned table. `relrowsecurity` is the flag, not the policy list:
    /// the policies themselves are never copied, so only the flag matters here.
    static func tableFactsSQL(_ source: DuplicateTableRef, quoting: DuplicateSQLQuoting) -> String {
        let literal = quoting.stringLiteral(qualifiedLiteral(source, quoting: quoting))
        return """
        SELECT obj_description(c.oid, 'pg_class'),
               c.relrowsecurity,
               pg_get_userbyid(c.relowner) = current_user,
               c.relkind = 'p'
        FROM pg_class c
        WHERE c.oid = \(literal)::regclass
        """
    }

    private func tableFacts(_ source: DuplicateTableRef) async throws -> TableFacts {
        let rows = try await driver.runSimple(Self.tableFactsSQL(source, quoting: driver.quoting))
        guard let row = rows.first, row.count >= 4 else {
            throw DuplicateError.sourceMissing(source.name)
        }
        return TableFacts(
            comment: row[0].flatMap { $0.isEmpty ? nil : $0 },
            hasRowLevelSecurity: Self.isTrue(row[1]),
            isOwner: Self.isTrue(row[2]),
            isPartitioned: Self.isTrue(row[3])
        )
    }

    // MARK: - Sequences

    /// `pg_sequences` carries `cache_size`, which the driver's own `fetchDependentSequences` does
    /// not read and could not report anyway: it returns a rendered `CREATE SEQUENCE` string built
    /// around the source's name.
    static func sequenceAttributesSQL(_ source: DuplicateTableRef, quoting: DuplicateSQLQuoting) -> String {
        let literal = quoting.stringLiteral(qualifiedLiteral(source, quoting: quoting))
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

    private func sequenceAttributes(
        _ source: DuplicateTableRef,
        columns: [PluginColumnInfo]
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
                cycle: isTrue(row[6])
            )
        }
        return result
    }

    // MARK: - Shared

    /// PostgreSQL renders a boolean as `t` or `f` in text format, but a driver that maps it to a
    /// Swift `Bool` first hands back `true`. Both spellings are accepted so the reader does not
    /// depend on which path the value took.
    static func isTrue(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == "t" || value.lowercased() == "true"
    }

    static func qualifiedLiteral(_ ref: DuplicateTableRef, quoting: DuplicateSQLQuoting) -> String {
        guard let schema = ref.schema, !schema.isEmpty else { return quoting.identifier(ref.name) }
        return "\(quoting.identifier(schema)).\(quoting.identifier(ref.name))"
    }
}
