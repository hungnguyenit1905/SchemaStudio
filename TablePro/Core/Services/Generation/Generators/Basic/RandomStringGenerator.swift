//
//  RandomStringGenerator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum RandomStringCharset: String, Codable, Sendable, CaseIterable {
    case alphanumeric
    case alphabetic
    case numeric
    case lowercase
    case uppercase
    case hexadecimal
    case custom

    var characters: [Character] {
        switch self {
        case .alphanumeric: return Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        case .alphabetic: return Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        case .numeric: return Array("0123456789")
        case .lowercase: return Array("abcdefghijklmnopqrstuvwxyz")
        case .uppercase: return Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        case .hexadecimal: return Array("0123456789abcdef")
        case .custom: return []
        }
    }
}

final class RandomStringGenerator: ValueGenerator {
    static let identifier = "RandomString"
    static let paramSchema = ParamSchema(fields: [
        ParamField(
            key: "minLength",
            label: "Shortest",
            type: .integer(minimum: 0, maximum: nil),
            defaultValue: .int(5)
        ),
        ParamField(
            key: "maxLength",
            label: "Longest",
            type: .integer(minimum: 0, maximum: nil),
            defaultValue: .int(20)
        ),
        ParamField(
            key: "charset",
            label: "Characters",
            type: .choice(RandomStringCharset.allCases.map { ParamChoice(value: $0.rawValue) }),
            defaultValue: .string(RandomStringCharset.alphanumeric.rawValue)
        ),
        ParamField(
            key: "customCharacters",
            label: "Custom characters",
            type: .text,
            defaultValue: .string(""),
            visibleWhen: ParamVisibility(key: "charset", equalsAnyOf: [.string(RandomStringCharset.custom.rawValue)])
        )
    ])

    private struct Params: Codable {
        var minLength: Int?
        var maxLength: Int?
        var charset: RandomStringCharset?
        var customCharacters: String?
    }

    private let alphabet: [Character]
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
        let charset = decoded.charset ?? .alphanumeric
        let requestedMax = decoded.maxLength ?? 20
        let characters = charset == .custom
            ? Array(decoded.customCharacters ?? "")
            : charset.characters
        guard !characters.isEmpty else {
            throw GenerationError.invalidParameters(
                generator: Self.identifier,
                reason: "the character set is empty"
            )
        }
        let ceiling = column.maxLength ?? requestedMax
        let upper = max(0, min(requestedMax, ceiling))
        let lower = max(0, min(decoded.minLength ?? 5, upper))
        alphabet = characters
        lengthRange = lower...upper
        self.seed = seed
        rng = SplitMix64(seed: seed)
    }

    var distinctValueCount: Int? {
        var total: UInt64 = 0
        for length in lengthRange {
            var combinations: UInt64 = 1
            for _ in 0..<length {
                let (product, overflowed) = combinations.multipliedReportingOverflow(by: UInt64(alphabet.count))
                guard !overflowed else { return Int.max }
                combinations = product
            }
            let (sum, overflowed) = total.addingReportingOverflow(combinations)
            guard !overflowed else { return Int.max }
            total = sum
        }
        return GenerationValueMapper.saturatingCount(total)
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        let length = rng.nextInt(in: lengthRange)
        var text = String()
        text.reserveCapacity(length)
        for _ in 0..<length {
            text.append(alphabet[rng.nextInt(upperBound: alphabet.count)])
        }
        return .text(text)
    }

    func reset() {
        rng = SplitMix64(seed: seed)
    }
}
