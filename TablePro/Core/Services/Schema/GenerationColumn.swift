//
//  GenerationColumn.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct GenerationForeignKey: Sendable, Hashable {
    let constraintName: String
    let localColumns: [String]
    let referencedSchema: String?
    let referencedTable: String
    let referencedColumn: String
    let referencedColumns: [String]

    var isComposite: Bool { localColumns.count > 1 }

    func referencedColumn(forLocal localColumn: String) -> String? {
        guard
            let position = localColumns.firstIndex(of: localColumn),
            position < referencedColumns.count
        else { return nil }
        return referencedColumns[position]
    }
}

struct GenerationUniqueConstraint: Sendable, Hashable {
    let name: String
    let columns: [String]
}

struct GenerationColumn: Sendable, Hashable {
    let name: String
    let type: TransferColumnType
    let isNullable: Bool
    let isPrimaryKey: Bool
    let identityKind: IdentityKind?
    let isGenerated: Bool
    let defaultValue: String?
    let checkExpressions: [String]
    let sequenceName: String?
    let uniqueConstraints: [String]
    let requiresUniqueValues: Bool
    let foreignKey: GenerationForeignKey?

    /// Carried because uniqueness is the server's comparison, not ours: under a
    /// case-insensitive collation `Alice` and `alice` are one value.
    let collation: String?

    init(
        name: String,
        type: TransferColumnType,
        isNullable: Bool,
        isPrimaryKey: Bool,
        identityKind: IdentityKind?,
        isGenerated: Bool,
        defaultValue: String?,
        checkExpressions: [String],
        sequenceName: String?,
        uniqueConstraints: [String],
        requiresUniqueValues: Bool,
        foreignKey: GenerationForeignKey?,
        collation: String? = nil
    ) {
        self.name = name
        self.type = type
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.identityKind = identityKind
        self.isGenerated = isGenerated
        self.defaultValue = defaultValue
        self.checkExpressions = checkExpressions
        self.sequenceName = sequenceName
        self.uniqueConstraints = uniqueConstraints
        self.requiresUniqueValues = requiresUniqueValues
        self.foreignKey = foreignKey
        self.collation = collation
    }

    var isIdentity: Bool { identityKind != nil }

    var isServerAssigned: Bool { isGenerated || identityKind == .always }

    var allowedValues: [String]? { type.allowedValues }

    var maxLength: Int? { type.length }

    var referencedColumn: String? { foreignKey?.referencedColumn(forLocal: name) }
}

struct GenerationTable: Sendable, Hashable {
    let schema: String?
    let name: String
    let vendor: TransferVendor?
    let columns: [GenerationColumn]
    let primaryKeyColumns: [String]
    let uniqueConstraints: [GenerationUniqueConstraint]
    let foreignKeys: [GenerationForeignKey]

    var compositeUniqueConstraints: [GenerationUniqueConstraint] {
        uniqueConstraints.filter { $0.columns.count > 1 }
    }

    func column(named name: String) -> GenerationColumn? {
        columns.first { $0.name == name }
    }
}
