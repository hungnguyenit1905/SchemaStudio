//
//  TransferStructureBuilder.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum TransferStructureWarning: Sendable, Hashable {
    case generatedColumn(String)
    case identityColumn(String)
    case checkConstraintNotCarried

    var message: String {
        switch self {
        case .generatedColumn(let column):
            return String(
                format: String(localized: "Column '%@' is computed by the server. It is not created and not written."),
                column
            )
        case .identityColumn(let column):
            return String(
                format: String(localized: "Column '%@' becomes a plain auto-increment column at the target."),
                column
            )
        case .checkConstraintNotCarried:
            return String(localized: "CHECK constraints and partitioning are not carried to the target.")
        }
    }
}

struct TransferTableStructure: Sendable {
    let table: String
    let definition: PluginCreateTableDefinition
    let indexes: [PluginIndexDefinition]
    let foreignKeys: [PluginForeignKeyDefinition]
    let generatedColumns: Set<String>
    let primaryKeyColumns: [String]
    let autoIncrementColumns: [String]
    let warnings: [TransferStructureWarning]

    var writableColumns: [String] {
        definition.columns.map(\.name)
    }
}

enum TransferStructureBuilder {
    static func build(
        table: String,
        columns: [PluginColumnInfo],
        indexes: [PluginIndexInfo],
        foreignKeys: [PluginForeignKeyInfo],
        targetSchema: String?
    ) -> TransferTableStructure {
        var warnings: [TransferStructureWarning] = []
        var definitions: [PluginColumnDefinition] = []
        var generatedColumns: Set<String> = []
        var autoIncrementColumns: [String] = []

        for column in columns {
            if column.isGenerated {
                generatedColumns.insert(column.name)
                warnings.append(.generatedColumn(column.name))
                continue
            }

            let autoIncrement = isAutoIncrement(column)
            if column.identityKind != nil {
                warnings.append(.identityColumn(column.name))
            }
            if autoIncrement {
                autoIncrementColumns.append(column.name)
            }

            definitions.append(
                PluginColumnDefinition(
                    name: column.name,
                    dataType: column.dataType,
                    isNullable: column.isNullable,
                    defaultValue: autoIncrement ? nil : column.defaultValue,
                    isPrimaryKey: column.isPrimaryKey,
                    autoIncrement: autoIncrement,
                    comment: column.comment,
                    charset: column.charset,
                    collation: column.collation
                )
            )
        }

        let primaryKeyColumns = columns.filter { $0.isPrimaryKey && !$0.isGenerated }.map(\.name)

        let definition = PluginCreateTableDefinition(
            tableName: table,
            columns: definitions,
            indexes: [],
            foreignKeys: [],
            primaryKeyColumns: primaryKeyColumns,
            ifNotExists: false
        )

        return TransferTableStructure(
            table: table,
            definition: definition,
            indexes: indexDefinitions(from: indexes, generatedColumns: generatedColumns),
            foreignKeys: foreignKeyDefinitions(from: foreignKeys, targetSchema: targetSchema),
            generatedColumns: generatedColumns,
            primaryKeyColumns: primaryKeyColumns,
            autoIncrementColumns: autoIncrementColumns,
            warnings: warnings
        )
    }

    static func isAutoIncrement(_ column: PluginColumnInfo) -> Bool {
        if column.identityKind != nil { return true }
        guard let extra = column.extra else { return false }
        return extra.lowercased().contains("auto_increment")
    }

    static func indexDefinitions(
        from indexes: [PluginIndexInfo],
        generatedColumns: Set<String>
    ) -> [PluginIndexDefinition] {
        indexes
            .filter { !$0.isPrimary }
            .filter { index in index.columns.allSatisfy { !generatedColumns.contains($0) } }
            .map { index in
                PluginIndexDefinition(
                    name: index.name,
                    columns: index.columns,
                    isUnique: index.isUnique,
                    indexType: index.type,
                    columnPrefixes: index.columnPrefixes,
                    whereClause: index.whereClause
                )
            }
    }

    /// `PluginForeignKeyInfo` carries one column per row, so a composite key
    /// arrives as several rows sharing a constraint name. Grouping keeps the
    /// order the driver returned, which is the order the constraint declares.
    static func foreignKeyDefinitions(
        from foreignKeys: [PluginForeignKeyInfo],
        targetSchema: String?
    ) -> [PluginForeignKeyDefinition] {
        var order: [String] = []
        var grouped: [String: [PluginForeignKeyInfo]] = [:]

        for foreignKey in foreignKeys {
            if grouped[foreignKey.name] == nil {
                order.append(foreignKey.name)
                grouped[foreignKey.name] = []
            }
            grouped[foreignKey.name]?.append(foreignKey)
        }

        return order.compactMap { name -> PluginForeignKeyDefinition? in
            guard let parts = grouped[name], let first = parts.first else { return nil }
            return PluginForeignKeyDefinition(
                name: name,
                columns: parts.map(\.column),
                referencedTable: first.referencedTable,
                referencedColumns: parts.map(\.referencedColumn),
                onDelete: first.onDelete,
                onUpdate: first.onUpdate,
                referencedSchema: first.referencedSchema == nil ? nil : targetSchema ?? first.referencedSchema
            )
        }
    }
}
