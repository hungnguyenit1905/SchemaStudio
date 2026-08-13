//
//  TransferRowConverter.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// Applies the column conversions the type mapper decided on, and nothing else.
///
/// Only the columns that actually need work are stored, with their position in
/// the row, so an 80 column table with two converted columns runs two
/// iterations. A same-dialect transfer produces no conversions at all, which is
/// what `isIdentity` reports so the caller can skip the step outright.
struct TransferRowConverter: Sendable {
    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "TransferValueConverter")

    private struct Conversion: Sendable {
        let index: Int
        let column: String
        let conversion: TransferValueConversion
    }

    private struct KeyColumn: Sendable {
        let index: Int
        let column: String
    }

    private let table: String
    private let conversions: [Conversion]
    private let keyColumns: [KeyColumn]

    var isIdentity: Bool { conversions.isEmpty }

    static let identity = TransferRowConverter(table: "", columns: [], conversions: [:], primaryKeyColumns: [])

    init(
        table: String,
        columns: [String],
        conversions: [String: TransferValueConversion],
        primaryKeyColumns: [String]
    ) {
        self.table = table

        var positions: [String: Int] = [:]
        for (index, column) in columns.enumerated() where positions[column] == nil {
            positions[column] = index
        }

        self.conversions = columns.enumerated().compactMap { index, column in
            guard let conversion = conversions[column] else { return nil }
            return Conversion(index: index, column: column, conversion: conversion)
        }

        keyColumns = primaryKeyColumns.compactMap { column in
            guard let index = positions[column] else { return nil }
            return KeyColumn(index: index, column: column)
        }
    }

    func convert(_ row: PluginRow) throws -> PluginRow {
        var converted = row
        for entry in conversions where entry.index < row.count {
            do {
                let outcome = try TransferValueConverter.convert(row[entry.index], using: entry.conversion)
                converted[entry.index] = outcome.value
                guard outcome.lostPrecision else { continue }
                Self.logger.warning(
                    """
                    Rounded a value in \(table, privacy: .public).\(entry.column, privacy: .public) \
                    to fit the target column
                    """
                )
            } catch let fault as TransferValueFault {
                throw TransferValueError(
                    fault: fault,
                    table: table,
                    column: entry.column,
                    primaryKey: primaryKeyDescription(row)
                )
            }
        }
        return converted
    }

    /// Names the failing row so the user can go find it, which is why the key
    /// value is spelled out here and nowhere else. A table with no primary key
    /// cannot be pointed at, and says so rather than quoting other columns.
    private func primaryKeyDescription(_ row: PluginRow) -> String {
        guard !keyColumns.isEmpty else { return String(localized: "no primary key") }
        let parts = keyColumns.compactMap { key -> String? in
            guard key.index < row.count else { return nil }
            return "\(key.column)=\(Self.describe(row[key.index]))"
        }
        return parts.isEmpty ? String(localized: "no primary key") : parts.joined(separator: ", ")
    }

    private static func describe(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let text):
            return (text as NSString).length > 64 ? String(text.prefix(64)) + "\u{2026}" : text
        case .bytes(let data):
            return String(format: String(localized: "%d bytes"), data.count)
        }
    }
}
