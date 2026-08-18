//
//  GenerationValueMapper.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum GenerationValueMapper {
    static func value(from text: String, base: TransferBaseType) -> PluginCellValue {
        switch base {
        case .bool:
            return boolean(from: text)
        case .int8, .int16, .int32, .int64:
            guard let number = Int64(text) else { return .text(text) }
            return .int(number)
        case .decimal:
            guard let number = Double(text), number.isFinite else { return .text(text) }
            return .decimalText(text)
        case .float32, .float64:
            guard let number = Double(text) else { return .text(text) }
            return .double(number)
        case .uuid:
            guard let identifier = UUID(uuidString: text) else { return .text(text) }
            return .uuid(identifier)
        case .date:
            guard let civil = CivilDate(iso8601: text) else { return .text(text) }
            return .date(year: civil.year, month: civil.month, day: civil.day)
        case .unknown, .string, .text, .bytes, .time, .timestamp, .timestampTZ, .interval,
             .json, .enumeration, .set, .geometry:
            return .text(text)
        }
    }

    static func value(from json: JSONValue, base: TransferBaseType) -> PluginCellValue {
        switch json {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .int(let number): return integer(number, base: base)
        case .double(let number): return decimal(number, base: base)
        case .string(let text): return value(from: text, base: base)
        case .array(let elements): return .array(elements.map { value(from: $0, base: base) })
        case .object: return .text(json.jsonText ?? "{}")
        }
    }

    /// True when a whole number handed to `value(from:base:)` comes back as text,
    /// which is what makes it subject to the column's length limit. A generator
    /// counting its own domain has to know this: the same range of numbers is
    /// 500 distinct values in an integer column and 9 in a `varchar(1)`.
    static func rendersIntegerAsText(base: TransferBaseType) -> Bool {
        switch base {
        case .string, .text, .enumeration, .set, .json: return true
        default: return false
        }
    }

    static func range(for base: TransferBaseType, unsigned: Bool) -> ClosedRange<Int64> {
        switch base {
        case .int8: return unsigned ? 0...255 : -128...127
        case .int16: return unsigned ? 0...65_535 : -32_768...32_767
        case .int32: return unsigned ? 0...4_294_967_295 : -2_147_483_648...2_147_483_647
        default: return unsigned ? 0...Int64.max : Int64.min...Int64.max
        }
    }

    /// `String(Double)` renders a large magnitude in scientific notation, which
    /// MySQL's `DECIMAL` parser rejects outright.
    static func fixedPointText(_ number: Double) -> String {
        guard number.isFinite else { return "0" }
        var text = String(format: "%.10f", number)
        guard text.contains(".") else { return text }
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }

    /// A domain wider than `Int` is reported as `Int.max`, which reads as
    /// "wide enough for any row count" everywhere pre-flight uses it.
    static func saturatingCount(_ value: UInt64) -> Int {
        value >= UInt64(Int.max) ? Int.max : Int(value)
    }

    private static func boolean(from text: String) -> PluginCellValue {
        switch text.lowercased() {
        case "1", "t", "true", "y", "yes", "on": return .bool(true)
        case "0", "f", "false", "n", "no", "off": return .bool(false)
        default: return .text(text)
        }
    }

    private static func integer(_ number: Int, base: TransferBaseType) -> PluginCellValue {
        switch base {
        case .decimal: return .decimalText(String(number))
        case .float32, .float64: return .double(Double(number))
        case .string, .text, .enumeration, .set, .json: return .text(String(number))
        case .bool: return .bool(number != 0)
        default: return .int(Int64(number))
        }
    }

    /// Every narrowing here goes through `Int64(exactly:)`. A plain `Int64(_:)`
    /// on a `Double` traps outside the representable range, and the value comes
    /// from a user-supplied parameter.
    private static func decimal(_ number: Double, base: TransferBaseType) -> PluginCellValue {
        switch base {
        case .decimal: return .decimalText(fixedPointText(number))
        case .int8, .int16, .int32, .int64:
            guard let exact = Int64(exactly: number.rounded()) else {
                return .decimalText(fixedPointText(number))
            }
            return .int(exact)
        case .string, .text, .enumeration, .set, .json: return .text(fixedPointText(number))
        default: return .double(number)
        }
    }
}
