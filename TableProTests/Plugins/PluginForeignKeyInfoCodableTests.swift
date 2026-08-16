//
//  PluginForeignKeyInfoCodableTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PluginForeignKeyInfo Codable")
struct PluginForeignKeyInfoCodableTests {
    // Phase 2 of the ABI v20 work adds non-optional `localColumns` and
    // `referencedColumns` arrays. Synthesized Codable would then throw
    // keyNotFound on every v19 payload, so the conformance becomes
    // hand-written. These fixtures are what prove the replacement kept old
    // payloads decodable and the encoded key set intact.

    private static let v19Keys: Set<String> = [
        "name", "column", "referencedTable", "referencedColumn",
        "referencedSchema", "onDelete", "onUpdate",
    ]

    private static let v19Fixture = Data("""
    {
        "name": "fk_orders_user",
        "column": "user_id",
        "referencedTable": "users",
        "referencedColumn": "id",
        "referencedSchema": "public",
        "onDelete": "CASCADE",
        "onUpdate": "RESTRICT"
    }
    """.utf8)

    @Test("A v19 payload carrying only v19 keys still decodes with every field intact")
    func v19FixtureDecodes() throws {
        let decoded = try JSONDecoder().decode(PluginForeignKeyInfo.self, from: Self.v19Fixture)

        #expect(decoded.name == "fk_orders_user")
        #expect(decoded.column == "user_id")
        #expect(decoded.referencedTable == "users")
        #expect(decoded.referencedColumn == "id")
        #expect(decoded.referencedSchema == "public")
        #expect(decoded.onDelete == "CASCADE")
        #expect(decoded.onUpdate == "RESTRICT")
    }

    @Test("A payload omitting referencedSchema decodes it as nil")
    func v19FixtureWithoutSchemaDecodes() throws {
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

        #expect(decoded.referencedSchema == nil)
        #expect(decoded.onDelete == "NO ACTION")
    }

    @Test("A fully populated value encodes exactly the v19 key set")
    func encodedKeySetMatchesV19() throws {
        let key = PluginForeignKeyInfo(
            name: "fk_orders_user",
            column: "user_id",
            referencedTable: "users",
            referencedColumn: "id",
            referencedSchema: "public",
            onDelete: "CASCADE",
            onUpdate: "RESTRICT"
        )
        let data = try JSONEncoder().encode(key)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == Self.v19Keys)
    }

    @Test("Every v19 key survives an encode then decode round trip")
    func v19FixtureSurvivesReEncoding() throws {
        let decoded = try JSONDecoder().decode(PluginForeignKeyInfo.self, from: Self.v19Fixture)
        let reEncoded = try JSONEncoder().encode(decoded)
        let object = try #require(try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any])

        #expect(Set(object.keys) == Self.v19Keys)
    }
}
