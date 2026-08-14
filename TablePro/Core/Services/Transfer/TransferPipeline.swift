//
//  TransferPipeline.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One table's column list as read from the source, delivered before the
/// first chunk so the writer can prepare its sink and its transaction.
struct TransferPipelineHeader: Sendable {
    let columns: [String]
}

/// A bounded batch of converted rows read from one source chunk, ready for
/// the writer. `isLast` marks the chunk that returned fewer rows than the
/// chunk size, which is how the reader knows the table is complete.
struct TransferPipelineChunk: Sendable {
    let rows: [[PluginCellValue]]
    let headerColumns: [String]
    let cursor: TransferChunkCursor?
    let isLast: Bool
    let index: Int
    let partition: Int
}

enum TransferPipelineEvent: Sendable {
    case header(TransferPipelineHeader)
    case chunk(TransferPipelineChunk)
}

/// A counting gate that bounds how many chunks may be in flight between the
/// reader and the writer. The reader waits in `acquire` while the writer is
/// behind, so a slow writer throttles the reader instead of letting it pile
/// rows into memory. `releaseAll` wakes every waiter and closes the gate, which
/// the stream's termination handler uses to unblock a cancelled reader.
actor TransferBackpressureGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var closed = false

    init(capacity: Int) {
        available = max(1, capacity)
    }

    /// False when the gate closed while the caller waited, which means the
    /// consumer went away and the caller should stop producing.
    func acquire() async -> Bool {
        if closed { return false }
        if available > 0 {
            available -= 1
            return true
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands one slot to a waiting producer, or returns it to the pool when
    /// nobody is waiting.
    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: true)
        } else {
            available += 1
        }
    }

    func releaseAll() {
        guard !closed else { return }
        closed = true
        available = 0
        for waiter in waiters {
            waiter.resume(returning: false)
        }
        waiters.removeAll()
    }
}
