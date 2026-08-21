//
//  PluginCellValue+StableHash.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginCellValue {
    private enum HashTag: UInt8 {
        case null = 0
        case text = 1
        case bytes = 2
        case int = 3
        case double = 4
        case decimalText = 5
        case bool = 6
        case date = 7
        case time = 8
        case timestamp = 9
        case uuid = 10
        case array = 11
    }

    var stableHash: UInt64 {
        FNV1aHasher.hash { hasher in
            switch self {
            case .null:
                hasher.combine(byte: HashTag.null.rawValue)
            case .text(let value):
                hasher.combine(byte: HashTag.text.rawValue)
                hasher.combine(value)
            case .bytes(let value):
                hasher.combine(byte: HashTag.bytes.rawValue)
                hasher.combine(lengthPrefixed: value)
            case .int(let value):
                hasher.combine(byte: HashTag.int.rawValue)
                hasher.combine(value)
            case .double(let value):
                hasher.combine(byte: HashTag.double.rawValue)
                hasher.combine(value)
            case .decimalText(let value):
                hasher.combine(byte: HashTag.decimalText.rawValue)
                hasher.combine(value)
            case .bool(let value):
                hasher.combine(byte: HashTag.bool.rawValue)
                hasher.combine(value)
            case .date(let year, let month, let day):
                hasher.combine(byte: HashTag.date.rawValue)
                hasher.combine(Int64(year))
                hasher.combine(Int64(month))
                hasher.combine(Int64(day))
            case .time(let seconds, let nanoseconds):
                hasher.combine(byte: HashTag.time.rawValue)
                hasher.combine(Int64(seconds))
                hasher.combine(Int64(nanoseconds))
            case .timestamp(let value):
                hasher.combine(byte: HashTag.timestamp.rawValue)
                hasher.combine(value.timeIntervalSince1970)
            case .uuid(let value):
                hasher.combine(byte: HashTag.uuid.rawValue)
                hasher.combine(lengthPrefixed: Data(Self.bytes(of: value)))
            case .array(let values):
                hasher.combine(byte: HashTag.array.rawValue)
                hasher.combine(UInt64(values.count))
                for element in values { hasher.combine(element.stableHash) }
            @unknown default:
                hasher.combine(byte: 0xff)
                hasher.combine(textFallback)
            }
        }
    }

    private static func bytes(of uuid: UUID) -> [UInt8] {
        let raw = uuid.uuid
        return [
            raw.0, raw.1, raw.2, raw.3, raw.4, raw.5, raw.6, raw.7,
            raw.8, raw.9, raw.10, raw.11, raw.12, raw.13, raw.14, raw.15
        ]
    }
}
