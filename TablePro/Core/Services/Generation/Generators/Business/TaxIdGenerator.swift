//
//  TaxIdGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Country tax-identifier shapes. These carry no check digit that a real registry
/// would accept, which is deliberate: a generated identifier that validates
/// against a live government service is a liability, not a feature.
enum TaxIdCountry: String, Codable, Sendable, CaseIterable {
    case us = "US"
    case vn = "VN"
    case gb = "GB"
    case de = "DE"

    var label: String {
        switch self {
        case .us: return String(localized: "United States (EIN)")
        case .vn: return String(localized: "Vietnam (MST)")
        case .gb: return String(localized: "United Kingdom (VAT)")
        case .de: return String(localized: "Germany (USt-IdNr.)")
        }
    }

    var maximumLength: Int {
        switch self {
        case .us: return 10
        case .vn: return 14
        case .gb: return 11
        case .de: return 11
        }
    }
}

final class TaxIdGenerator: ValueGenerator {
    static let identifier = "TaxID"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "country",
            label: "Country",
            type: .choice(TaxIdCountry.allCases.map { ParamChoice(value: $0.rawValue, label: $0.label) }),
            defaultValue: .string(TaxIdCountry.us.rawValue)
        ),
        ParamField(
            key: "includeBranch",
            label: "Include branch suffix",
            type: .toggle,
            defaultValue: .bool(false),
            help: String(localized: "Vietnamese tax codes gain a three-digit branch suffix."),
            visibleWhen: ParamVisibility(key: "country", equalsAnyOf: [.string(TaxIdCountry.vn.rawValue)])
        )
    ])

    private struct Params: Codable {
        var country: TaxIdCountry?
        var includeBranch: Bool?
    }

    private let country: TaxIdCountry
    private let includesBranch: Bool
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
        includesBranch = country == .vn && (decoded.includeBranch ?? false)
        try ColumnFit.requireRoom(
            for: includesBranch ? country.maximumLength : min(country.maximumLength, 11),
            column: column,
            generator: Self.identifier
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        switch country {
        case .us:
            return .text("\(digits(2))-\(digits(7))")
        case .vn:
            let core = digits(10)
            return .text(includesBranch ? "\(core)-\(digits(3))" : core)
        case .gb:
            return .text("GB\(digits(9))")
        case .de:
            return .text("DE\(digits(9))")
        }
    }

    private func digits(_ count: Int) -> String {
        var value = ""
        for _ in 0..<count {
            value.append(String(rng.nextInt(upperBound: 10)))
        }
        return value
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
