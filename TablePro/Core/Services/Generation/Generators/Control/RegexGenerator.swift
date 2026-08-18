//
//  RegexGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class RegexGenerator: ValueGenerator {
    static let identifier = "Regex"
    static let defaultRepeatCap = 16

    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "pattern",
            label: "Pattern",
            type: .text,
            defaultValue: .string("[A-Z]{3}-[0-9]{4}"),
            help: String(localized: "Literals, character classes, quantifiers, alternation, groups and anchors.")
        ),
        ParamField(
            key: "maxRepeat",
            label: "Repeat limit",
            type: .integer(minimum: 1, maximum: 1_000),
            defaultValue: .int(defaultRepeatCap),
            help: String(localized: "How many times *, + and {n,} repeat at most.")
        )
    ])

    private struct Params: Codable {
        var pattern: String?
        var maxRepeat: Int?
    }

    private let node: RegexPatternNode
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let pattern = decoded.pattern ?? ""
        guard !pattern.isEmpty else {
            throw GenerationError.invalidParameters(generator: Self.identifier, reason: "no pattern was written")
        }
        let requestedCap = decoded.maxRepeat ?? Self.defaultRepeatCap
        let cap = min(max(1, requestedCap), column.maxLength ?? requestedCap)
        do {
            node = try RegexPatternParser.parse(pattern, repeatCap: cap)
        } catch let error as RegexPatternError {
            throw GenerationError.invalidParameters(generator: Self.identifier, reason: error.reason)
        }
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        .text(RegexStringSynthesizer.synthesize(node, using: &rng))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
