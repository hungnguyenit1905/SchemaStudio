//
//  FullNameGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Name order is the part that has to be right per locale. English runs given
/// name, middle, family name. Vietnamese runs family name, middle, given name,
/// and two of its middle names are gendered (`Văn` for men, `Thị` for women),
/// so drawing one of those pair is corrected to agree with the given name. The
/// rest of the Vietnamese list carries no gender and is used as drawn.
final class FullNameGenerator: ValueGenerator {
    static let identifier = "FullName"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        ),
        ParamField(
            key: "gender",
            label: "Gender",
            type: .choice(PersonGender.paramChoices),
            defaultValue: .string(PersonGender.any.rawValue)
        ),
        ParamField(key: "includeMiddle", label: "Include a middle name", type: .toggle, defaultValue: .bool(false))
    ])

    private struct Params: Codable {
        var locale: String?
        var gender: PersonGender?
        var includeMiddle: Bool?
    }

    private static let vietnameseMaleMiddle = "Văn"
    private static let vietnameseFemaleMiddle = "Thị"
    private static let vietnameseGenderedMiddles: Set<String> = [vietnameseMaleMiddle, vietnameseFemaleMiddle]

    private let given: GenderedNameSource
    private let family: LocaleWordSource
    private let middle: LocaleWordSource?
    private let locale: GenerationLocale
    private let truncator: GenerationStringTruncator
    private let maxLength: Int?
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        locale = GenerationLocale.resolve(decoded.locale)
        given = try GenderedNameSource(
            locale: locale,
            gender: decoded.gender ?? .any,
            generator: Self.identifier
        )
        family = try LocaleWordSource(.lastNames, locale: locale, generator: Self.identifier)
        middle = (decoded.includeMiddle ?? false)
            ? try LocaleWordSource(.middleNames, locale: locale, generator: Self.identifier)
            : nil
        maxLength = column.maxLength
        truncator = .forVendor(nil)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let picked = given.pick(using: &rng)
        let surname = family.pick(using: &rng)
        var parts: [String]
        if locale == .viVN {
            parts = [surname]
            if let middle {
                parts.append(Self.vietnameseMiddle(middle.pick(using: &rng), gender: picked.gender))
            }
            parts.append(picked.name)
        } else {
            parts = [picked.name]
            if let middle { parts.append(middle.pick(using: &rng)) }
            parts.append(surname)
        }
        return .text(truncator.truncate(parts.joined(separator: " "), to: maxLength))
    }

    private static func vietnameseMiddle(_ word: String, gender: PersonGender) -> String {
        guard vietnameseGenderedMiddles.contains(word) else { return word }
        return gender == .female ? vietnameseFemaleMiddle : vietnameseMaleMiddle
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
