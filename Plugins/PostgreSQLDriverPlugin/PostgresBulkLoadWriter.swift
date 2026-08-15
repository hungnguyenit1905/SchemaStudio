//
//  PostgresBulkLoadWriter.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

final class PostgresBulkLoadWriter: PluginBulkLoadWriter, @unchecked Sendable {
    private let core: LibPQDriverCore
    private var buffer = Data()
    private var rowCount = 0
    private var finished = false

    private static let flushThresholdBytes = 1_048_576

    init(core: LibPQDriverCore, statement: String) async throws {
        self.core = core
        try await core.beginCopyFromStdin(statement)
    }

    func write(row: [PluginCellValue]) async throws {
        guard !finished else {
            throw LibPQPluginError(
                message: "Bulk writer already finished",
                sqlState: nil,
                detail: nil
            )
        }
        buffer.append(Self.copyRowData(row))
        rowCount += 1
        guard buffer.count >= Self.flushThresholdBytes else { return }
        let chunk = buffer
        buffer.removeAll(keepingCapacity: true)
        try await core.copyWrite(chunk)
    }

    /// The whole chunk is encoded into the buffer before anything is awaited,
    /// so a chunk costs one suspension instead of one per row.
    func write(rows: [[PluginCellValue]]) async throws {
        guard !finished else {
            throw LibPQPluginError(
                message: "Bulk writer already finished",
                sqlState: nil,
                detail: nil
            )
        }
        for row in rows {
            buffer.append(Self.copyRowData(row))
        }
        rowCount += rows.count
        guard buffer.count >= Self.flushThresholdBytes else { return }
        let chunk = buffer
        buffer.removeAll(keepingCapacity: true)
        try await core.copyWrite(chunk)
    }

    func finish() async throws -> Int {
        guard !finished else { return rowCount }
        finished = true
        if !buffer.isEmpty {
            let chunk = buffer
            buffer.removeAll(keepingCapacity: true)
            try await core.copyWrite(chunk)
        }
        _ = try await core.copyFinish()
        return rowCount
    }

    func abort() async {
        finished = true
        buffer.removeAll(keepingCapacity: true)
        await core.copyAbort()
    }

    static func copyRowData(_ row: [PluginCellValue]) -> Data {
        var text = row.map(copyTextValue).joined(separator: "\t")
        text.append("\n")
        return Data(text.utf8)
    }

    private static func copyTextValue(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "\\N"
        case .text(let string):
            var out = ""
            out.reserveCapacity(string.count)
            for char in string {
                switch char {
                case "\\": out += "\\\\"
                case "\t": out += "\\t"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                default: out.append(char)
                }
            }
            return out
        case .bytes(let data):
            var hex = "\\\\x"
            hex.reserveCapacity(2 + data.count * 2)
            for byte in data {
                hex += String(format: "%02X", byte)
            }
            return hex
        }
    }
}
