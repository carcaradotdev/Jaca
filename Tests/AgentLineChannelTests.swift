import XCTest
@testable import Jaca

/// The socket layer both agent transports now share. It binds a real loopback pair — deterministic
/// and entirely local, following the `ProxyServerTests` precedent — because the invariants that
/// matter here (`SO_NOSIGPIPE`, the fd outliving `stopAccepting`, frames straddling a `recv`) only
/// exist against a real socket.
final class AgentLineChannelTests: XCTestCase {

    // MARK: - Recording

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        private var _firstBytes = 0
        private var _connected = 0
        private var _disconnected = 0

        func line(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
        func firstBytes() { lock.lock(); _firstBytes += 1; lock.unlock() }
        func connected() { lock.lock(); _connected += 1; lock.unlock() }
        func disconnected() { lock.lock(); _disconnected += 1; lock.unlock() }

        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        var firstBytesCount: Int { lock.lock(); defer { lock.unlock() }; return _firstBytes }
        var connectedCount: Int { lock.lock(); defer { lock.unlock() }; return _connected }
        var disconnectedCount: Int { lock.lock(); defer { lock.unlock() }; return _disconnected }

        var callbacks: AgentLineChannel.Callbacks {
            .init(onLine: { [self] in line($0) },
                  onFirstBytes: { [self] in firstBytes() },
                  onConnected: { [self] in connected() },
                  onDisconnected: { [self] in disconnected() })
        }
    }

    // MARK: - A raw peer, standing in for the agent

    /// Connects like the agent does. Deliberately hand-rolled rather than a second channel, so the
    /// bytes on the wire are asserted directly.
    private func connectPeer(to port: UInt16, file: StaticString = #filePath, line: UInt = #line) throws -> Int32 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { close(s); XCTFail("peer couldn't connect", file: file, line: line); throw Failure() }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return s
    }

    private struct Failure: Error {}

    private func peerSend(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { send(fd, $0.baseAddress!, bytes.count, 0) }
    }

    /// Reads until `lines` newlines have arrived: two frames written back-to-back are free to
    /// arrive as two TCP segments, so a single `recv` proves nothing.
    private func peerReceive(_ fd: Int32, lines: Int = 1) -> String {
        var chunk = [UInt8](repeating: 0, count: 4096)
        var text = ""
        while text.filter({ $0 == "\n" }).count < lines {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { break }
            text += String(decoding: chunk[0..<n], as: UTF8.self)
        }
        return text
    }

    /// Polls rather than sleeps a fixed amount, so a slow machine doesn't make the suite flaky.
    private func wait(_ timeout: TimeInterval = 3, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    // MARK: - Tests

    func test_listenReturnsABoundPort() throws {
        let channel = AgentLineChannel(name: "test-bind", callbacks: .init())
        defer { channel.close() }
        let port = try XCTUnwrap(channel.listen())
        XCTAssertGreaterThan(port, 0)
    }

    func test_peerLinesArriveInOrder() throws {
        let recorder = Recorder()
        let channel = AgentLineChannel(name: "test-order", callbacks: recorder.callbacks)
        defer { channel.close() }
        let port = try XCTUnwrap(channel.listen())
        let peer = try connectPeer(to: port)
        defer { close(peer) }

        // Split mid-frame on purpose: the framer must hold the remainder across the read boundary.
        peerSend(peer, "{\"a\":1}\n{\"b\":2}\n{\"c\"")
        peerSend(peer, ":3}\n")

        XCTAssertTrue(wait { recorder.lines.count == 3 }, "got \(recorder.lines)")
        XCTAssertEqual(recorder.lines, ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
        XCTAssertEqual(recorder.connectedCount, 1)
    }

    func test_writeReachesThePeer() throws {
        let recorder = Recorder()
        let channel = AgentLineChannel(name: "test-write", callbacks: recorder.callbacks)
        defer { channel.close() }
        let port = try XCTUnwrap(channel.listen())
        let peer = try connectPeer(to: port)
        defer { close(peer) }
        XCTAssertTrue(wait { channel.isConnected })

        let outcome = expectation(description: "write outcome")
        var reported: AgentLineChannel.WriteOutcome?
        channel.write("{\"type\":\"divert\"}") { result in
            reported = result
            outcome.fulfill()
        }
        wait(for: [outcome], timeout: 3)
        XCTAssertEqual(reported, .written)
        // Newline-framed on the wire, so the device can read one frame at a time.
        XCTAssertEqual(peerReceive(peer), "{\"type\":\"divert\"}\n")
    }

    /// A control frame with nobody on the other end is dropped, not fatal — and above all it must
    /// not raise SIGPIPE, which is what `SO_NOSIGPIPE` exists to prevent.
    func test_writeWithNoConnectionIsDroppedAndTheProcessSurvives() throws {
        let channel = AgentLineChannel(name: "test-nopeer", callbacks: .init())
        defer { channel.close() }
        _ = try XCTUnwrap(channel.listen())

        let outcome = expectation(description: "write outcome")
        var reported: AgentLineChannel.WriteOutcome?
        channel.write("{\"type\":\"divert\"}") { result in
            reported = result
            outcome.fulfill()
        }
        wait(for: [outcome], timeout: 3)
        XCTAssertEqual(reported, .droppedNoConnection)
        XCTAssertFalse(channel.isConnected)
    }

    /// Teardown ordering depends on this: `flush` must not resume until the frames queued before
    /// it have reached `send(2)`, or the disarm frame races the close that follows it.
    func test_flushResumesOnlyAfterQueuedFramesHaveLeft() async throws {
        let channel = AgentLineChannel(name: "test-flush", callbacks: .init())
        defer { channel.close() }
        let port = try XCTUnwrap(channel.listen())
        let peer = try connectPeer(to: port)
        defer { close(peer) }
        XCTAssertTrue(wait { channel.isConnected })

        let sent = Recorder()
        channel.write("{\"one\":1}") { _ in sent.line("one") }
        channel.write("{\"two\":2}") { _ in sent.line("two") }
        await channel.flush()

        XCTAssertEqual(sent.lines, ["one", "two"], "flush resumed before the writes drained")
        XCTAssertEqual(peerReceive(peer, lines: 2), "{\"one\":1}\n{\"two\":2}\n")
    }

    /// `adb forward` accepts a TCP connect whether or not anything listens on the device, so
    /// connecting proves nothing — only bytes prove the agent loaded.
    func test_onFirstBytesFiresOncePerConnection() throws {
        let recorder = Recorder()
        let channel = AgentLineChannel(name: "test-firstbytes", callbacks: recorder.callbacks)
        defer { channel.close() }
        let port = try XCTUnwrap(channel.listen())

        let peer = try connectPeer(to: port)
        XCTAssertTrue(wait { channel.isConnected })
        XCTAssertEqual(recorder.firstBytesCount, 0, "connecting alone must not count as loaded")
        peerSend(peer, "{\"a\":1}\n")
        peerSend(peer, "{\"b\":2}\n")
        XCTAssertTrue(wait { recorder.lines.count == 2 })
        XCTAssertEqual(recorder.firstBytesCount, 1)

        // A relaunched app reconnects, and that fresh connection reports its own first bytes.
        close(peer)
        XCTAssertTrue(wait { recorder.disconnectedCount == 1 })
        let second = try connectPeer(to: port)
        defer { close(second) }
        peerSend(second, "{\"c\":3}\n")
        XCTAssertTrue(wait { recorder.lines.count == 3 })
        XCTAssertEqual(recorder.firstBytesCount, 2)
    }

    func test_onDisconnectedFiresWhenThePeerCloses() throws {
        let recorder = Recorder()
        let channel = AgentLineChannel(name: "test-eof", callbacks: recorder.callbacks)
        defer { channel.close() }
        let port = try XCTUnwrap(channel.listen())
        let peer = try connectPeer(to: port)
        XCTAssertTrue(wait { channel.isConnected })

        close(peer)
        XCTAssertTrue(wait { recorder.disconnectedCount == 1 })
        XCTAssertFalse(channel.isConnected)
    }

    /// The other direction: Android dials a forwarded port instead of being dialled.
    func test_dialConnectsAndStreams() throws {
        let recorder = Recorder()
        let listener = AgentLineChannel(name: "test-dial-peer", callbacks: .init())
        defer { listener.close() }
        let port = try XCTUnwrap(listener.listen())

        let dialer = AgentLineChannel(name: "test-dial", callbacks: recorder.callbacks)
        defer { dialer.close() }
        dialer.dial(port: Int32(port), retry: .milliseconds(50))
        XCTAssertTrue(wait { dialer.isConnected && listener.isConnected })

        // The listening side writes; the dialling side reads. Both use the same framing.
        listener.write("{\"type\":\"divert\"}")
        XCTAssertTrue(wait { recorder.lines == ["{\"type\":\"divert\"}"] }, "got \(recorder.lines)")
    }

    /// The fd must outlive `stopAccepting()` — that is the whole reason the disarm frame still
    /// lands on teardown.
    func test_stopAcceptingLeavesTheLiveConnectionWritable() throws {
        let channel = AgentLineChannel(name: "test-stopaccepting", callbacks: .init())
        defer { channel.close() }
        let port = try XCTUnwrap(channel.listen())
        let peer = try connectPeer(to: port)
        defer { close(peer) }
        XCTAssertTrue(wait { channel.isConnected })

        channel.stopAccepting()
        XCTAssertTrue(channel.isConnected)

        let outcome = expectation(description: "write outcome")
        var reported: AgentLineChannel.WriteOutcome?
        channel.write("{\"type\":\"divert\",\"origin\":null}") { result in
            reported = result
            outcome.fulfill()
        }
        wait(for: [outcome], timeout: 3)
        XCTAssertEqual(reported, .written)
        XCTAssertEqual(peerReceive(peer), "{\"type\":\"divert\",\"origin\":null}\n")
    }

    // MARK: - Close is terminal

    /// `AgentController.run()` can be mid-`await` (pushing artifacts, setting up the forward) when
    /// the user stops capture. Teardown runs first and closes the channel; the resumed `run()` then
    /// calls `dial()`. Before `close()` was made terminal, `dial()` cleared the stop flag and span
    /// up a reconnect thread that retried every 300 ms *forever* against a port nothing would ever
    /// answer — observed on an emulator as ~27 refused connects per 8 s, indefinitely, per stop.
    func test_dialAfterCloseDoesNotStartAReconnectLoop() throws {
        let listener = AgentLineChannel(name: "test-revive-peer", callbacks: .init())
        defer { listener.close() }
        let port = try XCTUnwrap(listener.listen())

        let dialer = AgentLineChannel(name: "test-revive", callbacks: .init())
        dialer.stopAccepting()
        dialer.close()

        dialer.dial(port: Int32(port), retry: .milliseconds(20))

        XCTAssertFalse(wait(0.5) { dialer.isConnected },
                       "a closed channel was resurrected into a reconnect loop by dial()")
    }

    /// The same latch on the listening side, so a torn-down iOS controller can't reopen a port.
    func test_listenAfterCloseReturnsNil() {
        let channel = AgentLineChannel(name: "test-revive-listen", callbacks: .init())
        channel.close()
        XCTAssertNil(channel.listen(), "a closed channel bound a new listener")
    }
}
