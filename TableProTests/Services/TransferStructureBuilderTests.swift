import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("TransferStructureBuilder")
struct TransferStructureBuilderTests {
    private func build(
        columns: [PluginColumnInfo],
        indexes: [PluginIndexInfo] = [],
        foreignKeys: [PluginForeignKeyInfo] = [],
        targetSchema: String? = nil
    ) -> TransferTableStructure {
        TransferStructureBuilder.build(
            table: "orders",
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            targetSchema: targetSchema
        )
    }

    @Test("A MySQL auto_increment column carries over as auto increment")
    func mysqlAutoIncrement() {
        let structure = build(columns: [
            PluginColumnInfo(
                name: "id",
                dataType: "int",
                isNullable: false,
                isPrimaryKey: true,
                defaultValue: nil,
                extra: "auto_increment"
            )
        ])
        #expect(structure.definition.columns.first?.autoIncrement == true)
        #expect(structure.autoIncrementColumns == ["id"])
        #expect(structure.primaryKeyColumns == ["id"])
    }

    @Test("A PostgreSQL identity column becomes auto increment and warns")
    func identityColumn() {
        let structure = build(columns: [
            PluginColumnInfo(
                name: "id",
                dataType: "integer",
                isNullable: false,
                isPrimaryKey: true,
                identityKind: .always
            )
        ])
        #expect(structure.definition.columns.first?.autoIncrement == true)
        #expect(structure.warnings.contains(.identityColumn("id")))
    }

    @Test("An auto increment column drops the source default")
    func autoIncrementDropsDefault() {
        let structure = build(columns: [
            PluginColumnInfo(
                name: "id",
                dataType: "integer",
                isNullable: false,
                isPrimaryKey: true,
                defaultValue: "nextval('orders_id_seq'::regclass)",
                identityKind: .byDefault
            )
        ])
        #expect(structure.definition.columns.first?.defaultValue == nil)
    }

    @Test("A generated column is neither created nor written")
    func generatedColumn() {
        let structure = build(columns: [
            PluginColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: "total", dataType: "int", isGenerated: true)
        ])
        #expect(structure.definition.columns.map(\.name) == ["id"])
        #expect(structure.generatedColumns == ["total"])
        #expect(structure.warnings.contains(.generatedColumn("total")))
        #expect(structure.writableColumns == ["id"])
    }

    @Test("The primary key index is not recreated as a plain index")
    func primaryKeyIndexDropped() {
        let structure = build(
            columns: [PluginColumnInfo(name: "id", dataType: "int", isPrimaryKey: true)],
            indexes: [
                PluginIndexInfo(name: "PRIMARY", columns: ["id"], isUnique: true, isPrimary: true),
                PluginIndexInfo(name: "orders_customer_idx", columns: ["customer_id"])
            ]
        )
        #expect(structure.indexes.map(\.name) == ["orders_customer_idx"])
    }

    @Test("A partial index keeps its predicate and its name")
    func partialIndex() {
        let structure = build(
            columns: [PluginColumnInfo(name: "id", dataType: "int")],
            indexes: [
                PluginIndexInfo(
                    name: "orders_open_idx",
                    columns: ["status"],
                    type: "BTREE",
                    whereClause: "status = 'open'"
                )
            ]
        )
        #expect(structure.indexes.first?.whereClause == "status = 'open'")
        #expect(structure.indexes.first?.name == "orders_open_idx")
    }

    @Test("A composite foreign key keeps its column order")
    func compositeForeignKey() {
        let structure = build(
            columns: [PluginColumnInfo(name: "id", dataType: "int")],
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "orders_customer_fk",
                    column: "tenant_id",
                    referencedTable: "customers",
                    referencedColumn: "tenant_id"
                ),
                PluginForeignKeyInfo(
                    name: "orders_customer_fk",
                    column: "customer_id",
                    referencedTable: "customers",
                    referencedColumn: "id"
                )
            ]
        )
        #expect(structure.foreignKeys.count == 1)
        #expect(structure.foreignKeys.first?.columns == ["tenant_id", "customer_id"])
        #expect(structure.foreignKeys.first?.referencedColumns == ["tenant_id", "id"])
    }

    @Test("A foreign key with a schema points at the target schema")
    func foreignKeySchemaRetargeted() {
        let structure = build(
            columns: [PluginColumnInfo(name: "id", dataType: "int")],
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "orders_customer_fk",
                    column: "customer_id",
                    referencedTable: "customers",
                    referencedColumn: "id",
                    referencedSchema: "staging"
                )
            ],
            targetSchema: "public"
        )
        #expect(structure.foreignKeys.first?.referencedSchema == "public")
    }

    @Test("CREATE TABLE carries no index and no foreign key")
    func createDefinitionIsColumnsOnly() {
        let structure = build(
            columns: [PluginColumnInfo(name: "id", dataType: "int", isPrimaryKey: true)],
            indexes: [PluginIndexInfo(name: "orders_customer_idx", columns: ["customer_id"])],
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "orders_customer_fk",
                    column: "customer_id",
                    referencedTable: "customers",
                    referencedColumn: "id"
                )
            ]
        )
        #expect(structure.definition.indexes.isEmpty)
        #expect(structure.definition.foreignKeys.isEmpty)
        #expect(structure.indexes.count == 1)
        #expect(structure.foreignKeys.count == 1)
    }
}
