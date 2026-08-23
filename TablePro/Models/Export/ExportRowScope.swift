//
//  ExportRowScope.swift
//  TablePro
//

import Foundation

enum ExportRowScope: String, Sendable, CaseIterable, Hashable {
    case allRows
    case displayedRows
    case selectedRows
}
