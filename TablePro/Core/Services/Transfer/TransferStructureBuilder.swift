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
    case identifierShortened(original: String, mapped: String)
    case identifierCollision(first: String, second: String, mapped: String)
    case identifierTooLong(name: String, limit: Int)
    case caseOnlyNameClash(first: String, second: String)
    case externalForeignKeyDropped(table: String, references: [String])

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
        case .identifierShortened(let original, let mapped):
            return String(
                format: String(localized: "Name '%@' is too long for the target and becomes '%@'."),
                original,
                mapped
            )
        case .identifierCollision(let first, let second, let mapped):
            return String(
                format: String(localized: "Names '%@' and '%@' both become '%@' at the target."),
                first,
                second,
                mapped
            )
        case .identifierTooLong(let name, let limit):
            return String(
                format: String(localized: "Name '%@' is longer than the %d bytes the target allows and is not renamed."),
                name,
                limit
            )
        case .caseOnlyNameClash(let first, let second):
            return String(
                format: String(localized: "Names '%@' and '%@' differ only in capitalization and stay separate because the target quotes them."),
                first,
                second
            )
        case .externalForeignKeyDropped(let table, let references):
            return String(
                format: String(
                    localized: "'%@' is dropped and recreated while %@ still points at it. Its foreign key may end up invalid until it is fixed."
                ),
                table,
                references.joined(separator: ", ")
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
    let enumTypes: [TransferEnumType]

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
        mapper: TransferTypeMapper? = nil,
        keepsDescendingIndex: Bool = true
    ) -> TransferTableStructure {
        var warnings: [TransferStructureWarning] = []
        var definitions: [PluginColumnDefinition] = []
        var generatedColumns: Set<String> = []
        var autoIncrementColumns: [String] = []
        var conversions: [String: TransferValueConversion] = [:]
        var enumTypes: [TransferEnumType] = []

        let policy = TransferIdentifierPolicy.policy(for: mapper?.targetVendor)

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
            var allowedValues: [String]?
            if let mapper {
                let plan = mapper.plan(for: column, table: table)
                dataType = plan.targetType
                allowedValues = plan.allowedValues
                warnings.append(contentsOf: plan.warnings)
                if let conversion = plan.conversion { conversions[column.name] = conversion }
                if let enumType = plan.enumType, !enumTypes.contains(enumType) { enumTypes.append(enumType) }
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
                    unsigned: false,
                    onUpdate: nil,
                    charset: column.charset,
                    collation: column.collation,
                    allowedValues: allowedValues,
                    generatedExpression: nil,
                    identityKind: nil
                )
            )
        }

        warnings.append(contentsOf: nameWarnings(table: table, columns: definitions.map(\.name), policy: policy))

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

        if !keepsDescendingIndex {
            mappedIndexes = mappedIndexes.map { index in
                guard !index.descendingColumns.isEmpty else { return index }
                warnings.append(
                    .indexSilentlyIgnored(
                        table: table,
                        index: index.name,
                        reason: String(
                            localized: "The target builds an ascending index from a descending one without reporting it, so the index is created ascending."
                        )
                    )
                )
                return index.withDescendingColumns([])
            }
        }

        let mappedForeignKeys = foreignKeyDefinitions(from: foreignKeys, targetSchema: targetSchema)
        let names = TransferIdentifierMap(
            names: mappedIndexes.map(\.name) + mappedForeignKeys.map(\.name),
            policy: policy
        )
        warnings.append(contentsOf: names.warnings)

        return TransferTableStructure(
            table: table,
            definition: definition,
            indexes: mappedIndexes.map { $0.renamed(to: names.resolve($0.name)) },
            foreignKeys: mappedForeignKeys.map { $0.renamed(to: names.resolve($0.name)) },
            generatedColumns: generatedColumns,
            primaryKeyColumns: primaryKeyColumns,
            autoIncrementColumns: autoIncrementColumns,
            warnings: warnings,
            conversions: conversions,
            enumTypes: enumTypes
        )
    }

    /// A table or column keeps its source name, so an overrun here is reported
    /// rather than repaired: renaming either one would leave the INSERT
    /// statements pointing at something that does not exist.
    static func nameWarnings(
        table: String,
        columns: [String],
        policy: TransferIdentifierPolicy
    ) -> [TransferStructureWarning] {
        var warnings: [TransferStructureWarning] = []
        for name in [table] + columns where !policy.fits(name) {
            warnings.append(.identifierTooLong(name: name, limit: policy.maxLengthBytes))
        }

        var seen: [String: String] = [:]
        for name in columns {
            let key = name.lowercased()
            if let existing = seen[key], existing != name {
                warnings.append(.caseOnlyNameClash(first: existing, second: name))
                continue
            }
            seen[key] = name
        }
        return warnings
    }

    /// A PostgreSQL `serial` is not an identity column and carries no extra: it
    /// is an ordinary integer whose default reads from a sequence. Copying that
    /// default verbatim points the new table at the source's sequence, which
    /// does not exist in the target database, so the column has to be
    /// recognised here and recreated as the target's own auto-increment.
    static func isAutoIncrement(_ column: PluginColumnInfo) -> Bool {
        if column.identityKind != nil { return true }
        if let defaultValue = column.defaultValue,
           defaultValue.lowercased().hasPrefix("nextval(") {
            return true
        }
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
                    whereClause: index.whereClause,
                    descendingColumns: index.descendingColumns ?? []
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
