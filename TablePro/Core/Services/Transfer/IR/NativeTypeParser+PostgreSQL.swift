//
//  NativeTypeParser+PostgreSQL.swift
//  TablePro
//

import Foundation

/// An array type keeps its element base and is recognised later through
/// `TransferColumnType.isArray`, which reads the preserved `native` string.
/// Same-vendor transfers round-trip it verbatim; cross-vendor transfers fold it
/// into JSON.
struct PostgreSqlNativeTypeParser: NativeTypeParsing {
    func parse(_ native: String, allowedValues: [String]?) -> TransferColumnType {
        let syntax = NativeTypeSyntax.parse(native)
        let hasTimeZone = syntax.containsWord("with") && !syntax.containsWord("without")

        func type(
            _ base: TransferBaseType,
            length: Int? = nil,
            precision: Int? = nil,
            scale: Int? = nil,
            values: [String]? = nil
        ) -> TransferColumnType {
            TransferColumnType(
                base: base,
                length: length,
                precision: precision,
                scale: scale,
                allowedValues: values,
                native: native
            )
        }

        switch normalized(syntax) {
        case "boolean", "bool":
            return type(.bool)
        case "smallint", "int2", "smallserial", "serial2":
            return type(.int16)
        case "integer", "int", "int4", "serial", "serial4":
            return type(.int32)
        case "bigint", "int8", "bigserial", "serial8":
            return type(.int64)
        case "numeric", "decimal":
            return type(.decimal, precision: syntax.precision, scale: syntax.scale)
        case "real", "float4":
            return type(.float32)
        case "double", "float8", "float":
            return type(.float64)
        case "character varying", "varchar", "character", "char", "bpchar":
            guard let length = syntax.length else { return type(.text) }
            return type(.string, length: length)
        case "text", "citext", "name":
            return type(.text)
        case "bytea":
            return type(.bytes)
        case "date":
            return type(.date)
        case "time":
            return type(.time)
        case "timestamp":
            return hasTimeZone ? type(.timestampTZ) : type(.timestamp)
        case "timestamptz":
            return type(.timestampTZ)
        case "timetz":
            return type(.time)
        case "interval":
            return type(.interval)
        case "json", "jsonb":
            return type(.json)
        case "uuid":
            return type(.uuid)
        case "geometry", "geography", "point", "line", "polygon", "circle", "box", "path":
            return type(.geometry)
        default:
            return type(.unknown, values: allowedValues)
        }
    }

    /// The time-zone qualifier is stripped as a whole phrase. Removing its words
    /// one by one would erase the name of a bare `time` column.
    private func normalized(_ syntax: NativeTypeSyntax) -> String {
        var name = syntax.head
        for phrase in [" without time zone", " with time zone"] where name.hasSuffix(phrase) {
            name = String(name.dropLast(phrase.count))
        }
        name = name.trimmingCharacters(in: .whitespaces)

        if name.hasPrefix("character varying") { return "character varying" }
        if name.hasPrefix("double precision") { return "double" }
        return name
    }

    func render(_ type: TransferColumnType) -> String? {
        switch type.base {
        case .bool:
            return "boolean"
        case .int8, .int16:
            return "smallint"
        case .int32:
            return "integer"
        case .int64:
            return "bigint"
        case .decimal:
            guard let precision = type.precision else { return "numeric" }
            return "numeric(\(precision),\(type.scale ?? 0))"
        case .float32:
            return "real"
        case .float64:
            return "double precision"
        case .string:
            guard let length = type.length else { return "text" }
            return "varchar(\(length))"
        case .text:
            return "text"
        case .bytes:
            return "bytea"
        case .date:
            return "date"
        case .time:
            return "time"
        case .timestamp:
            return "timestamp"
        case .timestampTZ:
            return "timestamptz"
        case .interval:
            return "interval"
        case .json:
            return "jsonb"
        case .uuid:
            return "uuid"
        case .enumeration:
            let widest = type.allowedValues?.map(\.count).max() ?? 255
            return "varchar(\(max(widest, 1)))"
        case .set:
            return "text"
        case .geometry, .unknown:
            return nil
        }
    }
}
