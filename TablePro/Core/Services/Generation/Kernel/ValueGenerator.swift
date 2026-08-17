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

    init(params: Data, column: GenerationColumn, seed: UInt64) throws

    func next(row: RowContext, index: Int) throws -> PluginCellValue
    func reset()
}

extension ValueGenerator {
    static var paramSchema: ParamSchema { .empty }

    static var excludesColumnFromInsert: Bool { false }

    var rowDependencies: [String] { [] }

    var identifier: String { Self.identifier }
}

enum GenerationError: Error, Equatable {
    case unknownGenerator(identifier: String)
    case invalidParameters(generator: String, reason: String)
    case uniqueExhausted(column: String, attempts: Int)
    case dependencyMissing(column: String, dependsOn: String)
}

extension GenerationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unknownGenerator(let identifier):
            return String(format: String(localized: "No generator is registered as %@."), identifier)
        case .invalidParameters(let generator, let reason):
            return String(
                format: String(localized: "The %@ generator rejected its settings: %@"),
                generator,
                reason
            )
        case .uniqueExhausted(let column, let attempts):
            return String(
                format: String(localized: "Could not find a distinct value for %@ after %d attempts."),
                column,
                attempts
            )
        case .dependencyMissing(let column, let dependsOn):
            return String(
                format: String(localized: "%@ needs %@, which has not been generated yet."),
                column,
                dependsOn
            )
        }
    }
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
