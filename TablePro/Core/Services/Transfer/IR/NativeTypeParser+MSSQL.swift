//
//  NativeTypeParser+MSSQL.swift
//  TablePro
//

import Foundation

struct MssqlNativeTypeParser: NativeTypeParsing {
    func parse(_ native: String, allowedValues: [String]?) -> TransferColumnType {
        let syntax = NativeTypeSyntax.parse(native)

        func type(
            _ base: TransferBaseType,
            length: Int? = nil,
            precision: Int? = nil,
            scale: Int? = nil
        ) -> TransferColumnType {
            TransferColumnType(
                base: base,
                length: length,
                precision: precision,
                scale: scale,
                native: native
            )
        }

        switch syntax.head {
        case "bit":
            return type(.bool)
        case "tinyint":
            return type(.int8)
        case "smallint":
            return type(.int16)
        case "int", "integer":
            return type(.int32)
        case "bigint":
            return type(.int64)
        case "decimal", "numeric", "money", "smallmoney":
            return type(.decimal, precision: syntax.precision, scale: syntax.scale)
        case "real":
            return type(.float32)
        case "float":
            return type(.float64)
        case "char", "nchar", "varchar", "nvarchar":
            if syntax.isMaxLength { return type(.text) }
            guard let length = syntax.length else { return type(.text) }
            return type(.string, length: length)
        case "text", "ntext", "xml":
            return type(.text)
        case "binary", "varbinary", "image", "rowversion", "timestamp":
            return type(.bytes, length: syntax.isMaxLength ? nil : syntax.length)
        case "date":
            return type(.date)
        case "time":
            return type(.time)
        case "datetime", "datetime2", "smalldatetime":
            return type(.timestamp)
        case "datetimeoffset":
            return type(.timestampTZ)
        case "uniqueidentifier":
            return type(.uuid)
        case "geometry", "geography":
            return type(.geometry)
        default:
            return type(.unknown)
        }
    }

    func render(_ type: TransferColumnType) -> String? {
        switch type.base {
        case .bool:
            return "bit"
        case .int8:
            return "tinyint"
        case .int16:
            return "smallint"
        case .int32:
            return "int"
        case .int64:
            return "bigint"
        case .decimal:
            guard let precision = type.precision else { return "decimal(38,10)" }
            return "decimal(\(precision),\(type.scale ?? 0))"
        case .float32:
            return "real"
        case .float64:
            return "float"
        case .string:
            guard let length = type.length else { return "nvarchar(max)" }
            return "nvarchar(\(length))"
        case .text, .json, .set:
            return "nvarchar(max)"
        case .bytes:
            return "varbinary(max)"
        case .date:
            return "date"
        case .time:
            return "time"
        case .timestamp:
            return "datetime2"
        case .timestampTZ:
            return "datetimeoffset"
        case .uuid:
            return "uniqueidentifier"
        case .enumeration:
            let widest = type.allowedValues?.map(\.count).max() ?? 255
            return "nvarchar(\(max(widest, 1)))"
        case .geometry:
            return "geometry"
        case .interval, .unknown:
            return nil
        }
    }
}
