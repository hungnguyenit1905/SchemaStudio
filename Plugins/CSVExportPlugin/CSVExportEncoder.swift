//
//  CSVExportEncoder.swift
//  CSVExportPlugin
//
//  Bundle-free so the main test bundle can compile it directly.
//

import Foundation

public enum CSVExportEncoding: String, CaseIterable, Identifiable, Codable {
    case utf8 = "UTF-8"
    case utf8WithBOM = "UTF-8 with BOM"

    public var id: String { rawValue }

    public var displayName: String { rawValue }

    public var byteOrderMark: Data? {
        switch self {
        case .utf8: return nil
        case .utf8WithBOM: return Data([0xEF, 0xBB, 0xBF])
        }
    }

    public func encode(_ string: String) -> Data {
        Data(string.utf8)
    }
}

public struct CSVExportEncoder {
    private let encoding: CSVExportEncoding
    private var hasEmittedPreamble = false

    public init(encoding: CSVExportEncoding) {
        self.encoding = encoding
    }

    /// Returns the byte order mark on the first call and nothing on every call after it, so a
    /// multi-table document carries at most one preamble no matter how many writers ask for it.
    public mutating func preamble() -> Data {
        guard !hasEmittedPreamble else { return Data() }
        hasEmittedPreamble = true
        return encoding.byteOrderMark ?? Data()
    }

    public func encode(_ string: String) -> Data {
        encoding.encode(string)
    }
}
