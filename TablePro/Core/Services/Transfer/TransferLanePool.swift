//
//  TransferLanePool.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Hands out the lane numbers the data phase opens its extra driver pairs on.
/// A lane is exclusive for as long as its holder runs, so two table copies, or
/// a table copy and a partition, can never be handed the same pooled
/// connection and interleave their transactions on it. Lane 0 is never handed
/// out: it belongs to the pair the run itself holds.
@MainActor
final class TransferLaneAllocator {
    let capacity: Int

    private var free: [Int]
    private var waiters: [CheckedContinuation<Int, Never>] = []

    nonisolated init(capacity: Int) {
        self.capacity = max(1, capacity)
        free = Array((1 ... self.capacity).reversed())
    }

    func acquire() async -> Int {
        if let lane = free.popLast() { return lane }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release(_ lane: Int) {
        guard !waiters.isEmpty else {
            free.append(lane)
            return
        }
        waiters.removeFirst().resume(returning: lane)
    }
}

/// The driver pairs the data phase copies tables and partitions with. The pair
/// is handed to a body rather than returned, because everything that makes it
/// safe to use ends when the pool's `withDriver` body ends: the lease that
/// stops the connection being closed or evicted, the per-connection
/// serialization, and the lifted query timeout. Returning the pair out of
/// those bodies would leave a copy running on a connection the pool considers
/// idle.
@MainActor
final class TransferLanePool {
    private let source: TransferEndpoint
    private let target: TransferEndpoint
    private let restoreTimeout: Int
    private let allocator: TransferLaneAllocator

    var laneCount: Int { allocator.capacity }

    nonisolated init(source: TransferEndpoint, target: TransferEndpoint, laneCount: Int, restoreTimeout: Int) {
        self.source = source
        self.target = target
        self.restoreTimeout = restoreTimeout
        allocator = TransferLaneAllocator(capacity: laneCount)
    }

    func withLane<T: Sendable>(
        _ body: @escaping @Sendable @MainActor (
            TransferDriverContext,
            TransferDriverContext
        ) async throws -> T
    ) async throws -> T {
        let lane = await allocator.acquire()
        defer { allocator.release(lane) }

        let pool = MetadataConnectionPool.shared
        let source = source
        let target = target
        let restoreTimeout = restoreTimeout

        return try await pool.withDriver(scope: target.scope, workload: .bulk, lane: lane) { targetDriver in
            try await pool.withDriver(scope: source.scope, workload: .bulk, lane: lane) { sourceDriver in
                guard let laneSource = TransferDriverContext(driver: sourceDriver, endpoint: source),
                      let laneTarget = TransferDriverContext(driver: targetDriver, endpoint: target) else {
                    throw TransferError.noPluginDriver
                }
                await laneSource.applyQueryTimeout(0)
                await laneTarget.applyQueryTimeout(0)
                do {
                    let result = try await body(laneSource, laneTarget)
                    await Self.restoreTimeout(restoreTimeout, source: laneSource, target: laneTarget)
                    return result
                } catch {
                    await Self.restoreTimeout(restoreTimeout, source: laneSource, target: laneTarget)
                    throw error
                }
            }
        }
    }

    /// A lane driver outlives the run inside the pool, so the user's own query
    /// timeout has to go back on before the lane is released.
    private static func restoreTimeout(
        _ seconds: Int,
        source: TransferDriverContext,
        target: TransferDriverContext
    ) async {
        await source.applyQueryTimeout(seconds)
        await target.applyQueryTimeout(seconds)
    }
}
