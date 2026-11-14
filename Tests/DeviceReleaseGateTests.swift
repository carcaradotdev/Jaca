import XCTest
@testable import Jaca

/// The next capture on a device must not arm while the previous one still reverts it.
@MainActor
final class DeviceReleaseGateTests: XCTestCase {

    /// Finishes when the test calls `finish()`.
    private final class Latch: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false
        private let lock = NSLock()

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if finished { lock.unlock(); c.resume(); return }
                continuation = c
                lock.unlock()
            }
        }

        func finish() {
            lock.lock()
            finished = true
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    @MainActor private final class Flag { var value = false }

    func test_settleReturnsAtOnceWhenNothingIsTracked() async {
        let gate = DeviceReleaseGate()
        await gate.settle(serial: "emulator-5554")
        await gate.settleAll()
        XCTAssertTrue(gate.pendingSerials.isEmpty)
    }

    func test_settleWaitsForTheTrackedTask() async {
        let gate = DeviceReleaseGate()
        let latch = Latch()
        let flag = Flag()
        gate.track(serial: "a", task: Task { @MainActor in
            await latch.wait()
            flag.value = true
        })
        XCTAssertTrue(gate.isPending(serial: "a"))

        let settled = Task { @MainActor in
            await gate.settle(serial: "a")
            return flag.value
        }
        // Give `settle` a chance to run; it must still be waiting.
        await Task.yield()
        XCTAssertFalse(flag.value)

        latch.finish()
        let sawTeardown = await settled.value
        XCTAssertTrue(sawTeardown, "settle returned before the teardown finished")
        XCTAssertFalse(gate.isPending(serial: "a"))
    }

    func test_settleOnlyWaitsForItsOwnSerial() async {
        let gate = DeviceReleaseGate()
        let latch = Latch()
        gate.track(serial: "a", task: Task { await latch.wait() })

        await gate.settle(serial: "b")
        XCTAssertTrue(gate.isPending(serial: "a"))

        latch.finish()
        await gate.settle(serial: "a")
        XCTAssertFalse(gate.isPending(serial: "a"))
    }

    func test_settleAllWaitsForEveryDevice() async {
        let gate = DeviceReleaseGate()
        let latchA = Latch()
        let latchB = Latch()
        gate.track(serial: "a", task: Task { await latchA.wait() })
        gate.track(serial: "b", task: Task { await latchB.wait() })
        XCTAssertEqual(gate.pendingSerials, ["a", "b"])

        let all = Task { @MainActor in await gate.settleAll() }
        latchA.finish()
        latchB.finish()
        await all.value

        XCTAssertTrue(gate.pendingSerials.isEmpty)
    }

    func test_aFinishedTaskRemovesItself() async {
        let gate = DeviceReleaseGate()
        let task = Task<Void, Never> {}
        gate.track(serial: "a", task: task)
        await task.value
        // The self-removal hops back to the main actor after the task ends.
        for _ in 0..<50 where gate.isPending(serial: "a") { await Task.yield() }
        XCTAssertFalse(gate.isPending(serial: "a"))
    }
}
