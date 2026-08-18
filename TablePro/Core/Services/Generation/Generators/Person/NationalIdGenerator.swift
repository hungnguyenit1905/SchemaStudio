//
//  NationalIdGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// National identifier shapes. Like `TaxID`, these deliberately carry no valid
/// registry check digit: a generated identifier that a real government service
/// would accept is a liability rather than a feature. US numbers additionally
/// use the ranges the Social Security Administration never issues.
enum NationalIdCountry: String, Codable, Sendable, CaseIterable {
    case us = "US"
    case vn = "VN"

    var label: String {
        switch self {
        case .us: return String(localized: "United States (SSN shape)")
        case .vn: return String(localized: "Vietnam (12-digit)")
        }
    }

    var length: Int {
        switch self {
        case .us: return 11
        case .vn: return 12
        }
    }
}

final class NationalIdGenerator: ValueGenerator {
    static let identifier = "NationalID"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "country",
            label: "Country",
            type: .choice(NationalIdCountry.allCases.map { ParamChoice(value: $0.rawValue, label: $0.label) }),
            defaultValue: .string(NationalIdCountry.us.rawValue)
        ),
        ParamField(
            key: "separated",
            label: "Write separators",
            type: .toggle,
            defaultValue: .bool(true),
            visibleWhen: ParamVisibility(key: "country", equalsAnyOf: [.string(NationalIdCountry.us.rawValue)])
        )
    ])

    private struct Params: Codable {
        var country: NationalIdCountry?
        var separated: Bool?
    }

    private let country: NationalIdCountry
    private let separated: Bool
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        country = decoded.country ?? .us
        separated = country == .us && (decoded.separated ?? true)
        try ColumnFit.requireRoom(
            for: separated ? country.length : (country == .us ? 9 : country.length),
            column: column,
            generator: Self.identifier
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        switch country {
        case .us:
            let area = rng.nextInt(in: 900...999)
            let group = rng.nextInt(in: 10...99)
            let serial = rng.nextInt(in: 1_000...9_999)
            let parts = [String(area), String(group), String(serial)]
            return .text(parts.joined(separator: separated ? "-" : ""))
        case .vn:
            var digits = ""
            for _ in 0..<12 {
                digits.append(String(rng.nextInt(upperBound: 10)))
            }
            return .text(digits)
        }
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
