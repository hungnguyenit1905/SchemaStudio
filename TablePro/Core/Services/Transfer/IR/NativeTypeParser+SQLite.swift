//
//  NativeTypeParser+SQLite.swift
//  TablePro
//

import Foundation

/// SQLite has no declared type system, only column affinity, so the declared
/// string can be empty or arbitrary. This follows the affinity rules from the
/// SQLite documentation in their defined order rather than matching type names.
struct SqliteNativeTypeParser: NativeTypeParsing {
    func parse(_ native: String, allowedValues: [String]?) -> TransferColumnType {
        let syntax = NativeTypeSyntax.parse(native)
        let declared = syntax.head

        func type(_ base: TransferBaseType, length: Int? = nil) -> TransferColumnType {
            TransferColumnType(base: base, length: length, native: native)
        }

        if declared.isEmpty { return type(.bytes) }
        if declared.contains("int") { return type(.int64) }
        if declared.contains("char") || declared.contains("clob") || declared.contains("text") {
            return type(.text, length: syntax.length)
        }
        if declared.contains("blob") { return type(.bytes) }
        if declared.contains("real") || declared.contains("floa") || declared.contains("doub") {
            return type(.float64)
        }
        return type(.decimal, length: nil)
    }

    func render(_ type: TransferColumnType) -> String? {
        switch type.base {
        case .bool, .int8, .int16, .int32, .int64:
            return "integer"
        case .float32, .float64:
            return "real"
        case .decimal:
            return "numeric"
        case .string, .text, .date, .time, .timestamp, .timestampTZ,
             .json, .uuid, .enumeration, .set, .interval:
            return "text"
        case .bytes, .geometry:
            return "blob"
        case .unknown:
            return nil
        }
    }
}
