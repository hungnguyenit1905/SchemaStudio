//
//  XLSXCellReference.swift
//  XLSXImportPlugin
//
//  Excel omits empty cells, so a cell's position comes from its reference rather than from its
//  order in the row. The caps here are what keep a pre-sized row from becoming an
//  attacker-controlled allocation.
//

import Foundation

public struct XLSXCellReference: Equatable {
    public static let maximumColumnIndex = 16_383
    public static let maximumRowIndex = 1_048_575

    public let columnIndex: Int
    public let rowIndex: Int?

    public init?(_ reference: String) {
        var column = 0
        var digits = 0
        var rowDigits = ""
        var readingRow = false

        for character in reference.unicodeScalars {
            if !readingRow, character >= "A", character <= "Z" {
                column = column * 26 + Int(character.value - 64)
                digits += 1
                guard digits <= 3 else { return nil }
                continue
            }
            if character >= "0", character <= "9" {
                readingRow = true
                rowDigits.unicodeScalars.append(character)
                guard rowDigits.count <= 7 else { return nil }
                continue
            }
            return nil
        }

        guard digits > 0 else { return nil }
        let zeroBasedColumn = column - 1
        guard zeroBasedColumn >= 0, zeroBasedColumn <= Self.maximumColumnIndex else { return nil }
        self.columnIndex = zeroBasedColumn

        guard !rowDigits.isEmpty else {
            self.rowIndex = nil
            return
        }
        guard let row = Int(rowDigits), row >= 1 else { return nil }
        let zeroBasedRow = row - 1
        guard zeroBasedRow <= Self.maximumRowIndex else { return nil }
        self.rowIndex = zeroBasedRow
    }

    public static func columnIndex(for reference: String) -> Int? {
        XLSXCellReference(reference)?.columnIndex
    }
}
