//
//  RelativeDateTimeGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// An instant expressed as an offset from another column in the same row, which
/// is what makes `updated_at >= created_at` hold across a whole table instead of
/// holding by luck.
final class RelativeDateTimeGenerator: ValueGenerator {
    static let identifier = "RelativeDateTime"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "baseColumn", label: "Relative to", type: .text, defaultValue: .string("")),
        ParamField(
            key: "unit",
            label: "Offset unit",
            type: .choice(DateTimeGranularity.allCases.map { ParamChoice(value: $0.rawValue) }),
            defaultValue: .string(DateTimeGranularity.day.rawValue)
        ),
        ParamField(
            key: "offsetMin",
            label: "Smallest offset",
            type: .integer(minimum: nil, maximum: nil),
            defaultValue: .int(0
        )),
        ParamField(
            key: "offsetMax",
            label: "Largest offset",
            type: .integer(minimum: nil, maximum: nil),
            defaultValue: .int(30
        ))
    ])

    private struct Params: Codable {
        var baseColumn: String?
        var unit: DateTimeGranularity?
        var offsetMin: Int?
        var offsetMax: Int?
    }

    private let columnName: String
    private let baseColumn: String
    private let offsetRange: ClosedRange<Int>
    private let unitSeconds: Int
    private let emits: DateTimeShape
    private let seed: UInt64
    private var rng: SplitMix64
    private var runtimeWarnings: [GenerationWarning] = []
    private var overflowWarningIssued = false

    var warnings: [GenerationWarning] { runtimeWarnings }

    private enum DateTimeShape {
        case instant
        case calendarDay
        case text
    }

    var rowDependencies: [String] { [baseColumn] }

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let requested = decoded.baseColumn ?? ""
        guard !requested.isEmpty else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "no column to measure the offset from"
            )
        }
        guard requested != column.name else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "a column cannot be an offset from itself"
            )
        }
        columnName = column.name
        baseColumn = requested
        let upper = decoded.offsetMax ?? 30
        let lower = min(decoded.offsetMin ?? 0, upper)
        offsetRange = lower...upper
        unitSeconds = (decoded.unit ?? .day).seconds
        switch column.type.base {
        case .timestamp, .timestampTZ: emits = .instant
        case .date: emits = .calendarDay
        default: emits = .text
        }
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard let base = row[baseColumn] else {
            throw GenerationError.dependencyMissing(column: columnName, dependsOn: baseColumn)
        }
        guard let baseSeconds = Self.epochSeconds(base) else {
            guard base.isNull else {
                throw GenerationError.invalidParameters(
                    generator: Self.identifier,
                    reason: "\(baseColumn) does not hold a date or a timestamp"
                )
            }
            return .null
        }
        let seconds = clampedSeconds(base: baseSeconds, offset: rng.nextInt(in: offsetRange))
        switch emits {
        case .instant:
            return .timestamp(Date(timeIntervalSince1970: TimeInterval(seconds)))
        case .calendarDay:
            let civil = CivilDate.fromDaysSinceEpoch(Self.floorDivide(seconds, 86_400))
            return .date(year: civil.year, month: civil.month, day: civil.day)
        case .text:
            return .text(DateTimeGenerator.render(seconds: seconds))
        }
    }

    func reset() {
        rng = SplitMix64(seed: seed)
        runtimeWarnings.removeAll(keepingCapacity: true)
        overflowWarningIssued = false
    }

    /// The multiplication and the addition are both plain `Int` arithmetic, so a
    /// large offset, or a large unit multiplier against a base near the end of
    /// `Int`'s representable range, would otherwise trap. Both operations run
    /// through the reporting-overflow form and clamp to `Int.min...Int.max`,
    /// which is the representable range every downstream shape (`Date`,
    /// `CivilDate`, epoch text) is built from.
    private func clampedSeconds(base: Int, offset: Int) -> Int {
        let (product, productOverflowed) = offset.multipliedReportingOverflow(by: unitSeconds)
        guard !productOverflowed else {
            warnAboutOverflow()
            return (offset < 0) != (unitSeconds < 0) ? Int.min : Int.max
        }
        let (sum, sumOverflowed) = base.addingReportingOverflow(product)
        guard !sumOverflowed else {
            warnAboutOverflow()
            return product < 0 ? Int.min : Int.max
        }
        return sum
    }

    private func warnAboutOverflow() {
        guard !overflowWarningIssued else { return }
        overflowWarningIssued = true
        runtimeWarnings.append(
            GenerationWarning(
                column: columnName,
                message: String(
                    format: String(
                        localized: "%@'s offset from %@ overflowed and was clamped to the representable range."
                    ),
                    columnName,
                    baseColumn
                )
            )
        )
    }

    /// An integer base is read as a Unix time, which is how a `bigint` column
    /// carrying `created_at` is stored everywhere it is stored that way.
    private static func epochSeconds(_ value: PluginCellValue) -> Int? {
        switch value {
        case .timestamp(let instant): return Int(instant.timeIntervalSince1970)
        case .date(let year, let month, let day):
            return CivilDate(year: year, month: month, day: day).daysSinceEpoch * 86_400
        case .int(let number): return Int(number)
        case .text(let text): return DateTimeGenerator.epochSeconds(text)
        default: return nil
        }
    }

    private static func floorDivide(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }
}
