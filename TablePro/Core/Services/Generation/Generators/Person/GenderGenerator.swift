//
//  GenderGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum GenderWriting: String, Codable, Sendable, CaseIterable {
    case word
    case letter
    case number
}

/// Writes whichever spelling the column already uses. A schema that stores `M`
/// and `F` gains nothing from a column full of the word `male`, and an enum
/// column dictates its own vocabulary, which is read off `allowedValues` before
/// any parameter is considered.
final class GenderGenerator: ValueGenerator {
    static let identifier = "Gender"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "writing",
            label: "Written as",
            type: .choice([
                ParamChoice(value: GenderWriting.word.rawValue, label: String(localized: "Words, such as female")),
                ParamChoice(value: GenderWriting.letter.rawValue, label: String(localized: "Letters, such as F")),
                ParamChoice(value: GenderWriting.number.rawValue, label: String(localized: "Numbers, 1 and 2"))
            ]),
            defaultValue: .string(GenderWriting.word.rawValue)
        ),
        ParamField(
            key: "femalePercent",
            label: "Share female",
            type: .integer(minimum: 0, maximum: 100),
            defaultValue: .int(50)
        ),
        ParamField(
            key: "otherPercent",
            label: "Share other",
            type: .integer(minimum: 0, maximum: 100),
            defaultValue: .int(0)
        )
    ])

    private struct Params: Codable {
        var writing: GenderWriting?
        var femalePercent: Int?
        var otherPercent: Int?
    }

    private let maleValue: PluginCellValue
    private let femaleValue: PluginCellValue
    private let otherValue: PluginCellValue
    private let femalePercent: Int
    private let otherPercent: Int
    private let distinctCount: Int
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let writing = decoded.writing ?? .word
        let allowed = column.allowedValues ?? []
        let spellings: [String]
        if allowed.count >= 2 {
            spellings = allowed
        } else {
            switch writing {
            case .word: spellings = ["male", "female", "other"]
            case .letter: spellings = ["M", "F", "X"]
            case .number: spellings = ["1", "2", "3"]
            }
        }
        let values = spellings.map { GenerationValueMapper.value(from: $0, base: column.type.base) }
        maleValue = values[0]
        femaleValue = values[min(1, values.count - 1)]
        otherValue = values[min(2, values.count - 1)]
        let female = min(100, max(0, decoded.femalePercent ?? 50))
        let other = min(100 - female, max(0, decoded.otherPercent ?? 0))
        femalePercent = female
        otherPercent = other
        distinctCount = Set(
            [(maleValue, 100 - female - other), (femaleValue, female), (otherValue, other)]
                .filter { $0.1 > 0 }
                .map(\.0)
        ).count
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    /// Only the spellings a non-zero share can reach. The shares default to half
    /// female and no third value, so counting every spelling in the list claims a
    /// value the column will never hold, and an overstated count lets a unique
    /// column past pre-flight that the run cannot fill.
    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let draw = rng.nextInt(upperBound: 100)
        if draw < femalePercent { return femaleValue }
        if draw < femalePercent + otherPercent { return otherValue }
        return maleValue
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
