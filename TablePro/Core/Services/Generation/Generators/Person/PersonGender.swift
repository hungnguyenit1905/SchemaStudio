//
//  PersonGender.swift
//  TablePro
//

import Foundation

enum PersonGender: String, Codable, Sendable, CaseIterable {
    case male
    case female
    case any

    var label: String {
        switch self {
        case .male: return String(localized: "Male")
        case .female: return String(localized: "Female")
        case .any: return String(localized: "Any")
        }
    }

    var dataset: GenerationDataset? {
        switch self {
        case .male: return .firstNamesMale
        case .female: return .firstNamesFemale
        case .any: return nil
        }
    }

    static var paramChoices: [ParamChoice] {
        allCases.map { ParamChoice(value: $0.rawValue, label: $0.label) }
    }
}

/// The male and female lists resolved together, so a generator can draw a name
/// and know which list it came from. `FullName` needs that to keep a Vietnamese
/// middle name (`Văn` against `Thị`) agreeing with the given name.
struct GenderedNameSource {
    let male: LocaleWordSource
    let female: LocaleWordSource
    let requested: PersonGender

    init(locale: GenerationLocale, gender: PersonGender, generator: String) throws {
        male = try LocaleWordSource(.firstNamesMale, locale: locale, generator: generator)
        female = try LocaleWordSource(.firstNamesFemale, locale: locale, generator: generator)
        requested = gender
    }

    /// The names this source can actually hand out, which is only the requested
    /// gender's list. Counting both lists when one was asked for overstates the
    /// domain, and an overstated count lets an unfillable unique column through
    /// pre-flight.
    var candidates: [String] {
        switch requested {
        case .male: return male.words
        case .female: return female.words
        case .any: return male.words + female.words
        }
    }

    /// A name that reads either way sits in both lists, so the two lists laid end
    /// to end count it twice. `vi_VN` has `Hoàng Anh` in both.
    var distinctCount: Int { Set(candidates).count }

    func pick(using rng: inout SplitMix64) -> (name: String, gender: PersonGender) {
        let resolved: PersonGender
        switch requested {
        case .any: resolved = rng.rollsBelow(percent: 50) ? .female : .male
        case .male, .female: resolved = requested
        }
        let source = resolved == .female ? female : male
        return (source.pick(using: &rng), resolved)
    }
}
