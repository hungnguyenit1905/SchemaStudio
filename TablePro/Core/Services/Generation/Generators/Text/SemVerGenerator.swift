//
//  SemVerGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Semantic versions, optionally with a prerelease tag on some share of the rows
/// so a releases table carries both `2.4.0` and `2.4.0-rc.1`.
final class SemVerGenerator: ValueGenerator {
    static let identifier = "SemVer"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "maxMajor",
            label: "Highest major",
            type: .integer(minimum: 0, maximum: nil),
            defaultValue: .int(9
        )),
        ParamField(
            key: "maxMinor",
            label: "Highest minor",
            type: .integer(minimum: 0, maximum: nil),
            defaultValue: .int(20
        )),
        ParamField(
            key: "maxPatch",
            label: "Highest patch",
            type: .integer(minimum: 0, maximum: nil),
            defaultValue: .int(20
        )),
        ParamField(key: "prefixed", label: "Write a leading v", type: .toggle, defaultValue: .bool(false)),
        ParamField(
            key: "prereleasePercent",
            label: "Prerelease share",
            type: .integer(minimum: 0, maximum: 100),
            defaultValue: .int(0)
        )
    ])

    private struct Params: Codable {
        var maxMajor: Int?
        var maxMinor: Int?
        var maxPatch: Int?
        var prefixed: Bool?
        var prereleasePercent: Int?
    }

    private static let prereleaseNames = ["alpha", "beta", "rc"]
    private static let prereleaseNumbers = 1...9

    private let maxMajor: Int
    private let maxMinor: Int
    private let maxPatch: Int
    private let prefix: String
    private let prereleasePercent: Int
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
        maxMajor = max(0, decoded.maxMajor ?? 9)
        maxMinor = max(0, decoded.maxMinor ?? 20)
        maxPatch = max(0, decoded.maxPatch ?? 20)
        prefix = (decoded.prefixed ?? false) ? "v" : ""
        prereleasePercent = min(100, max(0, decoded.prereleasePercent ?? 0))
        maxLength = column.maxLength
        truncator = .forVendor(nil)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    /// The prerelease tags multiply the count only where they can actually appear,
    /// and a 100% share removes the plain form rather than adding to it.
    var distinctValueCount: Int? {
        let releases = (maxMajor + 1) * (maxMinor + 1) * (maxPatch + 1)
        let tags = Self.prereleaseNames.count * Self.prereleaseNumbers.count
        switch prereleasePercent {
        case 0: return releases
        case 100: return releases * tags
        default: return releases * (tags + 1)
        }
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let major = rng.nextInt(in: 0...maxMajor)
        let minor = rng.nextInt(in: 0...maxMinor)
        let patch = rng.nextInt(in: 0...maxPatch)
        var version = "\(prefix)\(major).\(minor).\(patch)"
        if rng.rollsBelow(percent: prereleasePercent) {
            let name = Self.prereleaseNames[rng.nextInt(upperBound: Self.prereleaseNames.count)]
            version += "-\(name).\(rng.nextInt(in: Self.prereleaseNumbers))"
        }
        return .text(truncator.truncate(version, to: maxLength))
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
