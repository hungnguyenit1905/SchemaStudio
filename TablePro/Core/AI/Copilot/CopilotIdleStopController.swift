//
//  CopilotIdleStopController.swift
//  TablePro
//
//  Schedules a deferred stop when an external condition (typically:
//  Copilot LSP server is running but the user hasn't signed in) holds
//  past a timeout. Pulled out of CopilotService so the timer logic
//  can be unit-tested without launching the real LSP process.
//

import Foundation

@MainActor
final class CopilotIdleStopController {
    private let timeout: Duration
    private let isAuthenticated: () -> Bool
    private let isRunning: () -> Bool
    private let onStopRequest: () async -> Void
    private let waitForTimeout: @Sendable (Duration) async throws -> Void
    private(set) var scheduledStop: Task<Void, Never>?

    init(
        timeout: Duration,
        isAuthenticated: @escaping () -> Bool,
        isRunning: @escaping () -> Bool,
        onStopRequest: @escaping () async -> Void,
        waitForTimeout: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.timeout = timeout
        self.isAuthenticated = isAuthenticated
        self.isRunning = isRunning
        self.onStopRequest = onStopRequest
        self.waitForTimeout = waitForTimeout
    }

    deinit {
        scheduledStop?.cancel()
    }

    /// Cancel any prior schedule and start a new one. No-op when already authenticated.
    func schedule() {
        scheduledStop?.cancel()
        guard !isAuthenticated() else {
            scheduledStop = nil
            return
        }
        let timeout = self.timeout
        let isAuthenticated = self.isAuthenticated
        let isRunning = self.isRunning
        let onStopRequest = self.onStopRequest
        let waitForTimeout = self.waitForTimeout
        scheduledStop = Task {
            do {
                try await waitForTimeout(timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard !isAuthenticated(), isRunning() else { return }
            await onStopRequest()
        }
    }

    /// Cancel any pending stop without triggering it.
    func cancel() {
        scheduledStop?.cancel()
        scheduledStop = nil
    }
}
