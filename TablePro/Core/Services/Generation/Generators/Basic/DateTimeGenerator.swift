//
//  DateTimeGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum DateTimeGranularity: String, Codable, Sendable, CaseIterable {
    case second
    case minute
    case hour
    case day

    var seconds: Int {
        switch self {
        case .second: return 1
        case .minute: return 60
        case .hour: return 3_600
        case .day: return 86_400
        }
    }
}

final class DateTimeGenerator: ValueGenerator {
    static let identifier = "DateTime"
    static let paramSchema = ParamSchema(fields: [
        ParamField(key: "from", label: "From", type: .text, defaultValue: .string("2000-01-01T00:00:00Z")),
        ParamField(key: "to", label: "To", type: .text, defaultValue: .string("2030-12-31T23:59:59Z")),
        ParamField(
            key: "granularity",
            label: "Round to",
            type: .choice(DateTimeGranularity.allCases.map { ParamChoice(value: $0.rawValue) }),
            defaultValue: .string(DateTimeGranularity.second.rawValue)
        )
    ])

    private struct Params: Codable {
        var from: String?
        var to: String?
        var granularity: DateTimeGranularity?
    }

    private let firstTick: Int
    private let tickCount: UInt64
    private let granularity: DateTimeGranularity
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
        let fromText = decoded.from ?? "2000-01-01T00:00:00Z"
        let toText = decoded.to ?? "2030-12-31T23:59:59Z"
        let requestedGranularity = decoded.granularity ?? .second
        guard let from = Self.epochSeconds(fromText) else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "\(fromText) is not a timestamp"
            )
        }
        guard let to = Self.epochSeconds(toText) else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "\(toText) is not a timestamp"
            )
        }
        guard from <= to else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "\(fromText) is after \(toText)"
            )
        }
        let step = requestedGranularity.seconds
        let alignedFirst = Self.floorDivide(from, step)
        let alignedLast = Self.floorDivide(to, step)
        firstTick = alignedFirst
        tickCount = UInt64(alignedLast - alignedFirst) &+ 1
        granularity = requestedGranularity
        emitsText = ![.timestamp, .timestampTZ, .date, .time].contains(column.type.base)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let tick = firstTick + Int(rng.next(span: tickCount))
        let seconds = tick * granularity.seconds
        let instant = Date(timeIntervalSince1970: TimeInterval(seconds))
        guard emitsText else { return .timestamp(instant) }
        return .text(Self.render(seconds: seconds))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }

    private static func floorDivide(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }

    static func render(seconds: Int) -> String {
        let days = floorDivide(seconds, 86_400)
        let civil = CivilDate.fromDaysSinceEpoch(days)
        let secondOfDay = seconds - days * 86_400
        return String(
            format: "%@ %02d:%02d:%02d",
            civil.iso8601,
            secondOfDay / 3_600,
            (secondOfDay / 60) % 60,
            secondOfDay % 60
        )
    }

    /// The date-only reading is reachable only when the text carries no time at
    /// all. Falling back to it after a failed timestamp parse silently turned a
    /// zoned instant into midnight UTC.
    static func epochSeconds(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parser = ISO8601DateFormatter()
        parser.timeZone = TimeZone(secondsFromGMT: 0)

        guard let separator = trimmed.firstIndex(where: { $0 == "T" || $0 == " " }) else {
            parser.formatOptions = [.withFullDate]
            return parser.date(from: trimmed).map { Int($0.timeIntervalSince1970) }
        }

        let datePart = trimmed[..<separator]
        let timePart = trimmed[trimmed.index(after: separator)...]
            .replacingOccurrences(of: " ", with: "")
        guard !timePart.isEmpty else {
            parser.formatOptions = [.withFullDate]
            return parser.date(from: String(datePart)).map { Int($0.timeIntervalSince1970) }
        }

        let carriesZone = timePart.hasSuffix("Z")
            || timePart.dropFirst().contains("+")
            || timePart.dropFirst().contains("-")
        let candidate = "\(datePart)T\(timePart)" + (carriesZone ? "" : "Z")

        for options in [
            ISO8601DateFormatter.Options([.withInternetDateTime]),
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds])
        ] {
            parser.formatOptions = options
            if let parsed = parser.date(from: candidate) { return Int(parsed.timeIntervalSince1970) }
        }
        return nil
    }
}
