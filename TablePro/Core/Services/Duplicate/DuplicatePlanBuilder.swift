//
//  DuplicatePlanBuilder.swift
//  TablePro
//

import Foundation

/// Builds the statement sequence for one vendor. Pure: introspection comes in, statements come
/// out, no connection involved, so the whole matrix of dialog options is unit-testable.
///
/// Quoting is injected through `DuplicateSQLQuoting` rather than reimplemented, because the
/// driver already owns the vendor's rules for identifiers and string literals.
protocol DuplicatePlanBuilding: Sendable {
    func plan(
        request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection,
        quoting: DuplicateSQLQuoting
    ) -> DuplicatePlan
}

/// `DatabaseType` is an open struct, so a type with no builder resolves to `nil` and the caller
/// refuses the operation rather than guessing a dialect.
///
/// The match is on the exact type, not on a dialect family. `TransferVendor` groups Redshift,
/// CockroachDB and PGlite with PostgreSQL, which is right for column-type syntax but wrong here:
/// Redshift's `CREATE TABLE (LIKE …)` accepts only `INCLUDING DEFAULTS`, so handing it this
/// builder would emit `INCLUDING CONSTRAINTS` and fail at the server instead of being refused up
/// front.
enum DuplicatePlanBuilder {
    static func builder(for databaseType: DatabaseType) -> DuplicatePlanBuilding? {
        switch databaseType {
        case .postgresql:
            return PostgreSqlDuplicatePlanBuilder()
        default:
            return nil
        }
    }
}
