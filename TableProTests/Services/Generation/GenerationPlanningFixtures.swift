//
//  GenerationPlanningFixtures.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit

enum GenerationPlanningFixtures {
    static func table(
        _ name: String,
        schema: String? = "public",
        columns: [PluginColumnInfo],
        foreignKeys: [PluginForeignKeyInfo] = [],
        indexes: [PluginIndexInfo] = [],
        databaseType: DatabaseType = .postgresql
    ) -> GenerationTable {
        SchemaFactsAssembler(databaseType: databaseType).assemble(
            schema: schema,
            table: name,
            columns: columns,
            foreignKeys: foreignKeys,
            indexes: indexes
        )
    }

    static func identityColumn(_ name: String = "id") -> PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: "bigint",
            isNullable: false,
            isPrimaryKey: true,
            identityKind: .always,
            checkExpressions: []
        )
    }

    static func foreignKey(
        from local: String,
        to parent: String,
        column parentColumn: String = "id",
        schema: String? = "public",
        name: String? = nil
    ) -> PluginForeignKeyInfo {
        PluginForeignKeyInfo(
            name: name ?? "fk_\(local)_\(parent)",
            column: local,
            referencedTable: parent,
            referencedColumn: parentColumn,
            referencedSchema: schema
        )
    }

    /// customers -> orders -> order_items, with a self-referencing employees
    /// table available separately.
    static var shopSchema: [GenerationTable] {
        [
            table("customers", columns: [
                identityColumn(),
                PluginColumnInfo(name: "email", dataType: "varchar(255)", isNullable: false)
            ]),
            table(
                "orders",
                columns: [
                    identityColumn(),
                    PluginColumnInfo(name: "customer_id", dataType: "bigint", isNullable: false)
                ],
                foreignKeys: [foreignKey(from: "customer_id", to: "customers")]
            ),
            table(
                "order_items",
                columns: [
                    identityColumn(),
                    PluginColumnInfo(name: "order_id", dataType: "bigint", isNullable: false)
                ],
                foreignKeys: [foreignKey(from: "order_id", to: "orders")]
            )
        ]
    }

    static func profile(
        seed: UInt64 = 1,
        tables: [GenerationTableProfile]
    ) -> GenerationProfile {
        GenerationProfile(name: "fixture", seed: seed, tables: tables)
    }

    static func tableProfile(
        _ name: String,
        schema: String? = "public",
        rowCount: Int = 10,
        emptyFirst: Bool = false,
        columns: [GenerationColumnProfile]
    ) -> GenerationTableProfile {
        GenerationTableProfile(
            schema: schema,
            table: name,
            rowCount: rowCount,
            emptyFirst: emptyFirst,
            columns: columns
        )
    }

    /// A profile that matches `schema` exactly, using the type fallback for
    /// every column, so a test only has to override what it cares about.
    static func autoProfile(for schema: [GenerationTable], rowCount: Int = 10) -> GenerationProfile {
        profile(
            tables: schema.map { table in
                tableProfile(
                    table.name,
                    schema: table.schema,
                    rowCount: rowCount,
                    columns: table.columns.map { column in
                        let resolution = TypeFallbackGeneratorResolver.resolve(column)
                        return GenerationColumnProfile(
                            column: column.name,
                            generator: resolution.identifier,
                            params: resolution.params
                        )
                    }
                )
            }
        )
    }
}
