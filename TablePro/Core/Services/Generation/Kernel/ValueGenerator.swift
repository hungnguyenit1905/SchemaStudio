//
//  ValueGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

protocol ValueGenerator: AnyObject {
    static var identifier: String { get }
    static var paramSchema: ParamSchema { get }

    /// True when the column carrying this generator is left out of the INSERT
    /// entirely, so the server supplies the value.
    static var excludesColumnFromInsert: Bool { get }

    /// Columns whose value must already be in the `RowContext` before this
    /// generator runs, which is what orders the columns inside a row.
    var rowDependencies: [String] { get }

    /// How many distinct values this generator can produce, where that is
    /// computable. Pre-flight uses it to refuse a unique column that cannot fill
    /// the requested row count. `nil` means "not computable", and the run falls
    /// back to the runtime `uniqueExhausted` error.
    var distinctValueCount: Int? { get }

    /// True when the generator's own values never repeat, so a unique column
    /// carrying it needs no tracking at all.
    var producesDistinctValues: Bool { get }

    /// The closed integer domain this generator draws from, where it has one.
    /// A unique column over a finite domain is filled from a shuffle of that
    /// domain rather than by drawing and rejecting duplicates.
    var integerDomain: ClosedRange<Int64>? { get }

    init(params: Data, column: GenerationColumn, seed: UInt64) throws

    func next(row: RowContext, index: Int) throws -> PluginCellValue
    func reset()
}

extension ValueGenerator {
    static var paramSchema: ParamSchema { .empty }

    static var excludesColumnFromInsert: Bool { false }

    var rowDependencies: [String] { [] }

    var distinctValueCount: Int? { nil }

    var producesDistinctValues: Bool { false }

    var integerDomain: ClosedRange<Int64>? { nil }

    var identifier: String { Self.identifier }

    var excludesColumnFromInsert: Bool { Self.excludesColumnFromInsert }
}

enum GenerationParams {
    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data, generator: String) throws -> Value {
        guard !data.isEmpty else {
            throw GenerationError.invalidParameters(generator: generator, reason: "no settings supplied")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GenerationError.invalidParameters(
                generator: generator,
                reason: error.localizedDescription
            )
        }
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        generator: String,
        default fallback: Value
    ) throws -> Value {
        guard !data.isEmpty else { return fallback }
        return try decode(type, from: data, generator: generator)
    }
}
