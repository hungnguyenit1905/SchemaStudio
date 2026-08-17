//
//  RandomBytesGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class RandomBytesGenerator: ValueGenerator {
    static let identifier = "RandomBytes"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "minLength",
            label: "Fewest bytes",
            type: .integer(minimum: 0, maximum: nil),
            defaultValue: .int(8)
        ),
        ParamField(
            key: "maxLength",
            label: "Most bytes",
            type: .integer(minimum: 0, maximum: nil),
            defaultValue: .int(32)
        )
    ])

    private struct Params: Codable {
        var minLength: Int?
        var maxLength: Int?
    }

    private let lengthRange: ClosedRange<Int>
    private let seed: UInt64
    private var rng: SplitMix64

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        let decoded = try GenerationParams.decode(
            Params.self,
            from: params,
            generator: Self.identifier,
            default: Params()
        )
        let requestedMax = decoded.maxLength ?? 32
        let ceiling = column.maxLength ?? requestedMax
        let upper = max(0, min(requestedMax, ceiling))
        let lower = max(0, min(decoded.minLength ?? 8, upper))
        lengthRange = lower...upper
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let length = rng.nextInt(in: lengthRange)
        var bytes = Data(capacity: length)
        for _ in 0..<length {
            bytes.append(UInt8(truncatingIfNeeded: rng.next()))
        }
        return .bytes(bytes)
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
