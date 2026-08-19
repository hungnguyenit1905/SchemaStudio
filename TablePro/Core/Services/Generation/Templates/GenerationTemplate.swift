//
//  GenerationTemplate.swift
//  TablePro
//

import Foundation

/// A profile authored against a shape rather than against one database. A
/// template names the tables and columns it expects; applying it matches that
/// shape onto the real schema. It carries no schema name and no row of its own,
/// so the same template fits any database whose tables are named the same way.
struct GenerationTemplate: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var summary: String
    var tables: [GenerationTemplateTable]

    init(id: String, name: String, summary: String, tables: [GenerationTemplateTable]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.tables = tables
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tables = try container.decodeIfPresent([GenerationTemplateTable].self, forKey: .tables) ?? []
    }
}

struct GenerationTemplateTable: Codable, Sendable, Hashable {
    var table: String
    var rowCount: Int
    var columns: [GenerationTemplateColumn]

    init(table: String, rowCount: Int, columns: [GenerationTemplateColumn]) {
        self.table = table
        self.rowCount = rowCount
        self.columns = columns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        table = try container.decode(String.self, forKey: .table)
        rowCount = try container.decodeIfPresent(Int.self, forKey: .rowCount) ?? 100
        columns = try container.decodeIfPresent([GenerationTemplateColumn].self, forKey: .columns) ?? []
    }
}

struct GenerationTemplateColumn: Codable, Sendable, Hashable {
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
