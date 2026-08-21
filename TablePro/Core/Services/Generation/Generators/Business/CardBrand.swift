//
//  CardBrand.swift
//  TablePro
//

import Foundation

/// Issuer identification ranges as published by the card networks. Shared by the
/// number, expiry and security-code generators so a profile that names a brand
/// gets a matching set across all three columns.
enum CardBrand: String, Codable, Sendable, CaseIterable {
    case visa
    case mastercard
    case amex
    case discover
    case jcb
    case any

    /// The digit groups a number of this brand may open with. Each entry is
    /// picked whole, so a range like JCB's is enumerated rather than expressed as
    /// bounds the caller would have to reinterpret.
    var prefixes: [String] {
        switch self {
        case .visa: return ["4"]
        case .mastercard: return ["51", "52", "53", "54", "55"]
        case .amex: return ["34", "37"]
        case .discover: return ["6011", "65"]
        case .jcb: return (3_528...3_589).map(String.init)
        case .any: return []
        }
    }

    var numberLength: Int {
        switch self {
        case .amex: return 15
        case .visa, .mastercard, .discover, .jcb, .any: return 16
        }
    }

    var securityCodeLength: Int {
        switch self {
        case .amex: return 4
        case .visa, .mastercard, .discover, .jcb, .any: return 3
        }
    }

    static var issuing: [CardBrand] { allCases.filter { $0 != .any } }

    static var paramChoices: [ParamChoice] {
        [
            ParamChoice(value: CardBrand.any.rawValue, label: String(localized: "Any brand")),
            ParamChoice(value: CardBrand.visa.rawValue, label: "Visa"),
            ParamChoice(value: CardBrand.mastercard.rawValue, label: "Mastercard"),
            ParamChoice(value: CardBrand.amex.rawValue, label: "American Express"),
            ParamChoice(value: CardBrand.discover.rawValue, label: "Discover"),
            ParamChoice(value: CardBrand.jcb.rawValue, label: "JCB")
        ]
    }
}
