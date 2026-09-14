//
//  GeneratorRegistry.swift
//  TablePro
//

import Foundation

struct GeneratorRegistry: Sendable {
    struct Entry: Sendable {
        let identifier: String
        let paramSchema: ParamSchema
        let excludesColumnFromInsert: Bool
        let producesKind: GenerationOutputKind
        let make: @Sendable (Data, GenerationColumn, UInt64) throws -> any ValueGenerator
    }

    private var entries: [String: Entry] = [:]

    init() {}

    var identifiers: [String] { entries.keys.sorted() }

    func contains(_ identifier: String) -> Bool { entries[identifier] != nil }

    func paramSchema(for identifier: String) -> ParamSchema? { entries[identifier]?.paramSchema }

    func excludesColumnFromInsert(_ identifier: String) -> Bool {
        entries[identifier]?.excludesColumnFromInsert ?? false
    }

    func producesKind(for identifier: String) -> GenerationOutputKind? {
        entries[identifier]?.producesKind
    }

    /// Every registered identifier whose declared output kind suits `base`.
    /// This is the same predicate `GenerationProfileValidator` refuses an
    /// unsuitable pairing with, so a generator the grid offers here never
    /// fails validation for that reason alone.
    func identifiers(suitableFor base: TransferBaseType) -> [String] {
        entries.values.filter { $0.producesKind.suits(base) }.map(\.identifier).sorted()
    }

    mutating func register<Generator: ValueGenerator>(_ type: Generator.Type) {
        entries[type.identifier] = Entry(
            identifier: type.identifier,
            paramSchema: type.paramSchema,
            excludesColumnFromInsert: type.excludesColumnFromInsert,
            producesKind: type.producesKind,
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
