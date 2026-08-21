//
//  EmailGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Addresses are built from the locale's name lists and the shipped domain list,
/// which holds only domains RFC 2606 and RFC 6761 reserve. A generated address
/// therefore cannot reach a real inbox, which matters the first time a test run
/// is pointed at a staging database that still has mail enabled.
final class EmailGenerator: ValueGenerator {
    static let identifier = "Email"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "locale",
            label: "Locale",
            type: .choice(GenerationLocale.paramChoices),
            defaultValue: .string(GenerationLocale.fallback.rawValue)
        ),
        ParamField(
            key: "style",
            label: "Written as",
            type: .choice(HandleStyle.paramChoices),
            defaultValue: .string(HandleStyle.firstDotLast.rawValue)
        ),
        ParamField(
            key: "domains",
            label: "Domains",
            type: .stringList,
            defaultValue: .array([]),
            help: String(localized: "Leave empty to use the reserved domains that can never receive mail.")
        )
    ])

    private struct Params: Codable {
        var locale: String?
        var style: HandleStyle?
        var domains: [String]?
    }

    private let handles: HandleSource
    private let domains: [String]
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
        let source = try HandleSource(
            locale: locale,
            style: decoded.style ?? .firstDotLast,
            generator: Self.identifier
        )
        handles = source

        let requested = (decoded.domains ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let resolved = requested.isEmpty
            ? try LocaleWordSource(.emailDomains, locale: locale, generator: Self.identifier).words
            : requested
        domains = Array(Set(resolved)).sorted()

        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator
        distinctCount = Self.resolveDistinctCount(
            handles: source,
            domains: domains,
            truncator: resolvedTruncator,
            maxLength: column.maxLength
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let handle = handles.pick(using: &rng)
        let domain = domains[rng.nextInt(upperBound: domains.count)]
        return .text(truncator.truncate("\(handle)@\(domain)", to: maxLength))
    }

    private static func resolveDistinctCount(
        handles: HandleSource,
        domains: [String],
        truncator: GenerationStringTruncator,
        maxLength: Int?
    ) -> Int? {
        guard let handleCount = handles.distinctCount else { return nil }
        let (product, overflowed) = handleCount.multipliedReportingOverflow(by: domains.count)
        guard !overflowed else { return nil }
        return TruncatedCardinality.count(
            maxLength: maxLength,
            truncator: truncator,
            product: product,
            combinations: { handles.combinations.flatMap { handle in domains.map { "\(handle)@\($0)" } } }
        )
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
