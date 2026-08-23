//
//  ZipArchiveReaderTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("Zip Archive Reader")
struct ZipArchiveReaderTests {
    private func entry(_ path: String, _ text: String, deflated: Bool = false) -> ZipArchiveTestBuilder.Entry {
        ZipArchiveTestBuilder.Entry(path: path, payload: Data(text.utf8), deflated: deflated)
    }

    private func expectError(_ expected: ZipArchiveError, _ body: () throws -> Void) {
        #expect(throws: expected) { try body() }
    }

    @Test("A stored entry reads back byte for byte")
    func readsStoredEntry() throws {
        let archive = ZipArchiveTestBuilder.archive(entries: [entry("xl/workbook.xml", "<workbook/>")])
        let reader = try ZipArchiveReader(data: archive)
        #expect(reader.entryPaths == ["xl/workbook.xml"])
        #expect(try reader.data(forEntry: "xl/workbook.xml") == Data("<workbook/>".utf8))
    }

    @Test("A deflated entry reads back byte for byte")
    func readsDeflatedEntry() throws {
        let payload = String(repeating: "<c r=\"A1\"><v>1</v></c>", count: 64)
        let archive = ZipArchiveTestBuilder.archive(entries: [entry("xl/sheet1.xml", payload, deflated: true)])
        let reader = try ZipArchiveReader(data: archive)
        #expect(try reader.data(forEntry: "xl/sheet1.xml") == Data(payload.utf8))
    }

    @Test("A deflated entry larger than one inflate window reads back complete")
    func readsChunkedDeflatedEntry() throws {
        let payload = (0 ..< 20_000)
            .map { "<c r=\"A\($0)\" s=\"\($0 % 97)\"><v>\($0 * 7_919)</v></c>" }
            .joined()
        let archive = ZipArchiveTestBuilder.archive(entries: [entry("big.xml", payload, deflated: true)])
        let reader = try ZipArchiveReader(data: archive)
        let output = try reader.data(forEntry: "big.xml")
        #expect(output.count > ZipArchiveLimits.inflateChunkSize)
        #expect(output == Data(payload.utf8))
    }

    @Test("Reads several entries and reports them in central directory order")
    func readsMultipleEntries() throws {
        let archive = ZipArchiveTestBuilder.archive(entries: [
            entry("[Content_Types].xml", "<Types/>"),
            entry("xl/workbook.xml", "<workbook/>", deflated: true),
            entry("xl/sharedStrings.xml", "<sst/>")
        ])
        let reader = try ZipArchiveReader(data: archive)
        #expect(reader.entryPaths == ["[Content_Types].xml", "xl/workbook.xml", "xl/sharedStrings.xml"])
        #expect(reader.contains("xl/sharedStrings.xml"))
        #expect(try reader.data(forEntry: "xl/workbook.xml") == Data("<workbook/>".utf8))
    }

    @Test("An archive comment still parses")
    func archiveCommentParses() throws {
        let archive = ZipArchiveTestBuilder.archive(
            entries: [entry("a.xml", "<a/>")],
            comment: "written by a spreadsheet"
        )
        let reader = try ZipArchiveReader(data: archive)
        #expect(try reader.data(forEntry: "a.xml") == Data("<a/>".utf8))
    }

    @Test("An unknown compression method throws")
    func unknownCompressionMethodThrows() throws {
        var stored = entry("a.xml", "<a/>")
        stored.declaredMethod = 12
        let archive = ZipArchiveTestBuilder.archive(entries: [stored])
        let reader = try ZipArchiveReader(data: archive)
        expectError(.unsupportedCompressionMethod(12)) { _ = try reader.data(forEntry: "a.xml") }
    }

    @Test("An encrypted entry is reported as a password-protected workbook")
    func encryptedEntryThrows() {
        var encrypted = entry("a.xml", "<a/>", deflated: true)
        encrypted.flags = 0x0001
        let archive = ZipArchiveTestBuilder.archive(entries: [encrypted])
        expectError(.encryptedEntry) { _ = try ZipArchiveReader(data: archive) }
    }

    @Test("Duplicate entry names are rejected outright")
    func duplicateEntryNamesThrow() {
        let archive = ZipArchiveTestBuilder.archive(
            entries: [entry("xl/sheet1.xml", "<a/>")],
            duplicateCentralRecordFor: "xl/sheet1.xml"
        )
        expectError(.duplicateEntryName("xl/sheet1.xml")) { _ = try ZipArchiveReader(data: archive) }
    }

    @Test("An appended second end record is rejected")
    func appendedEndRecordThrows() {
        let archive = ZipArchiveTestBuilder.archive(
            entries: [entry("a.xml", "<a/>")],
            appendSecondEndRecord: true
        )
        expectError(.trailingData) { _ = try ZipArchiveReader(data: archive) }
    }

    @Test("A truncated archive throws instead of crashing")
    func truncatedArchiveThrows() {
        let archive = ZipArchiveTestBuilder.archive(entries: [entry("a.xml", "<a/>")])
        let truncated = archive.prefix(archive.count / 2)
        #expect(throws: (any Error).self) { _ = try ZipArchiveReader(data: Data(truncated)) }
    }

    @Test("A file with no end record throws instead of crashing")
    func missingEndRecordThrows() {
        expectError(.endOfCentralDirectoryNotFound) {
            _ = try ZipArchiveReader(data: Data(repeating: 0x41, count: 512))
        }
        expectError(.endOfCentralDirectoryNotFound) { _ = try ZipArchiveReader(data: Data()) }
    }

    @Test("A checksum mismatch throws")
    func checksumMismatchThrows() throws {
        var archive = ZipArchiveTestBuilder.archive(entries: [entry("a.xml", "<a/>")])
        let payloadIndex = archive.firstIndex(of: UInt8(ascii: "<"))
        let index = try #require(payloadIndex)
        archive[index] = UInt8(ascii: ">")
        let reader = try ZipArchiveReader(data: archive)
        expectError(.checksumMismatch("a.xml")) { _ = try reader.data(forEntry: "a.xml") }
    }

    @Test("An absurd declared uncompressed size never sizes a buffer")
    func absurdDeclaredSizeIsIgnored() throws {
        var stored = entry("a.xml", "<a/>", deflated: true)
        stored.declaredUncompressedSize = 0xFFFF_FFF0
        let archive = ZipArchiveTestBuilder.archive(entries: [stored])
        let reader = try ZipArchiveReader(data: archive)
        #expect(try reader.data(forEntry: "a.xml") == Data("<a/>".utf8))
    }

    @Test("A high ratio bomb is refused during inflation")
    func compressionBombRefused() throws {
        let payload = String(repeating: "A", count: 4 * 1_024 * 1_024)
        let archive = ZipArchiveTestBuilder.archive(entries: [entry("bomb.xml", payload, deflated: true)])
        let reader = try ZipArchiveReader(data: archive)
        expectError(.compressionRatioExceeded("bomb.xml")) { _ = try reader.data(forEntry: "bomb.xml") }
    }

    @Test("A file over the size ceiling is refused before it is parsed")
    func fileSizeCeilingEnforced() {
        let oversized = Data(count: ZipArchiveLimits.maximumFileSize + 1)
        expectError(.fileTooLarge) { _ = try ZipArchiveReader(data: oversized) }
    }

    @Test("A path traversal, absolute path or backslash path is refused")
    func unsafePathsRefused() {
        for path in ["../../etc/passwd", "/etc/passwd", "xl\\sheet1.xml", "a/../../b.xml"] {
            let archive = ZipArchiveTestBuilder.archive(entries: [entry(path, "<a/>")])
            expectError(.unsafeEntryPath(path)) { _ = try ZipArchiveReader(data: archive) }
        }
    }

    @Test("A Zip64 archive fails with the explicit too large error")
    func zip64Refused() {
        expectError(.zip64Unsupported) { _ = try ZipArchiveReader(data: ZipArchiveTestBuilder.zip64Archive()) }
    }

    @Test("A missing entry throws a distinguishable not found error")
    func missingEntryThrows() throws {
        let archive = ZipArchiveTestBuilder.archive(entries: [entry("a.xml", "<a/>")])
        let reader = try ZipArchiveReader(data: archive)
        #expect(reader.contains("xl/workbook.xml") == false)
        expectError(.entryNotFound("xl/workbook.xml")) { _ = try reader.data(forEntry: "xl/workbook.xml") }
    }

    @Test("Cancellation during inflation propagates out of the reader")
    func cancellationPropagates() throws {
        struct Cancelled: Error {}
        let payload = (0 ..< 20_000).map { "<c r=\"A\($0)\"><v>\($0 * 7_919)</v></c>" }.joined()
        let archive = ZipArchiveTestBuilder.archive(entries: [entry("big.xml", payload, deflated: true)])
        let reader = try ZipArchiveReader(data: archive)
        #expect(throws: Cancelled.self) {
            _ = try reader.data(forEntry: "big.xml", onProgress: { throw Cancelled() })
        }
    }
}
