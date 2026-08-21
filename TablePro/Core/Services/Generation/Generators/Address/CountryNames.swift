//
//  CountryNames.swift
//  TablePro
//

import Foundation

/// Country names for the codes the locality datasets carry. A short map in code
/// rather than a column in every locality row, which would repeat the same
/// string thousands of times inside the bundle-size budget.
enum CountryNames {
    private static let english: [String: String] = [
        "US": "United States",
        "VN": "Vietnam"
    ]

    private static let vietnamese: [String: String] = [
        "US": "Hoa Kỳ",
        "VN": "Việt Nam"
    ]

    static func name(forCode code: String, locale: GenerationLocale) -> String {
        let table = locale == .viVN ? vietnamese : english
        return table[code.uppercased()] ?? code
    }
}
