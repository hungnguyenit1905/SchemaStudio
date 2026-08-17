//
//  CommonParams.swift
//  TablePro
//

import Foundation

enum GenerationTextCase: String, Codable, Sendable, Hashable, CaseIterable {
    case unchanged
    case lowercase
    case uppercase
    case titlecase

    func apply(to value: String) -> String {
        switch self {
        case .unchanged: return value
        case .lowercase: return value.lowercased()
        case .uppercase: return value.uppercased()
        case .titlecase: return value.capitalized
        }
    }
}

enum GenerationSortOrder: String, Codable, Sendable, Hashable, CaseIterable {
    case unsorted
    case ascending
    case descending
}

struct CommonParams: Codable, Sendable, Hashable {
    var nullPercent: Int
    var blankPercent: Int
    var unique: Bool
    var prefix: String
    var suffix: String
    var textCase: GenerationTextCase
    var sortOrder: GenerationSortOrder

    init(
        nullPercent: Int = 0,
        blankPercent: Int = 0,
        unique: Bool = false,
        prefix: String = "",
        suffix: String = "",
        textCase: GenerationTextCase = .unchanged,
        sortOrder: GenerationSortOrder = .unsorted
    ) {
        self.nullPercent = nullPercent
        self.blankPercent = blankPercent
        self.unique = unique
        self.prefix = prefix
        self.suffix = suffix
        self.textCase = textCase
        self.sortOrder = sortOrder
    }

    static let none = CommonParams()

    var affix: String { prefix + suffix }

    var hasAffix: Bool { !prefix.isEmpty || !suffix.isEmpty }
}
