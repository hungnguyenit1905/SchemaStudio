//
//  PersonGeneratorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// The person group has two things to prove. Its `distinctValueCount` must never
/// exceed what it can really produce, because `GenerationProfileValidator` trusts
/// that number to admit a unique column. And its names must read as names in the
/// locale asked for: the right word order, the right diacritics, and a Vietnamese
/// middle name that agrees with the given name.
@Suite("Person generators")
struct PersonGeneratorTests {
    private static let registry = GeneratorRegistry.standard

    private func generator(
        _ identifier: String,
        params: String = "{}",
        dataType: String = "text",
        allowedValues: [String]? = nil
    ) throws -> any ValueGenerator {
        try Self.registry.make(
            identifier: identifier,
            params: Data(params.utf8),
            column: GeneratorTestFixtures.column(dataType: dataType, allowedValues: allowedValues),
            seed: 21
        )
    }

    /// `limit` mirrors what `DecoratedGenerator` does to every text value on the
    /// way out, which is where a generator that writes a number into a narrow
    /// text column actually loses its variety.
    private func produced(_ generator: any ValueGenerator, draws: Int, limit: Int? = nil) throws -> [String] {
        let truncator = GenerationStringTruncator(unit: .unicodeScalars)
        return try (0..<draws).compactMap { index in
            let value = try generator.next(row: GeneratorTestFixtures.rowContext(rowIndex: index), index: index)
            guard case let .text(text) = value else { return nil }
            return truncator.truncate(text, to: limit)
        }
    }

    private func words(_ dataset: GenerationDataset, _ locale: GenerationLocale) throws -> [String] {
        try LocaleWordSource(dataset, locale: locale, generator: "test").words
    }

    // MARK: - Cardinality

    @Test("A name list never claims more values than a short column can hold", arguments: [
        ("FirstName", #"{"locale":"en_US"}"#),
        ("LastName", #"{"locale":"en_US"}"#),
        ("JobTitle", #"{"locale":"en_US"}"#),
        ("MiddleName", #"{"locale":"en_US"}"#),
        ("Title", #"{"locale":"en_US"}"#)
    ])
    func truncationIsNotCountedAsVariety(identifier: String, params: String) throws {
        let narrow = try generator(identifier, params: params, dataType: "varchar(3)")
        let claimed = try #require(narrow.distinctValueCount)
        let seen = Set(try produced(narrow, draws: 20_000))
        #expect(claimed >= seen.count, "\(identifier) claims \(claimed) but produced \(seen.count)")
    }

    /// `Hoàng Anh` is in both Vietnamese given-name lists, so laying the two lists
    /// end to end counts it twice. Every name it can hand out is still reachable,
    /// which is what separates this from an under-count.
    @Test("A name in both gender lists is counted once")
    func overlappingNamesAreCountedOnce() throws {
        let male = try words(.firstNamesMale, .viVN)
        let female = try words(.firstNamesFemale, .viVN)
        let overlap = Set(male).intersection(female)
        #expect(!overlap.isEmpty, "the vi_VN lists no longer overlap, so this case proves nothing")

        let anyGender = try generator("FirstName", params: #"{"locale":"vi_VN","gender":"any"}"#)
        #expect(anyGender.distinctValueCount == Set(male + female).count)
        #expect(anyGender.distinctValueCount != male.count + female.count)
    }

    @Test("Asking for one gender counts only that gender's list")
    func oneGenderCountsOneList() throws {
        let female = try words(.firstNamesFemale, .enUS)
        let single = try generator("FirstName", params: #"{"locale":"en_US","gender":"female"}"#)
        #expect(single.distinctValueCount == Set(female).count)
        #expect(Set(try produced(single, draws: 5_000)).isSubset(of: Set(female)))
    }

    @Test("An initial-only middle name counts initials, not names")
    func initialsAreCountedAsInitials() throws {
        let names = try words(.middleNames, .enUS)
        let initials = try generator("MiddleName", params: #"{"locale":"en_US","form":"initial"}"#)
        #expect(initials.distinctValueCount == Set(names.compactMap(\.first)).count)
        #expect(try produced(initials, draws: 500).allSatisfy { $0.count == 2 && $0.hasSuffix(".") })
    }

    // MARK: - Age

    @Test("An age column that stores text is counted as the digits it writes")
    func ageInATextColumnCountsDigits() throws {
        let narrow = try generator("Age", params: #"{"min":18,"max":80}"#, dataType: "varchar(1)")
        let claimed = try #require(narrow.distinctValueCount)
        let seen = Set(try produced(narrow, draws: 5_000, limit: 1))
        #expect(claimed >= seen.count)
        #expect(claimed < 63, "a one-character column cannot hold 63 distinct ages")
    }

    @Test("An age column that stores a number keeps the whole range")
    func ageInANumericColumnKeepsTheRange() throws {
        let numeric = try generator("Age", params: #"{"min":18,"max":80}"#, dataType: "integer")
        #expect(numeric.distinctValueCount == 63)
        #expect(numeric.integerDomain == 18...80)
    }

    /// The shuffle writes the drawn number out directly, skipping the value mapper
    /// and the length limit, so a text column must not offer one.
    @Test("A text age column offers no integer domain to shuffle")
    func ageOffersNoDomainWhenStoredAsText() throws {
        #expect(try generator("Age", dataType: "varchar(4)").integerDomain == nil)
        #expect(try generator("Age", dataType: "text").integerDomain == nil)
        #expect(try generator("Age", dataType: "integer").integerDomain != nil)
    }

    @Test("The age range is clamped and never inverts")
    func ageRangeIsClamped() throws {
        let inverted = try generator("Age", params: #"{"min":90,"max":10}"#, dataType: "integer")
        #expect(inverted.integerDomain == 90...90)
        let outOfBounds = try generator("Age", params: #"{"min":-40,"max":900}"#, dataType: "integer")
        #expect(outOfBounds.integerDomain == 0...150)
    }

    // MARK: - Gender

    @Test("Gender counts only the spellings a share can reach")
    func genderCountsReachableSpellingsOnly() throws {
        let byDefault = try generator("Gender")
        #expect(byDefault.distinctValueCount == 2)
        #expect(Set(try produced(byDefault, draws: 5_000)) == ["male", "female"])

        let withOther = try generator("Gender", params: #"{"femalePercent":45,"otherPercent":10}"#)
        #expect(withOther.distinctValueCount == 3)
        #expect(Set(try produced(withOther, draws: 5_000)) == ["male", "female", "other"])

        let femaleOnly = try generator("Gender", params: #"{"femalePercent":100}"#)
        #expect(femaleOnly.distinctValueCount == 1)
        #expect(Set(try produced(femaleOnly, draws: 1_000)) == ["female"])
    }

    /// A PostgreSQL enum arrives as its own type name, which is what carries the
    /// value list. The list wins over the `writing` parameter: a column that
    /// already spells the values gains nothing from a third vocabulary.
    @Test("Gender writes the spelling the column already uses")
    func genderFollowsTheColumnVocabulary() throws {
        let letters = try generator("Gender", params: #"{"writing":"letter","otherPercent":10}"#)
        #expect(Set(try produced(letters, draws: 5_000)) == ["M", "F", "X"])

        let enumerated = try generator(
            "Gender",
            params: #"{"writing":"word"}"#,
            dataType: "gender_kind",
            allowedValues: ["nu", "nam"]
        )
        #expect(Set(try produced(enumerated, draws: 2_000)) == ["nu", "nam"])
        #expect(enumerated.distinctValueCount == 2)
    }

    // MARK: - Full name

    @Test("English full names run given name then family name")
    func englishNameOrder() throws {
        let given = Set(try words(.firstNamesMale, .enUS) + words(.firstNamesFemale, .enUS))
        let family = Set(try words(.lastNames, .enUS))
        let full = try generator("FullName", params: #"{"locale":"en_US"}"#)
        for name in try produced(full, draws: 500) {
            let parts = name.split(separator: " ").map(String.init)
            #expect(parts.count >= 2)
            #expect(given.contains(parts[0]))
            #expect(family.contains(parts[parts.count - 1]))
        }
    }

    @Test("Vietnamese full names run family name then given name, with diacritics")
    func vietnameseNameOrder() throws {
        let given = Set(try words(.firstNamesMale, .viVN) + words(.firstNamesFemale, .viVN))
        let family = Set(try words(.lastNames, .viVN))
        let full = try generator("FullName", params: #"{"locale":"vi_VN"}"#)
        let names = try produced(full, draws: 500)
        for name in names {
            let parts = name.split(separator: " ").map(String.init)
            #expect(family.contains(parts[0]))
            #expect(given.contains(parts.dropFirst().joined(separator: " ")))
        }
        #expect(names.contains { $0.contains("ễ") || $0.contains("ầ") || $0.contains("ơ") })
    }

    /// The Vietnamese middle-name list is mostly ungendered, and the two entries
    /// that are gendered have to follow the given name rather than be drawn
    /// independently of it.
    @Test("A Vietnamese middle name comes from the list and agrees with the given name")
    func vietnameseMiddleNamesUseTheDataset() throws {
        let female = Set(try words(.firstNamesFemale, .viVN))
        let male = Set(try words(.firstNamesMale, .viVN))
        let middles = Set(try words(.middleNames, .viVN))
        let full = try generator("FullName", params: #"{"locale":"vi_VN","includeMiddle":true}"#)

        var used: Set<String> = []
        for name in try produced(full, draws: 2_000) {
            let parts = name.split(separator: " ").map(String.init)
            #expect(parts.count >= 3)
            let middle = parts[1]
            let givenName = parts.dropFirst(2).joined(separator: " ")
            #expect(middles.contains(middle))
            used.insert(middle)
            if middle == "Thị" { #expect(female.contains(givenName)) }
            if middle == "Văn" { #expect(male.contains(givenName)) }
        }
        #expect(used.count > 2, "every name got a gendered middle, so the list is unused")
    }

    @Test("An English full name can carry a middle name from the list")
    func englishMiddleNamesUseTheDataset() throws {
        let middles = Set(try words(.middleNames, .enUS))
        let full = try generator("FullName", params: #"{"locale":"en_US","includeMiddle":true}"#)
        for name in try produced(full, draws: 300) {
            let parts = name.split(separator: " ").map(String.init)
            #expect(parts.count == 3)
            #expect(middles.contains(parts[1]))
        }
    }

    // MARK: - National identifier

    @Test("US identifiers use a range the Social Security Administration never issues")
    func usIdentifiersAreNeverReal() throws {
        let separated = try generator("NationalID", params: #"{"country":"US","separated":true}"#)
        for value in try produced(separated, draws: 1_000) {
            let parts = value.split(separator: "-").map(String.init)
            #expect(parts.count == 3)
            #expect((900...999).contains(Int(parts[0]) ?? 0))
            #expect(parts[1].count == 2 && parts[2].count == 4)
        }

        let plain = try generator("NationalID", params: #"{"country":"US","separated":false}"#)
        #expect(try produced(plain, draws: 200).allSatisfy { $0.count == 9 && $0.allSatisfy(\.isNumber) })
    }

    @Test("Vietnamese identifiers are twelve digits")
    func vietnameseIdentifierShape() throws {
        let generated = try generator("NationalID", params: #"{"country":"VN"}"#)
        #expect(try produced(generated, draws: 500).allSatisfy { $0.count == 12 && $0.allSatisfy(\.isNumber) })
    }

    @Test("A column too short for an identifier is refused rather than truncated")
    func shortColumnsAreRefused() {
        #expect(throws: GenerationError.self) {
            _ = try generator("NationalID", params: #"{"country":"VN"}"#, dataType: "varchar(8)")
        }
        #expect(throws: GenerationError.self) {
            _ = try generator("NationalID", params: #"{"country":"US","separated":true}"#, dataType: "varchar(9)")
        }
    }

    // MARK: - Locales

    @Test("An unknown locale falls back to English rather than throwing")
    func unknownLocaleFallsBack() throws {
        let fallback = try generator("LastName", params: #"{"locale":"fr_FR"}"#)
        let english = Set(try words(.lastNames, .enUS))
        #expect(Set(try produced(fallback, draws: 500)).isSubset(of: english))
    }

    @Test("Every person generator has data for every locale", arguments: GenerationLocale.allCases)
    func everyLocaleHasData(locale: GenerationLocale) throws {
        let identifiers = ["FirstName", "LastName", "MiddleName", "FullName", "JobTitle", "Title"]
        for identifier in identifiers {
            let generated = try generator(identifier, params: #"{"locale":"\#(locale.rawValue)"}"#)
            #expect(try produced(generated, draws: 50).allSatisfy { !$0.isEmpty })
        }
    }
}
