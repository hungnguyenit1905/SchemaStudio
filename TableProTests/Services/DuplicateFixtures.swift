//
//  DuplicateFixtures.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit

/// Introspection shapes the duplicate builders have to get right. Kept in one place so the
/// PostgreSQL and MySQL suites assert against the same source tables.
enum DuplicateFixtures {
    static let quoting = DuplicateSQLQuoting(
        identifier: { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" },
        stringLiteral: { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
    )

    static func request(
        source: DuplicateTableRef = DuplicateTableRef(schema: "public", name: "orders"),
        targetSchema: String? = "public",
        targetName: String = "orders_copy",
        mode: DuplicateMode = .structureAndData,
        options: DuplicateOptions = DuplicateOptions()
    ) -> DuplicateTableRequest {
        DuplicateTableRequest(
            source: source,
            targetSchema: targetSchema,
            targetName: targetName,
            mode: mode,
            options: options
        )
    }

    // MARK: - Columns

    static func column(
        _ name: String,
        _ dataType: String = "integer",
        primaryKey: Bool = false,
        identity: IdentityKind? = nil,
        generated: Bool = false,
        defaultValue: String? = nil
    ) -> PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: !primaryKey,
            isPrimaryKey: primaryKey,
            defaultValue: defaultValue,
            identityKind: identity,
            isGenerated: generated
        )
    }

    // MARK: - Sequences

    /// Deliberately not the server defaults: a copy that silently resets `CACHE` or drops
    /// `CYCLE` would pass a fixture built from defaults.
    static let nonDefaultSequence = DuplicateSequenceAttributes(
        name: "orders_id_seq",
        increment: "5",
        minValue: "10",
        maxValue: "9999",
        cache: "20",
        cycle: true
    )

    /// A sequence that was renamed after the column was created, so nothing may depend on the
    /// `<table>_<column>_seq` convention.
    static let renamedSequence = DuplicateSequenceAttributes(
        name: "legacy_order_counter",
        increment: "1",
        minValue: "1",
        maxValue: "9223372036854775807",
        cache: "1",
        cycle: false
    )

    // MARK: - Introspection shapes

    static var serialTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("id", primaryKey: true), column("total", "numeric(10,2)")],
            sequencesByColumn: ["id": nonDefaultSequence],
            estimatedRowCount: 42
        )
    }

    static var renamedSequenceTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("id", primaryKey: true)],
            sequencesByColumn: ["id": renamedSequence]
        )
    }

    static var identityAlwaysTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("id", primaryKey: true, identity: .always), column("label", "text")]
        )
    }

    static var identityByDefaultTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("id", primaryKey: true, identity: .byDefault), column("label", "text")]
        )
    }

    static var generatedColumnTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [
                column("id", primaryKey: true),
                column("price", "numeric(10,2)"),
                column("price_with_tax", "numeric(10,2)", generated: true)
            ]
        )
    }

    /// One partial index whose predicate contains a literal equal to the source table name, one
    /// expression index, one GIN index. The predicate literal must survive untouched.
    static var threeIndexTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("id", primaryKey: true), column("email", "text"), column("payload", "jsonb")],
            indexes: [
                PluginIndexInfo(
                    name: "idx_orders_source",
                    columns: ["id"],
                    isUnique: false,
                    isPrimary: false,
                    type: "btree",
                    columnPrefixes: nil,
                    whereClause: "source = 'orders'",
                    descendingColumns: nil
                ),
                PluginIndexInfo(name: "idx_orders_lower_email", columns: ["lower(email)"]),
                PluginIndexInfo(
                    name: "idx_orders_payload",
                    columns: ["payload"],
                    isUnique: false,
                    isPrimary: false,
                    type: "gin",
                    columnPrefixes: nil,
                    whereClause: nil,
                    descendingColumns: nil
                )
            ]
        )
    }

    /// Source table named `order` with an index whose name embeds `orders`, the pair that breaks
    /// a naive token replacement.
    static var awkwardlyNamedTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("id", primaryKey: true)],
            indexes: [PluginIndexInfo(name: "idx_order_orders_id", columns: ["id"])]
        )
    }

    static var commentedTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("id", primaryKey: true)],
            tableComment: "Customer orders, don't drop"
        )
    }

    static var rowLevelSecurityOwnedTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("id", primaryKey: true)],
            hasRowLevelSecurity: true,
            isOwner: true
        )
    }

    static var rowLevelSecurityForeignTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("id", primaryKey: true)],
            hasRowLevelSecurity: true,
            isOwner: false
        )
    }

    static var partitionedTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("id", primaryKey: true)],
            isPartitioned: true
        )
    }

    static var emptyTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("id", primaryKey: true)],
            estimatedRowCount: 0
        )
    }

    /// The shape the PostgreSQL driver actually emits for a composite key: one row per column,
    /// sharing the constraint name. Points at a different table so this fixture exercises
    /// grouping only, not the self-referencing rewrite.
    static var compositeForeignKeyTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("tenant_id"), column("order_no")],
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "line_customer_fkey",
                    column: "tenant_id",
                    referencedTable: "customers",
                    referencedColumn: "tenant_id",
                    referencedSchema: "public"
                ),
                PluginForeignKeyInfo(
                    name: "line_customer_fkey",
                    column: "order_no",
                    referencedTable: "customers",
                    referencedColumn: "order_no",
                    referencedSchema: "public"
                )
            ]
        )
    }

    static var selfReferencingTable: DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [column("id", primaryKey: true), column("parent_id")],
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "orders_parent_fkey",
                    column: "parent_id",
                    referencedTable: "orders",
                    referencedColumn: "id",
                    referencedSchema: "public",
                    onDelete: "CASCADE",
                    onUpdate: "NO ACTION"
                )
            ]
        )
    }
}
