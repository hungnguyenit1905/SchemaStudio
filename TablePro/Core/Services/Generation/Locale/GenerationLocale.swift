//
//  GenerationLocale.swift
//  TablePro
//

import Foundation

/// The locales the catalog ships data for. Deliberately a small closed set: each
/// one costs a hand-curated dataset, so adding a case is a decision rather than a
/// configuration value a user can type.
enum GenerationLocale: String, Codable, Sendable, CaseIterable {
    case enUS = "en_US"
    case viVN = "vi_VN"

    static let fallback = GenerationLocale.enUS

    static func resolve(_ raw: String?) -> GenerationLocale {
        guard let raw, let match = GenerationLocale(rawValue: raw) else { return fallback }
        return match
    }

    var displayName: String {
        switch self {
        case .enUS: return String(localized: "English (United States)")
        case .viVN: return String(localized: "Vietnamese (Vietnam)")
        }
    }

    static var paramChoices: [ParamChoice] {
        allCases.map { ParamChoice(value: $0.rawValue, label: $0.displayName) }
    }
}

/// The datasets a locale directory may contain. An enum rather than free strings
/// so a typo in a generator is a compile error, not an empty list at run time.
enum GenerationDataset: String, Sendable, CaseIterable {
    case firstNamesMale = "first-names-male"
    case firstNamesFemale = "first-names-female"
    case lastNames = "last-names"
    case companyWords = "company-words"
    case companySuffixes = "company-suffixes"
    case departments = "departments"
    case productAdjectives = "product-adjectives"
    case productNouns = "product-nouns"
    case jobTitles = "job-titles"
    case middleNames = "middle-names"
    case titles
    case emailDomains = "email-domains"
    case streetNames = "street-names"
    case localities
}
