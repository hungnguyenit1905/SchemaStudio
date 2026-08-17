//
//  CopilotIdleStopControllerTests.swift
//  TableProTests
//
//  Verifies the deferred-stop state machine extracted from CopilotService.
//

@testable import SchemaStudio
import TableProPluginKit
import Testing

@MainActor
private final class TestState {
    var authenticated: Bool
    var running: Bool
    var stopCount: Int = 0

    init(authenticated: Bool = false, running: Bool = true) {
        self.authenticated = authenticated
        self.running = running
    }
}

private actor ManualTimeout {
    private var started = 0
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started += 1
        let waiting = observers
        observers = []
        for observer in waiting { observer.resume() }
        await withCheckedContinuation { continuation in
            sleepers.append(continuation)
        }
    }

    func waitUntilStarted(_ count: Int) async {
        while started < count {
            await withCheckedContinuation { continuation in
                observers.append(continuation)
            }
        }
    }

    func fire() {
        let pending = sleepers
        sleepers = []
        for sleeper in pending { sleeper.resume() }
    }
}

@Suite("CopilotIdleStopController")
@MainActor
struct CopilotIdleStopControllerTests {
    private func makeController(state: TestState, timeout: ManualTimeout) -> CopilotIdleStopController {
        CopilotIdleStopController(
            timeout: .seconds(1),
            isAuthenticated: { state.authenticated },
            isRunning: { state.running },
            onStopRequest: { state.stopCount += 1 },
            waitForTimeout: { _ in await timeout.wait() }
        )
    }

    @Test("Stops when timer fires while unauthenticated and running")
    func stopsAfterTimeout() async throws {
        let state = TestState()
        let timeout = ManualTimeout()
        let controller = makeController(state: state, timeout: timeout)

        controller.schedule()
        await timeout.waitUntilStarted(1)
        await timeout.fire()
        await controller.scheduledStop?.value

        #expect(state.stopCount == 1)
    }

    @Test("Skips when already authenticated at schedule time")
    func skipsWhenAuthenticated() async throws {
        let state = TestState(authenticated: true)
        let timeout = ManualTimeout()
        let controller = makeController(state: state, timeout: timeout)

        controller.schedule()

        #expect(controller.scheduledStop == nil)
        #expect(state.stopCount == 0)
    }

    @Test("Skips when authenticated by fire time")
    func skipsWhenAuthenticatedByFireTime() async throws {
        let state = TestState()
        let timeout = ManualTimeout()
        let controller = makeController(state: state, timeout: timeout)

        controller.schedule()
        await timeout.waitUntilStarted(1)
        state.authenticated = true
        await timeout.fire()
        await controller.scheduledStop?.value

        #expect(state.stopCount == 0)
    }

    @Test("Skips when not running by fire time")
    func skipsWhenNotRunningByFireTime() async throws {
        let state = TestState()
        let timeout = ManualTimeout()
        let controller = makeController(state: state, timeout: timeout)

        controller.schedule()
        await timeout.waitUntilStarted(1)
        state.running = false
        await timeout.fire()
        await controller.scheduledStop?.value

        #expect(state.stopCount == 0)
    }

    @Test("Cancel before fire prevents stop")
    func cancelPreventsStop() async throws {
        let state = TestState()
        let timeout = ManualTimeout()
        let controller = makeController(state: state, timeout: timeout)

        controller.schedule()
        await timeout.waitUntilStarted(1)
        let pending = controller.scheduledStop
        controller.cancel()
        await timeout.fire()
        await pending?.value

        #expect(state.stopCount == 0)
    }

    @Test("Reschedule cancels prior timer; only fires once")
    func rescheduleFiresOnce() async throws {
        let state = TestState()
        let timeout = ManualTimeout()
        let controller = makeController(state: state, timeout: timeout)

        controller.schedule()
        await timeout.waitUntilStarted(1)
        let first = controller.scheduledStop
        controller.schedule()
        await timeout.waitUntilStarted(2)
        await timeout.fire()
        await first?.value
        await controller.scheduledStop?.value

        #expect(state.stopCount == 1)
    }
}
