//
//  DuplicateTargetConflictResolver.swift
//  TablePro
//

import Foundation

/// A foreign key another table holds against the target name. The owning table is part of the
/// identity because dropping the constraint changes a table the user did not ask about, and the
/// dialog has to say which one.
struct ReferencingForeignKey: Sendable, Hashable {
    let constraintName: String
    let owningSchema: String?
    let owningTable: String

    var qualifiedOwner: String {
        guard let owningSchema, !owningSchema.isEmpty else { return owningTable }
        return "\(owningSchema).\(owningTable)"
    }

    var describedForDialog: String {
        String(format: String(localized: "%1$@ on %2$@"), constraintName, qualifiedOwner)
    }
}

/// How a vendor removes a table other tables still point at.
enum DuplicateDropDialect: Sendable, Hashable {
    /// PostgreSQL drops the dependent constraints itself when told to.
    case cascadeKeyword
    /// MySQL parses `CASCADE` and then ignores it, so every referencing constraint has to be
    /// named and dropped before the table can go.
    case dropReferencingFirst
}

/// Builds the statements that clear the target name for a `Drop and recreate` run.
///
/// Split from the plan builders because it needs a server read the builders never make: which
/// foreign keys point at the target. The builders stay pure and this stays the only place that
/// decides whether a drop cascades.
struct DuplicateTargetConflictResolver: Sendable {
    let catalog: any DuplicateVendorCatalog

    func referencingForeignKeys(
        target: DuplicateTableRef,
        driver: any DuplicateDriving
    ) async throws -> [ReferencingForeignKey] {
        try await catalog.referencingForeignKeys(target, driver: driver)
    }

    /// `referencing` is only ever non-empty when the user answered the second dialog with
    /// *Drop with CASCADE*. Nothing here decides to cascade on its own: an unanswered dialog
    /// stops the run before this is called.
    func dropPlan(
        target: DuplicateTableRef,
        referencing: [ReferencingForeignKey],
        quoting: DuplicateSQLQuoting
    ) -> [DuplicateStatement] {
        let qualified = quoting.qualified(target)
        guard !referencing.isEmpty else {
            return [DuplicateStatement(kind: .dropTarget, sql: "DROP TABLE IF EXISTS \(qualified)")]
        }

        switch catalog.dropDialect {
        case .cascadeKeyword:
            return [DuplicateStatement(kind: .dropTarget, sql: "DROP TABLE IF EXISTS \(qualified) CASCADE")]
        case .dropReferencingFirst:
            let owners = referencing.map { key in
                DuplicateStatement(
                    kind: .dropReferencingForeignKey,
                    sql: """
                    ALTER TABLE \(quoting.qualified(
                        DuplicateTableRef(schema: key.owningSchema, name: key.owningTable)
                    )) DROP FOREIGN KEY \(quoting.identifier(key.constraintName))
                    """
                )
            }
            return owners + [DuplicateStatement(kind: .dropTarget, sql: "DROP TABLE IF EXISTS \(qualified)")]
        }
    }
}

/// Both vendors answer the same three columns in the same order, so the row reading is written
/// once rather than in each catalog.
enum DuplicateReferencingForeignKeyReader {
    static func read(_ rows: [[String?]]) -> [ReferencingForeignKey] {
        rows.compactMap { row in
            guard row.count >= 3,
                  let name = row[0], !name.isEmpty,
                  let table = row[2], !table.isEmpty else { return nil }
            return ReferencingForeignKey(
                constraintName: name,
                owningSchema: row[1].flatMap { $0.isEmpty ? nil : $0 },
                owningTable: table
            )
        }
    }
}
