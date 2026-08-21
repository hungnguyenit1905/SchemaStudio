//
//  HandleSource.swift
//  TablePro
//

import Foundation

enum HandleStyle: String, Codable, Sendable, CaseIterable {
    case firstDotLast
    case firstUnderscoreLast
    case firstInitialLast
    case nameWithNumber

    var label: String {
        switch self {
        case .firstDotLast: return String(localized: "first.last")
        case .firstUnderscoreLast: return String(localized: "first_last")
        case .firstInitialLast: return String(localized: "flast")
        case .nameWithNumber: return String(localized: "firstlast42")
        }
    }

    static var paramChoices: [ParamChoice] {
        allCases.map { ParamChoice(value: $0.rawValue, label: $0.label) }
    }
}

/// The part of an email address or a username that comes from a person's name.
/// Shared so `Email` and `Username` fold and spell a name the same way, which is
/// what makes `nguyen.thi.huong@example.com` and `nthihuong` recognisably the
/// same person when a table carries both columns.
struct HandleSource {
    /// The two-digit tail `nameWithNumber` appends. Fixed width so the handles
    /// stay the same length as each other and nothing has to guess how many
    /// digits a given draw produced.
    static let numberRange = 10...99

    private let given: GenderedNameSource
    private let family: LocaleWordSource
    private let style: HandleStyle

    init(locale: GenerationLocale, style: HandleStyle, generator: String) throws {
        given = try GenderedNameSource(locale: locale, gender: .any, generator: generator)
        family = try LocaleWordSource(.lastNames, locale: locale, generator: generator)
        self.style = style
    }

    func pick(using rng: inout SplitMix64) -> String {
        let handle = Self.render(
            given: given.pick(using: &rng).name,
            family: family.pick(using: &rng),
            style: style
        )
        guard style == .nameWithNumber else { return handle }
        return handle + String(rng.nextInt(in: Self.numberRange))
    }

    /// Every handle these name lists can spell. Only read when `distinctCount`
    /// has already found the list small enough to enumerate.
    var combinations: [String] {
        var all: [String] = []
        for name in Set(given.candidates) {
            for surname in Set(family.words) {
                let handle = Self.render(given: name, family: surname, style: style)
                guard style == .nameWithNumber else {
                    all.append(handle)
                    continue
                }
                all.append(contentsOf: Self.numberRange.map { handle + String($0) })
            }
        }
        return all
    }

    /// Folding is lossy, so two different names can land on the same handle and
    /// the cross product overstates the domain. The list is deduplicated instead,
    /// which means it has to be small enough to enumerate: `nameWithNumber`
    /// multiplies it by ninety and usually lands past that, reporting "not
    /// computable" rather than a number pre-flight would trust.
    var distinctCount: Int? {
        let names = Set(given.candidates).count
        let surnames = Set(family.words).count
        let multiplier = style == .nameWithNumber ? Self.numberRange.count : 1
        let (pairs, pairOverflow) = names.multipliedReportingOverflow(by: surnames)
        guard !pairOverflow else { return nil }
        let (total, totalOverflow) = pairs.multipliedReportingOverflow(by: multiplier)
        guard !totalOverflow, total <= TruncatedCardinality.inspectionLimit else { return nil }
        return Set(combinations).count
    }

    /// A name that folds away to nothing would leave an address with an empty
    /// local part, which is not an address at all.
    private static let fallback = "user"

    private static func render(given: String, family: String, style: HandleStyle) -> String {
        let nameParts = AsciiSlug.words(given)
        let surnameParts = AsciiSlug.words(family)
        let rendered: String
        switch style {
        case .firstDotLast: rendered = (nameParts + surnameParts).joined(separator: ".")
        case .firstUnderscoreLast: rendered = (nameParts + surnameParts).joined(separator: "_")
        case .firstInitialLast: rendered = String(nameParts.joined().prefix(1)) + surnameParts.joined()
        case .nameWithNumber: rendered = nameParts.joined() + surnameParts.joined()
        }
        return rendered.isEmpty ? fallback : rendered
    }
}
