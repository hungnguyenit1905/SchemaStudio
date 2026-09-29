//
//  SessionDriverGate.swift
//  TablePro
//

import Foundation

/// Serialises access to a connection's single shared driver.
///
/// The driver carries one mutable position (its current database and schema), so an
/// operation has to move it before it runs. Without ordering, two windows interleave
/// their moves and each runs against the other's database.
///
/// The body runs inline in the caller's own task rather than in a detached one, so
/// cancellation still reaches the work.
@MainActor
final class SessionDriverGate<Key: Hashable> {
    private struct Waiter {
        let ticket: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var holders: Set<Key> = []
    private var waiters: [Key: [Waiter]] = [:]

    func withExclusiveAccess<T>(
        _ connectionId: Key,
        _ body: () async throws -> T
    ) async throws -> T {
        try await acquire(connectionId)
        defer { release(connectionId) }
        return try await body()
    }

    /// Fails everyone still queued for a connection that is going away. A body already running
    /// keeps the gate until it returns, so nobody can start alongside it on the same driver.
    func drain(connectionId: Key) {
        let pending = waiters.removeValue(forKey: connectionId) ?? []
        for waiter in pending {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    func withExclusiveAccessIfIdle<T>(
        _ connectionId: Key,
        _ body: () async throws -> T
    ) async rethrows -> T? {
        guard !holders.contains(connectionId) else { return nil }
        holders.insert(connectionId)
        defer { release(connectionId) }
        return try await body()
    }

    private func acquire(_ connectionId: Key) async throws {
        guard holders.contains(connectionId) else {
            holders.insert(connectionId)
            return
        }
        let ticket = UUID()
        try await withTaskCancellationHandler(
            operation: { try await enqueue(ticket: ticket, connectionId: connectionId) },
            onCancel: { [weak self] in
                Task { @MainActor in
                    self?.failWaiter(ticket: ticket, connectionId: connectionId)
                }
            }
        )
    }

    private func enqueue(ticket: UUID, connectionId: Key) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            waiters[connectionId, default: []].append(
                Waiter(ticket: ticket, continuation: continuation)
            )
        }
    }

    /// Removes the ticket before resuming it, so a cancellation racing a hand-off
    /// can only ever find one of them.
    private func failWaiter(ticket: UUID, connectionId: Key) {
        guard var pending = waiters[connectionId],
              let index = pending.firstIndex(where: { $0.ticket == ticket }) else {
            return
        }
        let waiter = pending.remove(at: index)
        waiters[connectionId] = pending.isEmpty ? nil : pending
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ connectionId: Key) {
        guard var pending = waiters[connectionId], !pending.isEmpty else {
            holders.remove(connectionId)
            waiters.removeValue(forKey: connectionId)
            return
        }
        let next = pending.removeFirst()
        waiters[connectionId] = pending.isEmpty ? nil : pending
        next.continuation.resume()
    }
}
