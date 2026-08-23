//
//  XLSXCellDecoder.swift
//  XLSXImportPlugin
//
//  Rows reach the caller in batches. A workbook holds up to 1,048,576 rows per sheet, so the
//  decoded matrix is never materialized in full.
//

import Foundation

public enum XLSXCellValue: Equatable {
    case empty
    case text(String)
    /// The raw `<v>` string, always. A 19-digit identifier round-tripped through `Double` loses
    /// precision, and a plugin cannot see the destination column's type to decide otherwise.
    case number(String)
    case boolean(Bool)
    case error(String)
    case dateTime(XLSXDateTime)

    public var isEmpty: Bool {
        self == .empty
    }
}

public struct XLSXRow: Equatable {
    public let index: Int
    public let cells: [XLSXCellValue]
}

public enum XLSXCellDecoder {
    /// Delivers rows in batches, aborting as soon as `onBatch` or `onProgress` throws.
    public static func decodeSheet(
        data: Data,
        workbook: XLSXWorkbookReader,
        partName: String,
        batchSize: Int,
        onProgress: (() throws -> Void)? = nil,
        onBatch: @escaping ([XLSXRow]) throws -> Void
    ) throws {
        let delegate = SheetDelegate(
            workbook: workbook,
            batchSize: max(1, batchSize),
            onProgress: onProgress,
            onBatch: onBatch
        )
        try XLSXXmlSafety.parse(data, partName: partName, delegate: delegate)
        try delegate.flush()
    }

    public static func decodeAllRows(
        data: Data,
        workbook: XLSXWorkbookReader,
        partName: String
    ) throws -> [XLSXRow] {
        var rows = [XLSXRow]()
        try decodeSheet(data: data, workbook: workbook, partName: partName, batchSize: 512) { batch in
            rows.append(contentsOf: batch)
        }
        return rows
    }
}

private final class SheetDelegate: XLSXXmlDelegate {
    private let workbook: XLSXWorkbookReader
    private let batchSize: Int
    private let onProgress: (() throws -> Void)?
    private let onBatch: ([XLSXRow]) throws -> Void

    private var batch: [XLSXRow] = []
    private var cellsSeen = 0

    private var rowIndex = 0
    private var rowCells: [Int: XLSXCellValue] = [:]

    private var cellColumn: Int?
    private var cellType = ""
    private var cellStyleIndex = 0
    private var value: String?
    private var inlineText: String?
    private var isCapturingValue = false
    private var isCapturingInline = false

    init(
        workbook: XLSXWorkbookReader,
        batchSize: Int,
        onProgress: (() throws -> Void)?,
        onBatch: @escaping ([XLSXRow]) throws -> Void
    ) {
        self.workbook = workbook
        self.batchSize = batchSize
        self.onProgress = onProgress
        self.onBatch = onBatch
    }

    func flush() throws {
        guard !batch.isEmpty else { return }
        let pending = batch
        batch = []
        try onBatch(pending)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch localName(elementName) {
        case "row":
            rowCells = [:]
            if let declared = attributes["r"].flatMap(Int.init), declared >= 1 {
                rowIndex = declared - 1
            }
            do {
                try onProgress?()
            } catch {
                fail(error)
                parser.abortParsing()
            }
        case "c":
            cellType = attributes["t"] ?? "n"
            cellStyleIndex = attributes["s"].flatMap(Int.init) ?? 0
            value = nil
            inlineText = nil
            guard let reference = attributes["r"] else {
                cellColumn = nil
                return
            }
            cellColumn = XLSXCellReference(reference)?.columnIndex
        case "v":
            guard cellColumn != nil else { return }
            value = ""
            isCapturingValue = true
        case "is":
            inlineText = ""
        case "t":
            isCapturingInline = inlineText != nil
        default:
            return
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCapturingValue {
            value? += string
        }
        if isCapturingInline {
            inlineText? += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch localName(elementName) {
        case "v":
            isCapturingValue = false
        case "t":
            isCapturingInline = false
        case "c":
            finishCell(parser)
        case "row":
            finishRow(parser)
        default:
            return
        }
    }

    private func finishCell(_ parser: XMLParser) {
        defer {
            cellColumn = nil
            value = nil
            inlineText = nil
        }
        guard let column = cellColumn else { return }

        cellsSeen += 1
        guard cellsSeen <= XLSXWorkbookReader.maximumCellsPerSheet else {
            fail(XLSXWorkbookError.cellBudgetExceeded)
            parser.abortParsing()
            return
        }

        let decoded = decodeValue()
        guard !decoded.isEmpty else { return }
        rowCells[column] = decoded
    }

    private func decodeValue() -> XLSXCellValue {
        switch cellType {
        case "s":
            guard let index = value.flatMap(Int.init), let resolved = workbook.sharedString(at: index) else {
                return .empty
            }
            return resolved.isEmpty ? .empty : .text(resolved)
        case "inlineStr":
            guard let text = inlineText, !text.isEmpty else { return .empty }
            return .text(text)
        case "str":
            guard let text = value, !text.isEmpty else { return .empty }
            return .text(text)
        case "b":
            guard let raw = value else { return .empty }
            return .boolean(raw == "1" || raw.lowercased() == "true")
        case "e":
            guard let raw = value, !raw.isEmpty else { return .empty }
            return .error(raw)
        case "d":
            guard let raw = value, !raw.isEmpty else { return .empty }
            return .text(raw)
        default:
            guard let raw = value, !raw.isEmpty else { return .empty }
            guard workbook.isDateFormatted(styleIndex: cellStyleIndex),
                  let serial = Double(raw),
                  let dateTime = XLSXDateConverter.dateTime(serial: serial, usesDate1904: workbook.usesDate1904)
            else {
                return .number(raw)
            }
            return .dateTime(dateTime)
        }
    }

    private func finishRow(_ parser: XMLParser) {
        defer {
            rowIndex += 1
            rowCells = [:]
        }
        let width = (rowCells.keys.max() ?? -1) + 1
        var cells = [XLSXCellValue](repeating: .empty, count: max(0, width))
        for (column, cell) in rowCells where column < width {
            cells[column] = cell
        }
        batch.append(XLSXRow(index: rowIndex, cells: cells))

        guard batch.count >= batchSize else { return }
        let pending = batch
        batch = []
        do {
            try onBatch(pending)
        } catch {
            fail(error)
            parser.abortParsing()
        }
    }
}

private func localName(_ elementName: String) -> String {
    guard let separator = elementName.lastIndex(of: ":") else { return elementName }
    return String(elementName[elementName.index(after: separator)...])
}
