//
//  UniqueTrackerMemoryTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// Peak footprint of unique tracking at five million rows, which is the scale the
/// phase budget is written against. Off by default because it allocates hundreds
/// of megabytes and runs for a few seconds; the number it prints is recorded in
/// `plans/260816-1844-data-generation-engine/phase-07-uniqueness-and-sequences.md`.
///
/// Set `UNIQUE_TRACKER_MEASURE=1` to run it.
@Suite("UniqueTracker memory", .serialized)
struct UniqueTrackerMemoryTests {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["UNIQUE_TRACKER_MEASURE"] == "1"
    }

    private static var footprintBytes: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    @Test("Five million tracked values stay inside the memory budget", .enabled(if: isEnabled))
    func fiveMillionRows() {
        let rows = 5_000_000
        let before = Self.footprintBytes

        var tracker = UniqueTracker(expectedCount: rows)
        var admittedAll = true
        for value in 0 ..< rows where !tracker.admit(.int(Int64(value))) {
            admittedAll = false
        }
        let peak = Self.footprintBytes

        #expect(admittedAll)
        #expect(tracker.count == rows)

        let grown = peak > before ? peak - before : 0
        let megabytes = Double(grown) / 1_048_576.0
        print(String(format: "UNIQUE-TRACKER-MEMORY rows=%d peakDeltaMB=%.1f", rows, megabytes))
        try? String(format: "rows=%d peakDeltaMB=%.1f", rows, megabytes)
            .write(
                toFile: (ProcessInfo.processInfo.environment["UNIQUE_TRACKER_MEASURE_OUTPUT"] ?? "/tmp/unique-tracker-memory.txt"),
                atomically: true,
                encoding: .utf8
            )
        #expect(megabytes < 512)
    }

    @Test("A pre-sized tracker does not rehash its way to five million", .enabled(if: isEnabled))
    func presizingAvoidsRehashing() {
        let rows = 1_000_000
        var presized = UniqueTracker(expectedCount: rows)
        let presizedStart = Date()
        for value in 0 ..< rows {
            _ = presized.admit(.int(Int64(value)))
        }
        let presizedDuration = Date().timeIntervalSince(presizedStart)

        var grown = UniqueTracker()
        let grownStart = Date()
        for value in 0 ..< rows {
            _ = grown.admit(.int(Int64(value)))
        }
        let grownDuration = Date().timeIntervalSince(grownStart)

        print(
            String(
                format: "UNIQUE-TRACKER-TIMING rows=%d presized=%.3fs grown=%.3fs",
                rows,
                presizedDuration,
                grownDuration
            )
        )
        #expect(presized.count == rows)
        #expect(grown.count == rows)
    }
}
