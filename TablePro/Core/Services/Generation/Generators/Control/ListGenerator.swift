//
//  ListGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum ListSelectionMode: String, Codable, Sendable, CaseIterable {
    case random
    case sequential
}

final class ListGenerator: ValueGenerator {
    static let identifier = "List"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "values", label: "Values", type: .stringList, defaultValue: .array([])),
        ParamField(key: "weights", label: "Weights", type: .stringList, defaultValue: .array([])),
        ParamField(
            key: "mode",
            label: "Pick",
            type: .choice([
                ParamChoice(value: ListSelectionMode.random.rawValue, label: String(localized: "At random")),
                ParamChoice(value: ListSelectionMode.sequential.rawValue, label: String(localized: "In order"))
            ]),
            defaultValue: .string(ListSelectionMode.random.rawValue)
        )
    ])

    private struct Params: Codable {
        var values: [String]?
        var weights: [Int]?
        var mode: ListSelectionMode?
    }

    private let values: [PluginCellValue]
    private let cumulativeWeights: [Int]
    private let totalWeight: Int
    private let mode: ListSelectionMode
    private let seed: UInt64
    private var rng: SplitMix64
    private var position = 0

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let requested = decoded.values ?? []
        let source = requested.isEmpty ? (column.allowedValues ?? []) : requested
        guard !source.isEmpty else {
            throw GenerationError.invalidParameters(generator: Self.identifier, reason: "the value list is empty")
        }
        if let weights = decoded.weights {
            guard weights.count == source.count else {
                throw GenerationError.invalidParameters(
                    generator: Self.identifier,
                    reason: "there are \(weights.count) weights for \(source.count) values"
                )
            }
            guard weights.allSatisfy({ $0 >= 0 }), weights.contains(where: { $0 > 0 }) else {
                throw GenerationError.invalidParameters(
                    generator: Self.identifier,
                    reason: "weights must be zero or more and at least one must be positive"
                )
            }
        }
        values = source.map { GenerationValueMapper.value(from: $0, base: column.type.base) }
        let weights = decoded.weights ?? Array(repeating: 1, count: source.count)
        var running: [Int] = []
        var total = 0
        for weight in weights {
            let (sum, overflowed) = total.addingReportingOverflow(weight)
            guard !overflowed else {
                throw GenerationError.invalidParameters(
                    generator: Self.identifier,
                    reason: "the weights add up to more than the largest whole number"
                )
            }
            total = sum
            running.append(total)
        }
        cumulativeWeights = running
        totalWeight = total
        mode = decoded.mode ?? .random
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard mode == .random else {
            defer { position += 1 }
            return values[position % values.count]
        }
        let draw = rng.nextInt(upperBound: totalWeight)
        guard let position = cumulativeWeights.firstIndex(where: { draw < $0 }) else {
            return values[values.count - 1]
        }
        return values[position]
    }

    func reset() {
        rng = SplitMix64(seed: seed)
        position = 0
    }
}
