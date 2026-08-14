//
//  TransferValueConverter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct TransferValueOutcome: Sendable, Hashable {
    let value: PluginCellValue
    let lostPrecision: Bool

    init(_ value: PluginCellValue, lostPrecision: Bool = false) {
        self.value = value
        self.lostPrecision = lostPrecision
    }
}

/// Pure, stateless, one cell at a time. A driver hands every cell over as text
/// or as bytes, so a conversion is string work and never needs a connection.
///
/// Nothing here guesses. A value that cannot be represented at the target
/// throws, because a converter that quietly picks something close is a data
/// corruption the user finds months later.
enum TransferValueConverter {
    private static let mysqlTimestampRange = 1 ... 2_147_483_647

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// Null passes through every conversion untouched. A target column that
    /// refuses null is the target's business, not the converter's.
    static func convert(
        _ value: PluginCellValue,
        using conversion: TransferValueConversion
    ) throws -> TransferValueOutcome {
        guard let text = value.asText else { return TransferValueOutcome(value) }

        switch conversion {
        case .boolToInt:
            return TransferValueOutcome(.text(try boolean(text) ? "1" : "0"))
        case .intToBool:
            return TransferValueOutcome(.text(try boolean(text) ? "true" : "false"))
        case .zeroDateToNull:
            return TransferValueOutcome(isZeroDate(text) ? .null : value)
        case .zeroDateToSentinel(let sentinel):
            return TransferValueOutcome(isZeroDate(text) ? .text(sentinel) : value)
        case .zeroDateReject:
            guard !isZeroDate(text) else { throw TransferValueFault.zeroDateInNotNull }
            return TransferValueOutcome(value)
        case .unsignedToDecimalText:
            return TransferValueOutcome(.text(try unsignedDecimal(text)))
        case .arrayToJson:
            return TransferValueOutcome(.text(try json(fromArrayLiteral: text)))
        case .jsonValidate:
            try validateJson(text)
            return TransferValueOutcome(value)
        case .mysqlTimestampRange:
            try validateMysqlTimestamp(text)
            return TransferValueOutcome(value)
        case .decimalFit(let precision, let scale):
            return try decimal(text, precision: precision, scale: scale, rounding: false)
        case .decimalRound(let precision, let scale):
            return try decimal(text, precision: precision, scale: scale, rounding: true)
        }
    }

    // MARK: - Boolean

    private static func boolean(_ text: String) throws -> Bool {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "t", "true", "y", "yes", "on":
            return true
        case "0", "f", "false", "n", "no", "off", "":
            return false
        default:
            guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else {
                throw TransferValueFault.invalidBoolean
            }
            return number != 0
        }
    }

    // MARK: - Zero date

    /// MySQL stores `0000-00-00` as a real value. Every other engine rejects it,
    /// and so does MySQL itself once the source data reaches a strict server.
    private static func isZeroDate(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).hasPrefix("0000-00-00")
    }

    // MARK: - Unsigned

    /// `bigint unsigned` reaches 18446744073709551615, above `Int64.max`, so the
    /// value stays text the whole way and the target parses it as a decimal.
    private static func unsignedDecimal(_ text: String) throws -> String {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("+") { digits = digits.dropFirst() }

        if digits.hasPrefix("-") {
            guard digits.dropFirst().allSatisfy({ $0 == "0" || $0 == "." }) else {
                throw TransferValueFault.negativeIntoUnsigned
            }
            return "0"
        }

        if let dot = digits.firstIndex(of: ".") {
            guard digits[digits.index(after: dot)...].allSatisfy({ $0 == "0" }) else {
                throw TransferValueFault.outOfRange
            }
            digits = digits[..<dot]
        }

        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { throw TransferValueFault.outOfRange }
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    // MARK: - JSON

    private static func validateJson(_ text: String) throws {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            throw TransferValueFault.invalidJson
        }
    }

    private static func json(fromArrayLiteral text: String) throws -> String {
        let elements = try PostgresArrayLiteral.parse(text)
        guard let data = try? JSONSerialization.data(withJSONObject: elements, options: []),
              let encoded = String(data: data, encoding: .utf8) else {
            throw TransferValueFault.invalidJson
        }
        return encoded
    }

    // MARK: - Timestamp

    /// MySQL `TIMESTAMP` is a 32-bit epoch: 1970-01-01 00:00:01 UTC through
    /// 2038-01-19 03:14:07 UTC. A value outside it is silently zeroed on a
    /// non-strict server, so it is caught here instead.
    private static func validateMysqlTimestamp(_ text: String) throws {
        guard let epoch = epochSeconds(text) else { return }
        guard mysqlTimestampRange.contains(epoch) else { throw TransferValueFault.outOfRange }
    }

    /// Returns nil for anything that is not a recognisable timestamp. The target
    /// server rejects such a value on its own, and guessing here would turn a
    /// clear server error into a wrong range check.
    static func epochSeconds(_ raw: String) -> Int? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var offsetSeconds = 0

        if text.hasSuffix("Z") || text.hasSuffix("z") {
            text.removeLast()
        } else if let index = text.dropFirst(11).firstIndex(where: { $0 == "+" || $0 == "-" }) {
            guard let offset = zoneOffset(String(text[text.index(after: index)...])) else { return nil }
            offsetSeconds = text[index] == "-" ? -offset : offset
            text = String(text[..<index])
        }

        let parts = text.split(whereSeparator: { $0 == " " || $0 == "T" || $0 == "t" })
        guard let datePart = parts.first else { return nil }
        let date = datePart.split(separator: "-").compactMap { Int($0) }
        guard date.count == 3 else { return nil }

        var time = [0, 0, 0]
        if parts.count > 1 {
            let seconds = parts[1].split(separator: ".").first ?? ""
            let fields = seconds.split(separator: ":").compactMap { Int($0) }
            guard fields.count >= 2 else { return nil }
            for (index, field) in fields.prefix(3).enumerated() { time[index] = field }
        }

        var components = DateComponents()
        components.year = date[0]
        components.month = date[1]
        components.day = date[2]
        components.hour = time[0]
        components.minute = time[1]
        components.second = time[2]
        components.timeZone = TimeZone(identifier: "UTC")

        guard let resolved = utcCalendar.date(from: components) else { return nil }
        return Int(resolved.timeIntervalSince1970) - offsetSeconds
    }

    private static func zoneOffset(_ text: String) -> Int? {
        let fields = text.split(separator: ":").compactMap { Int($0) }
        guard let hours = fields.first else { return nil }
        let minutes = fields.count > 1 ? fields[1] : 0
        return hours * 3_600 + minutes * 60
    }

    // MARK: - Decimal

    /// An overflowing integer part is never recoverable. An overflowing
    /// fractional part is, but only when the user asked for rounding, and the
    /// caller logs it either way.
    private static func decimal(
        _ text: String,
        precision: Int,
        scale: Int,
        rounding: Bool
    ) throws -> TransferValueOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let parts = DecimalDigits(trimmed) else { return TransferValueOutcome(.text(text)) }

        guard parts.integerDigits <= precision - scale else { throw TransferValueFault.precisionLoss }
        guard parts.fractionDigits > scale else { return TransferValueOutcome(.text(text)) }
        guard rounding, var value = Decimal(string: trimmed) else { throw TransferValueFault.precisionLoss }

        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, scale, .plain)
        return TransferValueOutcome(.text("\(rounded)"), lostPrecision: true)
    }
}

/// The digit counts of a plain decimal literal. Exponent notation returns nil:
/// the value is a float on its way to a float column, not a fixed-point number
/// this check applies to.
private struct DecimalDigits {
    let integerDigits: Int
    let fractionDigits: Int

    init?(_ text: String) {
        var body = Substring(text)
        if body.hasPrefix("-") || body.hasPrefix("+") { body = body.dropFirst() }
        guard !body.isEmpty, body.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }

        let whole = parts[0].drop { $0 == "0" }
        integerDigits = whole.count
        fractionDigits = parts.count == 2 ? parts[1].count : 0
    }
}

/// PostgreSQL renders an array as `{a,b}`, quoting only the elements that need
/// it, and writes an unquoted `NULL` for a missing element. A quoted `"NULL"`
/// is the four-character string.
private enum PostgresArrayLiteral {
    static func parse(_ text: String) throws -> [Any] {
        var scanner = Substring(text.trimmingCharacters(in: .whitespaces))
        let elements = try array(&scanner)
        guard scanner.isEmpty else { throw TransferValueFault.invalidJson }
        return elements
    }

    private static func array(_ scanner: inout Substring) throws -> [Any] {
        guard scanner.first == "{" else { throw TransferValueFault.invalidJson }
        scanner = scanner.dropFirst()

        var elements: [Any] = []
        if scanner.first == "}" {
            scanner = scanner.dropFirst()
            return elements
        }

        while true {
            elements.append(try element(&scanner))
            guard let separator = scanner.first else { throw TransferValueFault.invalidJson }
            scanner = scanner.dropFirst()
            if separator == "}" { return elements }
            guard separator == "," else { throw TransferValueFault.invalidJson }
        }
    }

    private static func element(_ scanner: inout Substring) throws -> Any {
        switch scanner.first {
        case "{":
            return try array(&scanner)
        case "\"":
            return try quoted(&scanner)
        default:
            let raw = scanner.prefix { $0 != "," && $0 != "}" }
            scanner = scanner.dropFirst(raw.count)
            let value = raw.trimmingCharacters(in: .whitespaces)
            guard value.caseInsensitiveCompare("NULL") != .orderedSame else { return NSNull() }
            return value
        }
    }

    private static func quoted(_ scanner: inout Substring) throws -> Any {
        scanner = scanner.dropFirst()
        var value = ""
        while let character = scanner.first {
            scanner = scanner.dropFirst()
            if character == "\\" {
                guard let escaped = scanner.first else { throw TransferValueFault.invalidJson }
                scanner = scanner.dropFirst()
                value.append(escaped)
                continue
            }
            if character == "\"" { return value }
            value.append(character)
        }
        throw TransferValueFault.invalidJson
    }
}
