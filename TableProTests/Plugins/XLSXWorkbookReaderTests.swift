//
//  XLSXWorkbookReaderTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("XLSX Cell Reference")
struct XLSXCellReferenceTests {
    @Test("Column letters convert to zero based indices")
    func columnLettersConvert() {
        #expect(XLSXCellReference.columnIndex(for: "A1") == 0)
        #expect(XLSXCellReference.columnIndex(for: "Z1") == 25)
        #expect(XLSXCellReference.columnIndex(for: "AA1") == 26)
        #expect(XLSXCellReference.columnIndex(for: "AMJ1") == 1_023)
        #expect(XLSXCellReference.columnIndex(for: "XFD1") == 16_383)
    }

    @Test("A reference past the last real column returns nil rather than sizing an array")
    func columnsPastTheLimitReturnNil() {
        #expect(XLSXCellReference("XFE1") == nil)
        #expect(XLSXCellReference("ZZZ1") == nil)
        #expect(XLSXCellReference("ZZZZZZZZ1") == nil)
    }

    @Test("A row index past the last real row returns nil")
    func rowsPastTheLimitReturnNil() {
        #expect(XLSXCellReference("A1048576")?.rowIndex == 1_048_575)
        #expect(XLSXCellReference("A1048577") == nil)
        #expect(XLSXCellReference("A0") == nil)
    }

    @Test("A malformed reference returns nil")
    func malformedReferencesReturnNil() {
        for reference in ["", "1", "A1B", "a1", "$A$1", "A-1", "A 1"] {
            #expect(XLSXCellReference(reference) == nil, "\(reference) should not parse")
        }
    }
}

@Suite("XLSX XML Safety")
struct XLSXXmlSafetyTests {
    @Test("A part beginning with a document type declaration is rejected")
    func doctypeRejected() {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE foo [ <!ENTITY a \"b\"> ]><foo>&a;</foo>"
        #expect(throws: XLSXXmlError.documentTypeDeclarationRejected) {
            try XLSXXmlSafety.rejectDocumentTypeDeclaration(in: Data(xml.utf8))
        }
    }

    @Test("A nested entity expansion bomb is rejected before it expands")
    func entityBombRejected() {
        let xml = """
        <?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol">\
        <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">\
        <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">]>\
        <lolz>&lol3;</lolz>
        """
        #expect(throws: (any Error).self) { try XLSXXmlSafety.makeParser(for: Data(xml.utf8)) }
    }

    @Test("An external system entity is rejected and never resolved")
    func externalEntityRejected() {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><r>&x;</r>"
        #expect(throws: (any Error).self) { try XLSXXmlSafety.makeParser(for: Data(xml.utf8)) }
    }

    @Test("A clean part parses with external entity resolution switched off")
    func cleanPartParses() throws {
        let parser = try XLSXXmlSafety.makeParser(for: Data("<?xml version=\"1.0\"?><r/>".utf8))
        #expect(parser.shouldResolveExternalEntities == false)
    }
}

@Suite("XLSX Date Converter")
struct XLSXDateConverterTests {
    @Test("Serial 1 on the 1900 epoch is 1900-01-01")
    func serialOneOn1900() throws {
        let value = try #require(XLSXDateConverter.dateTime(serial: 1, usesDate1904: false))
        #expect(value == XLSXDateTime(year: 1_900, month: 1, day: 1, hour: 0, minute: 0, second: 0))
    }

    @Test("Serial 59 and 61 bracket the Lotus leap year gap")
    func lotusLeapYearGap() throws {
        let before = try #require(XLSXDateConverter.dateTime(serial: 59, usesDate1904: false))
        let gap = try #require(XLSXDateConverter.dateTime(serial: 60, usesDate1904: false))
        let after = try #require(XLSXDateConverter.dateTime(serial: 61, usesDate1904: false))
        #expect(before == XLSXDateTime(year: 1_900, month: 2, day: 28, hour: 0, minute: 0, second: 0))
        #expect(gap == XLSXDateTime(year: 1_900, month: 2, day: 28, hour: 0, minute: 0, second: 0))
        #expect(after == XLSXDateTime(year: 1_900, month: 3, day: 1, hour: 0, minute: 0, second: 0))
    }

    @Test("A modern serial converts on the 1900 epoch")
    func modernSerialOn1900() throws {
        let value = try #require(XLSXDateConverter.dateTime(serial: 45_000, usesDate1904: false))
        #expect(value == XLSXDateTime(year: 2_023, month: 3, day: 15, hour: 0, minute: 0, second: 0))
    }

    @Test("Serial 1 on the 1904 epoch is 1904-01-02")
    func serialOneOn1904() throws {
        let value = try #require(XLSXDateConverter.dateTime(serial: 1, usesDate1904: true))
        #expect(value == XLSXDateTime(year: 1_904, month: 1, day: 2, hour: 0, minute: 0, second: 0))
        let zero = try #require(XLSXDateConverter.dateTime(serial: 0, usesDate1904: true))
        #expect(zero == XLSXDateTime(year: 1_904, month: 1, day: 1, hour: 0, minute: 0, second: 0))
    }

    @Test("A fractional serial yields the right time of day")
    func fractionYieldsTimeOfDay() throws {
        let value = try #require(XLSXDateConverter.dateTime(serial: 45_000.5, usesDate1904: false))
        #expect(value.hour == 12)
        #expect(value.minute == 0)
        #expect(value.second == 0)
        #expect(value.hasTimeOfDay)
    }

    @Test("Builtin and custom date formats are recognised, quoted literals are not")
    func dateFormatDetection() {
        #expect(XLSXDateConverter.isDateFormat(numberFormatId: 14, formatCode: nil))
        #expect(XLSXDateConverter.isDateFormat(numberFormatId: 22, formatCode: nil))
        #expect(XLSXDateConverter.isDateFormat(numberFormatId: 45, formatCode: nil))
        #expect(XLSXDateConverter.isDateFormat(numberFormatId: 164, formatCode: "yyyy-mm-dd"))
        #expect(XLSXDateConverter.isDateFormat(numberFormatId: 0, formatCode: "General") == false)
        #expect(XLSXDateConverter.isDateFormat(numberFormatId: 165, formatCode: "#,##0.00\" USD\"") == false)
        #expect(XLSXDateConverter.isDateFormat(numberFormatId: 166, formatCode: "0.00\" days\"") == false)
    }
}

@Suite("XLSX Workbook Reader")
struct XLSXWorkbookReaderTests {
    private func reader(_ data: Data) throws -> XLSXWorkbookReader {
        try XLSXWorkbookReader(archive: try ZipArchiveReader(data: data))
    }

    @Test("Sheet names and order come from the workbook part")
    func sheetNamesAndOrder() throws {
        let data = XLSXWorkbookTestBuilder.workbook(sheets: [
            .init(name: "Summary", partPath: "worksheets/sheet1.xml", xml: XLSXWorkbookTestBuilder.sheetXml(rows: [])),
            .init(name: "Detail", partPath: "worksheets/sheet2.xml", xml: XLSXWorkbookTestBuilder.sheetXml(rows: []))
        ])
        let workbook = try reader(data)
        #expect(workbook.sheets.map(\.name) == ["Summary", "Detail"])
    }

    @Test("Sheet part paths resolve through the relationship file, not by sheet order")
    func partPathsResolveThroughRelationships() throws {
        let data = XLSXWorkbookTestBuilder.workbook(sheets: [
            .init(name: "First", partPath: "worksheets/sheet7.xml", xml: XLSXWorkbookTestBuilder.sheetXml(rows: [])),
            .init(name: "Second", partPath: "worksheets/sheet3.xml", xml: XLSXWorkbookTestBuilder.sheetXml(rows: []))
        ])
        let workbook = try reader(data)
        #expect(workbook.sheets.map(\.partPath) == ["xl/worksheets/sheet7.xml", "xl/worksheets/sheet3.xml"])
        let sheet = try #require(workbook.sheet(named: "Second"))
        let sheetData = try workbook.sheetData(for: sheet)
        #expect(sheetData.isEmpty == false)
    }

    @Test("The 1904 epoch flag is read when present and defaults to off")
    func date1904Flag() throws {
        let sheets: [XLSXWorkbookTestBuilder.Sheet] = [
            .init(name: "S", partPath: "worksheets/sheet1.xml", xml: XLSXWorkbookTestBuilder.sheetXml(rows: []))
        ]
        let plain = try reader(XLSXWorkbookTestBuilder.workbook(sheets: sheets))
        let shifted = try reader(XLSXWorkbookTestBuilder.workbook(sheets: sheets, usesDate1904: true))
        #expect(plain.usesDate1904 == false)
        #expect(shifted.usesDate1904)
    }

    @Test("Shared strings resolve by index and out of range lookups return nil")
    func sharedStringsResolve() throws {
        let data = XLSXWorkbookTestBuilder.workbook(
            sheets: [.init(name: "S", partPath: "worksheets/sheet1.xml", xml: XLSXWorkbookTestBuilder.sheetXml(rows: []))],
            sharedStrings: ["id", "name", "Nguyễn Văn Đức"]
        )
        let workbook = try reader(data)
        #expect(workbook.sharedString(at: 0) == "id")
        #expect(workbook.sharedString(at: 2) == "Nguyễn Văn Đức")
        #expect(workbook.sharedString(at: 3) == nil)
        #expect(workbook.sharedString(at: -1) == nil)
    }

    @Test("Style indices resolve to date formatting through cellXfs")
    func styleIndicesResolve() throws {
        let data = XLSXWorkbookTestBuilder.workbook(
            sheets: [.init(name: "S", partPath: "worksheets/sheet1.xml", xml: XLSXWorkbookTestBuilder.sheetXml(rows: []))],
            stylesXml: XLSXWorkbookTestBuilder.styles(
                cellFormatIds: [0, 14, 164, 165],
                customFormats: [164: "yyyy-mm-dd", 165: "#,##0.00\" USD\""]
            )
        )
        let workbook = try reader(data)
        #expect(workbook.isDateFormatted(styleIndex: 0) == false)
        #expect(workbook.isDateFormatted(styleIndex: 1))
        #expect(workbook.isDateFormatted(styleIndex: 2))
        #expect(workbook.isDateFormatted(styleIndex: 3) == false)
        #expect(workbook.isDateFormatted(styleIndex: 99) == false)
    }

    @Test("A file with no workbook part is rejected as not a workbook")
    func missingWorkbookPartRejected() {
        let data = ZipArchiveTestBuilder.archive(entries: [
            ZipArchiveTestBuilder.Entry(path: "readme.txt", payload: Data("hello".utf8))
        ])
        #expect(throws: XLSXWorkbookError.workbookPartMissing) { _ = try reader(data) }
    }

    @Test("A workbook part carrying a document type declaration is rejected")
    func hostileWorkbookPartRejected() {
        let hostile = "<?xml version=\"1.0\"?><!DOCTYPE w [<!ENTITY x \"y\">]><workbook><sheets/></workbook>"
        let data = ZipArchiveTestBuilder.archive(entries: [
            XLSXWorkbookTestBuilder.entry("xl/workbook.xml", hostile)
        ])
        #expect(throws: XLSXXmlError.documentTypeDeclarationRejected) { _ = try reader(data) }
    }
}
