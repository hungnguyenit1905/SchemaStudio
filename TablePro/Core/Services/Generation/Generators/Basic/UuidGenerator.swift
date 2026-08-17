//
//  UuidGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Bytes come from the column's own stream rather than `UUID()`, which draws
/// from the system CSPRNG and would make a seeded run unrepeatable.
final class UuidGenerator: ValueGenerator {
    static let identifier = "UUID"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "version",
            label: "Version",
            type: .choice([ParamChoice(value: "4", label: String(localized: "4, random"))]),
            defaultValue: .int(4)
        ),
        ParamField(key: "uppercase", label: "Uppercase", type: .toggle, defaultValue: .bool(false))
    ])

    private struct Params: Codable {
        var version: Int?
        var uppercase: Bool?
    }

    private let emitsText: Bool
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
        guard (decoded.version ?? 4) == 4 else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "only version 4 is supported"
            )
        }
        emitsText = column.type.base != .uuid
        uppercase = decoded.uppercase ?? false
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? { Int.max }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let identifier = Self.version4(high: rng.next(), low: rng.next())
        guard emitsText else { return .uuid(identifier) }
        let text = identifier.uuidString
        return .text(uppercase ? text : text.lowercased())
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }

    private static func version4(high: UInt64, low: UInt64) -> UUID {
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: high >> UInt64(shift)))
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: low >> UInt64(shift)))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
