//
//  XLSXWorkbookReader.swift
//  XLSXImportPlugin
//

import Foundation

public struct XLSXSheetRef: Equatable {
    public let name: String
    public let partPath: String
}

public enum XLSXWorkbookError: LocalizedError, Equatable {
    case workbookPartMissing
    case noSheets
    case sheetNotFound(String)
    case cellBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .workbookPartMissing:
            return String(localized: "The file is not an Excel workbook.")
        case .noSheets:
            return String(localized: "The workbook contains no sheets.")
        case .sheetNotFound(let name):
            return String(format: String(localized: "The workbook has no sheet named '%@'."), name)
        case .cellBudgetExceeded:
            return String(localized: "The sheet contains more cells than can be read safely.")
        }
    }
}

public final class XLSXWorkbookReader {
    public static let maximumCellsPerSheet = 20_000_000

    private let archive: ZipArchiveReader
    private let sharedStrings: [String]
    private let dateFormattedStyles: [Bool]

    public let sheets: [XLSXSheetRef]
    public let usesDate1904: Bool

    public init(archive: ZipArchiveReader, onProgress: (() throws -> Void)? = nil) throws {
        self.archive = archive
        guard archive.contains("xl/workbook.xml") else { throw XLSXWorkbookError.workbookPartMissing }

        let workbookData = try archive.data(forEntry: "xl/workbook.xml", onProgress: onProgress)
        let workbook = WorkbookDelegate()
        try XLSXXmlSafety.parse(workbookData, partName: "xl/workbook.xml", delegate: workbook)
        guard !workbook.sheets.isEmpty else { throw XLSXWorkbookError.noSheets }
        self.usesDate1904 = workbook.usesDate1904

        let relationships = try Self.readRelationships(archive: archive, onProgress: onProgress)
        self.sheets = workbook.sheets.compactMap { sheet in
            guard let target = relationships[sheet.relationshipId] else { return nil }
            return XLSXSheetRef(name: sheet.name, partPath: Self.normalizedPartPath(target))
        }
        guard !sheets.isEmpty else { throw XLSXWorkbookError.noSheets }

        self.sharedStrings = try Self.readSharedStrings(archive: archive, onProgress: onProgress)
        self.dateFormattedStyles = try Self.readStyles(archive: archive, onProgress: onProgress)
    }

    public func sharedString(at index: Int) -> String? {
        guard index >= 0, index < sharedStrings.count else { return nil }
        return sharedStrings[index]
    }

    public func isDateFormatted(styleIndex: Int) -> Bool {
        guard styleIndex >= 0, styleIndex < dateFormattedStyles.count else { return false }
        return dateFormattedStyles[styleIndex]
    }

    public func sheet(named name: String?) -> XLSXSheetRef? {
        guard let name, !name.isEmpty else { return sheets.first }
        return sheets.first { $0.name == name }
    }

    public func sheetData(for sheet: XLSXSheetRef, onProgress: (() throws -> Void)? = nil) throws -> Data {
        guard archive.contains(sheet.partPath) else { throw XLSXWorkbookError.sheetNotFound(sheet.name) }
        return try archive.data(forEntry: sheet.partPath, onProgress: onProgress)
    }

    // MARK: - Parts

    private static func normalizedPartPath(_ target: String) -> String {
        var path = target
        if path.hasPrefix("/") { path.removeFirst() }
        if path.hasPrefix("xl/") { return path }
        return "xl/" + path
    }

    private static func readRelationships(
        archive: ZipArchiveReader,
        onProgress: (() throws -> Void)?
    ) throws -> [String: String] {
        let path = "xl/_rels/workbook.xml.rels"
        guard archive.contains(path) else { return [:] }
        let data = try archive.data(forEntry: path, onProgress: onProgress)
        let delegate = RelationshipDelegate()
        try XLSXXmlSafety.parse(data, partName: path, delegate: delegate)
        return delegate.targets
    }

    private static func readSharedStrings(
        archive: ZipArchiveReader,
        onProgress: (() throws -> Void)?
    ) throws -> [String] {
        let path = "xl/sharedStrings.xml"
        guard archive.contains(path) else { return [] }
        let data = try archive.data(forEntry: path, onProgress: onProgress)
        let delegate = SharedStringsDelegate(onProgress: onProgress)
        try XLSXXmlSafety.parse(data, partName: path, delegate: delegate)
        return delegate.strings
    }

    private static func readStyles(
        archive: ZipArchiveReader,
        onProgress: (() throws -> Void)?
    ) throws -> [Bool] {
        let path = "xl/styles.xml"
        guard archive.contains(path) else { return [] }
        let data = try archive.data(forEntry: path, onProgress: onProgress)
        let delegate = StylesDelegate()
        try XLSXXmlSafety.parse(data, partName: path, delegate: delegate)
        return delegate.cellFormatIds.map { formatId in
            XLSXDateConverter.isDateFormat(
                numberFormatId: formatId,
                formatCode: delegate.customFormats[formatId]
            )
        }
    }
}

// MARK: - Delegates

private final class WorkbookDelegate: XLSXXmlDelegate {
    struct SheetEntry {
        let name: String
        let relationshipId: String
    }

    private(set) var sheets: [SheetEntry] = []
    private(set) var usesDate1904 = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let name = elementName.hasSuffix(":sheet") ? "sheet" : elementName
        switch name {
        case "sheet":
            let sheetName = attributes["name"] ?? ""
            let relationshipId = attributes["r:id"] ?? attributes["id"] ?? ""
            guard !sheetName.isEmpty, !relationshipId.isEmpty else { return }
            sheets.append(SheetEntry(name: sheetName, relationshipId: relationshipId))
        case "workbookPr":
            let flag = attributes["date1904"] ?? attributes["date1904Compatibility"] ?? "0"
            usesDate1904 = flag == "1" || flag.lowercased() == "true"
        default:
            return
        }
    }
}

private final class RelationshipDelegate: XLSXXmlDelegate {
    private(set) var targets: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        guard elementName == "Relationship" || elementName.hasSuffix(":Relationship") else { return }
        guard let id = attributes["Id"], let target = attributes["Target"] else { return }
        targets[id] = target
    }
}

private final class SharedStringsDelegate: XLSXXmlDelegate {
    private(set) var strings: [String] = []

    private let onProgress: (() throws -> Void)?
    private var current: String?
    private var isCapturing = false

    init(onProgress: (() throws -> Void)?) {
        self.onProgress = onProgress
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch localName(elementName) {
        case "si":
            current = ""
            do {
                try onProgress?()
            } catch {
                fail(error)
                parser.abortParsing()
            }
        case "t":
            isCapturing = current != nil
        default:
            return
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isCapturing else { return }
        current? += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch localName(elementName) {
        case "t":
            isCapturing = false
        case "si":
            strings.append(current ?? "")
            current = nil
        default:
            return
        }
    }
}

private final class StylesDelegate: XLSXXmlDelegate {
    private(set) var cellFormatIds: [Int] = []
    private(set) var customFormats: [Int: String] = [:]

    private var inCellFormats = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch localName(elementName) {
        case "numFmt":
            guard let id = attributes["numFmtId"].flatMap(Int.init) else { return }
            customFormats[id] = attributes["formatCode"]
        case "cellXfs":
            inCellFormats = true
        case "xf":
            guard inCellFormats else { return }
            cellFormatIds.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)
        default:
            return
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard localName(elementName) == "cellXfs" else { return }
        inCellFormats = false
    }
}

private func localName(_ elementName: String) -> String {
    guard let separator = elementName.lastIndex(of: ":") else { return elementName }
    return String(elementName[elementName.index(after: separator)...])
}
