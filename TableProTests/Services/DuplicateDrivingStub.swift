//
//  DuplicateDrivingStub.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio

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
