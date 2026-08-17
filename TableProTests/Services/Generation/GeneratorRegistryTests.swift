//
//  GeneratorRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

private struct RegistryTestParams: Codable {
    let word: String
}

private final class EchoGenerator: ValueGenerator {
    static let identifier = "test.echo"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "word", label: "Word", type: .text, defaultValue: .string("hi")),
        ParamField(
            key: "shout",
            label: "Shout",
            type: .toggle,
            defaultValue: .bool(false),
            visibleWhen: ParamVisibility(key: "word", equalsAnyOf: [.string("hi")])
        )
    ])

    private let word: String

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        word = try GenerationParams.decode(
            RegistryTestParams.self,
            from: params,
            generator: Self.identifier,
            default: RegistryTestParams(word: "hi")
        ).word
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .text(word)
    }

    func reset() {}
}

@Suite("GeneratorRegistry")
struct GeneratorRegistryTests {
    private func column() -> GenerationColumn {
        let table = SchemaFactsAssembler(databaseType: .postgresql).assemble(
            schema: nil,
            table: "t",
            columns: [PluginColumnInfo(name: "c", dataType: "text")],
            foreignKeys: [],
            indexes: []
        )
        guard let resolved = table.column(named: "c") else { preconditionFailure("fixture column missing") }
        return resolved
    }

    private func registry() -> GeneratorRegistry {
        var registry = GeneratorRegistry()
        registry.register(EchoGenerator.self)
        return registry
    }

    @Test("A registered generator is constructed by identifier")
    func makesByIdentifier() throws {
        let params = try JSONEncoder().encode(RegistryTestParams(word: "there"))
        let generator = try registry().make(
            identifier: "test.echo",
            params: params,
            column: column(),
            seed: 1
        )
        #expect(try generator.next(row: RowContext(table: "t", rowIndex: 0), index: 0) == .text("there"))
    }

    @Test("Empty parameters fall back to the declared defaults")
    func emptyParamsUseDefaults() throws {
        let generator = try registry().make(identifier: "test.echo", params: Data(), column: column(), seed: 1)
        #expect(try generator.next(row: RowContext(table: "t", rowIndex: 0), index: 0) == .text("hi"))
    }

    @Test("An unknown identifier throws rather than returning a fallback generator")
    func unknownIdentifierThrows() {
        #expect(throws: GenerationError.unknownGenerator(identifier: "test.missing")) {
            _ = try registry().make(identifier: "test.missing", params: Data(), column: column(), seed: 1)
        }
    }

    @Test("Malformed parameters are reported against the generator that rejected them")
    func malformedParamsThrow() {
        #expect(throws: GenerationError.self) {
            _ = try registry().make(
                identifier: "test.echo",
                params: Data("not json".utf8),
                column: column(),
                seed: 1
            )
        }
    }

    @Test("The registry exposes identifiers and parameter schemas for the form builder")
    func exposesSchemas() {
        let registry = registry()
        #expect(registry.identifiers == ["test.echo"])
        #expect(registry.contains("test.echo"))
        #expect(!registry.contains("test.other"))
        #expect(registry.paramSchema(for: "test.echo")?.fields.count == 2)
        #expect(registry.paramSchema(for: "test.missing") == nil)
    }

    @Test("A conditional field is hidden until its controlling value matches")
    func conditionalFieldVisibility() throws {
        let schema = try #require(registry().paramSchema(for: "test.echo"))
        #expect(schema.defaults["word"] == .string("hi"))
        #expect(schema.visibleFields(for: schema.defaults).map(\.key) == ["word", "shout"])
        #expect(schema.visibleFields(for: ["word": .string("bye")]).map(\.key) == ["word"])
    }

    @Test("Supplied parameters win over the declared defaults")
    func suppliedParamsWin() throws {
        let schema = try #require(registry().paramSchema(for: "test.echo"))
        let merged = schema.applyingDefaults(to: ["word": .string("bye")])
        #expect(merged["word"] == .string("bye"))
        #expect(merged["shout"] == .bool(false))
    }
}
