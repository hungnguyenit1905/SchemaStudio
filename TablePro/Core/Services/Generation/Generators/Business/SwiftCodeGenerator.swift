//
//  SwiftCodeGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// ISO 9362: four letters for the institution, two for the country, two
/// alphanumerics for the location, and an optional three-character branch.
final class SwiftCodeGenerator: ValueGenerator {
    static let identifier = "SWIFT"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "includeBranch",
            label: "Include branch code",
            type: .toggle,
            defaultValue: .bool(false),
            help: String(localized: "Adds the trailing three characters, making an 11-character code.")
        )
    ])

    private struct Params: Codable {
        var includeBranch: Bool?
    }

    private static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let alphanumerics = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let countries = ["US", "GB", "DE", "FR", "NL", "ES", "IT", "JP", "SG", "VN", "AU", "CA"]

    private let includeBranch: Bool
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        includeBranch = decoded.includeBranch ?? false
        try ColumnFit.requireRoom(for: includeBranch ? 11 : 8, column: column, generator: Self.identifier)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        var code = ""
        for _ in 0..<4 {
            code.append(Self.letters[rng.nextInt(upperBound: Self.letters.count)])
        }
        code += Self.countries[rng.nextInt(upperBound: Self.countries.count)]
        for _ in 0..<2 {
            code.append(Self.alphanumerics[rng.nextInt(upperBound: Self.alphanumerics.count)])
        }
        guard includeBranch else { return .text(code) }
        for _ in 0..<3 {
            code.append(Self.alphanumerics[rng.nextInt(upperBound: Self.alphanumerics.count)])
        }
        return .text(code)
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
