//
//  XLSXRowMapper.swift
//  XLSXImportPlugin
//
//  Bundle-free so the main test bundle can compile it directly.
//

import Foundation
import TableProPluginKit

enum XLSXRowMapper {
    static func columnNames(headerRow: XLSXRow?, columnCount: Int) -> [String] {
        var names = [String]()
        var seen = [String: Int]()
        for index in 0 ..< max(columnCount, 0) {
            let raw = headerRow.flatMap { row -> String? in
                guard index < row.cells.count else { return nil }
                return displayText(row.cells[index])
            }
            var name = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                name = "column_\(index + 1)"
            }
            if let count = seen[name] {
                seen[name] = count + 1
                name = "\(name)_\(count + 1)"
            } else {
                seen[name] = 1
            }
            names.append(name)
        }
        return names
    }

    static func row(
        _ row: XLSXRow,
        columnNames: [String],
        options: XLSXImportOptions
    ) -> [String: PluginCellValue] {
        var mapped = [String: PluginCellValue]()
        mapped.reserveCapacity(columnNames.count)
        for (index, name) in columnNames.enumerated() {
            let cell = index < row.cells.count ? row.cells[index] : .empty
            mapped[name] = cellValue(cell, options: options)
        }
        return mapped
    }

    static func detectFields(rows: [XLSXRow], options: XLSXImportOptions) -> [PluginImportField] {
        guard let firstRow = rows.first else { return [] }
        let width = rows.reduce(0) { max($0, $1.cells.count) }
        let names = columnNames(headerRow: options.hasHeaderRow ? firstRow : nil, columnCount: width)
        let dataRows = options.hasHeaderRow ? Array(rows.dropFirst()) : rows

        return names.enumerated().map { index, name in
            let sample = dataRows.lazy
                .compactMap { row -> XLSXCellValue? in
                    guard index < row.cells.count, !row.cells[index].isEmpty else { return nil }
                    return row.cells[index]
                }
                .first
            return PluginImportField(
                name: name,
                sampleValue: sample.map(sampleText),
                inferredType: inferredType(for: sample)
            )
        }
    }

    static func sampleText(_ cell: XLSXCellValue) -> String {
        displayText(cell) ?? ""
    }

    static func inferredType(for cell: XLSXCellValue?) -> PluginImportFieldType {
        switch cell {
        case .boolean: return .boolean
        case .number(let raw): return Int64(raw) != nil ? .integer : .real
        default: return .text
        }
    }

    static func isBlank(_ row: XLSXRow) -> Bool {
        !row.cells.contains { !$0.isEmpty }
    }

    /// Numeric cells always cross as a lossless string. `decimalText` exists for exactly this:
    /// a 19-digit identifier has no lossless `Double` path, and a plugin cannot see the
    /// destination column's type to decide otherwise.
    static func cellValue(_ cell: XLSXCellValue, options: XLSXImportOptions) -> PluginCellValue {
        switch cell {
        case .empty:
            return options.emptyAsNull ? .null : .text("")
        case .text(let value):
            return textValue(value, options: options)
        case .number(let raw):
            return .decimalText(raw)
        case .boolean(let value):
            return .bool(value)
        case .error(let value):
            return textValue(value, options: options)
        case .dateTime(let value):
            return dateValue(value)
        }
    }

    private static func textValue(_ value: String, options: XLSXImportOptions) -> PluginCellValue {
        let resolved = options.trimWhitespace
            ? value.trimmingCharacters(in: .whitespacesAndNewlines)
            : value
        if !options.nullString.isEmpty, resolved == options.nullString { return .null }
        if resolved.isEmpty, options.emptyAsNull { return .null }
        return .text(resolved)
    }

    /// A workbook's datetime carries no timezone, so one is never invented here. A date without a
    /// time crosses as a calendar date and a datetime crosses as an unambiguous literal the
    /// driver binds.
    private static func dateValue(_ value: XLSXDateTime) -> PluginCellValue {
        guard value.hasTimeOfDay else {
            return .date(year: value.year, month: value.month, day: value.day)
        }
        let text = String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            value.year, value.month, value.day, value.hour, value.minute, value.second
        )
        return .text(text)
    }

    private static func displayText(_ cell: XLSXCellValue) -> String? {
        switch cell {
        case .empty: return nil
        case .text(let value): return value
        case .number(let raw): return raw
        case .boolean(let value): return value ? "true" : "false"
        case .error(let value): return value
        case .dateTime(let value): return String(format: "%04d-%02d-%02d", value.year, value.month, value.day)
        }
    }
}
