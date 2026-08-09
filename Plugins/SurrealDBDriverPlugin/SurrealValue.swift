//
//  SurrealValue.swift
//  SurrealDBDriverPlugin
//

import Foundation

public struct SurrealRecordID: Equatable, Sendable {
    public let table: String
    public let id: SurrealValue

    public init(table: String, id: SurrealValue) {
        self.table = table
        self.id = id
    }
}

public struct SurrealBound: Equatable, Sendable {
    public let value: SurrealValue
    public let isInclusive: Bool

    public init(value: SurrealValue, isInclusive: Bool) {
        self.value = value
        self.isInclusive = isInclusive
    }
}

public indirect enum SurrealValue: Equatable, Sendable {
    case null
    case none
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case bytes(Data)
    case array([SurrealValue])
    case object([(key: String, value: SurrealValue)])
    case recordId(SurrealRecordID)
    case table(String)
    case uuid(UUID)
    case decimal(String)
    case datetime(seconds: Int64, nanoseconds: UInt32)
    case duration(seconds: Int64, nanoseconds: UInt32)
    case tagged(tag: UInt64, value: SurrealValue)
    case range(from: SurrealBound?, to: SurrealBound?)

    public static func == (lhs: SurrealValue, rhs: SurrealValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null), (.none, .none):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.int(let a), .int(let b)):
            return a == b
        case (.double(let a), .double(let b)):
            return a == b
        case (.string(let a), .string(let b)):
            return a == b
        case (.bytes(let a), .bytes(let b)):
            return a == b
        case (.array(let a), .array(let b)):
            return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.recordId(let a), .recordId(let b)):
            return a == b
        case (.table(let a), .table(let b)):
            return a == b
        case (.uuid(let a), .uuid(let b)):
            return a == b
        case (.decimal(let a), .decimal(let b)):
            return a == b
        case (.datetime(let sa, let na), .datetime(let sb, let nb)):
            return sa == sb && na == nb
        case (.duration(let sa, let na), .duration(let sb, let nb)):
            return sa == sb && na == nb
        case (.tagged(let ta, let va), .tagged(let tb, let vb)):
            return ta == tb && va == vb
        case (.range(let fa, let ta), .range(let fb, let tb)):
            return fa == fb && ta == tb
        default:
            return false
        }
    }
}

public extension SurrealValue {
    subscript(key: String) -> SurrealValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    var objectPairs: [(key: String, value: SurrealValue)]? {
        guard case .object(let pairs) = self else { return nil }
        return pairs
    }

    var arrayValues: [SurrealValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .table(let name):
            return name
        default:
            return nil
        }
    }

    var intValue: Int64? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return Int64(exactly: value.rounded())
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var isAbsent: Bool {
        switch self {
        case .null, .none:
            return true
        default:
            return false
        }
    }
}
