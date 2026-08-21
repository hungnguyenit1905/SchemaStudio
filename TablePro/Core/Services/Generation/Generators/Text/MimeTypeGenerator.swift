//
//  MimeTypeGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// IANA media types, filtered by top-level type so an `avatar_content_type`
/// column can be held to images.
final class MimeTypeGenerator: ValueGenerator {
    static let identifier = "MimeType"
    static let paramSchema = ParamSchema(fields: [
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
            key: "types",
            label: "Types",
            type: .stringList,
            defaultValue: .array([]),
            help: String(localized: "Leave empty to draw from the common media types.")
        )
    ])

    private struct Params: Codable {
        var category: String?
        var types: [String]?
    }

    private let types: [String]
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
        let requested = decoded.types ?? []
        let resolved = requested.isEmpty ? MimeTypeCatalog.types(category: decoded.category ?? "any") : requested
        guard !resolved.isEmpty else {
            throw GenerationError.invalidParameters(generator: Self.identifier, reason: "the type list is empty")
        }
        types = resolved
        maxLength = column.maxLength
        let resolvedTruncator = GenerationStringTruncator.forVendor(nil)
        truncator = resolvedTruncator
        distinctCount = TruncatedCardinality.count(
            maxLength: column.maxLength,
            truncator: resolvedTruncator,
            product: Set(resolved).count,
            combinations: { resolved }
        )
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { distinctCount }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .text(truncator.truncate(types[rng.nextInt(upperBound: types.count)], to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
