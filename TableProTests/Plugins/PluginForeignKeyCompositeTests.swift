//
//  PluginForeignKeyCompositeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PluginForeignKeyInfo composite columns")
struct PluginForeignKeyCompositeTests {
    @Test("The v19 initializer mirrors its single column into the composite arrays")
    func singleColumnInitPopulatesArrays() {
        let key = PluginForeignKeyInfo(
            name: "fk_orders_user",
            column: "user_id",
            referencedTable: "users",
            referencedColumn: "id"
        )

        #expect(key.localColumns == ["user_id"])
        #expect(key.referencedColumns == ["id"])
        #expect(key.column == key.localColumns.first)
        #expect(key.referencedColumn == key.referencedColumns.first)
    }

    @Test("The composite initializer derives the singular fields from the first elements")
    func compositeInitDerivesSingularFields() {
        let key = PluginForeignKeyInfo(
            name: "fk_line_item",
            localColumns: ["order_id", "line_no"],
            referencedTable: "order_lines",
            referencedColumns: ["order_id", "seq"],
            referencedSchema: "sales",
            onDelete: "CASCADE"
        )

        #expect(key.localColumns == ["order_id", "line_no"])
        #expect(key.referencedColumns == ["order_id", "seq"])
        #expect(key.column == "order_id")
        #expect(key.referencedColumn == "order_id")
        #expect(key.referencedSchema == "sales")
        #expect(key.onDelete == "CASCADE")
        #expect(key.onUpdate == "NO ACTION")
    }

    @Test("Empty composite arrays leave the singular fields empty rather than trapping")
    func emptyCompositeArraysDoNotTrap() {
        let key = PluginForeignKeyInfo(
            name: "fk_empty",
            localColumns: [],
            referencedTable: "users",
            referencedColumns: []
        )

        #expect(key.column.isEmpty)
        #expect(key.referencedColumn.isEmpty)
        #expect(key.localColumns.isEmpty)
    }

    @Test("A v19 payload decodes with the composite arrays derived from the singular keys")
    func v19PayloadBackfillsCompositeArrays() throws {
        let json = Data("""
        {
            "name": "fk_orders_user",
            "column": "user_id",
            "referencedTable": "users",
            "referencedColumn": "id",
            "onDelete": "NO ACTION",
            "onUpdate": "NO ACTION"
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PluginForeignKeyInfo.self, from: json)

        #expect(decoded.localColumns == ["user_id"])
        #expect(decoded.referencedColumns == ["id"])
    }

    @Test("A composite key round-trips through JSON with both arrays intact")
    func compositeRoundTrips() throws {
        let key = PluginForeignKeyInfo(
            name: "fk_line_item",
            localColumns: ["order_id", "line_no"],
            referencedTable: "order_lines",
            referencedColumns: ["order_id", "seq"]
        )
        let decoded = try JSONDecoder().decode(
            PluginForeignKeyInfo.self,
            from: JSONEncoder().encode(key)
        )

        #expect(decoded.localColumns == ["order_id", "line_no"])
        #expect(decoded.referencedColumns == ["order_id", "seq"])
        #expect(decoded.column == "order_id")
    }
}

@Suite("PluginColumnInfo generation metadata")
struct PluginColumnInfoGenerationMetadataTests {
    @Test("The v19 initializer leaves the generation metadata empty")
    func v19InitLeavesMetadataEmpty() {
        let column = PluginColumnInfo(name: "id", dataType: "INTEGER")

        #expect(column.checkExpressions.isEmpty)
        #expect(column.sequenceName == nil)
        #expect(column.uniqueConstraints.isEmpty)
    }

    @Test("The extended initializer sets the generation metadata")
    func extendedInitSetsMetadata() {
        let column = PluginColumnInfo(
            name: "age",
            dataType: "INTEGER",
            isNullable: false,
            checkExpressions: ["age >= 0", "age < 150"],
            sequenceName: "public.age_seq",
            uniqueConstraints: ["uq_person_age"]
        )

        #expect(column.checkExpressions == ["age >= 0", "age < 150"])
        #expect(column.sequenceName == "public.age_seq")
        #expect(column.uniqueConstraints == ["uq_person_age"])
        #expect(column.name == "age")
        #expect(!column.isNullable)
    }

    @Test("Generation metadata round-trips through JSON")
    func metadataRoundTrips() throws {
        let column = PluginColumnInfo(
            name: "age",
            dataType: "INTEGER",
            checkExpressions: ["age >= 0"],
            sequenceName: "public.age_seq",
            uniqueConstraints: ["uq_person_age"]
        )
        let decoded = try JSONDecoder().decode(
            PluginColumnInfo.self,
            from: JSONEncoder().encode(column)
        )

        #expect(decoded.checkExpressions == ["age >= 0"])
        #expect(decoded.sequenceName == "public.age_seq")
        #expect(decoded.uniqueConstraints == ["uq_person_age"])
    }

    // The hand-written encoder is the half a decode test cannot reach: a field
    // missing from `encode(to:)` still round-trips through the fields that are
    // there, so the key set has to be asserted directly.
    @Test("A value carrying generation metadata encodes every new key")
    func metadataKeysAppearInEncodedPayload() throws {
        let column = PluginColumnInfo(
            name: "age",
            dataType: "INTEGER",
            checkExpressions: ["age >= 0"],
            sequenceName: "public.age_seq",
            uniqueConstraints: ["uq_person_age"]
        )
        let data = try JSONEncoder().encode(column)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys).isSuperset(of: ["checkExpressions", "sequenceName", "uniqueConstraints"]))
    }

    @Test("A composite foreign key encodes both column arrays")
    func compositeKeysAppearInEncodedPayload() throws {
        let key = PluginForeignKeyInfo(
            name: "fk_line_item",
            localColumns: ["order_id", "line_no"],
            referencedTable: "order_lines",
            referencedColumns: ["order_id", "seq"]
        )
        let data = try JSONEncoder().encode(key)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys).isSuperset(of: ["localColumns", "referencedColumns"]))
    }
}
