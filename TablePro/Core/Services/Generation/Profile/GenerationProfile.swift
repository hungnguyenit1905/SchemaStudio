//
//  GenerationProfile.swift
//  TablePro
//

import Foundation

/// A saved configuration for a generation run. It stores **names**, never server
/// identifiers: an OID changes across a dump and restore, a table name does not.
struct GenerationProfile: Codable, Sendable, Hashable {
    static let currentVersion = 1

    var version: Int
    var name: String
    var seed: UInt64
    var tables: [GenerationTableProfile]

    init(
        version: Int = GenerationProfile.currentVersion,
        name: String,
        seed: UInt64,
        tables: [GenerationTableProfile]
    ) {
        self.version = version
        self.name = name
        self.seed = seed
        self.tables = tables
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard decodedVersion <= Self.currentVersion else {
            throw GenerationError.unsupportedProfileVersion(
                found: decodedVersion,
                supported: Self.currentVersion
            )
        }
        version = Self.currentVersion
        name = try container.decode(String.self, forKey: .name)
        seed = try container.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0
        tables = try container.decodeIfPresent([GenerationTableProfile].self, forKey: .tables) ?? []
    }

    func table(named table: String, schema: String?) -> GenerationTableProfile? {
        tables.first { $0.table == table && $0.schema == schema }
    }
}

struct GenerationTableProfile: Codable, Sendable, Hashable {
    var schema: String?
    var table: String
    var rowCount: Int
    var emptyFirst: Bool
    var columns: [GenerationColumnProfile]

    init(
        schema: String? = nil,
        table: String,
        rowCount: Int,
        emptyFirst: Bool = false,
        columns: [GenerationColumnProfile]
    ) {
        self.schema = schema
        self.table = table
        self.rowCount = rowCount
        self.emptyFirst = emptyFirst
        self.columns = columns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
        table = try container.decode(String.self, forKey: .table)
        rowCount = try container.decodeIfPresent(Int.self, forKey: .rowCount) ?? 0
        emptyFirst = try container.decodeIfPresent(Bool.self, forKey: .emptyFirst) ?? false
        columns = try container.decodeIfPresent([GenerationColumnProfile].self, forKey: .columns) ?? []
    }

    var reference: GenerationTableReference {
        GenerationTableReference(schema: schema, table: table)
    }

    func column(named column: String) -> GenerationColumnProfile? {
        columns.first { $0.column == column }
    }
}

/// `params` is a `JSONValue` so a generator's heterogeneous settings survive a
/// decode and re-encode without the profile knowing any generator's shape. Each
/// generator decodes its own struct from the re-serialized bytes.
struct GenerationColumnProfile: Codable, Sendable, Hashable {
    var column: String
    var generator: String
    var params: JSONValue
    var common: CommonParams

    init(
        column: String,
        generator: String,
        params: JSONValue = .object([:]),
        common: CommonParams = .none
    ) {
        self.column = column
        self.generator = generator
        self.params = params
        self.common = common
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        column = try container.decode(String.self, forKey: .column)
        generator = try container.decode(String.self, forKey: .generator)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params) ?? .object([:])
        common = try container.decodeIfPresent(CommonParams.self, forKey: .common) ?? .none
    }

    var paramData: Data {
        guard let text = params.jsonText else { return Data() }
        return Data(text.utf8)
    }
}

struct GenerationTableReference: Codable, Sendable, Hashable {
    let schema: String?
    let table: String

    var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return table }
        return "\(schema).\(table)"
    }
}
