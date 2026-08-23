//
//  XLSXWorkbookTestBuilder.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio

enum XLSXWorkbookTestBuilder {
    struct Sheet {
        let name: String
        let partPath: String
        let xml: String
    }

    static func workbook(
        sheets: [Sheet],
        sharedStrings: [String] = [],
        stylesXml: String? = nil,
        usesDate1904: Bool = false,
        omitWorkbookPart: Bool = false,
        extraEntries: [ZipArchiveTestBuilder.Entry] = []
    ) -> Data {
        var entries = [ZipArchiveTestBuilder.Entry]()

        if !omitWorkbookPart {
            let sheetTags = sheets.enumerated().map { index, sheet in
                "<sheet name=\"\(sheet.name)\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
            }.joined()
            let workbookPr = usesDate1904 ? "<workbookPr date1904=\"1\"/>" : ""
            let workbookXml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            \(workbookPr)<sheets>\(sheetTags)</sheets></workbook>
            """
            entries.append(entry("xl/workbook.xml", workbookXml))

            let relTags = sheets.enumerated().map { index, sheet in
                "<Relationship Id=\"rId\(index + 1)\" Target=\"\(sheet.partPath)\" " +
                    "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\"/>"
            }.joined()
            entries.append(entry(
                "xl/_rels/workbook.xml.rels",
                "<?xml version=\"1.0\"?><Relationships>\(relTags)</Relationships>"
            ))
        }

        if !sharedStrings.isEmpty {
            let items = sharedStrings.map { "<si><t>\(escape($0))</t></si>" }.joined()
            entries.append(entry(
                "xl/sharedStrings.xml",
                "<?xml version=\"1.0\"?><sst count=\"\(sharedStrings.count)\">\(items)</sst>"
            ))
        }

        if let stylesXml {
            entries.append(entry("xl/styles.xml", stylesXml))
        }

        for sheet in sheets {
            entries.append(entry("xl/" + sheet.partPath, sheet.xml))
        }
        entries.append(contentsOf: extraEntries)

        return ZipArchiveTestBuilder.archive(entries: entries)
    }

    static func sheetXml(rows: [String]) -> String {
        "<?xml version=\"1.0\"?><worksheet><sheetData>\(rows.joined())</sheetData></worksheet>"
    }

    static func row(_ index: Int, _ cells: String) -> String {
        "<row r=\"\(index)\">\(cells)</row>"
    }

    static func styles(cellFormatIds: [Int], customFormats: [Int: String] = [:]) -> String {
        let numFmts = customFormats
            .sorted { $0.key < $1.key }
            .map { "<numFmt numFmtId=\"\($0.key)\" formatCode=\"\(escape($0.value))\"/>" }
            .joined()
        let xfs = cellFormatIds.map { "<xf numFmtId=\"\($0)\"/>" }.joined()
        return "<?xml version=\"1.0\"?><styleSheet><numFmts>\(numFmts)</numFmts>" +
            "<cellXfs count=\"\(cellFormatIds.count)\">\(xfs)</cellXfs></styleSheet>"
    }

    static func entry(_ path: String, _ text: String) -> ZipArchiveTestBuilder.Entry {
        ZipArchiveTestBuilder.Entry(path: path, payload: Data(text.utf8), deflated: true)
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
