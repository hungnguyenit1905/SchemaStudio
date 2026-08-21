import Foundation
import TableProPluginKit
import Testing

@Suite("PluginColumnInfo Codable")
struct PluginColumnInfoCodableTests {
    @Test("allowedValues round-trips through JSON encoding")
    func allowedValuesRoundTrip() throws {
        let original = PluginColumnInfo(
            name: "status",
            dataType: "ENUM",
            allowedValues: ["active", "inactive", "pending"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: data)
        #expect(decoded.allowedValues == ["active", "inactive", "pending"])
    }

    @Test("nil allowedValues encodes and decodes back to nil")
    func nilAllowedValuesRoundTrip() throws {
        let original = PluginColumnInfo(name: "id", dataType: "INTEGER")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: data)
        #expect(decoded.allowedValues == nil)
    }

    @Test("decoding a payload without allowedValues keeps it nil for forward compatibility")
    func legacyPayloadDecodesToNilAllowedValues() throws {
        let legacyJson = Data("""
        {
            "name": "id",
            "dataType": "INTEGER",
            "isNullable": false,
            "isPrimaryKey": true,
            "isGenerated": false
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: legacyJson)
        #expect(decoded.allowedValues == nil)
        #expect(decoded.name == "id")
        #expect(decoded.isPrimaryKey)
    }

    // MARK: - v19 wire compatibility
    //
    // Nothing in the repo currently encodes or decodes PluginColumnInfo, so
    // these guard the published Codable conformance rather than a live
    // persistence path. Phase 2 of the ABI v20 work replaces the synthesized
    // conformance with a hand-written init(from:)/encode(to:) in order to add
    // non-optional array fields without breaking v19 payloads; the fixture
    // below is what proves that replacement kept old payloads decodable. It is
    // a hand-written JSON literal on purpose: a re-encode of a live value would
    // pass under any implementation and prove nothing.

    private static let v19Keys: Set<String> = [
        "name", "dataType", "isNullable", "isPrimaryKey", "defaultValue", "extra",
        "charset", "collation", "comment", "identityKind", "isGenerated", "allowedValues",
    ]

    private static let v19Fixture = Data("""
    {
        "name": "status",
        "dataType": "ENUM",
        "isNullable": false,
        "isPrimaryKey": false,
        "defaultValue": "'active'",
        "extra": "on update",
        "charset": "utf8mb4",
        "collation": "utf8mb4_general_ci",
        "comment": "row status",
        "identityKind": "BY DEFAULT",
        "isGenerated": false,
        "allowedValues": ["active", "inactive"]
    }
    """.utf8)

    @Test("A v19 payload carrying only v19 keys still decodes with every field intact")
    func v19FixtureDecodes() throws {
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: Self.v19Fixture)

        #expect(decoded.name == "status")
        #expect(decoded.dataType == "ENUM")
        #expect(!decoded.isNullable)
        #expect(!decoded.isPrimaryKey)
        #expect(decoded.defaultValue == "'active'")
        #expect(decoded.extra == "on update")
        #expect(decoded.charset == "utf8mb4")
        #expect(decoded.collation == "utf8mb4_general_ci")
        #expect(decoded.comment == "row status")
        #expect(decoded.identityKind == .byDefault)
        #expect(!decoded.isGenerated)
        #expect(decoded.allowedValues == ["active", "inactive"])
    }

    @Test("A fully populated value encodes exactly the v19 key set")
    func encodedKeySetMatchesV19() throws {
        let column = PluginColumnInfo(
            name: "status",
            dataType: "ENUM",
            isNullable: false,
            isPrimaryKey: false,
            defaultValue: "'active'",
            extra: "on update",
            charset: "utf8mb4",
            collation: "utf8mb4_general_ci",
            comment: "row status",
            identityKind: .byDefault,
            isGenerated: false,
            allowedValues: ["active", "inactive"]
        )
        let data = try JSONEncoder().encode(column)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == Self.v19Keys)
    }

    @Test("Every v19 key survives an encode then decode round trip")
    func v19FixtureSurvivesReEncoding() throws {
        let decoded = try JSONDecoder().decode(PluginColumnInfo.self, from: Self.v19Fixture)
        let reEncoded = try JSONEncoder().encode(decoded)
        let object = try #require(try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any])

        #expect(Set(object.keys) == Self.v19Keys)
    }
}
