//
//  PostgreSQLPluginDriver+BulkLoad.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    func bulkLoadWriter(
        table: String,
        schema: String?,
        columns: [String]
    ) async throws -> PluginBulkLoadWriter? {
        let resolvedSchema = schema ?? core.currentSchema
        let qualifiedTable = "\(quoteIdentifier(resolvedSchema)).\(quoteIdentifier(table))"
        let columnList = columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let statement = "COPY \(qualifiedTable) (\(columnList)) FROM STDIN"
        return try await PostgresBulkLoadWriter(core: core, statement: statement)
    }

    func serverLimits() async throws -> PluginServerLimits? {
        PluginServerLimits(maxPacketBytes: nil, maxBindParameters: 65_535, supportsLocalInfile: nil)
    }

    func constraintDisableCapability() async -> PluginConstraintDisableCapability {
        do {
            try await execute(query: "BEGIN")
        } catch {
            return .unknown
        }
        do {
            _ = try await execute(query: "SET LOCAL session_replication_role = replica")
            _ = try await execute(query: "ROLLBACK")
            return .supported
        } catch {
            _ = try? await execute(query: "ROLLBACK")
            return .notPermitted
        }
    }
}
