//
//  TransferLaneAllocatorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@MainActor
@Suite("TransferLaneAllocator")
struct TransferLaneAllocatorTests {
    @Test("lanes are numbered from 1, so the run's own pair is never handed out")
    func lanesNeverIncludeZero() async {
        let allocator = TransferLaneAllocator(capacity: 3)
        var lanes: Set<Int> = []
        for _ in 0 ..< 3 {
            lanes.insert(await allocator.acquire())
        }
        #expect(lanes == [1, 2, 3])
    }

    @Test("a lane is never handed to two holders at once")
    func lanesAreExclusive() async {
        let allocator = TransferLaneAllocator(capacity: 2)
        let first = await allocator.acquire()
        let second = await allocator.acquire()
        #expect(first != second)
    }

    @Test("a caller waits for a lane and gets the one that was released")
    func waiterGetsTheReleasedLane() async {
        let allocator = TransferLaneAllocator(capacity: 1)
        let held = await allocator.acquire()

        async let waiting = allocator.acquire()
        await Task.yield()
        allocator.release(held)

        #expect(await waiting == held)
    }

    @Test("a capacity below one still yields a usable lane")
    func capacityIsAtLeastOne() async {
        let allocator = TransferLaneAllocator(capacity: 0)
        #expect(allocator.capacity == 1)
        #expect(await allocator.acquire() == 1)
    }
}
