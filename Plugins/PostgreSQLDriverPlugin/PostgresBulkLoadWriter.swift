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

    /// Encoding runs over UTF-8 bytes, not Characters, and writes into one
    /// buffer. Building a String per value and joining them cost more than the
    /// copy itself: grapheme breaking on every character, an intermediate array
    /// and String per row, then a re-encode back to bytes.
    static func copyRowData(_ row: [PluginCellValue]) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64 * row.count)
        for (index, value) in row.enumerated() {
            if index > 0 { bytes.append(0x09) }
            append(value, to: &bytes)
        }
        bytes.append(0x0A)
        return Data(bytes)
    }

    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    private static func append(_ value: PluginCellValue, to bytes: inout [UInt8]) {
        switch value {
        case .null:
            bytes.append(contentsOf: [0x5C, 0x4E])
        case .text(let string):
            for byte in string.utf8 {
                switch byte {
                case 0x5C: bytes.append(contentsOf: [0x5C, 0x5C])
                case 0x09: bytes.append(contentsOf: [0x5C, 0x74])
                case 0x0A: bytes.append(contentsOf: [0x5C, 0x6E])
                case 0x0D: bytes.append(contentsOf: [0x5C, 0x72])
                default: bytes.append(byte)
                }
            }
        case .bytes(let data):
            // A bytea literal inside COPY text needs the backslash itself
            // escaped, so the value starts with \\x and continues in hex.
            bytes.append(contentsOf: [0x5C, 0x5C, 0x78])
            for byte in data {
                bytes.append(hexDigits[Int(byte >> 4)])
                bytes.append(hexDigits[Int(byte & 0x0F)])
            }
        case .int, .double, .decimalText, .bool, .date, .time, .timestamp, .uuid, .array:
            append(.text(value.textFallback), to: &bytes)
        @unknown default:
            append(.text(value.textFallback), to: &bytes)
        }
    }
}
