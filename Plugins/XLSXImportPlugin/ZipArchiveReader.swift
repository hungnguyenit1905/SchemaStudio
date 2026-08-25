//
//  ZipArchiveReader.swift
//  XLSXImportPlugin
//
//  Bundle-free so the main test bundle can compile it directly. Parses attacker-influenced
//  bytes, so every declared size is treated as untrusted and every limit is enforced during
//  inflation rather than against a declared value.
//

import Compression
import Foundation

public enum ZipArchiveLimits {
    public static let maximumFileSize = 256 * 1024 * 1024
    public static let maximumEntrySize = 512 * 1024 * 1024
    public static let maximumTotalInflatedSize = 1024 * 1024 * 1024
    public static let maximumCompressionRatio = 200
    public static let inflateChunkSize = 65_536
}

public enum ZipArchiveError: LocalizedError, Equatable {
    case fileTooLarge
    case endOfCentralDirectoryNotFound
    case malformedArchive
    case truncatedArchive
    case unsupportedCompressionMethod(UInt16)
    case encryptedEntry
    case duplicateEntryName(String)
    case trailingData
    case zip64Unsupported
    case entryNotFound(String)
    case unsafeEntryPath(String)
    case entryTooLarge(String)
    case archiveTooLarge
    case compressionRatioExceeded(String)
    case checksumMismatch(String)
    case inflateFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return String(localized: "The workbook is too large to open.")
        case .endOfCentralDirectoryNotFound, .malformedArchive:
            return String(localized: "The file is not a valid workbook.")
        case .truncatedArchive:
            return String(localized: "The workbook is incomplete or damaged.")
        case .unsupportedCompressionMethod(let method):
            return String(format: String(localized: "The workbook uses an unsupported compression method (%d)."), Int(method))
        case .encryptedEntry:
            return String(localized: "The workbook is password-protected.")
        case .duplicateEntryName(let name):
            return String(format: String(localized: "The workbook contains duplicate entries named '%@'."), name)
        case .trailingData:
            return String(localized: "The workbook has extra data appended and cannot be trusted.")
        case .zip64Unsupported:
            return String(localized: "The workbook is too large to open (Zip64 archives are not supported).")
        case .entryNotFound(let name):
            return String(format: String(localized: "The workbook is missing a required part: %@"), name)
        case .unsafeEntryPath(let name):
            return String(format: String(localized: "The workbook contains an unsafe entry path: %@"), name)
        case .entryTooLarge(let name):
            return String(format: String(localized: "A part of the workbook is too large to read: %@"), name)
        case .archiveTooLarge:
            return String(localized: "The workbook expands to more data than can be read safely.")
        case .compressionRatioExceeded(let name):
            return String(format: String(localized: "A part of the workbook expands far beyond its stored size: %@"), name)
        case .checksumMismatch(let name):
            return String(format: String(localized: "A part of the workbook failed its checksum: %@"), name)
        case .inflateFailed(let name):
            return String(format: String(localized: "A part of the workbook could not be decompressed: %@"), name)
        }
    }
}

public struct ZipEntry: Equatable {
    public let path: String
    public let compressionMethod: UInt16
    public let generalPurposeFlags: UInt16
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let crc32: UInt32
    public let localHeaderOffset: Int

    public var isEncrypted: Bool { generalPurposeFlags & 0x0001 != 0 }
}

public final class ZipArchiveReader {
    private let data: Data
    private let entries: [String: ZipEntry]
    private let orderedPaths: [String]
    private var totalInflated = 0

    public init(data: Data) throws {
        guard data.count <= ZipArchiveLimits.maximumFileSize else { throw ZipArchiveError.fileTooLarge }
        self.data = data

        let directory = try Self.locateCentralDirectory(in: data)
        let parsed = try Self.parseCentralDirectory(in: data, directory: directory)
        self.orderedPaths = parsed.map(\.path)

        var byPath = [String: ZipEntry]()
        for entry in parsed {
            guard byPath[entry.path] == nil else { throw ZipArchiveError.duplicateEntryName(entry.path) }
            byPath[entry.path] = entry
        }
        self.entries = byPath
    }

    public var entryPaths: [String] { orderedPaths }

    public func contains(_ path: String) -> Bool {
        entries[path] != nil
    }

    public func data(forEntry path: String, onProgress: (() throws -> Void)? = nil) throws -> Data {
        guard let entry = entries[path] else { throw ZipArchiveError.entryNotFound(path) }
        guard !entry.isEncrypted else { throw ZipArchiveError.encryptedEntry }

        let payload = try localPayload(for: entry)
        let output: Data
        switch entry.compressionMethod {
        case 0:
            guard payload.count <= ZipArchiveLimits.maximumEntrySize else {
                throw ZipArchiveError.entryTooLarge(entry.path)
            }
            output = payload
        case 8:
            output = try inflate(payload, entry: entry, onProgress: onProgress)
        default:
            throw ZipArchiveError.unsupportedCompressionMethod(entry.compressionMethod)
        }

        totalInflated += output.count
        guard totalInflated <= ZipArchiveLimits.maximumTotalInflatedSize else {
            throw ZipArchiveError.archiveTooLarge
        }
        guard Self.crc32(of: output) == entry.crc32 else {
            throw ZipArchiveError.checksumMismatch(entry.path)
        }
        return output
    }

    // MARK: - Central directory

    private struct CentralDirectoryLocation {
        let offset: Int
        let size: Int
        let entryCount: Int
        let recordOffset: Int
    }

    private static func locateCentralDirectory(in data: Data) throws -> CentralDirectoryLocation {
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let minimumRecord = 22
        guard data.count >= minimumRecord else { throw ZipArchiveError.endOfCentralDirectoryNotFound }

        let searchWindow = min(data.count, 65_535 + minimumRecord)
        let lowerBound = data.count - searchWindow
        var recordOffset: Int?
        var index = data.count - minimumRecord
        while index >= lowerBound {
            if byte(data, index) == signature[0],
               byte(data, index + 1) == signature[1],
               byte(data, index + 2) == signature[2],
               byte(data, index + 3) == signature[3] {
                recordOffset = index
                break
            }
            index -= 1
        }
        guard let recordOffset else { throw ZipArchiveError.endOfCentralDirectoryNotFound }

        let entryCount = Int(readUInt16(data, recordOffset + 10))
        let size = Int(readUInt32(data, recordOffset + 12))
        let offset = Int(readUInt32(data, recordOffset + 16))
        let commentLength = Int(readUInt16(data, recordOffset + 20))

        guard recordOffset + minimumRecord + commentLength == data.count else {
            throw ZipArchiveError.trailingData
        }
        guard offset != 0xFFFF_FFFF, size != 0xFFFF_FFFF, entryCount != 0xFFFF else {
            throw ZipArchiveError.zip64Unsupported
        }
        guard offset >= 0, size >= 0, offset <= data.count, offset + size <= data.count else {
            throw ZipArchiveError.malformedArchive
        }
        guard offset + size == recordOffset else { throw ZipArchiveError.trailingData }

        return CentralDirectoryLocation(
            offset: offset,
            size: size,
            entryCount: entryCount,
            recordOffset: recordOffset
        )
    }

    private static func parseCentralDirectory(
        in data: Data,
        directory: CentralDirectoryLocation
    ) throws -> [ZipEntry] {
        var entries = [ZipEntry]()
        var cursor = directory.offset
        let end = directory.offset + directory.size

        for _ in 0 ..< directory.entryCount {
            guard cursor + 46 <= end else { throw ZipArchiveError.malformedArchive }
            guard readUInt32(data, cursor) == 0x0201_4B50 else { throw ZipArchiveError.malformedArchive }

            let flags = readUInt16(data, cursor + 8)
            let method = readUInt16(data, cursor + 10)
            let crc = readUInt32(data, cursor + 16)
            let compressedSize = Int(readUInt32(data, cursor + 20))
            let uncompressedSize = Int(readUInt32(data, cursor + 24))
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            let localOffset = Int(readUInt32(data, cursor + 42))

            guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF,
                  localOffset != 0xFFFF_FFFF else {
                throw ZipArchiveError.zip64Unsupported
            }
            guard cursor + 46 + nameLength + extraLength + commentLength <= end else {
                throw ZipArchiveError.malformedArchive
            }
            guard localOffset >= 0, localOffset < data.count else { throw ZipArchiveError.malformedArchive }

            let nameRange = (cursor + 46) ..< (cursor + 46 + nameLength)
            guard let name = String(data: data.subdata(in: nameRange), encoding: .utf8) else {
                throw ZipArchiveError.malformedArchive
            }
            guard isSafeEntryPath(name) else { throw ZipArchiveError.unsafeEntryPath(name) }
            guard flags & 0x0001 == 0 else { throw ZipArchiveError.encryptedEntry }

            entries.append(ZipEntry(
                path: name,
                compressionMethod: method,
                generalPurposeFlags: flags,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                crc32: crc,
                localHeaderOffset: localOffset
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func isSafeEntryPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        guard !path.hasPrefix("/") else { return false }
        guard !path.contains("\\") else { return false }
        guard !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    // MARK: - Entry payload

    private func localPayload(for entry: ZipEntry) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count else { throw ZipArchiveError.truncatedArchive }
        guard Self.readUInt32(data, header) == 0x0403_4B50 else { throw ZipArchiveError.malformedArchive }

        let nameLength = Int(Self.readUInt16(data, header + 26))
        let extraLength = Int(Self.readUInt16(data, header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end >= start, end <= data.count else { throw ZipArchiveError.truncatedArchive }
        return data.subdata(in: start ..< end)
    }

    /// Ported from the shipping chunked decode loop in `KdbxDatabase.inflateRawDeflate`, which
    /// already handles the finalize and full-output-buffer cases that a hand-rolled loop
    /// silently truncates on. The size, ratio and cancellation checks run as output accumulates,
    /// never against the declared size.
    private func inflate(_ payload: Data, entry: ZipEntry, onProgress: (() throws -> Void)?) throws -> Data {
        guard !payload.isEmpty else { return Data() }

        let bufferSize = ZipArchiveLimits.inflateChunkSize
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var stream = compression_stream(
            dst_ptr: destination,
            dst_size: bufferSize,
            src_ptr: UnsafePointer(destination),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else {
            throw ZipArchiveError.inflateFailed(entry.path)
        }
        defer { compression_stream_destroy(&stream) }

        let ratioCeiling = payload.count * ZipArchiveLimits.maximumCompressionRatio
        var output = Data()
        var thrown: Error?

        payload.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                thrown = ZipArchiveError.inflateFailed(entry.path)
                return
            }
            stream.src_ptr = base
            stream.src_size = raw.count
            stream.dst_ptr = destination
            stream.dst_size = bufferSize

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
                    if produced > 0 {
                        output.append(destination, count: produced)
                    }
                    return
                default:
                    thrown = ZipArchiveError.inflateFailed(entry.path)
                    return
                }

                if output.count > ZipArchiveLimits.maximumEntrySize {
                    thrown = ZipArchiveError.entryTooLarge(entry.path)
                    return
                }
                if output.count > ratioCeiling {
                    thrown = ZipArchiveError.compressionRatioExceeded(entry.path)
                    return
                }
                if totalInflated + output.count > ZipArchiveLimits.maximumTotalInflatedSize {
                    thrown = ZipArchiveError.archiveTooLarge
                    return
                }
                do {
                    try onProgress?()
                } catch {
                    thrown = error
                    return
                }
            }
        }

        if let thrown { throw thrown }
        guard output.count <= ZipArchiveLimits.maximumEntrySize else {
            throw ZipArchiveError.entryTooLarge(entry.path)
        }
        guard output.count <= ratioCeiling else {
            throw ZipArchiveError.compressionRatioExceeded(entry.path)
        }
        return output
    }

    // MARK: - Byte access

    private static func byte(_ data: Data, _ index: Int) -> UInt8 {
        guard index >= 0, index < data.count else { return 0 }
        return data[data.startIndex + index]
    }

    private static func readUInt16(_ data: Data, _ index: Int) -> UInt16 {
        UInt16(byte(data, index)) | (UInt16(byte(data, index + 1)) << 8)
    }

    private static func readUInt32(_ data: Data, _ index: Int) -> UInt32 {
        UInt32(byte(data, index))
            | (UInt32(byte(data, index + 1)) << 8)
            | (UInt32(byte(data, index + 2)) << 16)
            | (UInt32(byte(data, index + 3)) << 24)
    }

    private static let crcTable: [UInt32] = {
        (0 ..< 256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    public static func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
