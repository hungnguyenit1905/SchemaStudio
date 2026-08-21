//
//  FileNameGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// A file name built from the same product words the catalog already ships, so
/// an uploads table reads like one: `wireless-adapter.pdf` rather than a random
/// string with a dot in it.
final class FileNameGenerator: ValueGenerator {
    static let identifier = "FileName"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        ),
        ParamField(
            key: "category",
            label: "Kind",
            type: .choice(
                [ParamChoice(value: "any", label: String(localized: "Any"))]
                    + MimeTypeCatalog.categories.map { ParamChoice(value: $0) }
            ),
            defaultValue: .string("any")
        ),
        ParamField(
            key: "extensions",
            label: "Extensions",
            type: .stringList,
            defaultValue: .array([]),
            help: String(localized: "Leave empty to use the extensions that match the chosen kind.")
        ),
        ParamField(key: "separator", label: "Separator", type: .text, defaultValue: .string("-"))
    ])

    private struct Params: Codable {
        var locale: String?
        var category: String?
        var extensions: [String]?
        var separator: String?
    }

    private let stems: [String]
    private let extensions: [String]
    private let truncator: GenerationStringTruncator
    private let maxLength: Int?
    private let distinctCount: Int?
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let locale = GenerationLocale.resolve(decoded.locale)
        let adjectives = try LocaleWordSource(.productAdjectives, locale: locale, generator: Self.identifier).words
        let nouns = try LocaleWordSource(.productNouns, locale: locale, generator: Self.identifier).words
        let separator = decoded.separator ?? "-"
        stems = Self.stems(adjectives: adjectives, nouns: nouns, separator: separator)

        let requested = (decoded.extensions ?? []).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
        let resolved = requested.filter { !$0.isEmpty }
        extensions = resolved.isEmpty
            ? MimeTypeCatalog.fileExtensions(category: decoded.category ?? "any")
            : resolved
        guard !stems.isEmpty, !extensions.isEmpty else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "there are no words or no extensions to build a file name from"
            )
        }

        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator
        let resolvedStems = stems
        let resolvedExtensions = extensions
        let (product, overflowed) = resolvedStems.count.multipliedReportingOverflow(by: resolvedExtensions.count)
        distinctCount = overflowed ? nil : TruncatedCardinality.count(
            maxLength: column.maxLength,
            truncator: resolvedTruncator,
            product: product,
            combinations: {
                resolvedStems.flatMap { stem in resolvedExtensions.map { "\(stem).\($0)" } }
            }
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let stem = stems[rng.nextInt(upperBound: stems.count)]
        let fileExtension = extensions[rng.nextInt(upperBound: extensions.count)]
        return .text(truncator.truncate("\(stem).\(fileExtension)", to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }

    /// Built once and de-duplicated, because two different display words can fold
    /// to the same slug and a name counted twice overstates the distinct count.
    private static func stems(adjectives: [String], nouns: [String], separator: String) -> [String] {
        var seen: Set<String> = []
        var built: [String] = []
        for adjective in adjectives {
            let head = AsciiSlug.joined(adjective, separator: separator)
            guard !head.isEmpty else { continue }
            for noun in nouns {
                let tail = AsciiSlug.joined(noun, separator: separator)
                guard !tail.isEmpty else { continue }
                let stem = head + separator + tail
                guard seen.insert(stem).inserted else { continue }
                built.append(stem)
            }
        }
        return built
    }
}
