//
//  RowContext.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct RowContext: Sendable {
    let table: String
    let rowIndex: Int
    private var values: [String: PluginCellValue]

    init(table: String, rowIndex: Int, values: [String: PluginCellValue] = [:]) {
        self.table = table
        self.rowIndex = rowIndex
        self.values = values
    }

    subscript(column: String) -> PluginCellValue? {
        values[column]
    }

    mutating func set(_ value: PluginCellValue, for column: String) {
        values[column] = value
    }

    mutating func clearValues() {
        values.removeAll(keepingCapacity: true)
    }
}
