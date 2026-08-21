//
//  MySQLTemporalLiteral.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// MySQL-specific rendering for `PluginCellValue.timestamp`.
///
/// `textFallback` renders a timestamp as ISO-8601 (`2025-08-12T12:00:00Z`),
/// which PostgreSQL and SQLite accept but MySQL rejects outright with error
/// 1292 "Incorrect datetime value": it accepts neither the `T` separator nor a
/// trailing zone designator in a `DATETIME` or `TIMESTAMP` literal.
///
/// DATETIME carries no timezone, so the instant is rendered as its UTC wall
/// clock. That matches the boundary contract, where `.timestamp` is UTC by
/// definition, and matches what a `timestamp without time zone` column stores
/// on PostgreSQL for the same value.
internal enum MySQLTemporalLiteral {
    static func string(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return "" }
        calendar.timeZone = utc

        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date
        )
        let base = String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )

        let microseconds = ((parts.nanosecond ?? 0) + 500) / 1_000
        guard microseconds > 0 else { return base }
        return base + String(format: ".%06d", microseconds)
    }

    /// The literal MySQL should receive for a cell, which is `textFallback` for
    /// every case except `.timestamp`.
    static func literal(for value: PluginCellValue) -> String {
        if case .timestamp(let date) = value {
            return string(from: date)
        }
        return value.textFallback
    }
}
