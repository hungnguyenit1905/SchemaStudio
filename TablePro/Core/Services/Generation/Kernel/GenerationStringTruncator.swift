//
//  GenerationStringTruncator.swift
//  TablePro
//

import Foundation

enum GenerationLengthUnit: String, Sendable, Hashable, CaseIterable {
    case unicodeScalars
    case utf16CodeUnits
    case utf8Bytes

    func width(of scalar: Unicode.Scalar) -> Int {
        switch self {
        case .unicodeScalars: return 1
        case .utf16CodeUnits: return UTF16.width(scalar)
        case .utf8Bytes: return UTF8.width(scalar)
        }
    }

    func measure(_ value: String) -> Int {
        switch self {
        case .unicodeScalars: return value.unicodeScalars.count
        case .utf16CodeUnits: return value.utf16.count
        case .utf8Bytes: return value.utf8.count
        }
    }
}

struct GenerationStringTruncator: Sendable, Hashable {
    let unit: GenerationLengthUnit
    let byteLimit: Int?

    init(unit: GenerationLengthUnit, byteLimit: Int? = nil) {
        self.unit = unit
        self.byteLimit = byteLimit
    }

    static func unit(for vendor: TransferVendor?) -> GenerationLengthUnit {
        switch vendor {
        case .mssql: return .utf16CodeUnits
        case .postgresql, .mysql, .sqlite: return .unicodeScalars
        case nil: return .unicodeScalars
        }
    }

    static func forVendor(_ vendor: TransferVendor?, byteLimit: Int? = nil) -> GenerationStringTruncator {
        GenerationStringTruncator(unit: unit(for: vendor), byteLimit: byteLimit)
    }

    func fits(_ value: String, limit: Int?) -> Bool {
        if let limit, unit.measure(value) > limit { return false }
        if let byteLimit, value.utf8.count > byteLimit { return false }
        return true
    }

    func truncate(_ value: String, to limit: Int?) -> String {
        guard !fits(value, limit: limit) else { return value }
        var truncated = value
        if let limit {
            truncated = Self.cut(truncated, to: limit, unit: unit)
        }
        if let byteLimit {
            truncated = Self.cut(truncated, to: byteLimit, unit: .utf8Bytes)
        }
        return truncated
    }

    private static func cut(_ value: String, to limit: Int, unit: GenerationLengthUnit) -> String {
        guard limit > 0 else { return "" }
        var used = 0
        var kept = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            let width = unit.width(of: scalar)
            guard used + width <= limit else { break }
            used += width
            kept.append(scalar)
        }
        return String(kept)
    }
}
