//
//  XLSXImportOptions.swift
//  XLSXImportPlugin
//
//  Bundle-free so the main test bundle can compile it directly.
//

import Foundation
import TableProPluginKit

struct XLSXImportOptions: Equatable, Codable {
    var hasHeaderRow: Bool = true
    var trimWhitespace: Bool = false
    var emptyAsNull: Bool = true
    var nullString: String = ""
    var errorHandling: ImportErrorHandling = .stopAndRollback
    var wrapInTransaction: Bool = true
    var deleteExistingRows: Bool = false

    var detectionSignature: String {
        [
            hasHeaderRow ? "h1" : "h0",
            trimWhitespace ? "t1" : "t0",
            emptyAsNull ? "n1" : "n0",
            nullString
        ].joined(separator: "|")
    }
}

/// The plugin instance is cached one per format on a singleton and never torn down per run, so a
/// file-scoped choice must not live in persisted settings. This is keyed by source URL and
/// re-resolved against the workbook's real sheet list at import time.
struct XLSXSheetSelection: Equatable {
    private(set) var sourceURL: URL?
    private(set) var sheetNames: [String] = []
    private(set) var selectedSheetName: String?

    var hasChoice: Bool { sheetNames.count > 1 }

    mutating func adopt(url: URL, sheetNames: [String]) {
        if sourceURL != url {
            selectedSheetName = nil
        }
        sourceURL = url
        self.sheetNames = sheetNames
        if let current = selectedSheetName, !sheetNames.contains(current) {
            selectedSheetName = nil
        }
        if selectedSheetName == nil {
            selectedSheetName = sheetNames.first
        }
    }

    mutating func select(_ name: String) {
        guard sheetNames.contains(name) else { return }
        selectedSheetName = name
    }

    /// A name that is no longer in the workbook resolves to the first sheet rather than failing,
    /// and the caller reports that as a warning.
    func resolvedSheetName(in available: [String]) -> String? {
        guard let selectedSheetName, available.contains(selectedSheetName) else { return available.first }
        return selectedSheetName
    }

    func resolutionFellBack(to resolved: String?) -> Bool {
        guard let selectedSheetName, let resolved else { return false }
        return selectedSheetName != resolved
    }

    var signature: String {
        [sourceURL?.path ?? "", selectedSheetName ?? ""].joined(separator: "|")
    }
}
