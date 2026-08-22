//
//  DuplicateDrivingStub.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit

/// Records which wire protocol each statement took, so a test can prove that anything carrying the
/// user's row filter went through the extended path rather than the one that accepts several
/// statements in a single string.
final class DuplicateDrivingStub: DuplicateDriving, @unchecked Sendable {
    enum Call: Sendable, Hashable {
        case simple(String)
        case extended(String)
        case begin
        case commit
        case rollback
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var supportsTransactionalDDL: Bool
    /// Rows returned for a SQL string, matched by substring so a test only has to name the part it
    /// cares about.
    var rowsForQueryContaining: [String: [[String?]]] = [:]
    var columns: [PluginColumnInfo] = []
    /// Columns returned by the second read, the one that happens after authorization. Nil means
    /// the structure did not change.
    var columnsAfterAuthorization: [PluginColumnInfo]?
    var indexes: [PluginIndexInfo] = []
    var foreignKeys: [PluginForeignKeyInfo] = []
    var approximateRowCount: Int?
    private var columnReadCount = 0
    /// Errors thrown for a SQL string, matched the same way.
    var errorForQueryContaining: [String: any Error] = [:]

    init(supportsTransactionalDDL: Bool = true) {
        self.supportsTransactionalDDL = supportsTransactionalDDL
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    var executedSQL: [String] {
        calls.compactMap { call in
            switch call {
            case .simple(let sql), .extended(let sql): return sql
            case .begin, .commit, .rollback: return nil
            }
        }
    }

    func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func escapeStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    func runSimple(_ sql: String) async throws -> [[String?]] {
        lock.withLock { recorded.append(.simple(sql)) }
        return try result(for: sql)
    }

    func runExtended(_ sql: String) async throws -> [[String?]] {
        lock.withLock { recorded.append(.extended(sql)) }
        return try result(for: sql)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        lock.lock()
        columnReadCount += 1
        let isSecondRead = columnReadCount > 1
        lock.unlock()
        if isSecondRead, let changed = columnsAfterAuthorization { return changed }
        return columns
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { indexes }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        foreignKeys
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        approximateRowCount
    }

    func begin() async throws { lock.withLock { recorded.append(.begin) } }

    func commit() async throws { lock.withLock { recorded.append(.commit) } }

    func rollback() async throws { lock.withLock { recorded.append(.rollback) } }

    private func result(for sql: String) throws -> [[String?]] {
        if let match = errorForQueryContaining.first(where: { sql.contains($0.key) }) {
            throw match.value
        }
        if let match = rowsForQueryContaining.first(where: { sql.contains($0.key) }) {
            return match.value
        }
        return []
    }
}

struct DuplicateStubError: LocalizedError, Hashable {
    let message: String

    var errorDescription: String? { message }
}


/// Hands the same stub driver to every step, and reports whichever routing answer the test wants.
struct DuplicateSessionStub: DuplicateSessionProviding {
    let driver: DuplicateDrivingStub
    var runsOnSharedConnection = false

    func withDriver<T: Sendable>(
        tracksCancellation: Bool,
        _ body: @Sendable @escaping (any DuplicateDriving) async throws -> T
    ) async throws -> T {
        try await body(driver)
    }
}
