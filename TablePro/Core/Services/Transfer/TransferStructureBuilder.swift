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
    case typeNotMapped(table: String, column: String, native: String)
    case typeLossy(table: String, column: String, from: String, to: String, reason: String)
    case indexNotMapped(table: String, index: String, reason: String)
    case indexSilentlyIgnored(table: String, index: String, reason: String)

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
        case .typeNotMapped(_, let column, let native):
            return String(
                format: String(localized: "Column '%@' keeps the source type '%@' because the target has no match for it."),
                column,
                native
            )
        case .typeLossy(_, let column, let from, let to, let reason):
            return String(
                format: String(localized: "Column '%@' changes from '%@' to '%@'. %@"),
                column,
                from,
                to,
                reason
            )
        case .indexNotMapped(_, let index, let reason):
            return String(format: String(localized: "Index '%@' changes at the target. %@"), index, reason)
        case .indexSilentlyIgnored(_, let index, let reason):
            return String(
                format: String(localized: "Index '%@' is accepted but ignored by the target server. %@"),
                index,
                reason
            )
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
    let conversions: [String: TransferValueConversion]

    var writableColumns: [String] {
        definition.columns.map(\.name)
    }
}

enum TransferStructureBuilder {
    /// `mapper` is nil for a same-dialect transfer, where the source type string
    /// is already valid at the target. A cross-vendor transfer passes a mapper
    /// so every type goes through the IR.
    static func build(
        table: String,
        columns: [PluginColumnInfo],
        indexes: [PluginIndexInfo],
        foreignKeys: [PluginForeignKeyInfo],
        targetSchema: String?,
        mapper: TransferTypeMapper? = nil
    ) -> TransferTableStructure {
        var warnings: [TransferStructureWarning] = []
        var definitions: [PluginColumnDefinition] = []
        var generatedColumns: Set<String> = []
        var autoIncrementColumns: [String] = []
        var conversions: [String: TransferValueConversion] = [:]

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

            var dataType = column.dataType
            if let mapper {
                let plan = mapper.plan(for: column, table: table)
                dataType = plan.targetType
                warnings.append(contentsOf: plan.warnings)
                if let conversion = plan.conversion { conversions[column.name] = conversion }
            }

            definitions.append(
                PluginColumnDefinition(
                    name: column.name,
                    dataType: dataType,
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

        var mappedIndexes = indexDefinitions(from: indexes, generatedColumns: generatedColumns)
        if let mapper {
            var kept: [PluginIndexDefinition] = []
            for index in mappedIndexes {
                let plan = mapper.plan(for: index, table: table)
                warnings.append(contentsOf: plan.warnings)
                if let mapped = plan.index { kept.append(mapped) }
            }
            mappedIndexes = kept
        }

        return TransferTableStructure(
            table: table,
            definition: definition,
            indexes: mappedIndexes,
            foreignKeys: foreignKeyDefinitions(from: foreignKeys, targetSchema: targetSchema),
            generatedColumns: generatedColumns,
            primaryKeyColumns: primaryKeyColumns,
            autoIncrementColumns: autoIncrementColumns,
            warnings: warnings,
            conversions: conversions
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
