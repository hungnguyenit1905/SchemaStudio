//
//  DateGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Emits `.date` components rather than a `Foundation.Date`. A `Date` is an
/// absolute instant, so rendering one for a plain `date` column shifts the day
/// across a timezone boundary.
final class DateGenerator: ValueGenerator {
    static let identifier = "Date"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "from", label: "From", type: .date, defaultValue: .string("2000-01-01")),
        ParamField(key: "to", label: "To", type: .date, defaultValue: .string("2030-12-31"))
    ])

    private struct Params: Codable {
        var from: String?
        var to: String?
    }

    private let firstDay: Int
    private let dayCount: UInt64
    private let emitsText: Bool
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let fromText = decoded.from ?? "2000-01-01"
        let toText = decoded.to ?? "2030-12-31"
        guard let from = CivilDate(iso8601: fromText) else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "\(fromText) is not a calendar date"
            )
        }
        guard let to = CivilDate(iso8601: toText) else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "\(toText) is not a calendar date"
            )
        }
        guard from <= to else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "\(fromText) is after \(toText)"
            )
        }
        firstDay = from.daysSinceEpoch
        dayCount = UInt64(to.daysSinceEpoch - from.daysSinceEpoch) &+ 1
        emitsText = ![.date, .timestamp, .timestampTZ].contains(column.type.base)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { GenerationValueMapper.saturatingCount(dayCount) }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let civil = CivilDate.fromDaysSinceEpoch(firstDay + Int(rng.next(span: dayCount)))
        guard emitsText else {
            return .date(year: civil.year, month: civil.month, day: civil.day)
        }
        return .text(civil.iso8601)
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
