//
//  UrlGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class UrlGenerator: ValueGenerator {
    static let identifier = "URL"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        ),
        ParamField(
            key: "scheme",
            label: "Scheme",
            type: .choice([ParamChoice(value: "https"), ParamChoice(value: "http")]),
            defaultValue: .string("https")
        ),
        ParamField(key: "includePath", label: "Add a path", type: .toggle, defaultValue: .bool(true)),
        ParamField(
            key: "topLevels",
            label: "Top-level domains",
            type: .stringList,
            defaultValue: .array([]),
            help: String(localized: "Leave empty to use the reserved names that can never resolve.")
        )
    ])

    private struct Params: Codable {
        var locale: String?
        var scheme: String?
        var includePath: Bool?
        var topLevels: [String]?
    }

    private let domains: DomainSource
    private let paths: [String]
    private let prefix: String
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
        let source = try DomainSource(
            locale: locale,
            topLevels: decoded.topLevels ?? [],
            generator: Self.identifier
        )
        domains = source
        prefix = (decoded.scheme == "http" ? "http" : "https") + "://"

        if decoded.includePath ?? true {
            let nouns = try LocaleWordSource(.productNouns, locale: locale, generator: Self.identifier).words
            paths = Set(nouns.map { AsciiSlug.joined($0, separator: "-") }).filter { !$0.isEmpty }.sorted()
        } else {
            paths = []
        }

        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator
        let resolvedPrefix = prefix
        let resolvedPaths = paths
        let (product, overflowed) = source.distinctCount.multipliedReportingOverflow(by: max(1, resolvedPaths.count))
        distinctCount = overflowed ? nil : TruncatedCardinality.count(
            maxLength: column.maxLength,
            truncator: resolvedTruncator,
            product: product,
            combinations: {
                source.combinations.flatMap { host in
                    Self.render(prefix: resolvedPrefix, host: host, paths: resolvedPaths)
                }
            }
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let host = prefix + domains.pick(using: &rng)
        guard !paths.isEmpty else { return .text(truncator.truncate(host, to: maxLength)) }
        let path = paths[rng.nextInt(upperBound: paths.count)]
        return .text(truncator.truncate("\(host)/\(path)", to: maxLength))
    }

    private static func render(prefix: String, host: String, paths: [String]) -> [String] {
        guard !paths.isEmpty else { return [prefix + host] }
        return paths.map { "\(prefix)\(host)/\($0)" }
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
