//
//  GeneratorRegistry.swift
//  TablePro
//

import Foundation

struct GeneratorRegistry: Sendable {
    struct Entry: Sendable {
        let identifier: String
        let paramSchema: ParamSchema
        let make: @Sendable (Data, GenerationColumn, UInt64) throws -> any ValueGenerator
    }

    private var entries: [String: Entry] = [:]

    init() {}

    var identifiers: [String] { entries.keys.sorted() }

    func contains(_ identifier: String) -> Bool { entries[identifier] != nil }

    func paramSchema(for identifier: String) -> ParamSchema? { entries[identifier]?.paramSchema }

    mutating func register<Generator: ValueGenerator>(_ type: Generator.Type) {
        entries[type.identifier] = Entry(
            identifier: type.identifier,
            paramSchema: type.paramSchema,
            make: { params, column, seed in try type.init(params: params, column: column, seed: seed) }
        )
    }

    func make(
        identifier: String,
        params: Data,
        column: GenerationColumn,
        seed: UInt64
    ) throws -> any ValueGenerator {
        guard let entry = entries[identifier] else {
            throw GenerationError.unknownGenerator(identifier: identifier)
        }
        return try entry.make(params, column, seed)
    }
}
