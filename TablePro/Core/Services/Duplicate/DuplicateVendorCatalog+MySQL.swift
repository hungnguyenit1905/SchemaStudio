//
//  DuplicateVendorCatalog+MySQL.swift
//  TablePro
//

import Foundation

/// MySQL and MariaDB catalog reads. Everything comes from `information_schema` except the
/// permission check, which has no table form: `SHOW GRANTS` is the only place a grant that was
/// made to a role, or with `WITH GRANT OPTION`, shows up as it actually applies.
struct MySqlDuplicateCatalog: DuplicateVendorCatalog {
    var identifierPolicy: TransferIdentifierPolicy { TransferIdentifierPolicy.policy(for: .mysql) }

    // MARK: - Facts

    static func factsSQL(_ source: DuplicateTableRef, quoting: DuplicateSQLQuoting) -> String {
        let schema = schemaExpression(source.schema, quoting: quoting)
        let name = quoting.stringLiteral(source.name)
        return """
        SELECT t.TABLE_COMMENT,
               (SELECT COUNT(*)
                FROM information_schema.PARTITIONS p
                WHERE p.TABLE_SCHEMA = t.TABLE_SCHEMA
                  AND p.TABLE_NAME = t.TABLE_NAME
                  AND p.PARTITION_NAME IS NOT NULL)
        FROM information_schema.TABLES t
        WHERE t.TABLE_SCHEMA = \(schema)
          AND t.TABLE_NAME = \(name)
        """
    }

    /// `STATISTICS.EXPRESSION` only exists on MySQL 8.0.13 and later. Asking for it anywhere else
    /// is an error, not an empty answer, which is why this is a separate statement whose failure
    /// is read as "no expression indexes": MariaDB has none, and neither does an older MySQL.
    static func expressionIndexSQL(_ source: DuplicateTableRef, quoting: DuplicateSQLQuoting) -> String {
        let schema = schemaExpression(source.schema, quoting: quoting)
        return """
        SELECT COUNT(*)
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = \(schema)
          AND TABLE_NAME = \(quoting.stringLiteral(source.name))
          AND EXPRESSION IS NOT NULL
        """
    }

    func facts(_ source: DuplicateTableRef, driver: any DuplicateDriving) async throws -> DuplicateTableFacts {
        let rows = try await driver.runSimple(Self.factsSQL(source, quoting: driver.quoting))
        guard let row = rows.first, row.count >= 2 else {
            throw DuplicateError.sourceMissing(source.name)
        }
        let expressionRows = try? await driver.runSimple(
            Self.expressionIndexSQL(source, quoting: driver.quoting)
        )
        return DuplicateTableFacts(
            comment: row[0].flatMap { $0.isEmpty ? nil : $0 },
            hasRowLevelSecurity: false,
            isOwner: true,
            isPartitioned: Self.isPositiveCount(row[1]),
            hasExpressionIndex: Self.isPositiveCount(expressionRows?.first?.first ?? nil)
        )
    }

    /// MySQL has no sequences. An `AUTO_INCREMENT` column carries its counter in the table's own
    /// metadata and `CREATE TABLE … LIKE` brings the column across, so there is nothing to read
    /// and nothing to recreate.
    func sequenceAttributes(
        _ source: DuplicateTableRef,
        driver: any DuplicateDriving
    ) async throws -> [String: DuplicateSequenceAttributes] {
        [:]
    }

    // MARK: - Preflight

    static func targetExistsSQL(_ request: DuplicateTableRequest, quoting: DuplicateSQLQuoting) -> String {
        """
        SELECT 1
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = \(schemaExpression(request.targetSchema, quoting: quoting))
          AND TABLE_NAME = \(quoting.stringLiteral(request.targetName))
        LIMIT 1
        """
    }

    func targetIsTaken(_ request: DuplicateTableRequest, driver: any DuplicateDriving) async throws -> Bool {
        try await !driver.runSimple(Self.targetExistsSQL(request, quoting: driver.quoting)).isEmpty
    }

    func missingPrivilege(
        _ request: DuplicateTableRequest,
        driver: any DuplicateDriving
    ) async throws -> DuplicateError? {
        guard let rows = try? await driver.runSimple("SHOW GRANTS FOR CURRENT_USER()") else { return nil }
        guard let schema = try await currentSchema(request, driver: driver) else { return nil }
        let granted = Self.grantedPrivileges(from: rows, schema: schema)
        guard !granted.isEmpty else { return nil }
        guard !granted.contains(Self.allPrivileges) else { return nil }

        for privilege in Self.requiredPrivileges(for: request) where !granted.contains(privilege) {
            return .missingPrivilege(privilege: privilege, schema: schema)
        }
        return nil
    }

    private func currentSchema(
        _ request: DuplicateTableRequest,
        driver: any DuplicateDriving
    ) async throws -> String? {
        if let schema = request.targetSchema, !schema.isEmpty { return schema }
        let rows = try await driver.runSimple("SELECT DATABASE()")
        return rows.first?.first.flatMap { $0 }
    }

    // MARK: - Grants

    static let allPrivileges = "ALL PRIVILEGES"

    /// What the plan is actually going to do, so a structure-only copy is not refused for want of
    /// a privilege it never uses.
    static func requiredPrivileges(for request: DuplicateTableRequest) -> [String] {
        var privileges = ["CREATE", "SELECT"]
        if request.mode == .structureAndData {
            privileges.append("INSERT")
        }
        if request.options.foreignKeys {
            privileges.append("REFERENCES")
        }
        if needsAlter(request) {
            privileges.append("ALTER")
        }
        return privileges
    }

    /// Every statement after the create is an `ALTER TABLE`: dropping and replaying the indexes,
    /// clearing the comment, and setting the auto-increment counter.
    private static func needsAlter(_ request: DuplicateTableRequest) -> Bool {
        if !request.options.indexes || !request.options.comments { return true }
        if request.options.identity { return true }
        return request.mode == .structureAndData && request.options.indexes
    }

    /// Reads `SHOW GRANTS` into the set of privileges that apply to `schema`.
    ///
    /// Bounded parsing, like the index harvest: each line is split at ` ON ` and ` TO `, the
    /// scope is compared, and the privilege names are taken as written. A line that does not have
    /// that shape, such as a role grant, is skipped rather than guessed at. An empty result means
    /// nothing could be read, and the caller treats that as "do not block".
    static func grantedPrivileges(from rows: [[String?]], schema: String) -> Set<String> {
        var granted: Set<String> = []
        for row in rows {
            guard let line = row.first.flatMap({ $0 }) else { continue }
            guard let grant = grant(inLine: line), scope(grant.scope, matches: schema) else { continue }
            granted.formUnion(grant.privileges)
        }
        return granted
    }

    private struct Grant {
        let privileges: [String]
        let scope: String
    }

    private static func grant(inLine line: String) -> Grant? {
        let upper = line.uppercased()
        guard upper.hasPrefix("GRANT ") else { return nil }
        guard let onRange = upper.range(of: " ON ") else { return nil }
        guard let toRange = upper.range(of: " TO ", range: onRange.upperBound ..< upper.endIndex) else { return nil }

        let names = withoutColumnLists(String(line[line.index(line.startIndex, offsetBy: 6) ..< onRange.lowerBound]))
        let privileges = names
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .map { $0 == "ALL" ? allPrivileges : $0 }
            .filter { !$0.isEmpty }

        let scope = line[onRange.upperBound ..< toRange.lowerBound].trimmingCharacters(in: .whitespaces)
        return Grant(privileges: privileges, scope: scope)
    }

    /// A column-level grant reads `SELECT (`id`, `email`)`, whose commas belong to the column
    /// list rather than to the privilege list. Dropping the parenthesised groups first is what
    /// keeps `email` from being read as a privilege named `` `EMAIL`) ``.
    private static func withoutColumnLists(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "(":
                depth += 1
            case ")":
                depth = max(0, depth - 1)
            default:
                if depth == 0 { result.append(character) }
            }
        }
        return result
    }

    /// A grant applies here if it is global (`*.*`) or names this schema, whatever it names after
    /// the dot: a table-level grant on the target schema still proves the privilege exists there,
    /// and a preflight that guessed otherwise would refuse a duplicate the server would allow.
    private static func scope(_ scope: String, matches schema: String) -> Bool {
        guard let dot = scope.range(of: ".") else { return false }
        let database = unquoted(String(scope[scope.startIndex ..< dot.lowerBound]))
        return database == "*" || database == schema
    }

    private static func unquoted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("`"), trimmed.hasSuffix("`"), trimmed.count >= 2 else { return trimmed }
        return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
    }

    // MARK: - Shared

    /// A duplicate with no schema chosen runs against whatever database the connection is on, and
    /// `DATABASE()` is the only thing that knows which one that is.
    private static func schemaExpression(_ schema: String?, quoting: DuplicateSQLQuoting) -> String {
        guard let schema, !schema.isEmpty else { return "DATABASE()" }
        return quoting.stringLiteral(schema)
    }

    private static func isPositiveCount(_ value: String?) -> Bool {
        guard let value, let count = Int(value.trimmingCharacters(in: .whitespaces)) else { return false }
        return count > 0
    }
}
