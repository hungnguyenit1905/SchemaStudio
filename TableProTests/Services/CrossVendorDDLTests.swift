import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Cross-vendor DDL")
struct CrossVendorDDLTests {
    private func build(
        table: String = "orders",
        columns: [PluginColumnInfo],
        indexes: [PluginIndexInfo] = [],
        foreignKeys: [PluginForeignKeyInfo] = [],
        source: DatabaseType,
        target: DatabaseType,
        options: TransferMappingOptions = TransferMappingOptions()
    ) -> TransferTableStructure {
        let mapper = TransferTypeMapper(sourceType: source, targetType: target, options: options)
        return TransferStructureBuilder.build(
            table: table,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            targetSchema: nil,
            mapper: mapper.isSameDialect ? nil : mapper
        )
    }

    private func enumColumn(_ name: String = "status") -> PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: "enum('new','paid','shipped')",
            isNullable: false,
            allowedValues: ["new", "paid", "shipped"]
        )
    }

    // MARK: - Enumerated columns

    @Test("A MySQL enum becomes a varchar carrying its value list to PostgreSQL")
    func mysqlEnumToPostgresCheck() {
        let structure = build(columns: [enumColumn()], source: .mysql, target: .postgresql)
        let column = structure.definition.columns.first

        #expect(column?.dataType == "varchar(7)")
        #expect(column?.allowedValues == ["new", "paid", "shipped"])
        #expect(structure.enumTypes.isEmpty)
    }

    @Test("A MySQL enum becomes a named type on PostgreSQL when asked")
    func mysqlEnumToPostgresNativeType() {
        var options = TransferMappingOptions()
        options.mysqlEnumAs = .nativeType

        let structure = build(columns: [enumColumn()], source: .mysql, target: .postgresql, options: options)
        let column = structure.definition.columns.first

        #expect(column?.dataType == "orders_status")
        #expect(column?.allowedValues == nil)
        #expect(structure.enumTypes == [TransferEnumType(name: "orders_status", values: ["new", "paid", "shipped"])])
    }

    /// Only PostgreSQL has a standalone enumerated type, so the same option has
    /// to fall back rather than name a type the target cannot declare.
    @Test("A named type falls back to a CHECK on a target without one")
    func nativeTypeFallsBackOnSqlite() {
        var options = TransferMappingOptions()
        options.mysqlEnumAs = .nativeType

        let structure = build(columns: [enumColumn()], source: .mysql, target: .sqlite, options: options)

        #expect(structure.enumTypes.isEmpty)
        #expect(structure.definition.columns.first?.allowedValues == ["new", "paid", "shipped"])
    }

    @Test("Plain text drops the value list and warns")
    func plainTextDropsValues() {
        var options = TransferMappingOptions()
        options.mysqlEnumAs = .plainText

        let structure = build(columns: [enumColumn()], source: .mysql, target: .postgresql, options: options)

        #expect(structure.definition.columns.first?.allowedValues == nil)
        #expect(structure.warnings.contains { warning in
            if case .typeLossy = warning { return true }
            return false
        })
    }

    /// MySQL writes the value list into the type itself, so a second copy
    /// alongside it would render a redundant CHECK.
    @Test("An enum reaching MySQL keeps its list inside the type")
    func enumToMysqlKeepsInlineList() {
        let column = PluginColumnInfo(
            name: "status",
            dataType: "status_kind",
            isNullable: false,
            allowedValues: ["new", "paid"]
        )
        let structure = build(columns: [column], source: .postgresql, target: .mysql)

        #expect(structure.definition.columns.first?.allowedValues == nil)
    }

    @Test("Two columns naming the same type produce one type")
    func duplicateEnumTypesCollapse() {
        var options = TransferMappingOptions()
        options.mysqlEnumAs = .nativeType

        let structure = build(
            columns: [enumColumn("status"), enumColumn("status")],
            source: .mysql,
            target: .postgresql,
            options: options
        )

        #expect(structure.enumTypes.count == 1)
    }

    // MARK: - Structure across vendors

    @Test("A MySQL table maps column by column to PostgreSQL")
    func mysqlTableToPostgres() {
        let structure = build(
            columns: [
                PluginColumnInfo(
                    name: "id",
                    dataType: "bigint",
                    isNullable: false,
                    isPrimaryKey: true,
                    extra: "auto_increment"
                ),
                PluginColumnInfo(name: "title", dataType: "varchar(120)", isNullable: false),
                PluginColumnInfo(name: "is_paid", dataType: "tinyint(1)", isNullable: false),
                PluginColumnInfo(name: "notes", dataType: "longtext", isNullable: true)
            ],
            source: .mysql,
            target: .postgresql
        )

        #expect(structure.definition.columns.count == 4)
        #expect(structure.primaryKeyColumns == ["id"])
        #expect(structure.definition.columns.first?.autoIncrement == true)
        #expect(structure.definition.columns[1].dataType == "varchar(120)")
        #expect(structure.definition.columns[1].isNullable == false)
        #expect(structure.definition.columns[2].dataType == "boolean")
        #expect(structure.definition.columns[3].dataType == "text")
        #expect(structure.definition.columns[3].isNullable == true)
    }

    @Test("A PostgreSQL table maps column by column to MySQL")
    func postgresTableToMysql() {
        let structure = build(
            columns: [
                PluginColumnInfo(
                    name: "id",
                    dataType: "integer",
                    isNullable: false,
                    isPrimaryKey: true,
                    identityKind: .always
                ),
                PluginColumnInfo(name: "active", dataType: "boolean", isNullable: false),
                PluginColumnInfo(name: "body", dataType: "text", isNullable: true)
            ],
            source: .postgresql,
            target: .mysql
        )

        #expect(structure.definition.columns.count == 3)
        #expect(structure.definition.columns.first?.autoIncrement == true)
        #expect(structure.definition.columns[1].dataType == "tinyint(1)")
        #expect(structure.definition.columns[2].dataType == "longtext")
    }

    @Test("A generated column is left out of the target table")
    func generatedColumnExcluded() {
        let structure = build(
            columns: [
                PluginColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true),
                PluginColumnInfo(name: "total", dataType: "int", isNullable: true, isGenerated: true)
            ],
            source: .mysql,
            target: .postgresql
        )

        #expect(structure.definition.columns.map(\.name) == ["id"])
        #expect(structure.generatedColumns == ["total"])
    }

    // MARK: - Index and constraint names

    @Test("An index name over the PostgreSQL limit is shortened")
    func longIndexNameShortened() {
        let name = "idx_" + String(repeating: "customer_reference_", count: 5)
        let structure = build(
            columns: [PluginColumnInfo(name: "id", dataType: "int", isNullable: false)],
            indexes: [PluginIndexInfo(name: name, columns: ["id"], isUnique: false, isPrimary: false)],
            source: .mysql,
            target: .postgresql
        )

        let mapped = structure.indexes.first?.name
        #expect(mapped != name)
        #expect((mapped?.utf8.count ?? 0) <= 63)
    }

    @Test("Two long index names sharing a prefix stay distinct")
    func longIndexNamesStayDistinct() {
        let prefix = "idx_" + String(repeating: "a", count: 60)
        let structure = build(
            columns: [PluginColumnInfo(name: "id", dataType: "int", isNullable: false)],
            indexes: [
                PluginIndexInfo(name: prefix + "_created", columns: ["id"], isUnique: false, isPrimary: false),
                PluginIndexInfo(name: prefix + "_updated", columns: ["id"], isUnique: false, isPrimary: false)
            ],
            source: .mysql,
            target: .postgresql
        )

        let names = Set(structure.indexes.map(\.name))
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.utf8.count <= 63 })
    }

    /// A foreign key names the constraint it creates, so a shortened name has to
    /// come out the same on both passes or the constraint pass builds something
    /// the report no longer describes.
    @Test("A foreign key name is shortened the same way every time")
    func foreignKeyNameShortenedConsistently() {
        let name = "fk_" + String(repeating: "order_line_item_", count: 6)
        let foreignKey = PluginForeignKeyInfo(
            name: name,
            column: "order_id",
            referencedTable: "orders",
            referencedColumn: "id"
        )
        let columns = [PluginColumnInfo(name: "order_id", dataType: "int", isNullable: false)]

        let first = build(columns: columns, foreignKeys: [foreignKey], source: .mysql, target: .postgresql)
        let second = build(columns: columns, foreignKeys: [foreignKey], source: .mysql, target: .postgresql)

        #expect(first.foreignKeys.first?.name == second.foreignKeys.first?.name)
        #expect((first.foreignKeys.first?.name.utf8.count ?? 0) <= 63)
    }

    @Test("A same-vendor transfer leaves long names alone")
    func sameVendorKeepsNames() {
        let name = "idx_" + String(repeating: "a", count: 80)
        let structure = build(
            columns: [PluginColumnInfo(name: "id", dataType: "int", isNullable: false)],
            indexes: [PluginIndexInfo(name: name, columns: ["id"], isUnique: false, isPrimary: false)],
            source: .mysql,
            target: .mysql
        )

        #expect(structure.indexes.first?.name == name)
    }

    // MARK: - Step ordering

    /// A type outlives the table that names it, so a rerun has to drop the table
    /// first and then the type: a type still referenced by a column cannot go.
    @Test("Replacing an existing table drops the table before its types")
    func copyDropsTableBeforeTypes() {
        let steps = TransferModePlanner.plan(mode: .copy, options: TransferOptions(), targetExists: true)

        guard let dropTable = steps.firstIndex(of: .dropTargetTable),
              let dropTypes = steps.firstIndex(of: .dropTargetTypes),
              let createTypes = steps.firstIndex(of: .createTargetTypes),
              let createTable = steps.firstIndex(of: .createTargetTable) else {
            Issue.record("Expected the copy plan to carry both type steps")
            return
        }

        #expect(dropTable < dropTypes)
        #expect(dropTypes < createTypes)
        #expect(createTypes < createTable)
    }

    @Test("Creating a missing table declares its types first")
    func createDeclaresTypesFirst() {
        var options = TransferOptions()
        options.createTargetIfNotExists = true
        let steps = TransferModePlanner.plan(mode: .emptyThenTransfer, options: options, targetExists: false)

        guard let createTypes = steps.firstIndex(of: .createTargetTypes),
              let createTable = steps.firstIndex(of: .createTargetTable) else {
            Issue.record("Expected the create plan to declare types")
            return
        }

        #expect(createTypes < createTable)
    }

    @Test("Emptying an existing table touches no types")
    func truncateSkipsTypes() {
        let steps = TransferModePlanner.plan(mode: .emptyThenTransfer, options: TransferOptions(), targetExists: true)

        #expect(!steps.contains(.createTargetTypes))
        #expect(!steps.contains(.dropTargetTypes))
    }
}
