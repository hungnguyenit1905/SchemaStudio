//
//  IPv6Generator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// `2001:db8::/32` is the block RFC 3849 reserves for documentation and
/// `fd00::/8` is unique local, so neither can route to a real host.
enum IPv6Block: String, Codable, Sendable, CaseIterable {
    case documentation
    case uniqueLocal

    var label: String {
        switch self {
        case .documentation: return String(localized: "Documentation (RFC 3849)")
        case .uniqueLocal: return String(localized: "Unique local (RFC 4193)")
        }
    }

    var leadingGroups: [String] {
        switch self {
        case .documentation: return ["2001", "0db8"]
        case .uniqueLocal: return ["fd00"]
        }
    }

    static var paramChoices: [ParamChoice] {
        allCases.map { ParamChoice(value: $0.rawValue, label: $0.label) }
    }
}

final class IPv6Generator: ValueGenerator {
    static let identifier = "IPv6"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "block",
            label: "Address block",
            type: .choice(IPv6Block.paramChoices),
            defaultValue: .string(IPv6Block.documentation.rawValue)
        ),
        ParamField(key: "uppercase", label: "Uppercase", type: .toggle, defaultValue: .bool(false))
    ])

    private struct Params: Codable {
        var block: IPv6Block?
        var uppercase: Bool?
    }

    private static let groupCount = 8
    private static let maximumLength = 39

    private let leadingGroups: [String]
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
        leadingGroups = (decoded.block ?? .documentation).leadingGroups
        uppercase = decoded.uppercase ?? false
        try ColumnFit.requireRoom(for: Self.maximumLength, column: column, generator: Self.identifier)
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    /// At least six free groups of sixteen bits each, which is past anything a
    /// row count can reach, so pre-flight reads it as "wide enough".
    var distinctValueCount: Int? { Int.max }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        var groups = leadingGroups
        while groups.count < Self.groupCount {
            groups.append(String(format: "%04x", rng.nextInt(upperBound: 0x1_0000)))
        }
        let address = groups.joined(separator: ":")
        return .text(uppercase ? address.uppercased() : address)
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
