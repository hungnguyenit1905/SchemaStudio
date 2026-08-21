//
//  TypeFallbackGeneratorResolver.swift
//  TablePro
//

import Foundation

/// The constraint and type tiers of the mapping, split so `AutoMapper` can read
/// the column's name between them: constraints outrank a name, a name outranks
/// the bare type.
enum TypeFallbackGeneratorResolver {
    struct Resolution: Sendable, Hashable {
        let identifier: String
        let params: JSONValue
    }

    static let readableIntegerCeiling = 10_000

    static let shortStringLength = 10

    static func resolve(_ column: GenerationColumn) -> Resolution {
        constraintResolution(column) ?? typeResolution(column)
    }

    /// What the schema leaves no choice about. Nothing in the name or the type can
    /// override any of these.
    static func constraintResolution(_ column: GenerationColumn) -> Resolution? {
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
        return nil
    }

    static func typeResolution(_ column: GenerationColumn) -> Resolution {
        Resolution(identifier: identifier(for: column), params: params(for: column))
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
        case .json:
            return FixedGenerator.identifier
        case .string:
            return isShort(column) ? RandomStringGenerator.identifier : LoremWordsGenerator.identifier
        case .text, .interval, .enumeration, .set, .geometry, .unknown:
            return LoremWordsGenerator.identifier
        }
    }

    /// Words read better than noise in a column wide enough to hold them, and
    /// noise is all that fits in a narrow one.
    private static func isShort(_ column: GenerationColumn) -> Bool {
        guard let maxLength = column.maxLength else { return false }
        return maxLength <= shortStringLength
    }

    private static func params(for column: GenerationColumn) -> JSONValue {
        switch column.type.base {
        case .string where isShort(column):
            guard let maxLength = column.maxLength, maxLength > 0 else { return .object([:]) }
            return .object([
                "minLength": .int(max(1, min(3, maxLength))),
                "maxLength": .int(maxLength)
            ])
        case .int8, .int16, .int32, .int64:
            return integerParams(for: column)
        case .json:
            return .object(["value": .string("{}")])
        default:
            return .object([:])
        }
    }

    /// The native range of a `bigint` spans both signs and nineteen digits, which
    /// is valid and unreadable. A column that has to hold distinct values keeps the
    /// full range: capping it would exhaust the domain on a large run.
    private static func integerParams(for column: GenerationColumn) -> JSONValue {
        guard !column.requiresUniqueValues, !column.isPrimaryKey else { return .object([:]) }
        return .object(["min": .int(0), "max": .int(readableIntegerCeiling)])
    }
}
