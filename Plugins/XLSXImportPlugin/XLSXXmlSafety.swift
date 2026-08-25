//
//  XLSXXmlSafety.swift
//  XLSXImportPlugin
//
//  The decompressed parts are attacker-controlled XML. Every part passes through here so no
//  call site can forget to reject a DTD or to switch external entity resolution off.
//

import Foundation

public enum XLSXXmlError: LocalizedError, Equatable {
    case documentTypeDeclarationRejected
    case entityDeclarationRejected
    case malformedXml(String)

    public var errorDescription: String? {
        switch self {
        case .documentTypeDeclarationRejected:
            return String(localized: "The workbook contains a document type declaration and was not read.")
        case .entityDeclarationRejected:
            return String(localized: "The workbook contains XML entity declarations and was not read.")
        case .malformedXml(let part):
            return String(format: String(localized: "A part of the workbook is not valid XML: %@"), part)
        }
    }
}

public enum XLSXXmlSafety {
    public static func rejectDocumentTypeDeclaration(in data: Data) throws {
        let scanLimit = min(data.count, 4_096)
        let head = data.prefix(scanLimit)
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            return
        }
        guard !text.uppercased().contains("<!DOCTYPE") else {
            throw XLSXXmlError.documentTypeDeclarationRejected
        }
        guard !text.uppercased().contains("<!ENTITY") else {
            throw XLSXXmlError.entityDeclarationRejected
        }
    }

    public static func makeParser(for data: Data) throws -> XMLParser {
        try rejectDocumentTypeDeclaration(in: data)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        return parser
    }

    public static func parse(_ data: Data, partName: String, delegate: XLSXXmlDelegate) throws {
        let parser = try makeParser(for: data)
        parser.delegate = delegate
        guard parser.parse() else {
            if let failure = delegate.failure { throw failure }
            throw XLSXXmlError.malformedXml(partName)
        }
        if let failure = delegate.failure { throw failure }
    }
}

/// Base delegate that turns any entity declaration into a hard failure. `XMLParser` never
/// resolves external entities once `shouldResolveExternalEntities` is off, and an internal
/// declaration is refused here so a nested-entity expansion never runs.
public class XLSXXmlDelegate: NSObject, XMLParserDelegate {
    public private(set) var failure: Error?

    public func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
    }

    public func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        fail(XLSXXmlError.entityDeclarationRejected)
        parser.abortParsing()
    }

    public func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        fail(XLSXXmlError.entityDeclarationRejected)
        parser.abortParsing()
    }

    public func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        fail(XLSXXmlError.entityDeclarationRejected)
        parser.abortParsing()
        return nil
    }
}
