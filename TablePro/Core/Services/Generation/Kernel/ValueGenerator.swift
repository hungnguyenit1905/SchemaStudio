//
//  ValueGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What shape of value a generator commits to producing, independent of the
/// column it ends up on. Most generators adapt to whatever column they are
/// pointed at (a free-text generator fits any string-like column, and several
/// typed generators such as `Boolean` or `DateTime` already choose their own
/// wire shape from the column's declared type) and stay `.any`. A generator
/// that always emits one specific shape, regardless of the column, declares
/// that shape so the validator and the column grid can refuse a column it
/// cannot suit.
enum GenerationOutputKind: Sendable, Equatable {
    case any
    /// Always `.decimalText`: a numeric literal rendered as a string.
    /// `DecimalGenerator` is the only generator that commits to this
    /// unconditionally, and an affix or a character limit applied to it turns
    /// the string into something that is no longer a valid decimal, so it only
    /// suits a column whose own type is numeric.
    case decimalOnly

    func suits(_ base: TransferBaseType) -> Bool {
        switch self {
        case .any:
            return true
        case .decimalOnly:
            switch base {
            case .decimal, .float32, .float64, .unknown:
                return true
            default:
                return false
            }
        }
    }
}

protocol ValueGenerator: AnyObject {
    static var identifier: String { get }
    static var paramSchema: ParamSchema { get }

    /// The shape of value this generator commits to, used to refuse pairing it
    /// with a column its output cannot suit. Defaults to `.any`.
    static var producesKind: GenerationOutputKind { get }

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

    /// Something the generator noticed about its own output while running,
    /// such as a value it had to clamp. Reported once per column, alongside
    /// every other warning the run collects.
    var warnings: [GenerationWarning] { get }

    init(params: Data, column: GenerationColumn, seed: UInt64) throws

    func next(row: RowContext, index: Int) throws -> PluginCellValue

    /// Hands back a value the caller drew but did not write, so a generator
    /// enforcing uniqueness can return it to its domain.
    func discard(_ value: PluginCellValue)
    func reset()
}

extension ValueGenerator {
    static var paramSchema: ParamSchema { .empty }

    static var producesKind: GenerationOutputKind { .any }

    static var excludesColumnFromInsert: Bool { false }

    func discard(_ value: PluginCellValue) {}

    var rowDependencies: [String] { [] }

    var distinctValueCount: Int? { nil }

    var producesDistinctValues: Bool { false }

    var integerDomain: ClosedRange<Int64>? { nil }

    var warnings: [GenerationWarning] { [] }

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
