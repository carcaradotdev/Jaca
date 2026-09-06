import XCTest
@testable import Jaca

/// The coordinator writes through an injected `AgentControlWriter` and reaches the device through
/// an injected `DivertTunnel`, so its whole control-frame contract can be asserted with no device,
/// no `adb` and no subprocess. The only real socket anywhere here is the loopback listener
/// `OverrideServer` binds on port 0, which is local and deterministic.
final class DivertCoordinatorTests: XCTestCase {

    private final class RecordingWriter: AgentControlWriter, @unchecked Sendable {
        enum Event: Equatable { case frame(String), flush }

        private let lock = NSLock()
        private var _events: [Event] = []

        func write(_ json: String) { lock.lock(); _events.append(.frame(json)); lock.unlock() }
        func flush(timeout: Duration) async { lock.lock(); _events.append(.flush); lock.unlock() }

        var events: [Event] { lock.lock(); defer { lock.unlock() }; return _events }
        var frames: [String] {
            events.compactMap { if case .frame(let f) = $0 { return f } else { return nil } }
        }
    }

    /// Stands in for `AdbReverseTunnel` without spawning anything, and can be told to fail so the
    /// "whose words does the user see?" question has an answer in a test rather than on a device.
    private final class StubTunnel: DivertTunnel, @unchecked Sendable {
        let failure: String?
        private let lock = NSLock()
        private var _closedPorts: [Int] = []

        init(failure: String? = nil) { self.failure = failure }

        func origin(forLocalPort port: Int) -> String { "http://stub:\(port)" }
        func open(localPort port: Int) async throws {
            if let failure { throw DivertTunnelError(userMessage: failure) }
        }
        func close(localPort port: Int) async { lock.lock(); _closedPorts.append(port); lock.unlock() }
        var needsTunnelLedger: Bool { false }

        var closedPorts: [Int] { lock.lock(); defer { lock.unlock() }; return _closedPorts }
    }

    /// A tunnel whose `open` parks until released, so a `stop()` can be driven *into* the
    /// bring-up window rather than merely before or after it.
    private final class BlockingTunnel: DivertTunnel, @unchecked Sendable {
        private let opened = AsyncSemaphore()
        private let release = AsyncSemaphore()
        private let lock = NSLock()
        private var _closedPorts: [Int] = []

        func origin(forLocalPort port: Int) -> String { "http://stub:\(port)" }
        func open(localPort port: Int) async throws {
            opened.signal()
            await release.wait()
        }
        func close(localPort port: Int) async { lock.lock(); _closedPorts.append(port); lock.unlock() }
        var needsTunnelLedger: Bool { false }

        var closedPorts: [Int] { lock.lock(); defer { lock.unlock() }; return _closedPorts }
        func waitUntilOpenCalled() async { await opened.wait() }
        func releaseOpen() { release.signal() }
    }

    /// Minimal one-shot gate; `Task.sleep`-based coordination makes this test flaky by design.
    private final class AsyncSemaphore: @unchecked Sendable {
        private let lock = NSLock()
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            let pending: [CheckedContinuation<Void, Never>] = {
                lock.lock(); defer { lock.unlock() }
                signalled = true
                let w = waiters; waiters = []
                return w
            }()
            pending.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if signalled { lock.unlock(); c.resume(); return }
                waiters.append(c)
                lock.unlock()
            }
        }
    }

    private func makeCoordinator(_ writer: RecordingWriter,
                                 tunnel: DivertTunnel = StubTunnel(),
                                 heartbeatSeconds: Int = 15) -> DivertCoordinator {
        DivertCoordinator(transport: .agentDivert(package: "com.example.app"),
                          deviceID: "unit-test-serial",
                          appID: "com.example.app",
                          capabilities: .desktopTerminated,
                          tunnel: tunnel,
                          writer: writer,
                          heartbeatSeconds: heartbeatSeconds)
    }

    /// The port the coordinator bound, taken from the state it published.
    private func activePort(_ state: InterceptArmingState) -> Int? {
        if case .active(let port, _) = state { return port }
        return nil
    }

    // MARK: - Silence before the agent has proven itself

    /// Until the agent says hello, the desktop has no evidence it can read control frames at all,
    /// so it says nothing — an older agent build is a no-op rather than a hazard.
    func test_nothingIsPushedBeforeTheAgentSaysHello() {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        coordinator.updateHosts(["api.example.com"])
        XCTAssertTrue(writer.events.isEmpty, "got \(writer.events)")
        XCTAssertEqual(coordinator.currentState, .idle)
    }

    /// …and a hello with no server bound is still silence: there is no origin to name yet.
    func test_helloWithoutABoundServerPushesNothing() {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        coordinator.agentDidAdvertiseOverrideSupport()
        XCTAssertTrue(writer.events.isEmpty, "got \(writer.events)")
    }

    func test_reconnectBeforeAnyHelloPushesNothing() {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        coordinator.agentDidReconnect()
        XCTAssertTrue(writer.events.isEmpty, "got \(writer.events)")
    }

    // MARK: - Start

    /// The lie this step removes. A bound server means the *desktop* is ready; nothing is being
    /// diverted until the agent has said hello, and `.active` there paints a live green bolt over
    /// a session where every request goes straight past us.
    func test_aBoundServerWithNoHelloIsWaitingForTheAgentNotActive() async {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        coordinator.updateHosts(["api.example.com"])
        await coordinator.start(pipeline: .passthrough)

        XCTAssertEqual(coordinator.currentState, .waitingForAgent)
        XCTAssertTrue(writer.events.isEmpty, "got \(writer.events)")
        await coordinator.stop()
    }

    func test_helloAfterStartArmsTheDeviceAtTheBoundPort() async throws {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        coordinator.updateHosts(["api.example.com"])
        await coordinator.start(pipeline: .passthrough)
        coordinator.agentDidAdvertiseOverrideSupport()

        let port = try XCTUnwrap(activePort(coordinator.currentState))
        XCTAssertEqual(coordinator.currentState, .active(port: port, hosts: ["api.example.com"]))
        XCTAssertEqual(writer.frames, [OverrideEndpoint.divertFrame(
            OverrideEndpoint(origin: "http://stub:\(port)", hosts: ["api.example.com"]))])
        await coordinator.stop()
    }

    /// An agent build that predates overrides is alive and streaming transactions, so silence
    /// would look exactly like "still loading" forever. It gets its own state, and no frames.
    func test_aHelloWithoutOverrideSupportSaysTheAgentIsTooOld() async {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        await coordinator.start(pipeline: .passthrough)
        coordinator.agentDidAdvertiseWithoutOverrideSupport()

        XCTAssertEqual(coordinator.currentState, .agentTooOld)
        XCTAssertTrue(writer.events.isEmpty, "got \(writer.events)")
        await coordinator.stop()
    }

    /// A re-attach re-points the reporter socket. Waiting for a second hello that may never be
    /// seen would strand the device unarmed with no way back, so support is sticky.
    func test_reconnectReArmsWithoutASecondHello() async throws {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        coordinator.updateHosts(["api.example.com"])
        await coordinator.start(pipeline: .passthrough)
        coordinator.agentDidAdvertiseOverrideSupport()
        let first = try XCTUnwrap(writer.frames.first)

        coordinator.agentDidReconnect()

        XCTAssertEqual(writer.frames, [first, first])
        XCTAssertNotNil(activePort(coordinator.currentState))
        await coordinator.stop()
    }

    /// Empty hosts must disarm the device, never divert everything: `OverrideEndpoint`'s init
    /// clears the origin with the host set, so the frame that lands is a real disarm.
    func test_clearingTheHostSetDisarmsRatherThanDivertingEverything() async throws {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        coordinator.updateHosts(["api.example.com"])
        await coordinator.start(pipeline: .passthrough)
        coordinator.agentDidAdvertiseOverrideSupport()

        coordinator.updateHosts([])

        let last = try XCTUnwrap(writer.frames.last)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        XCTAssertTrue(obj["origin"] is NSNull)
        XCTAssertEqual((obj["hosts"] as? [String]) ?? ["unset"], [])
        await coordinator.stop()
    }

    /// Whoever knows what failed is the one who words it — a generic "couldn't open the tunnel"
    /// is exactly the sentence that sends someone to the logs.
    func test_aTunnelFailureSurfacesTheTunnelsOwnMessage() async {
        let writer = RecordingWriter()
        let tunnel = StubTunnel(failure: "adb reverse tcp:41234 failed — device offline")
        let coordinator = makeCoordinator(writer, tunnel: tunnel)
        await coordinator.start(pipeline: .passthrough)

        XCTAssertEqual(coordinator.currentState,
                       .failed("adb reverse tcp:41234 failed — device offline"))
        // The listener must not be left behind when the device can't reach it anyway.
        XCTAssertTrue(writer.events.isEmpty, "got \(writer.events)")
    }

    /// The heartbeat re-states the **full** endpoint rather than pinging, so any desync — an app
    /// restart the desktop didn't notice, a lapsed window — repairs itself within one interval.
    func test_theHeartbeatReStatesTheWholeEndpoint() async throws {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer, heartbeatSeconds: 1)
        coordinator.updateHosts(["api.example.com"])
        await coordinator.start(pipeline: .passthrough)
        coordinator.agentDidAdvertiseOverrideSupport()
        let armed = try XCTUnwrap(writer.frames.first)

        let deadline = Date().addingTimeInterval(4)
        while writer.frames.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertGreaterThanOrEqual(writer.frames.count, 2, "the heartbeat never fired")
        XCTAssertEqual(writer.frames[1], armed, "the heartbeat must re-state, not ping")
        await coordinator.stop()
    }

    // MARK: - Teardown

    /// The guarantee this step adds: the disarm frame reaches `send(2)` **before** anything else
    /// goes away. It used to hold only by accident, because the next step happened to await an
    /// `adb` spawn long enough for the write to drain.
    func test_stopFlushesTheDisarmFrameBeforeTearingAnythingDown() async {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        await coordinator.stop()

        XCTAssertEqual(writer.events,
                       [.frame(OverrideEndpoint.divertFrame(.disarmed(heartbeatSeconds: 15))), .flush])
        XCTAssertEqual(coordinator.currentState, .idle)
    }

    /// …and the tunnel is closed for the port that was actually bound, so a stale mapping can't
    /// outlive the listener it points at.
    func test_stopClosesTheTunnelForTheBoundPort() async throws {
        let writer = RecordingWriter()
        let tunnel = StubTunnel()
        let coordinator = makeCoordinator(writer, tunnel: tunnel)
        await coordinator.start(pipeline: .passthrough)
        coordinator.agentDidAdvertiseOverrideSupport()
        let port = try XCTUnwrap(activePort(coordinator.currentState))

        await coordinator.stop()

        XCTAssertEqual(tunnel.closedPorts, [port])
        XCTAssertEqual(coordinator.currentState, .idle)
    }

    /// There is one spelling of "stop", and it carries the heartbeat window so the value survives
    /// teardown.
    func test_theDisarmFrameCarriesANullOriginAndNoHosts() async throws {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer, heartbeatSeconds: 9)
        await coordinator.stop()

        let frame = try XCTUnwrap(writer.frames.first)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "divert")
        XCTAssertTrue(obj["origin"] is NSNull)
        XCTAssertEqual((obj["hosts"] as? [String]) ?? ["unset"], [])
        XCTAssertEqual(obj["heartbeatSeconds"] as? Int, 9)
    }

    // MARK: - Heartbeat cadence

    /// Derived from the window it has to stay inside, rather than the `5` literal that used to sit
    /// in the controller one careless edit away from outliving the 15 s window it fed.
    // MARK: - The app went away underneath us (iOS)

    /// The `.active` lie this exists to break: `agentDidReconnect` deliberately keeps `override/1`
    /// support sticky across a socket cycle, so after the user quits the app the coordinator still
    /// believes the agent supports overrides. Without an outside report it would keep publishing
    /// `.active` while nothing whatsoever was being diverted.
    func test_aRunningAppWithNoAgentInItReportsDetachedNotActive() async {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        await coordinator.start(pipeline: .passthrough)
        coordinator.agentDidAdvertiseOverrideSupport()
        coordinator.agentDidReconnect()                     // the socket cycled: support stays sticky

        coordinator.appPresenceChanged(.running(pid: 4321))

        XCTAssertEqual(coordinator.currentState, .detached(appID: "com.example.app"))
        await coordinator.stop()
    }

    func test_anAppThatIsNotRunningReportsWaitingForApp() async {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        await coordinator.start(pipeline: .passthrough)
        coordinator.agentDidAdvertiseOverrideSupport()

        coordinator.appPresenceChanged(.notRunning)

        XCTAssertEqual(coordinator.currentState, .waitingForApp(appID: "com.example.app"))
        await coordinator.stop()
    }

    func test_aShutDownSimulatorIsAFailureNotAWait() async {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        await coordinator.start(pipeline: .passthrough)
        coordinator.agentDidAdvertiseOverrideSupport()

        coordinator.appPresenceChanged(.notBooted)

        guard case .failed(let detail) = coordinator.currentState else {
            return XCTFail("expected .failed, got \(coordinator.currentState)")
        }
        XCTAssertFalse(detail.isEmpty)
        await coordinator.stop()
    }

    /// A hello can only come from a live socket inside the app, so it invalidates whatever the
    /// supervisor last said. Without this the re-attach would fix capture and leave the banner up.
    func test_aFreshHelloClearsAStalePresenceReport() async throws {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        coordinator.updateHosts(["api.example.com"])
        await coordinator.start(pipeline: .passthrough)
        coordinator.agentDidAdvertiseOverrideSupport()
        coordinator.appPresenceChanged(.running(pid: 4321))
        XCTAssertEqual(coordinator.currentState, .detached(appID: "com.example.app"))

        coordinator.agentDidAdvertiseOverrideSupport()       // relaunched, agent back in-process

        let port = try XCTUnwrap(activePort(coordinator.currentState))
        XCTAssertEqual(coordinator.currentState, .active(port: port, hosts: ["api.example.com"]))
        await coordinator.stop()
    }

    /// Nothing is armed before the server binds, so a presence report can't fabricate a state.
    func test_aPresenceReportBeforeStartChangesNothing() {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        coordinator.appPresenceChanged(.running(pid: 1))
        XCTAssertEqual(coordinator.currentState, .idle)
    }

    func test_heartbeatIntervalIsAThirdOfTheWindow() {
        XCTAssertEqual(DivertCoordinator.heartbeatInterval(heartbeatSeconds: 15), .seconds(5))
        XCTAssertEqual(DivertCoordinator.heartbeatInterval(heartbeatSeconds: 30), .seconds(10))
        XCTAssertEqual(DivertCoordinator.heartbeatInterval(heartbeatSeconds: 9), .seconds(3))
    }

    /// A window so short that a third of it rounds to zero must not turn the heartbeat into a
    /// spin loop.
    func test_heartbeatIntervalNeverCollapsesToZero() {
        XCTAssertEqual(DivertCoordinator.heartbeatInterval(heartbeatSeconds: 1), .seconds(1))
        XCTAssertEqual(DivertCoordinator.heartbeatInterval(heartbeatSeconds: 0), .seconds(1))
    }

    // MARK: - Teardown is terminal

    /// The owning controller can be mid-`await` in its bring-up (pushing ~15 MB of artifacts over
    /// adb) when the user hits stop. Teardown then runs to completion *first*, and the resumed
    /// bring-up calls `start()` afterwards. Before `stop()` was made terminal, that late `start()`
    /// bound a second `OverrideServer`, opened a tunnel, and spawned a heartbeat with nothing left
    /// to cancel it — observed on a device as `adb reverse --list` still showing the mapping and
    /// the state stuck at `.waitingForAgent` eight seconds after stopping.
    func test_startAfterStopIsRefusedRatherThanLeakingASecondServer() async {
        let writer = RecordingWriter()
        let tunnel = StubTunnel()
        let coordinator = makeCoordinator(writer, tunnel: tunnel)

        await coordinator.stop()                          // teardown wins the race
        await coordinator.start(pipeline: .passthrough)   // the resumed bring-up arrives late

        XCTAssertEqual(coordinator.currentState, .idle,
                       "a late start() re-armed a coordinator that was already torn down")
    }

    /// The *interleaved* ordering, which the sequential test above cannot reach.
    ///
    /// `claimStart()` tests `stopped` on entry, then `start` awaits `tunnel.open` (an `adb`
    /// spawn in production). A `stop()` arriving inside that await finds no server to release —
    /// it isn't published yet — so unless the resumed `start` re-checks, it commits a bound
    /// listener, an open tunnel and an uncancellable heartbeat after teardown, and parks the
    /// toolbar on "Arming" for good.
    func test_stopDuringTunnelOpenLeavesNothingBehind() async {
        let writer = RecordingWriter()
        let tunnel = BlockingTunnel()
        let coordinator = makeCoordinator(writer, tunnel: tunnel)

        let bringUp = Task { await coordinator.start(pipeline: .passthrough) }
        await tunnel.waitUntilOpenCalled()      // start() is now parked mid-bring-up

        await coordinator.stop()                // teardown lands inside the window
        tunnel.releaseOpen()
        await bringUp.value                     // start() resumes and must unwind itself

        XCTAssertEqual(coordinator.currentState, .idle,
                       "a start() interrupted by stop() published itself anyway")
        XCTAssertFalse(tunnel.closedPorts.isEmpty,
                       "the tunnel opened during bring-up was never closed — a leaked mapping")
    }

    /// The other half of the same race: an agent reconnecting after teardown must not be able to
    /// arm a dead coordinator, because the only thing that would ever disarm it is already gone.
    func test_anAgentReconnectingAfterStopCannotReArmIt() async {
        let writer = RecordingWriter()
        let coordinator = makeCoordinator(writer)
        await coordinator.start(pipeline: .passthrough)
        coordinator.updateHosts(["example.com"])
        coordinator.agentDidAdvertiseOverrideSupport()
        await coordinator.stop()

        let framesAfterStop = writer.frames.count
        coordinator.agentDidAdvertiseOverrideSupport()
        coordinator.agentDidReconnect()

        XCTAssertEqual(coordinator.currentState, .idle)
        for frame in writer.frames.dropFirst(framesAfterStop) {
            XCTAssertTrue(frame.contains("\"origin\":null"),
                          "a torn-down coordinator armed the device again: \(frame)")
        }
    }
}
