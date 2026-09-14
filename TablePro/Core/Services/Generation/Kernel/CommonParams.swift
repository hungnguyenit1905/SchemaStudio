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

struct CommonParams: Codable, Sendable, Hashable {
    var nullPercent: Int
    var blankPercent: Int
    var unique: Bool
    var prefix: String
    var suffix: String
    var textCase: GenerationTextCase

    init(
        nullPercent: Int = 0,
        blankPercent: Int = 0,
        unique: Bool = false,
        prefix: String = "",
        suffix: String = "",
        textCase: GenerationTextCase = .unchanged
    ) {
        self.nullPercent = nullPercent
        self.blankPercent = blankPercent
        self.unique = unique
        self.prefix = prefix
        self.suffix = suffix
        self.textCase = textCase
    }

    /// Written by hand because a synthesized `init(from:)` ignores the property
    /// defaults above and throws `keyNotFound` for every key a saved profile
    /// happens not to carry. `decodeIfPresent` is also what lets a profile
    /// exported before `sortOrder` was removed keep importing: the key has no
    /// `CodingKeys` case any more, so the decoder just ignores it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nullPercent = try container.decodeIfPresent(Int.self, forKey: .nullPercent) ?? 0
        blankPercent = try container.decodeIfPresent(Int.self, forKey: .blankPercent) ?? 0
        unique = try container.decodeIfPresent(Bool.self, forKey: .unique) ?? false
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try container.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        textCase = try container.decodeIfPresent(GenerationTextCase.self, forKey: .textCase) ?? .unchanged
    }

    static let none = CommonParams()

    var affix: String { prefix + suffix }

    var hasAffix: Bool { !prefix.isEmpty || !suffix.isEmpty }
}
