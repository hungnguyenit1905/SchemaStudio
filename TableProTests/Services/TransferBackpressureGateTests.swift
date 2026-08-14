import Foundation
@testable import SchemaStudio
import Testing

@Suite("TransferBackpressureGate")
struct TransferBackpressureGateTests {
    @Test("a small buffer throttles a fast producer to the consumer's pace")
    func fastProducerIsThrottled() async {
        let gate = TransferBackpressureGate(capacity: 3)
        let produced = ActorCounter()

        async let producer: Void = {
            for _ in 0 ..< 20 {
                let allowed = await gate.acquire()
                guard allowed else { return }
                _ = await produced.next()
            }
        }()

        async let consumer: Void = {
            // Consume one element every few yields, far slower than production.
            for _ in 0 ..< 20 {
                await gate.release()
                await Task.yield()
                await Task.yield()
            }
        }()

        _ = await (producer, consumer)
        #expect(await produced.count == 20)
    }

    @Test("every element passes through with a consumer as fast as the producer")
    func noElementIsDropped() async {
        let gate = TransferBackpressureGate(capacity: 2)
        let produced = ActorCounter()

        async let producer: Void = {
            for _ in 0 ..< 50 {
                let allowed = await gate.acquire()
                guard allowed else { return }
                _ = await produced.next()
            }
        }()

        async let consumer: Void = {
            for _ in 0 ..< 50 {
                await gate.release()
            }
        }()

        _ = await (producer, consumer)
        #expect(await produced.count == 50)
    }

    @Test("acquire never exceeds the capacity in flight")
    func inFlightNeverExceedsCapacity() async {
        let gate = TransferBackpressureGate(capacity: 2)
        let gauge = InFlightGauge()

        async let producer: Void = {
            for _ in 0 ..< 30 {
                let allowed = await gate.acquire()
                guard allowed else { return }
                await gauge.enter()
            }
        }()

        async let consumer: Void = {
            for _ in 0 ..< 30 {
                await gate.release()
                await gauge.exit()
                await Task.yield()
            }
        }()

        _ = await (producer, consumer)
        #expect(await gauge.peak <= 2)
    }

    @Test("releaseAll wakes a suspended waiter and closes the gate")
    func releaseAllUnblocksWaiters() async {
        let gate = TransferBackpressureGate(capacity: 1)
        let first = await gate.acquire()
        #expect(first == true)

        async let waiter: Bool = gate.acquire()

        await Task.yield()
        await gate.releaseAll()

        let acquired = await waiter
        #expect(acquired == false)
        let later = await gate.acquire()
        #expect(later == false)
    }
}

private actor ActorCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }

    var count: Int { value }
}

private actor InFlightGauge {
    private var active = 0
    private var highest = 0

    func enter() {
        active += 1
        if active > highest { highest = active }
    }

    func exit() {
        active -= 1
    }

    var peak: Int { highest }
}
