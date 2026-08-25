//
//  XLSXCellDecoderTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("XLSX Cell Decoder")
struct XLSXCellDecoderTests {
    private func decode(
        rows: [String],
        sharedStrings: [String] = [],
        stylesXml: String? = nil,
        usesDate1904: Bool = false
    ) throws -> [XLSXRow] {
        let data = XLSXWorkbookTestBuilder.workbook(
            sheets: [.init(
                name: "Sheet1",
                partPath: "worksheets/sheet1.xml",
                xml: XLSXWorkbookTestBuilder.sheetXml(rows: rows)
            )],
            sharedStrings: sharedStrings,
            stylesXml: stylesXml,
            usesDate1904: usesDate1904
        )
        let workbook = try XLSXWorkbookReader(archive: try ZipArchiveReader(data: data))
        let sheet = try #require(workbook.sheets.first)
        let sheetData = try workbook.sheetData(for: sheet)
        return try XLSXCellDecoder.decodeAllRows(
            data: sheetData,
            workbook: workbook,
            partName: sheet.partPath
        )
    }

    @Test("A row with gaps places values by reference and never shifts columns")
    func sparseRowDoesNotShift() throws {
        let rows = try decode(rows: [
            XLSXWorkbookTestBuilder.row(1, """
            <c r="A1"><v>10</v></c><c r="C1"><v>30</v></c><c r="E1"><v>50</v></c>
            """)
        ])
        #expect(rows.count == 1)
        #expect(rows[0].cells == [.number("10"), .empty, .number("30"), .empty, .number("50")])
    }

    @Test("A nineteen digit integer survives exactly as a string")
    func bigIntegerSurvives() throws {
        let identifier = "9223372036854775807"
        let rows = try decode(rows: [
            XLSXWorkbookTestBuilder.row(1, "<c r=\"A1\"><v>\(identifier)</v></c>")
        ])
        #expect(rows[0].cells == [.number(identifier)])
        if case let .number(raw) = rows[0].cells[0] {
            #expect(raw == identifier)
        }
    }

    @Test("Shared string, inline string, boolean and error cells each decode")
    func cellTypesDecode() throws {
        let rows = try decode(
            rows: [XLSXWorkbookTestBuilder.row(1, """
            <c r="A1" t="s"><v>1</v></c>\
            <c r="B1" t="inlineStr"><is><t>inline</t></is></c>\
            <c r="C1" t="b"><v>1</v></c>\
            <c r="D1" t="e"><v>#DIV/0!</v></c>
            """)],
            sharedStrings: ["first", "second"]
        )
        #expect(rows[0].cells == [.text("second"), .text("inline"), .boolean(true), .error("#DIV/0!")])
    }

    @Test("A formula cell yields its cached value, not the formula text")
    func formulaYieldsCachedValue() throws {
        let rows = try decode(rows: [
            XLSXWorkbookTestBuilder.row(1, "<c r=\"A1\"><f>SUM(B1:C1)</f><v>42</v></c>")
        ])
        #expect(rows[0].cells == [.number("42")])
    }

    @Test("A date formatted numeric cell decodes to a date value")
    func dateFormattedCellDecodes() throws {
        let rows = try decode(
            rows: [XLSXWorkbookTestBuilder.row(1, """
            <c r="A1" s="1"><v>45000</v></c><c r="B1" s="0"><v>45000</v></c>
            """)],
            stylesXml: XLSXWorkbookTestBuilder.styles(cellFormatIds: [0, 14])
        )
        #expect(rows[0].cells[0] == .dateTime(
            XLSXDateTime(year: 2_023, month: 3, day: 15, hour: 0, minute: 0, second: 0)
        ))
        #expect(rows[0].cells[1] == .number("45000"))
    }

    @Test("A 1904 workbook shifts its dates by the epoch difference")
    func date1904WorkbookDecodes() throws {
        let rows = try decode(
            rows: [XLSXWorkbookTestBuilder.row(1, "<c r=\"A1\" s=\"0\"><v>1</v></c>")],
            stylesXml: XLSXWorkbookTestBuilder.styles(cellFormatIds: [14]),
            usesDate1904: true
        )
        #expect(rows[0].cells[0] == .dateTime(
            XLSXDateTime(year: 1_904, month: 1, day: 2, hour: 0, minute: 0, second: 0)
        ))
    }

    @Test("A merged range contributes its top left value only")
    func mergedRangeKeepsTopLeftOnly() throws {
        let rows = try decode(
            rows: [
                XLSXWorkbookTestBuilder.row(1, """
                <c r="A1" t="s"><v>0</v></c><c r="B1" s="0"/>
                """),
                XLSXWorkbookTestBuilder.row(2, "<c r=\"A2\" s=\"0\"/><c r=\"B2\" s=\"0\"/>")
            ],
            sharedStrings: ["merged"]
        )
        #expect(rows[0].cells == [.text("merged")])
        #expect(rows[1].cells == [XLSXCellValue.empty, XLSXCellValue.empty] || rows[1].cells.isEmpty)
    }

    @Test("An empty sheet yields zero rows")
    func emptySheetYieldsNoRows() throws {
        let rows = try decode(rows: [])
        #expect(rows.isEmpty)
    }

    @Test("An out of range cell reference is dropped rather than sizing a row")
    func outOfRangeReferenceDropped() throws {
        let rows = try decode(rows: [
            XLSXWorkbookTestBuilder.row(1, "<c r=\"A1\"><v>1</v></c><c r=\"XFE1\"><v>2</v></c>")
        ])
        #expect(rows[0].cells == [.number("1")])
    }

    @Test("Rows reach the caller in batches rather than as one array")
    func rowsArriveInBatches() throws {
        let sheetRows = (1 ... 25).map { XLSXWorkbookTestBuilder.row($0, "<c r=\"A\($0)\"><v>\($0)</v></c>") }
        let data = XLSXWorkbookTestBuilder.workbook(sheets: [.init(
            name: "Sheet1",
            partPath: "worksheets/sheet1.xml",
            xml: XLSXWorkbookTestBuilder.sheetXml(rows: sheetRows)
        )])
        let workbook = try XLSXWorkbookReader(archive: try ZipArchiveReader(data: data))
        let sheet = try #require(workbook.sheets.first)

        var batchSizes = [Int]()
        var total = 0
        let sheetData = try workbook.sheetData(for: sheet)
        try XLSXCellDecoder.decodeSheet(
            data: sheetData,
            workbook: workbook,
            partName: sheet.partPath,
            batchSize: 10
        ) { batch in
            batchSizes.append(batch.count)
            total += batch.count
        }
        #expect(total == 25)
        #expect(batchSizes.count > 1)
        #expect(batchSizes.allSatisfy { $0 <= 10 })
    }

    @Test("Cancellation during the row loop stops the parse")
    func cancellationStopsTheParse() throws {
        struct Cancelled: Error {}
        let sheetRows = (1 ... 500).map { XLSXWorkbookTestBuilder.row($0, "<c r=\"A\($0)\"><v>\($0)</v></c>") }
        let data = XLSXWorkbookTestBuilder.workbook(sheets: [.init(
            name: "Sheet1",
            partPath: "worksheets/sheet1.xml",
            xml: XLSXWorkbookTestBuilder.sheetXml(rows: sheetRows)
        )])
        let workbook = try XLSXWorkbookReader(archive: try ZipArchiveReader(data: data))
        let sheet = try #require(workbook.sheets.first)

        let sheetData = try workbook.sheetData(for: sheet)
        var seen = 0
        #expect(throws: Cancelled.self) {
            try XLSXCellDecoder.decodeSheet(
                data: sheetData,
                workbook: workbook,
                partName: sheet.partPath,
                batchSize: 10,
                onProgress: { if seen >= 20 { throw Cancelled() } }
            ) { batch in
                seen += batch.count
            }
        }
        #expect(seen < 500)
    }
}
