//
//  ZipArchiveTestBuilder.swift
//  TableProTests
//

import Compression
import Foundation
@testable import SchemaStudio

enum ZipArchiveTestBuilder {
    struct Entry {
        let path: String
        let payload: Data
        var deflated: Bool = false
        var flags: UInt16 = 0
        var declaredUncompressedSize: UInt32?
        var declaredMethod: UInt16?
    }

    static func archive(
        entries: [Entry],
        comment: String = "",
        appendSecondEndRecord: Bool = false,
        duplicateCentralRecordFor: String? = nil
    ) -> Data {
        var output = Data()
        var central = Data()
        var records: [(Entry, Data, UInt32, Int)] = []

        for entry in entries {
            let stored = entry.deflated ? deflate(entry.payload) : entry.payload
            let crc = ZipArchiveReader.crc32(of: entry.payload)
            let offset = output.count
            records.append((entry, stored, crc, offset))

            let name = Data(entry.path.utf8)
            let method = entry.declaredMethod ?? (entry.deflated ? 8 : 0)
            output.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            output.appendUInt16(20)
            output.appendUInt16(entry.flags)
            output.appendUInt16(method)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt32(crc)
            output.appendUInt32(UInt32(stored.count))
            output.appendUInt32(entry.declaredUncompressedSize ?? UInt32(entry.payload.count))
            output.appendUInt16(UInt16(name.count))
            output.appendUInt16(0)
            output.append(name)
            output.append(stored)
        }

        var centralCount = 0
        for (entry, stored, crc, offset) in records {
            central.append(centralRecord(entry: entry, stored: stored, crc: crc, offset: offset))
            centralCount += 1
            if entry.path == duplicateCentralRecordFor {
                central.append(centralRecord(entry: entry, stored: stored, crc: crc, offset: offset))
                centralCount += 1
            }
        }

        let centralOffset = output.count
        output.append(central)
        output.append(endRecord(
            entryCount: centralCount,
            centralSize: central.count,
            centralOffset: centralOffset,
            comment: comment
        ))
        if appendSecondEndRecord {
            output.append(endRecord(
                entryCount: centralCount,
                centralSize: central.count,
                centralOffset: centralOffset,
                comment: ""
            ))
        }
        return output
    }

    private static func centralRecord(entry: Entry, stored: Data, crc: UInt32, offset: Int) -> Data {
        var central = Data()
        let name = Data(entry.path.utf8)
        let method = entry.declaredMethod ?? (entry.deflated ? 8 : 0)
        central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        central.appendUInt16(20)
        central.appendUInt16(20)
        central.appendUInt16(entry.flags)
        central.appendUInt16(method)
        central.appendUInt16(0)
        central.appendUInt16(0)
        central.appendUInt32(crc)
        central.appendUInt32(UInt32(stored.count))
        central.appendUInt32(entry.declaredUncompressedSize ?? UInt32(entry.payload.count))
        central.appendUInt16(UInt16(name.count))
        central.appendUInt16(0)
        central.appendUInt16(0)
        central.appendUInt16(0)
        central.appendUInt16(0)
        central.appendUInt32(0)
        central.appendUInt32(UInt32(offset))
        central.append(name)
        return central
    }

    private static func endRecord(entryCount: Int, centralSize: Int, centralOffset: Int, comment: String) -> Data {
        var record = Data()
        let commentData = Data(comment.utf8)
        record.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        record.appendUInt16(0)
        record.appendUInt16(0)
        record.appendUInt16(UInt16(entryCount))
        record.appendUInt16(UInt16(entryCount))
        record.appendUInt32(UInt32(centralSize))
        record.appendUInt32(UInt32(centralOffset))
        record.appendUInt16(UInt16(commentData.count))
        record.append(commentData)
        return record
    }

    static func zip64Archive() -> Data {
        var output = Data()
        output.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(0xFFFF)
        output.appendUInt16(0xFFFF)
        output.appendUInt32(0xFFFF_FFFF)
        output.appendUInt32(0xFFFF_FFFF)
        output.appendUInt16(0)
        return output
    }

    static func deflate(_ input: Data) -> Data {
        guard !input.isEmpty else { return Data() }
        let bufferSize = 65_536
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var stream = compression_stream(
            dst_ptr: destination,
            dst_size: bufferSize,
            src_ptr: destination,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else { return input }
        defer { compression_stream_destroy(&stream) }

        return input.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return input }
            stream.src_ptr = base
            stream.src_size = raw.count
            stream.dst_ptr = destination
            stream.dst_size = bufferSize

            var output = Data()
            while true {
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                switch status {
                case COMPRESSION_STATUS_OK:
                    if stream.dst_size == 0 {
                        output.append(destination, count: bufferSize)
                        stream.dst_ptr = destination
                        stream.dst_size = bufferSize
                    }
                case COMPRESSION_STATUS_END:
                    if produced > 0 { output.append(destination, count: produced) }
                    return output
                default:
                    return output
                }
            }
        }
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
