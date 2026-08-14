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

    static func line(for row: [PluginCellValue], hexColumns: [Bool]) -> Data {
        var data = Data()
        for (index, value) in row.enumerated() {
            if index > 0 { data.append(fieldTerminator) }
            data.append(field(value, asHex: index < hexColumns.count && hexColumns[index]))
        }
        data.append(lineTerminator)
        return data
    }

    private static func field(_ value: PluginCellValue, asHex: Bool) -> Data {
        switch value {
        case .null:
            return nullField
        case .text(let text):
            let bytes = Data(text.utf8)
            return asHex ? Data(hex(bytes).utf8) : escaped(bytes)
        case .bytes(let bytes):
            return asHex ? Data(hex(bytes).utf8) : escaped(bytes)
        }
    }

    /// `\N` is the only spelling of NULL the loader accepts, and it has to reach
    /// the server unescaped, which is why it is built here rather than run
    /// through `escaped`.
    private static var nullField: Data { Data([escape, 0x4E]) }

    /// The escape character, both terminators and NUL are the four bytes that
    /// would otherwise end a field, end a row, or truncate the value.
    static func escaped(_ bytes: Data) -> Data {
        var output = Data()
        output.reserveCapacity(bytes.count)
        for byte in bytes {
            switch byte {
            case escape:
                output.append(contentsOf: [escape, escape])
            case fieldTerminator:
                output.append(contentsOf: [escape, 0x74])
            case lineTerminator:
                output.append(contentsOf: [escape, 0x6E])
            case 0x0D:
                output.append(contentsOf: [escape, 0x72])
            case 0x00:
                output.append(contentsOf: [escape, 0x30])
            default:
                output.append(byte)
            }
        }
        return output
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
