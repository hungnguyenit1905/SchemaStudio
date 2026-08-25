//
//  XLSXImportPluginTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("XLSX Sheet Selection")
struct XLSXSheetSelectionTests {
    private let first = URL(fileURLWithPath: "/tmp/q1.xlsx")
    private let second = URL(fileURLWithPath: "/tmp/q2.xlsx")

    @Test("Adopting a workbook selects its first sheet")
    func adoptSelectsFirstSheet() {
        var selection = XLSXSheetSelection()
        selection.adopt(url: first, sheetNames: ["Summary", "Detail"])
        #expect(selection.selectedSheetName == "Summary")
        #expect(selection.hasChoice)
    }

    @Test("A single sheet workbook needs no choice")
    func singleSheetNeedsNoChoice() {
        var selection = XLSXSheetSelection()
        selection.adopt(url: first, sheetNames: ["Sheet1"])
        #expect(selection.hasChoice == false)
        #expect(selection.selectedSheetName == "Sheet1")
    }

    @Test("Changing the sheet changes the detection signature")
    func changingSheetChangesSignature() {
        var selection = XLSXSheetSelection()
        selection.adopt(url: first, sheetNames: ["Summary", "Detail"])
        let before = selection.signature
        selection.select("Detail")
        #expect(selection.selectedSheetName == "Detail")
        #expect(selection.signature != before)
    }

    @Test("Selecting a sheet the workbook does not have is ignored")
    func unknownSelectionIgnored() {
        var selection = XLSXSheetSelection()
        selection.adopt(url: first, sheetNames: ["Summary", "Detail"])
        selection.select("Nope")
        #expect(selection.selectedSheetName == "Summary")
    }

    @Test("Opening a different workbook does not carry the previous sheet name")
    func switchingFilesResetsSelection() {
        var selection = XLSXSheetSelection()
        selection.adopt(url: first, sheetNames: ["Summary", "Detail"])
        selection.select("Detail")
        selection.adopt(url: second, sheetNames: ["Q2", "Notes"])
        #expect(selection.selectedSheetName == "Q2")
        #expect(selection.signature.contains("q2.xlsx"))
    }

    @Test("Re-adopting the same workbook keeps the chosen sheet")
    func reAdoptingSameFileKeepsSelection() {
        var selection = XLSXSheetSelection()
        selection.adopt(url: first, sheetNames: ["Summary", "Detail"])
        selection.select("Detail")
        selection.adopt(url: first, sheetNames: ["Summary", "Detail"])
        #expect(selection.selectedSheetName == "Detail")
    }

    @Test("A sheet name absent from the workbook resolves to the first sheet and reports the fallback")
    func absentSheetFallsBackToFirst() {
        var selection = XLSXSheetSelection()
        selection.adopt(url: first, sheetNames: ["Summary", "Detail"])
        selection.select("Detail")
        let resolved = selection.resolvedSheetName(in: ["Alpha", "Beta"])
        #expect(resolved == "Alpha")
        #expect(selection.resolutionFellBack(to: resolved))
    }

    @Test("A present sheet name resolves to itself with no fallback")
    func presentSheetResolvesToItself() {
        var selection = XLSXSheetSelection()
        selection.adopt(url: first, sheetNames: ["Summary", "Detail"])
        selection.select("Detail")
        let resolved = selection.resolvedSheetName(in: ["Summary", "Detail"])
        #expect(resolved == "Detail")
        #expect(selection.resolutionFellBack(to: resolved) == false)
    }
}

@Suite("XLSX Row Mapper")
struct XLSXRowMapperTests {
    private func row(_ cells: [XLSXCellValue]) -> XLSXRow {
        XLSXRow(index: 0, cells: cells)
    }

    @Test("A header row supplies the field names")
    func headerRowSuppliesFieldNames() {
        var options = XLSXImportOptions()
        options.hasHeaderRow = true
        let fields = XLSXRowMapper.detectFields(
            rows: [row([.text("id"), .text("name")]), row([.number("1"), .text("Ada")])],
            options: options
        )
        #expect(fields.map(\.name) == ["id", "name"])
        #expect(fields[0].sampleValue == "1")
        #expect(fields[0].inferredType == .integer)
        #expect(fields[1].inferredType == .text)
    }

    @Test("With no header row the fields are positional and row one stays data")
    func positionalFieldNamesWithoutHeader() {
        var options = XLSXImportOptions()
        options.hasHeaderRow = false
        let fields = XLSXRowMapper.detectFields(
            rows: [row([.text("id"), .text("name")]), row([.number("1"), .text("Ada")])],
            options: options
        )
        #expect(fields.map(\.name) == ["column_1", "column_2"])
        #expect(fields[0].sampleValue == "id")
    }

    @Test("Blank and duplicate header names are made usable and unique")
    func headerNamesAreMadeUnique() {
        let names = XLSXRowMapper.columnNames(
            headerRow: row([.text("id"), .empty, .text("id")]),
            columnCount: 3
        )
        #expect(names == ["id", "column_2", "id_2"])
    }

    @Test("A nineteen digit identifier reaches the sink as an unmodified lossless string")
    func bigIntegerReachesSinkUnmodified() {
        let identifier = "9223372036854775807"
        let value = XLSXRowMapper.cellValue(.number(identifier), options: XLSXImportOptions())
        #expect(value == .decimalText(identifier))
    }

    @Test("Treat empty as NULL and NULL text behave as they do for CSV import")
    func nullHandlingMatchesCsv() {
        var options = XLSXImportOptions()
        options.emptyAsNull = true
        options.nullString = "\\N"
        #expect(XLSXRowMapper.cellValue(.empty, options: options) == .null)
        #expect(XLSXRowMapper.cellValue(.text("\\N"), options: options) == .null)
        #expect(XLSXRowMapper.cellValue(.text(""), options: options) == .null)
        #expect(XLSXRowMapper.cellValue(.text("value"), options: options) == .text("value"))

        options.emptyAsNull = false
        #expect(XLSXRowMapper.cellValue(.empty, options: options) == .text(""))
    }

    @Test("Trimming applies only when it is switched on")
    func trimmingIsOptional() {
        var options = XLSXImportOptions()
        options.trimWhitespace = false
        #expect(XLSXRowMapper.cellValue(.text("  a  "), options: options) == .text("  a  "))
        options.trimWhitespace = true
        #expect(XLSXRowMapper.cellValue(.text("  a  "), options: options) == .text("a"))
    }

    @Test("A date without a time crosses as a calendar date and a datetime as an unambiguous literal")
    func dateValuesCross() {
        let options = XLSXImportOptions()
        let dateOnly = XLSXDateTime(year: 2_023, month: 3, day: 15, hour: 0, minute: 0, second: 0)
        let dateTime = XLSXDateTime(year: 2_023, month: 3, day: 15, hour: 12, minute: 30, second: 5)
        #expect(XLSXRowMapper.cellValue(.dateTime(dateOnly), options: options) == .date(year: 2_023, month: 3, day: 15))
        #expect(XLSXRowMapper.cellValue(.dateTime(dateTime), options: options) == .text("2023-03-15 12:30:05"))
    }

    @Test("Booleans cross as booleans")
    func booleansCross() {
        #expect(XLSXRowMapper.cellValue(.boolean(true), options: XLSXImportOptions()) == .bool(true))
    }

    @Test("A short row is padded to the column list rather than dropping columns")
    func shortRowIsPadded() {
        var options = XLSXImportOptions()
        options.emptyAsNull = true
        let mapped = XLSXRowMapper.row(
            row([.number("1")]),
            columnNames: ["id", "name", "note"],
            options: options
        )
        #expect(mapped["id"] == .decimalText("1"))
        #expect(mapped["name"] == .null)
        #expect(mapped["note"] == .null)
    }

    @Test("A row with gaps maps values to the right columns")
    func sparseRowMapsCorrectly() {
        let mapped = XLSXRowMapper.row(
            row([.number("1"), .empty, .text("third")]),
            columnNames: ["a", "b", "c"],
            options: XLSXImportOptions()
        )
        #expect(mapped["a"] == .decimalText("1"))
        #expect(mapped["b"] == .null)
        #expect(mapped["c"] == .text("third"))
    }

    @Test("A fully empty row is reported as blank")
    func blankRowDetected() {
        #expect(XLSXRowMapper.isBlank(row([.empty, .empty])))
        #expect(XLSXRowMapper.isBlank(row([])))
        #expect(XLSXRowMapper.isBlank(row([.empty, .text("x")])) == false)
    }

    @Test("Options that change parsing change the detection signature")
    func optionsChangeDetectionSignature() {
        var options = XLSXImportOptions()
        let baseline = options.detectionSignature
        options.hasHeaderRow = false
        #expect(options.detectionSignature != baseline)
        options.hasHeaderRow = true
        options.nullString = "\\N"
        #expect(options.detectionSignature != baseline)
    }
}
