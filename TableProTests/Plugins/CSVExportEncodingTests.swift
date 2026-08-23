//
//  CSVExportEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("CSV Export Encoding")
struct CSVExportEncodingTests {
    private let bom = Data([0xEF, 0xBB, 0xBF])

    private func writeDocument(encoding: CSVExportEncoding, tableCount: Int) -> Data {
        var encoder = CSVExportEncoder(encoding: encoding)
        var output = Data()
        output.append(encoder.preamble())
        for index in 0 ..< tableCount {
            output.append(encoder.encode("# Table: t\(index)\n"))
            output.append(encoder.encode("id,name\n"))
            output.append(encoder.encode("1,row\n"))
            if index < tableCount - 1 {
                output.append(encoder.encode("\n\n"))
            }
        }
        return output
    }

    @Test("UTF-8 output carries no byte order mark")
    func utf8HasNoBOM() {
        let output = writeDocument(encoding: .utf8, tableCount: 3)
        #expect(output.starts(with: bom) == false)
        #expect(output.ranges(of: bom).isEmpty)
    }

    @Test("UTF-8 with BOM starts with the mark and carries it exactly once across a multi table export")
    func bomWrittenExactlyOnce() {
        let output = writeDocument(encoding: .utf8WithBOM, tableCount: 3)
        #expect(output.starts(with: bom))
        #expect(output.ranges(of: bom).count == 1)
    }

    @Test("Default output is byte identical to the same document written without an encoding option")
    func defaultOutputUnchanged() {
        let fixture = "# Table: t0\nid,name\n1,row\n"
        let encoder = CSVExportEncoder(encoding: .utf8)
        #expect(encoder.encode(fixture) == Data(fixture.utf8))
        #expect(writeDocument(encoding: .utf8, tableCount: 1) == Data(fixture.utf8))
    }

    @Test("Only the preamble differs between the two encodings")
    func encodingsDifferOnlyByPreamble() {
        let plain = writeDocument(encoding: .utf8, tableCount: 2)
        let marked = writeDocument(encoding: .utf8WithBOM, tableCount: 2)
        #expect(marked == bom + plain)
    }

    @Test("Vietnamese and CJK text round trips through both encodings")
    func nonAsciiRoundTrips() throws {
        let vietnamese = "Nguyễn Văn Đức"
        let cjk = "日本語のテキスト"
        for encoding in CSVExportEncoding.allCases {
            var encoder = CSVExportEncoder(encoding: encoding)
            var output = Data()
            output.append(encoder.preamble())
            output.append(encoder.encode("name\n"))
            output.append(encoder.encode("\(vietnamese)\n"))
            output.append(encoder.encode("\(cjk)\n"))

            var payload = output
            if payload.starts(with: bom) {
                payload = payload.dropFirst(bom.count)
            }
            let decoded = try #require(String(data: payload, encoding: .utf8))
            #expect(decoded.contains(vietnamese))
            #expect(decoded.contains(cjk))
        }
    }

    @Test("Preamble is empty on every call after the first for both encodings")
    func preambleIsOnceOnly() {
        for encoding in CSVExportEncoding.allCases {
            var encoder = CSVExportEncoder(encoding: encoding)
            _ = encoder.preamble()
            #expect(encoder.preamble().isEmpty)
            #expect(encoder.preamble().isEmpty)
        }
    }
}
