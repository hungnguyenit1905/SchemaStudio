//
//  GenerationProgressThrottle.swift
//  TablePro
//

import Foundation

/// Decides which row counters reach the consumer. A million-row table produces a
/// million counter moves and a SwiftUI consumer cannot survive them, so a
/// progress event is emitted at most once per interval or once per fraction of
/// the table, whichever comes first. Terminal events never come through here.
struct GenerationProgressThrottle: Sendable {
    static let defaultInterval: TimeInterval = 0.2
    static let defaultFraction = 0.05

    let interval: TimeInterval
    let fraction: Double

    private var lastEmittedAt: TimeInterval?
    private var lastEmittedRows = 0

    init(interval: TimeInterval = GenerationProgressThrottle.defaultInterval, fraction: Double = GenerationProgressThrottle.defaultFraction) {
        self.interval = interval
        self.fraction = fraction
    }

    mutating func reset() {
        lastEmittedAt = nil
        lastEmittedRows = 0
    }

    mutating func shouldEmit(rowsWritten: Int, totalRows: Int, now: TimeInterval) -> Bool {
        guard rowsWritten > lastEmittedRows else { return false }
        guard let lastEmittedAt else {
            record(rowsWritten: rowsWritten, now: now)
            return true
        }
        if now - lastEmittedAt >= interval {
            record(rowsWritten: rowsWritten, now: now)
            return true
        }
        if totalRows > 0, Double(rowsWritten - lastEmittedRows) >= Double(totalRows) * fraction {
            record(rowsWritten: rowsWritten, now: now)
            return true
        }
        return false
    }

    private mutating func record(rowsWritten: Int, now: TimeInterval) {
        lastEmittedAt = now
        lastEmittedRows = rowsWritten
    }
}
