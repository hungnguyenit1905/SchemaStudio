//
//  LegacyCellBulkLoadWriter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Holds a driver that has not declared ``PluginCapabilities/typedCellValues``
/// to the pre-v20 case set on the bulk path.
///
/// The streaming writer takes cells straight from the generator, so without
/// this the gate applied to the prepared-statement path would not cover a bulk
/// table.
struct LegacyCellBulkLoadWriter: PluginBulkLoadWriter {
    private let wrapped: any PluginBulkLoadWriter

    init(wrapping wrapped: any PluginBulkLoadWriter) {
        self.wrapped = wrapped
    }

    func write(row: [PluginCellValue]) async throws {
        try await wrapped.write(row: row.downgradedToLegacyCases)
    }

    func write(rows: [[PluginCellValue]]) async throws {
        try await wrapped.write(rows: rows.downgradedToLegacyCases)
    }

    func finish() async throws -> Int {
        try await wrapped.finish()
    }

    func abort() async {
        await wrapped.abort()
    }
}
