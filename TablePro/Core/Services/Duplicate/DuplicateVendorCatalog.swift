//
//  DuplicateVendorCatalog.swift
//  TablePro
//

import Foundation

/// What the source table is, beyond what the driver's structured reads already answer.
struct DuplicateTableFacts: Sendable, Hashable {
    let comment: String?
    let hasRowLevelSecurity: Bool
    let isOwner: Bool
    let isPartitioned: Bool
    let hasExpressionIndex: Bool

    init(
        comment: String? = nil,
        hasRowLevelSecurity: Bool = false,
        isOwner: Bool = true,
        isPartitioned: Bool = false,
        hasExpressionIndex: Bool = false
    ) {
        self.comment = comment
        self.hasRowLevelSecurity = hasRowLevelSecurity
        self.isOwner = isOwner
        self.isPartitioned = isPartitioned
        self.hasExpressionIndex = hasExpressionIndex
    }
}

/// The catalog questions no driver requirement answers, asked in each vendor's own system tables.
///
/// It is a separate seam from `DuplicatePlanBuilding` because it is the only part of this feature
/// that talks to a server before anything is created. Keeping the SQL here rather than in the
/// builder is what lets the builders stay pure and fully unit-testable.
protocol DuplicateVendorCatalog: Sendable {
    /// The byte budget for the one name this feature invents.
    var identifierPolicy: TransferIdentifierPolicy { get }

    func facts(_ source: DuplicateTableRef, driver: any DuplicateDriving) async throws -> DuplicateTableFacts

    /// Only PostgreSQL has these. MySQL's `AUTO_INCREMENT` lives on the column and travels with
    /// `CREATE TABLE … LIKE`, so there is nothing to read.
    func sequenceAttributes(
        _ source: DuplicateTableRef,
        driver: any DuplicateDriving
    ) async throws -> [String: DuplicateSequenceAttributes]

    /// Whether anything at all already holds the target name. Views, sequences and indexes count:
    /// they share the namespace, so filtering to tables only moves the failure later.
    func targetIsTaken(_ request: DuplicateTableRequest, driver: any DuplicateDriving) async throws -> Bool

    /// The first permission the user is missing, or `nil` if the check passed or could not run.
    func missingPrivilege(
        _ request: DuplicateTableRequest,
        driver: any DuplicateDriving
    ) async throws -> DuplicateError?
}

/// `DatabaseType` is an open struct, so a type with no catalog resolves to `nil` and the caller
/// refuses the operation rather than running PostgreSQL system SQL against something else.
enum DuplicateVendorCatalogRegistry {
    static func catalog(for databaseType: DatabaseType) -> (any DuplicateVendorCatalog)? {
        switch databaseType {
        case .postgresql:
            return PostgreSqlDuplicateCatalog()
        case .mysql, .mariadb:
            return MySqlDuplicateCatalog()
        default:
            return nil
        }
    }
}
