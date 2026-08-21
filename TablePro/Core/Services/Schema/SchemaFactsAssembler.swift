//
//  SchemaFactsAssembler.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct SchemaFactsAssembler {
    private let vendor: TransferVendor?
    private let parser: NativeTypeParsing?

    init(databaseType: DatabaseType) {
        vendor = TransferVendor(databaseType)
        parser = vendor.map { NativeTypeParserRegistry.parser(for: $0) }
    }

    func assemble(
        schema: String?,
        table: String,
        columns: [PluginColumnInfo],
        foreignKeys: [PluginForeignKeyInfo],
        indexes: [PluginIndexInfo]
    ) -> GenerationTable {
        let primaryKeyColumns = columns.filter(\.isPrimaryKey).map(\.name)
        let resolvedForeignKeys = foreignKeys.map(Self.foreignKey)
        let uniqueConstraints = Self.uniqueConstraints(
            columns: columns,
            indexes: indexes,
            primaryKeyColumns: primaryKeyColumns
        )
        let singleColumnUniqueNames = Set(
            uniqueConstraints.filter { $0.columns.count == 1 }.compactMap(\.columns.first)
        )

        let generationColumns = columns.map { column in
            GenerationColumn(
                name: column.name,
                type: columnType(for: column),
                isNullable: column.isNullable,
                isPrimaryKey: column.isPrimaryKey,
                identityKind: column.identityKind,
                isGenerated: column.isGenerated,
                defaultValue: column.defaultValue,
                checkExpressions: column.checkExpressions,
                sequenceName: column.sequenceName,
                uniqueConstraints: column.uniqueConstraints,
                requiresUniqueValues: singleColumnUniqueNames.contains(column.name),
                foreignKey: resolvedForeignKeys.first { $0.localColumns.contains(column.name) },
                collation: column.collation
            )
        }

        return GenerationTable(
            schema: schema,
            name: table,
            vendor: vendor,
            columns: generationColumns,
            primaryKeyColumns: primaryKeyColumns,
            uniqueConstraints: uniqueConstraints,
            foreignKeys: resolvedForeignKeys
        )
    }

    private func columnType(for column: PluginColumnInfo) -> TransferColumnType {
        guard let parser else {
            return TransferColumnType(
                base: .unknown,
                allowedValues: column.allowedValues,
                native: column.dataType
            )
        }
        return parser.parse(column.dataType, allowedValues: column.allowedValues)
    }

    private static func foreignKey(_ key: PluginForeignKeyInfo) -> GenerationForeignKey {
        GenerationForeignKey(
            constraintName: key.name,
            localColumns: key.localColumns,
            referencedSchema: key.referencedSchema,
            referencedTable: key.referencedTable,
            referencedColumn: key.referencedColumn,
            referencedColumns: key.referencedColumns
        )
    }

    private static func uniqueConstraints(
        columns: [PluginColumnInfo],
        indexes: [PluginIndexInfo],
        primaryKeyColumns: [String]
    ) -> [GenerationUniqueConstraint] {
        var order: [String] = []
        var byName: [String: [String]] = [:]

        for name in columns.flatMap(\.uniqueConstraints) where byName[name] == nil {
            let members = columns.filter { $0.uniqueConstraints.contains(name) }.map(\.name)
            byName[name] = members
            order.append(name)
        }

        for index in indexes where index.isUnique || index.isPrimary {
            guard Self.constrainsWholeValues(index) else {
                byName.removeValue(forKey: index.name)
                order.removeAll { $0 == index.name }
                continue
            }
            if byName[index.name] == nil { order.append(index.name) }
            byName[index.name] = index.columns
        }

        var constraints = order.compactMap { name in
            byName[name].map { GenerationUniqueConstraint(name: name, columns: $0) }
        }

        let primaryKeyAlreadyPresent = constraints.contains { Set($0.columns) == Set(primaryKeyColumns) }
        if !primaryKeyColumns.isEmpty, !primaryKeyAlreadyPresent {
            constraints.insert(
                GenerationUniqueConstraint(name: Self.primaryKeyConstraintName, columns: primaryKeyColumns),
                at: 0
            )
        }
        return constraints
    }

    /// A partial index constrains only the rows its predicate selects and a
    /// prefix index constrains only the leading characters, so neither means the
    /// column's values have to be distinct. Treating them as full uniqueness
    /// makes generation enforce a rule the server never asked for, and on a
    /// small value domain that aborts the run with `uniqueExhausted`.
    private static func constrainsWholeValues(_ index: PluginIndexInfo) -> Bool {
        index.whereClause == nil && (index.columnPrefixes?.isEmpty ?? true)
    }

    private static let primaryKeyConstraintName = "PRIMARY"
}
