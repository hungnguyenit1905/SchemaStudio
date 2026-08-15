//
//  MySQLLoadDataEncodingTests.swift
//  TableProTests
//
//  Covers the LOAD DATA LOCAL INFILE stream format and statement shape.
//
import Foundation
import TableProPluginKit
import Testing

@Suite("MySQL LOAD DATA encoding")
struct MySQLLoadDataEncodingTests {
    @Test("NULL is written as the loader's own spelling, not as empty")
    func nullField() {
        let line = MySQLLocalInfileEncoder.line(for: [.null], hexColumns: [false])
        #expect(line == Data([0x5C, 0x4E, 0x0A]))
    }

    @Test("Tab, newline, carriage return, backslash and NUL are escaped")
    func escapesTerminators() {
        let value = "a\tb\nc\rd\\e\0f"
        let line = MySQLLocalInfileEncoder.line(for: [.text(value)], hexColumns: [false])
        let text = String(decoding: line, as: UTF8.self)
        #expect(text == "a\\tb\\nc\\rd\\\\e\\0f\n")
    }

    @Test("Fields are tab separated and the row ends with one newline")
    func fieldSeparation() {
        let line = MySQLLocalInfileEncoder.line(
            for: [.text("1"), .text("two"), .null],
            hexColumns: [false, false, false]
        )
        #expect(String(decoding: line, as: UTF8.self) == "1\ttwo\t\\N\n")
    }

    @Test("A binary column travels as hex so its bytes skip charset conversion")
    func binaryColumnUsesHex() {
        let blob = Data([0x00, 0xFF, 0x09, 0x0A, 0x5C])
        let line = MySQLLocalInfileEncoder.line(
            for: [.text("id"), .bytes(blob)],
            hexColumns: [false, true]
        )
        #expect(String(decoding: line, as: UTF8.self) == "id\t00FF090A5C\n")
    }

    @Test("A NULL in a binary column stays NULL rather than an empty blob")
    func nullInBinaryColumn() {
        let line = MySQLLocalInfileEncoder.line(for: [.null], hexColumns: [true])
        #expect(String(decoding: line, as: UTF8.self) == "\\N\n")
    }

    @Test("Bytes in a non-binary column are escaped rather than dropped")
    func bytesInTextColumn() {
        let line = MySQLLocalInfileEncoder.line(
            for: [.bytes(Data([0x61, 0x09, 0x62]))],
            hexColumns: [false]
        )
        #expect(String(decoding: line, as: UTF8.self) == "a\\tb\n")
    }

    @Test("A table with no binary column loads straight into its columns")
    func statementWithoutBinaryColumns() {
        let sql = MySQLLoadDataStatement.statement(
            table: "users",
            schema: nil,
            columns: ["id", "name"],
            hexColumns: [false, false],
            quote: { "`\($0)`" }
        )
        #expect(sql.contains("INTO TABLE `users`"))
        #expect(sql.contains("(`id`, `name`)"))
        #expect(!sql.contains("UNHEX"))
    }

    @Test("A binary column is read into a variable and assigned through UNHEX")
    func statementWithBinaryColumn() {
        let sql = MySQLLoadDataStatement.statement(
            table: "files",
            schema: "app",
            columns: ["id", "payload"],
            hexColumns: [false, true],
            quote: { "`\($0)`" }
        )
        #expect(sql.contains("INTO TABLE `app`.`files`"))
        #expect(sql.contains("(`id`, @tablepro_col1)"))
        #expect(sql.hasSuffix("SET `payload` = UNHEX(@tablepro_col1)"))
    }

    @Test("The statement pins the charset instead of inheriting the session's")
    func statementPinsCharset() {
        let sql = MySQLLoadDataStatement.statement(
            table: "t",
            schema: nil,
            columns: ["a"],
            hexColumns: [false],
            quote: { "`\($0)`" }
        )
        #expect(sql.contains("CHARACTER SET utf8mb4"))
        #expect(sql.contains("FIELDS TERMINATED BY '\\t' ESCAPED BY '\\\\'"))
        #expect(sql.contains("LINES TERMINATED BY '\\n'"))
    }

    @Test("Byte-valued types are classified binary and character types are not")
    func binaryTypeClassification() {
        for type in ["blob", "LONGBLOB", "tinyblob", "binary", "varbinary", "bit", "geometry", "point"] {
            #expect(MySQLLoadDataStatement.isBinaryType(type), "\(type) should be binary")
        }
        for type in ["varchar", "text", "int", "json", "datetime", "decimal"] {
            #expect(!MySQLLoadDataStatement.isBinaryType(type), "\(type) should not be binary")
        }
    }
}

// MARK: - Local Copy of the Plugin Encoder

// Copied from Plugins/MySQLDriverPlugin/MySQLLocalInfileEncoder.swift and
// MySQLLoadDataStatement.swift because the plugin is a bundle target and cannot
// be imported with @testable import, the same arrangement GeometryWKBParserTests
// uses.

private enum MySQLLocalInfileEncoder {
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

private enum MySQLLoadDataStatement {
    static let streamName = "tablepro-transfer-stream"

    static func statement(
        table: String,
        schema: String?,
        columns: [String],
        hexColumns: [Bool],
        quote: (String) -> String
    ) -> String {
        let qualified = schema.map { "\(quote($0)).\(quote(table))" } ?? quote(table)
        var targets: [String] = []
        var assignments: [String] = []

        for (index, column) in columns.enumerated() {
            guard index < hexColumns.count, hexColumns[index] else {
                targets.append(quote(column))
                continue
            }
            let variable = "@tablepro_col\(index)"
            targets.append(variable)
            assignments.append("\(quote(column)) = UNHEX(\(variable))")
        }

        var sql = """
        LOAD DATA LOCAL INFILE '\(streamName)' INTO TABLE \(qualified) \
        CHARACTER SET utf8mb4 \
        FIELDS TERMINATED BY '\\t' ESCAPED BY '\\\\' \
        LINES TERMINATED BY '\\n' \
        (\(targets.joined(separator: ", ")))
        """
        if !assignments.isEmpty {
            sql += " SET \(assignments.joined(separator: ", "))"
        }
        return sql
    }

    static func isBinaryType(_ typeName: String) -> Bool {
        let normalized = typeName.lowercased()
        if normalized.hasSuffix("blob") || normalized.hasPrefix("blob") { return true }
        return [
            "binary", "varbinary", "bit",
            "geometry", "point", "linestring", "polygon",
            "multipoint", "multilinestring", "multipolygon", "geometrycollection"
        ].contains(normalized)
    }
}
