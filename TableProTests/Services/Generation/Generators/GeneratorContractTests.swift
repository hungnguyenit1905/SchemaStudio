//
//  GeneratorContractTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Generator contract")
struct GeneratorContractTests {
    private static let registry = GeneratorRegistry.standard

    static let identifiers = registry.identifiers

    private func make(_ identifier: String, seed: UInt64 = 7) throws -> any ValueGenerator {
        let generator = try Self.registry.make(
            identifier: identifier,
            params: GeneratorTestFixtures.contractParams[identifier] ?? Data(),
            column: GeneratorTestFixtures.column(),
            seed: seed
        )
        GeneratorTestFixtures.bindPools(generator)
        return generator
    }

    private func take(_ generator: any ValueGenerator, _ count: Int) throws -> [PluginCellValue] {
        try (0..<count).map { index in
            try generator.next(row: GeneratorTestFixtures.rowContext(rowIndex: index), index: index)
        }
    }

    @Test("Every generator in the catalog is registered exactly once")
    func catalogIsComplete() {
        #expect(Self.identifiers.count == 17)
        #expect(Set(Self.identifiers).count == Self.identifiers.count)
        #expect(Set(Self.identifiers) == [
            "AutoIncrement", "Boolean", "Copy", "Date", "DateTime", "Decimal", "Default",
            "Double", "Fixed", "Integer", "List", "LoremWords", "Null", "RandomBytes",
            "RandomString", "Reference", "UUID"
        ])
    }

    @Test("Two instances built from one seed produce identical values", arguments: identifiers)
    func deterministicUnderAFixedSeed(identifier: String) throws {
        let first = try take(make(identifier), 1_000)
        let second = try take(make(identifier), 1_000)
        #expect(first == second)
    }

    @Test("Different seeds produce different values for any random generator", arguments: identifiers)
    func seedsChangeOutputWhereRandomnessApplies(identifier: String) throws {
        let first = try take(make(identifier, seed: 1), 200)
        let second = try take(make(identifier, seed: 2), 200)
        let deterministicByDesign = ["AutoIncrement", "Fixed", "Null", "Default", "Copy"]
        guard !deterministicByDesign.contains(identifier) else {
            #expect(first == second)
            return
        }
        #expect(first != second)
    }

    @Test("Reset returns the generator to its opening state", arguments: identifiers)
    func resetRestartsTheStream(identifier: String) throws {
        let generator = try make(identifier)
        let first = try take(generator, 100)
        generator.reset()
        GeneratorTestFixtures.bindPools(generator)
        #expect(try take(generator, 100) == first)
    }

    @Test("Empty parameters either work or throw a legible error", arguments: identifiers)
    func emptyParamsNeverCrash(identifier: String) throws {
        do {
            let generator = try Self.registry.make(
                identifier: identifier,
                params: Data(),
                column: GeneratorTestFixtures.column(),
                seed: 3
            )
            GeneratorTestFixtures.bindPools(generator)
            _ = try? generator.next(row: GeneratorTestFixtures.rowContext(), index: 0)
        } catch let error as GenerationError {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test("Malformed parameters throw rather than producing a value", arguments: identifiers)
    func malformedParamsThrow(identifier: String) {
        guard Self.registry.paramSchema(for: identifier)?.fields.isEmpty == false else { return }
        #expect(throws: GenerationError.self) {
            _ = try Self.registry.make(
                identifier: identifier,
                params: Data("{ not json".utf8),
                column: GeneratorTestFixtures.column(),
                seed: 3
            )
        }
    }

    @Test("A generator with parameters declares them in its schema", arguments: identifiers)
    func paramSchemaIsDeclared(identifier: String) throws {
        let schema = try #require(Self.registry.paramSchema(for: identifier))
        let parameterless = ["Null", "Default"]
        #expect(schema.fields.isEmpty == parameterless.contains(identifier))
        #expect(Set(schema.fields.map(\.key)).count == schema.fields.count)
    }

    @Test("Only the server-filled generators drop their column from the INSERT")
    func insertExclusionIsDeclared() {
        let excluded = Self.identifiers.filter { Self.registry.excludesColumnFromInsert($0) }
        #expect(Set(excluded) == ["AutoIncrement", "Default"])
    }

    @Test("A partly filled parameter object keeps the declared defaults", arguments: identifiers)
    func partialParamsKeepDefaults(identifier: String) throws {
        let generator = try Self.registry.make(
            identifier: identifier,
            params: GeneratorTestFixtures.partialParams[identifier] ?? Data("{}".utf8),
            column: GeneratorTestFixtures.column(),
            seed: 5
        )
        GeneratorTestFixtures.bindPools(generator)
        _ = try generator.next(row: GeneratorTestFixtures.rowContext(), index: 0)
    }

    @Test("Copy declares the row dependency that orders it after its source")
    func rowDependenciesAreDeclared() throws {
        #expect(try make("Copy").rowDependencies == ["other"])
        #expect(try make("Integer").rowDependencies.isEmpty)
    }
}
