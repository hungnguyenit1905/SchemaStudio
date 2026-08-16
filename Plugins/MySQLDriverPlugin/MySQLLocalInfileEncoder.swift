//
//  MySQLLocalInfileEncoder.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// Encodes rows into the text stream `LOAD DATA LOCAL INFILE` reads: tab
/// between fields, newline between rows, backslash escapes, and `\N` for NULL.
/// A column the table declares as binary is written as hex instead and put back
/// together by `UNHEX` at the server, so a BLOB never has to survive a charset
/// conversion on the way in.
enum MySQLLocalInfileEncoder {
    static let fieldTerminator: UInt8 = 0x09
    static let lineTerminator: UInt8 = 0x0A
    private static let escape: UInt8 = 0x5C

    /// One byte buffer per row, no String anywhere: a String per value plus a
    /// join costs more than the load it feeds.
    static func line(for row: [PluginCellValue], hexColumns: [Bool]) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64 * row.count)
        for (index, value) in row.enumerated() {
            if index > 0 { bytes.append(fieldTerminator) }
            append(value, asHex: index < hexColumns.count && hexColumns[index], to: &bytes)
        }
        bytes.append(lineTerminator)
        return Data(bytes)
    }

    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    private static func append(_ value: PluginCellValue, asHex: Bool, to bytes: inout [UInt8]) {
        switch value {
        case .null:
            // `\N` is the only spelling of NULL the loader accepts, and it has
            // to reach the server unescaped.
            bytes.append(contentsOf: [escape, 0x4E])
        case .text(let text):
            asHex ? appendHex(text.utf8, to: &bytes) : appendEscaped(text.utf8, to: &bytes)
        case .bytes(let data):
            asHex ? appendHex(data, to: &bytes) : appendEscaped(data, to: &bytes)
        case .int, .double, .decimalText, .bool, .date, .time, .timestamp, .uuid, .array:
            append(.text(value.textFallback), asHex: asHex, to: &bytes)
        @unknown default:
            append(.text(value.textFallback), asHex: asHex, to: &bytes)
        }
    }

    /// The escape character, both terminators and NUL are the four bytes that
    /// would otherwise end a field, end a row, or truncate the value.
    private static func appendEscaped<Bytes: Sequence>(
        _ source: Bytes,
        to bytes: inout [UInt8]
    ) where Bytes.Element == UInt8 {
        for byte in source {
            switch byte {
            case escape: bytes.append(contentsOf: [escape, escape])
            case fieldTerminator: bytes.append(contentsOf: [escape, 0x74])
            case lineTerminator: bytes.append(contentsOf: [escape, 0x6E])
            case 0x0D: bytes.append(contentsOf: [escape, 0x72])
            case 0x00: bytes.append(contentsOf: [escape, 0x30])
            default: bytes.append(byte)
            }
        }
    }

    private static func appendHex<Bytes: Sequence>(
        _ source: Bytes,
        to bytes: inout [UInt8]
    ) where Bytes.Element == UInt8 {
        for byte in source {
            bytes.append(hexDigits[Int(byte >> 4)])
            bytes.append(hexDigits[Int(byte & 0x0F)])
        }
    }
}
