//
//  SchemaFactsAssemblerTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("SchemaFactsAssembler")
struct SchemaFactsAssemblerTests {
    private func assemble(
        databaseType: DatabaseType = .postgresql,
        columns: [PluginColumnInfo],
        foreignKeys: [PluginForeignKeyInfo] = [],
        indexes: [PluginIndexInfo] = []
    ) -> GenerationTable {
        SchemaFactsAssembler(databaseType: databaseType).assemble(
            schema: "public",
            table: "orders",
            columns: columns,
            foreignKeys: foreignKeys,
            indexes: indexes
        )
    }

    private func column(_ table: GenerationTable, _ name: String) throws -> GenerationColumn {
        try #require(table.columns.first { $0.name == name })
    }

    @Test("A varchar length comes from the native type parser, not from the app")
    func lengthComesFromParser() throws {
        let table = assemble(columns: [PluginColumnInfo(name: "code", dataType: "varchar(64)")])
        let code = try column(table, "code")
        #expect(code.type.base == .string)
        #expect(code.type.length == 64)
        #expect(code.maxLength == 64)
    }

    @Test("An identity column carries its kind and is server assigned when ALWAYS")
    func identityColumn() throws {
        let table = assemble(columns: [
            PluginColumnInfo(
                name: "id",
                dataType: "bigint",
                isNullable: false,
                isPrimaryKey: true,
                identityKind: .always,
                checkExpressions: [],
                sequenceName: "orders_id_seq"
            ),
            PluginColumnInfo(name: "legacy_id", dataType: "bigint", identityKind: .byDefault, checkExpressions: [])
        ])
        let identity = try column(table, "id")
        #expect(identity.isIdentity)
        #expect(identity.identityKind == .always)
        #expect(identity.isServerAssigned)
        #expect(identity.sequenceName == "orders_id_seq")

        let byDefault = try column(table, "legacy_id")
        #expect(byDefault.isIdentity)
        #expect(!byDefault.isServerAssigned)
    }

    @Test("A generated column is server assigned and never gets a generator")
    func generatedColumn() throws {
        let table = assemble(columns: [
            PluginColumnInfo(name: "total", dataType: "numeric(10,2)", isGenerated: true)
        ])
        let total = try column(table, "total")
        #expect(total.isGenerated)
        #expect(total.isServerAssigned)
        #expect(total.type.precision == 10)
        #expect(total.type.scale == 2)
    }

    @Test("An enum column carries its allowed values")
    func enumColumn() throws {
        let table = assemble(
            databaseType: .mysql,
            columns: [
                PluginColumnInfo(
                    name: "status",
                    dataType: "enum('new','paid','shipped')",
                    allowedValues: ["new", "paid", "shipped"]
                )
            ]
        )
        let status = try column(table, "status")
        #expect(status.type.base == .enumeration)
        #expect(status.allowedValues == ["new", "paid", "shipped"])
    }

    @Test("A nullable single-column foreign key resolves to its parent")
    func nullableForeignKey() throws {
        let table = assemble(
            columns: [PluginColumnInfo(name: "customer_id", dataType: "bigint", isNullable: true)],
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "orders_customer_fk",
                    column: "customer_id",
                    referencedTable: "customers",
                    referencedColumn: "id",
                    referencedSchema: "public"
                )
            ]
        )
        let customer = try column(table, "customer_id")
        let key = try #require(customer.foreignKey)
        #expect(key.referencedTable == "customers")
        #expect(key.referencedColumn == "id")
        #expect(key.referencedSchema == "public")
        #expect(!key.isComposite)
        #expect(customer.isNullable)
    }

    @Test("A composite foreign key is marked composite on every member column")
    func compositeForeignKey() throws {
        let table = assemble(
            columns: [
                PluginColumnInfo(name: "tenant_id", dataType: "bigint", isNullable: false),
                PluginColumnInfo(name: "customer_id", dataType: "bigint", isNullable: false)
            ],
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "orders_customer_fk",
                    localColumns: ["tenant_id", "customer_id"],
                    referencedTable: "customers",
                    referencedColumns: ["tenant_id", "id"]
                )
            ]
        )
        let tenant = try column(table, "tenant_id")
        let customer = try column(table, "customer_id")
        #expect(try #require(tenant.foreignKey).isComposite)
        #expect(tenant.referencedColumn == "tenant_id")
        #expect(customer.referencedColumn == "id")
        #expect(table.foreignKeys.count == 1)
    }

    @Test("A column in two unique constraints keeps both names")
    func columnInTwoUniqueConstraints() throws {
        let table = assemble(
            columns: [
                PluginColumnInfo(
                    name: "email",
                    dataType: "varchar(255)",
                    checkExpressions: [],
                    uniqueConstraints: ["orders_email_key", "orders_tenant_email_key"]
                ),
                PluginColumnInfo(
                    name: "tenant_id",
                    dataType: "bigint",
                    checkExpressions: [],
                    uniqueConstraints: ["orders_tenant_email_key"]
                )
            ],
            indexes: [
                PluginIndexInfo(name: "orders_email_key", columns: ["email"], isUnique: true),
                PluginIndexInfo(
                    name: "orders_tenant_email_key",
                    columns: ["tenant_id", "email"],
                    isUnique: true
                )
            ]
        )
        let email = try column(table, "email")
        #expect(email.uniqueConstraints == ["orders_email_key", "orders_tenant_email_key"])
        #expect(email.requiresUniqueValues)

        let tenant = try column(table, "tenant_id")
        #expect(!tenant.requiresUniqueValues)
        #expect(table.compositeUniqueConstraints.map(\.name) == ["orders_tenant_email_key"])
    }

    @Test("Unique arity falls back to the column lists when no index is reported")
    func uniqueArityWithoutIndexes() throws {
        let table = assemble(columns: [
            PluginColumnInfo(name: "a", dataType: "int", checkExpressions: [], uniqueConstraints: ["pair"]),
            PluginColumnInfo(name: "b", dataType: "int", checkExpressions: [], uniqueConstraints: ["pair"]),
            PluginColumnInfo(name: "c", dataType: "int", checkExpressions: [], uniqueConstraints: ["solo"])
        ])
        #expect(!(try column(table, "a").requiresUniqueValues))
        #expect(try column(table, "c").requiresUniqueValues)
        #expect(table.compositeUniqueConstraints.map(\.columns) == [["a", "b"]])
    }

    @Test("A single-column primary key requires distinct values, a composite one does not")
    func primaryKeyUniqueness() throws {
        let single = assemble(columns: [
            PluginColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true)
        ])
        #expect(try column(single, "id").requiresUniqueValues)

        let composite = assemble(columns: [
            PluginColumnInfo(name: "a", dataType: "int", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: "b", dataType: "int", isNullable: false, isPrimaryKey: true)
        ])
        #expect(!(try column(composite, "a").requiresUniqueValues))
        #expect(composite.primaryKeyColumns == ["a", "b"])
    }

    @Test("CHECK expressions are carried verbatim")
    func checkExpressions() throws {
        let table = assemble(columns: [
            PluginColumnInfo(name: "qty", dataType: "int", checkExpressions: ["(qty > 0)", "(qty < 1000)"])
        ])
        #expect(try column(table, "qty").checkExpressions == ["(qty > 0)", "(qty < 1000)"])
    }

    @Test("Empty driver metadata degrades to a usable column")
    func emptyMetadataDegrades() throws {
        let table = assemble(columns: [PluginColumnInfo(name: "note", dataType: "text")])
        let note = try column(table, "note")
        #expect(note.checkExpressions.isEmpty)
        #expect(note.sequenceName == nil)
        #expect(note.uniqueConstraints.isEmpty)
        #expect(note.foreignKey == nil)
        #expect(!note.requiresUniqueValues)
        #expect(table.compositeUniqueConstraints.isEmpty)
        #expect(table.primaryKeyColumns.isEmpty)
    }

    @Test("A vendor with no native type parser keeps the declared type verbatim")
    func unknownVendorKeepsNativeType() throws {
        let table = assemble(
            databaseType: DatabaseType(rawValue: "unheard-of"),
            columns: [PluginColumnInfo(name: "value", dataType: "SOMETYPE(9)")]
        )
        let value = try column(table, "value")
        #expect(value.type.base == .unknown)
        #expect(value.type.native == "SOMETYPE(9)")
        #expect(value.maxLength == nil)
    }

    @Test("The table carries the vendor family it was assembled for")
    func tableCarriesVendor() {
        #expect(assemble(databaseType: .mysql, columns: []).vendor == .mysql)
        #expect(assemble(databaseType: DatabaseType(rawValue: "unheard-of"), columns: []).vendor == nil)
    }
}
