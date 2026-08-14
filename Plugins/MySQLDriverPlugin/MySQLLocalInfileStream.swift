//
//  MySQLLocalInfileStream.swift
//  MySQLDriverPlugin
//

import Foundation

/// The bridge between the writer, which appends rows from Swift concurrency,
/// and libmariadb's local infile callback, which pulls bytes synchronously from
/// the thread blocked inside `mysql_real_query`. The callback blocks on the
/// condition until there is something to hand over, and the producer blocks
/// once the buffer is full, so a slow server throttles the reader instead of
/// letting the whole table pile up in memory.
///
/// Nothing here ever opens a file. The server names one in the protocol and the
/// name is ignored: the only bytes the client sends are the ones the transfer
/// put in this buffer.
final class MySQLLocalInfileStream: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var isFinished = false
    private var failure: String?

    private let highWaterMark: Int

    init(highWaterMark: Int = 4 * 1_048_576) {
        self.highWaterMark = highWaterMark
    }

    /// Blocks the producer while the buffer is over its mark, which is the
    /// backpressure that keeps memory flat on a table larger than memory.
    func append(_ data: Data) throws {
        condition.lock()
        defer { condition.unlock() }
        while buffer.count >= highWaterMark, failure == nil, !isFinished {
            condition.wait()
        }
        if let failure { throw MariaDBPluginError(code: 0, message: failure, sqlState: nil) }
        guard !isFinished else { return }
        buffer.append(data)
        condition.signal()
    }

    func finish() {
        condition.lock()
        isFinished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Aborting leaves the reason in place: the callback reports it to the
    /// server through the error hook, which makes the server abort the load
    /// rather than commit a truncated table.
    func abort(reason: String) {
        condition.lock()
        failure = reason
        isFinished = true
        condition.broadcast()
        condition.unlock()
    }

    var abortReason: String? {
        condition.lock()
        defer { condition.unlock() }
        return failure
    }

    /// Called from the C callback. Returns 0 at the end of the stream and -1
    /// when the transfer aborted.
    func read(into destination: UnsafeMutablePointer<CChar>, capacity: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        while buffer.isEmpty, !isFinished, failure == nil {
            condition.wait()
        }
        if failure != nil { return -1 }
        guard !buffer.isEmpty else { return 0 }

        let count = min(capacity, buffer.count)
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            destination.withMemoryRebound(to: UInt8.self, capacity: count) { target in
                target.update(from: base.assumingMemoryBound(to: UInt8.self), count: count)
            }
        }
        buffer.removeFirst(count)
        condition.signal()
        return count
    }
}
