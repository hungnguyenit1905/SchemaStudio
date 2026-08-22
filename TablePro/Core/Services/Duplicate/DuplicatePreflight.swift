//
//  DuplicatePreflight.swift
//  TablePro
//

import Foundation

/// Refuses a duplicate before anything is created, so a failure reads as a permission or a naming
/// problem instead of a syntax error partway through a half-built table.
struct DuplicatePreflight: Sendable {
    let driver: any DuplicateDriving

    func check(_ request: DuplicateTableRequest, introspection: DuplicateTableIntrospection) async throws {
        if let reason = DuplicateTargetNaming.validate(
            request.targetName,
            policy: TransferIdentifierPolicy.policy(for: .postgresql)
        ) {
            throw DuplicateError.invalidTargetName(reason)
        }

        guard !introspection.isPartitioned else {
            throw DuplicateError.partitionedSource(request.source.name)
        }

        try await checkTargetIsFree(request)
        try await checkPrivileges(request)
    }

    /// The check ignores `relkind` on purpose. A table name collides with a view, a sequence, an
    /// index or a composite type in the same schema, so filtering to tables would let the create
    /// fail later with a less useful message.
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

    private func checkTargetIsFree(_ request: DuplicateTableRequest) async throws {
        let rows = try await driver.runSimple(Self.targetExistsSQL(request, quoting: driver.quoting))
        guard rows.isEmpty else {
            guard request.options.onExists == .dropAndRecreate else {
                throw DuplicateError.targetExists(request.targetName)
            }
            return
        }
    }

    static func privilegesSQL(_ request: DuplicateTableRequest, quoting: DuplicateSQLQuoting) -> String {
        let schema = request.targetSchema ?? "public"
        let source = DuplicateIntrospector.qualifiedLiteral(request.source, quoting: quoting)
        return """
        SELECT has_schema_privilege(current_user, \(quoting.stringLiteral(schema)), 'CREATE'),
               has_table_privilege(current_user, \(quoting.stringLiteral(source)), 'SELECT')
        """
    }

    private func checkPrivileges(_ request: DuplicateTableRequest) async throws {
        let rows = try await driver.runSimple(Self.privilegesSQL(request, quoting: driver.quoting))
        guard let row = rows.first, row.count >= 2 else { return }
        guard DuplicateIntrospector.isTrue(row[0]) else {
            throw DuplicateError.missingCreatePrivilege(request.targetSchema ?? "public")
        }
        guard DuplicateIntrospector.isTrue(row[1]) else {
            throw DuplicateError.missingSelectPrivilege(request.source.name)
        }
    }
}
