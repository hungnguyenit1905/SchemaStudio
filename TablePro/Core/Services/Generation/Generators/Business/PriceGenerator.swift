//
//  PriceGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// How a price ends. Real catalogues almost never carry uniformly random
/// fractions, so a price column filled by `Decimal` reads as noise however
/// correct its range is.
enum PriceEnding: String, Codable, Sendable, CaseIterable {
    case charm
    case round
    case any
}

final class PriceGenerator: ValueGenerator {
    static let identifier = "Price"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "min", label: "Minimum", type: .decimal(minimum: nil, maximum: nil), defaultValue: .int(1)),
        ParamField(key: "max", label: "Maximum", type: .decimal(minimum: nil, maximum: nil), defaultValue: .int(1_000)),
        ParamField(
            key: "ending",
            label: "Price endings",
            type: .choice([
                ParamChoice(value: PriceEnding.charm.rawValue, label: String(localized: "Charm prices (.99, .95)")),
                ParamChoice(value: PriceEnding.round.rawValue, label: String(localized: "Whole amounts")),
                ParamChoice(value: PriceEnding.any.rawValue, label: String(localized: "Any fraction"))
            ]),
            defaultValue: .string(PriceEnding.charm.rawValue)
        ),
        ParamField(key: "scale", label: "Decimal places", type: .integer(minimum: 0, maximum: 6), defaultValue: .null)
    ])

    private struct Params: Codable {
        var min: Double?
        var max: Double?
        var ending: PriceEnding?
        var scale: Int?
    }

    private static let charmFractions = [99, 99, 99, 95, 95, 49, 50, 0]

    private let scale: Int
    private let wholeRange: ClosedRange<Int64>
    private let ending: PriceEnding
    private let base: TransferBaseType
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        base = column.type.base
        scale = max(0, min(decoded.scale ?? column.type.scale ?? 2, 6))
        let ceiling = Self.precisionCeiling(column: column, scale: scale)
        let upper = min(decoded.max ?? 1_000, ceiling)
        let requestedLower = decoded.min ?? 1
        let lower = decoded.min == nil ? min(requestedLower, upper) : requestedLower
        guard lower <= upper else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "the minimum \(lower) is above the maximum \(upper)"
            )
        }
        wholeRange = Int64(lower.rounded(.up))...max(Int64(lower.rounded(.up)), Int64(upper.rounded(.down)))
        ending = decoded.ending ?? .charm
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    /// `DECIMAL(5,2)` holds 999.99, not the default maximum of 1000: the digits
    /// left of the point are `precision - scale`, and a value that overruns them
    /// is rejected by the server rather than rounded.
    private static func precisionCeiling(column: GenerationColumn, scale: Int) -> Double {
        guard let precision = column.type.precision, precision > 0 else { return .greatestFiniteMagnitude }
        let wholeDigits = precision - scale
        guard wholeDigits > 0 else { return 0 }
        return pow(10.0, Double(wholeDigits)) - 1
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let span = UInt64(bitPattern: wholeRange.upperBound &- wholeRange.lowerBound) &+ 1
        let whole = wholeRange.lowerBound &+ Int64(bitPattern: rng.next(span: span))
        guard scale > 0 else { return value(whole: whole, text: String(whole)) }
        let unscaled = whole &* Self.powerOfTen(scale) &+ Int64(fractionalPart())
        return value(whole: whole, text: DecimalGenerator.format(unscaled: unscaled, scale: scale))
    }

    /// An integer column cannot hold the fraction, so it takes the whole amount
    /// rather than a rounded string the driver would have to reparse.
    private func value(whole: Int64, text: String) -> PluginCellValue {
        switch base {
        case .int8, .int16, .int32, .int64: return .int(whole)
        case .float32, .float64: return .double(Double(text) ?? Double(whole))
        case .string, .text, .enumeration, .set, .json: return .text(text)
        default: return .decimalText(text)
        }
    }

    /// Charm endings are defined at two decimal places, which is where prices are
    /// actually written; a wider scale pads them rather than inventing digits that
    /// would defeat the point.
    private func fractionalPart() -> Int {
        let hundredths: Int
        switch ending {
        case .charm: hundredths = Self.charmFractions[rng.nextInt(upperBound: Self.charmFractions.count)]
        case .round: hundredths = 0
        case .any: return rng.nextInt(upperBound: Int(Self.powerOfTen(scale)))
        }
        guard scale != 2 else { return hundredths }
        guard scale > 2 else { return hundredths / Int(Self.powerOfTen(2 - scale)) }
        return hundredths * Int(Self.powerOfTen(scale - 2))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }

    private static func powerOfTen(_ exponent: Int) -> Int64 {
        var result: Int64 = 1
        for _ in 0..<min(max(exponent, 0), 18) { result &*= 10 }
        return result
    }
}
