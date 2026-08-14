//
//  NativeTypeParser+MySQL.swift
//  TablePro
//

import Foundation

/// MySQL parenthesised integer widths are display widths, meaningless since
/// 8.0.17. They are dropped so a render to another vendor never emits
/// `integer(11)`. The single exception is `tinyint(1)`, the conventional
/// boolean marker, which resolves to `.bool`.
struct MySqlNativeTypeParser: NativeTypeParsing {
    private static let modifiers: Set<String> = ["unsigned", "signed", "zerofill"]

    func parse(_ native: String, allowedValues: [String]?) -> TransferColumnType {
        let syntax = NativeTypeSyntax.parse(native)
        let name = syntax.name(removing: Self.modifiers)
        let unsigned = syntax.containsWord("unsigned")

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
                unsigned: unsigned,
                allowedValues: values,
                native: native
            )
        }

        switch name {
        case "bit":
            return (syntax.length ?? 1) == 1 ? type(.bool) : type(.bytes)
        case "bool", "boolean":
            return type(.bool)
        case "tinyint":
            return syntax.length == 1 ? type(.bool) : type(.int8)
        case "smallint":
            return type(.int16)
        case "mediumint", "int", "integer":
            return type(.int32)
        case "bigint":
            return type(.int64)
        case "year":
            return type(.int16)
        case "decimal", "numeric", "dec", "fixed":
            return type(.decimal, precision: syntax.precision, scale: syntax.scale)
        case "float":
            return type(.float32)
        case "double", "double precision", "real":
            return type(.float64)
        case "char", "varchar":
            return type(.string, length: syntax.length)
        case "tinytext", "text", "mediumtext", "longtext":
            return type(.text)
        case "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob":
            return type(.bytes, length: syntax.length)
        case "date":
            return type(.date)
        case "time":
            return type(.time)
        case "datetime":
            return type(.timestamp)
        case "timestamp":
            return type(.timestampTZ)
        case "enum":
            return type(.enumeration, values: allowedValues ?? syntax.quotedArguments)
        case "set":
            return type(.set, values: allowedValues ?? syntax.quotedArguments)
        case "json":
            return type(.json)
        case "geometry", "point", "linestring", "polygon",
             "multipoint", "multilinestring", "multipolygon", "geometrycollection":
            return type(.geometry)
        default:
            return type(.unknown)
        }
    }

    func render(_ type: TransferColumnType) -> String? {
        let suffix = type.unsigned ? " unsigned" : ""

        switch type.base {
        case .bool:
            return "tinyint(1)"
        case .int8:
            return "tinyint" + suffix
        case .int16:
            return "smallint" + suffix
        case .int32:
            return "int" + suffix
        case .int64:
            return "bigint" + suffix
        case .decimal:
            guard let precision = type.precision else { return "decimal(65,30)" }
            return "decimal(\(precision),\(type.scale ?? 0))"
        case .float32:
            return "float"
        case .float64:
            return "double"
        case .string:
            return "varchar(\(type.length ?? 255))"
        case .text:
            return "longtext"
        case .bytes:
            return "longblob"
        case .date:
            return "date"
        case .time:
            return "time"
        case .timestamp:
            return "datetime"
        case .timestampTZ:
            return "timestamp"
        case .json:
            return "json"
        case .uuid:
            return "char(36)"
        case .enumeration:
            guard let values = type.allowedValues, !values.isEmpty else { return "varchar(255)" }
            return "enum(\(values.map(quoted).joined(separator: ",")))"
        case .set:
            guard let values = type.allowedValues, !values.isEmpty else { return "varchar(255)" }
            return "set(\(values.map(quoted).joined(separator: ",")))"
        case .geometry:
            return "geometry"
        case .interval, .unknown:
            return nil
        }
    }

    private func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
