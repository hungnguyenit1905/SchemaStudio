//
//  TypeFallbackGeneratorResolver.swift
//  TablePro
//

import Foundation

/// Picks a generator from the column's type alone. This is the bottom tier of
/// the mapping; Phase 6's auto-mapper reads names and comments on top of it, and
/// falls back to here when nothing matches.
enum TypeFallbackGeneratorResolver {
    struct Resolution: Sendable, Hashable {
        let identifier: String
        let params: JSONValue
    }

    static func resolve(_ column: GenerationColumn) -> Resolution {
        if column.isServerAssigned {
            return Resolution(identifier: DefaultGenerator.identifier, params: .object([:]))
        }
        if let allowedValues = column.allowedValues, !allowedValues.isEmpty {
            return Resolution(
                identifier: ListGenerator.identifier,
                params: .object(["values": .array(allowedValues.map(JSONValue.string))])
            )
        }
        if let foreignKey = column.foreignKey, !foreignKey.isComposite {
            return Resolution(identifier: ReferenceGenerator.identifier, params: .object([:]))
        }
        if column.identityKind != nil || column.sequenceName != nil {
            return Resolution(identifier: DefaultGenerator.identifier, params: .object([:]))
        }
        return Resolution(identifier: identifier(for: column), params: params(for: column))
    }

    private static func identifier(for column: GenerationColumn) -> String {
        switch column.type.base {
        case .bool:
            return BooleanGenerator.identifier
        case .int8, .int16, .int32, .int64:
            return IntegerGenerator.identifier
        case .decimal:
            return DecimalGenerator.identifier
        case .float32, .float64:
            return DoubleGenerator.identifier
        case .uuid:
            return UuidGenerator.identifier
        case .date:
            return DateGenerator.identifier
        case .time, .timestamp, .timestampTZ:
            return DateTimeGenerator.identifier
        case .bytes:
            return RandomBytesGenerator.identifier
        case .string:
            return RandomStringGenerator.identifier
        case .text, .json, .interval, .enumeration, .set, .geometry, .unknown:
            return LoremWordsGenerator.identifier
        }
    }

    private static func params(for column: GenerationColumn) -> JSONValue {
        guard column.type.base == .string, let maxLength = column.maxLength, maxLength > 0 else {
            return .object([:])
        }
        return .object([
            "minLength": .int(max(1, min(3, maxLength))),
            "maxLength": .int(min(maxLength, 32))
        ])
    }
}
