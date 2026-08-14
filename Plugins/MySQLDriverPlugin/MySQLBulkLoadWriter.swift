//
//  MySQLBulkLoadWriter.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// Streams rows into MySQL through `LOAD DATA LOCAL INFILE`. The statement runs
/// for the whole table on its own task while `write(row:)` feeds the stream it
/// reads from, so nothing buffers the table and the server pulls at its own
/// pace.
final class MySQLBulkLoadWriter: PluginBulkLoadWriter, @unchecked Sendable {
    private let stream: MySQLLocalInfileStream
    private let hexColumns: [Bool]
    private let load: Task<UInt64, Error>

    private let lock = NSLock()
    private var rowCount = 0
    private var finished = false

    private static let flushThresholdBytes = 1_048_576

    private var buffer = Data()

    init(
        connection: MariaDBPluginConnection,
        statement: String,
        hexColumns: [Bool]
    ) {
        let stream = MySQLLocalInfileStream()
        self.stream = stream
        self.hexColumns = hexColumns
        load = Task {
            try await connection.loadDataLocalInfile(statement: statement, stream: stream)
        }
    }

    func write(row: [PluginCellValue]) async throws {
        let chunk: Data? = lock.withLock {
            guard !finished else { return nil }
            buffer.append(MySQLLocalInfileEncoder.line(for: row, hexColumns: hexColumns))
            rowCount += 1
            guard buffer.count >= Self.flushThresholdBytes else { return nil }
            let pending = buffer
            buffer.removeAll(keepingCapacity: true)
            return pending
        }
        guard let chunk else { return }
        try stream.append(chunk)
    }

    /// The server's own count is what the table actually took, so it wins over
    /// the rows this writer handed over.
    func finish() async throws -> Int {
        let tail: Data? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let pending = buffer
            buffer.removeAll(keepingCapacity: true)
            return pending
        }
        if let tail, !tail.isEmpty {
            try stream.append(tail)
        }
        stream.finish()
        let affected = try await load.value
        return affected > 0 ? Int(affected) : lock.withLock { rowCount }
    }

    /// Aborting has to reach the server, not just stop the producer: the load is
    /// mid-statement, and only the error hook makes it roll back instead of
    /// committing what it already read.
    func abort() async {
        lock.withLock {
            finished = true
            buffer.removeAll(keepingCapacity: true)
        }
        stream.abort(reason: "Transfer aborted before the table finished loading")
        _ = try? await load.value
    }
}
