//
//  MacAddressGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum MacAddressWriting: String, Codable, Sendable, CaseIterable {
    case colons
    case hyphens
    case dotted

    var label: String {
        switch self {
        case .colons: return String(localized: "Colons, such as 02:1a:2b:3c:4d:5e")
        case .hyphens: return String(localized: "Hyphens, such as 02-1A-2B-3C-4D-5E")
        case .dotted: return String(localized: "Dotted, such as 021a.2b3c.4d5e")
        }
    }

    static var paramChoices: [ParamChoice] {
        allCases.map { ParamChoice(value: $0.rawValue, label: $0.label) }
    }
}

/// The first octet always has the locally administered bit set and the multicast
/// bit clear, so a generated address can never collide with a real vendor's
/// assigned range.
final class MacAddressGenerator: ValueGenerator {
    static let identifier = "MACAddress"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "writing",
            label: "Written as",
            type: .choice(MacAddressWriting.paramChoices),
            defaultValue: .string(MacAddressWriting.colons.rawValue)
        ),
        ParamField(key: "uppercase", label: "Uppercase", type: .toggle, defaultValue: .bool(false))
    ])

    private struct Params: Codable {
        var writing: MacAddressWriting?
        var uppercase: Bool?
    }

    private static let octetCount = 6
    private static let locallyAdministered = 0x02
    private static let multicast = 0x01

    private let writing: MacAddressWriting
    private let uppercase: Bool
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        writing = decoded.writing ?? .colons
        uppercase = decoded.uppercase ?? false
        try ColumnFit.requireRoom(for: Self.length(for: writing), column: column, generator: Self.identifier)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    /// Two bits of the first octet are fixed, leaving forty-six free, which is
    /// past anything a row count can reach.
    var distinctValueCount: Int? { Int.max }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        var octets: [Int] = [(rng.nextInt(upperBound: 256) | Self.locallyAdministered) & ~Self.multicast]
        while octets.count < Self.octetCount {
            octets.append(rng.nextInt(upperBound: 256))
        }
        let hex = octets.map { String(format: "%02x", $0) }
        let address = Self.write(hex, as: writing)
        return .text(uppercase ? address.uppercased() : address)
    }

    private static func write(_ hex: [String], as writing: MacAddressWriting) -> String {
        switch writing {
        case .colons: return hex.joined(separator: ":")
        case .hyphens: return hex.joined(separator: "-")
        case .dotted: return stride(from: 0, to: hex.count, by: 2)
            .map { hex[$0] + hex[$0 + 1] }
            .joined(separator: ".")
        }
    }

    private static func length(for writing: MacAddressWriting) -> Int {
        write(Array(repeating: "ff", count: octetCount), as: writing).count
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
