import Foundation

/// Where a coordinator's control frames go. Injected, so the coordinator never owns an fd.
protocol AgentControlWriter: AnyObject, Sendable {
    func write(_ json: String)
    /// Resumes once queued frames have reached `send(2)` (or provably can't), so a teardown's
    /// disarm frame can't be lost to a racing close.
    func flush(timeout: Duration) async
}

extension AgentControlWriter {
    /// The teardown default. Here, not on the requirement: a protocol method's default argument
    /// is invisible through an existential.
    func flush() async { await flush(timeout: .milliseconds(300)) }
}

/// One newline-framed JSON connection to an in-process agent, in either direction: Android dials
/// an `adb forward` port, the iOS-Simulator agent dials us. Owns the fd, its lock, `SO_NOSIGPIPE`,
/// `SO_REUSEADDR`, the framer and the reconnect loop, so neither side hand-rolls them.
final class AgentLineChannel: AgentControlWriter, @unchecked Sendable {

    enum WriteOutcome: Sendable, Equatable { case written, droppedNoConnection, failed(errno: Int32) }

    struct Callbacks: Sendable {
        var onLine: @Sendable (String) -> Void = { _ in }
        /// First bytes — proof the agent loaded. `adb forward` accepts a TCP connect whether or
        /// not anything listens on the device, so connecting alone proves nothing.
        var onFirstBytes: @Sendable () -> Void = {}
        var onConnected: @Sendable () -> Void = {}
        var onDisconnected: @Sendable () -> Void = {}

        init(onLine: @escaping @Sendable (String) -> Void = { _ in },
             onFirstBytes: @escaping @Sendable () -> Void = {},
             onConnected: @escaping @Sendable () -> Void = {},
             onDisconnected: @escaping @Sendable () -> Void = {}) {
            self.onLine = onLine
            self.onFirstBytes = onFirstBytes
            self.onConnected = onConnected
            self.onDisconnected = onDisconnected
        }
    }

    private let name: String
    private let callbacks: Callbacks

    /// The connection, listener and stop flag are touched by the reader thread, the write queue
    /// and `stop()` alike, so every access goes through this lock.
    private let lock = NSLock()
    private var connFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var stopped = false
    /// **Terminal.** `stopped` alone can be un-set by a caller racing teardown: the controller
    /// stops while `run()` is parked on an `await`, then resumes into `dial()` and resurrects a
    /// channel nobody owns into a forever-retrying loop. Channels are one-shot, so there is no
    /// legitimate second bring-up to refuse.
    private var closed = false
    private var thread: Thread?

    /// Serialises writes, so frames can't interleave and `flush` has something to queue behind.
    private let writeQueue: DispatchQueue

    init(name: String, callbacks: Callbacks) {
        self.name = name
        self.callbacks = callbacks
        self.writeQueue = DispatchQueue(label: "jaca.agent.channel.\(name)")
    }

    // MARK: - Bring-up

    /// Binds 127.0.0.1:0 and starts accepting, returning the bound port or nil. Split from `init`
    /// because Android's forwarded port doesn't exist until `adb forward` has run.
    func listen() -> UInt16? {
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(s, 4) == 0 else { Darwin.close(s); return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(s, $0, &len) }
        }
        // Under the same lock that clears `stopped`, so a `close()` landing between the bind and
        // here can't be undone.
        let adopted: Bool = withLock {
            guard !closed else { return false }
            stopped = false
            listenFD = s
            return true
        }
        guard adopted else { Darwin.close(s); return nil }
        startThread { [weak self] in self?.acceptLoop(listener: s) }
        return UInt16(bigEndian: addr.sin_port)
    }

    /// Connects to 127.0.0.1:`port`, retrying until stopped. A no-op once `close()` has run.
    func dial(port: Int32, retry: Duration = .milliseconds(300)) {
        // Same lock that clears `stopped`, so a teardown landing mid-await isn't reversed here.
        let mayDial: Bool = withLock {
            guard !closed else { return false }
            stopped = false
            return true
        }
        guard mayDial else {
            JacaLog.debug("agent", "\(name): dial ignored — channel already closed")
            return
        }
        let pause = Self.seconds(retry)
        startThread { [weak self] in self?.dialLoop(port: port, retry: pause) }
    }

    var isConnected: Bool { withLock { connFD >= 0 } }

    // MARK: - Writing

    func write(_ json: String) { write(json, completion: nil) }

    func write(_ json: String, completion: (@Sendable (WriteOutcome) -> Void)?) {
        writeQueue.async { [weak self] in
            guard let self else { completion?(.droppedNoConnection); return }
            let outcome = self.sendNow(json)
            switch outcome {
            case .written:
                break
            case .droppedNoConnection:
                // Not escalated: an ordinary relaunch drops a frame or two, and the heartbeat
                // re-states the endpoint within one window.
                JacaLog.warn("agent", "\(self.name): control frame dropped — no connection")
            case .failed(let code):
                JacaLog.warn("agent", "\(self.name): control frame failed — errno \(code)")
            }
            completion?(outcome)
        }
    }

    func flush(timeout: Duration = .milliseconds(300)) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OnceContinuation(continuation)
            // A serial queue makes this a barrier: it runs only after every frame queued before it.
            writeQueue.async { once.resume() }
            // …but a `send` to a wedged socket can block, and teardown must not hang on it.
            Task { try? await Task.sleep(for: timeout); once.resume() }
        }
    }

    // MARK: - Teardown

    /// Stops accepting/dialling; the live fd stays valid so a disarm frame still lands. Clearing
    /// the connection here would make every teardown write bail, leaving the device to recover
    /// only via the EOF/heartbeat fallbacks.
    func stopAccepting() {
        let listener: Int32 = withLock {
            stopped = true
            let l = listenFD
            listenFD = -1
            return l
        }
        if listener >= 0 { Darwin.close(listener) }   // unblocks a thread parked in accept()
    }

    /// Closes the connection and the listener. Call after `flush`.
    func close() {
        let (conn, listener): (Int32, Int32) = withLock {
            stopped = true
            closed = true                 // terminal: `listen()`/`dial()` can no longer revive this
            let c = connFD, l = listenFD
            connFD = -1
            listenFD = -1
            return (c, l)
        }
        if listener >= 0 { Darwin.close(listener) }
        if conn >= 0 {
            // Wake the reader parked in `recv` *before* the fd goes away: Darwin doesn't
            // guarantee a blocked `recv` returns, and a recycled fd number lets the stale reader
            // consume another connection's bytes. `SHUT_RD`, not `SHUT_RDWR` — the write half has
            // to survive for the disarm frame queued below.
            Darwin.shutdown(conn, SHUT_RD)
            // On the write queue, so the close is ordered behind any frame already queued.
            writeQueue.async { Darwin.close(conn) }
        }
    }

    // MARK: - Loops

    private func acceptLoop(listener: Int32) {
        while !isStopped {
            let c = Darwin.accept(listener, nil, nil)
            if c < 0 {
                if isStopped { return }
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            noSigPipe(c)
            adopt(c)
            serve(c)
            finish(c)
            if isStopped { return }
        }
    }

    /// Connects and streams, retrying until stopped so a re-attached app's agent is picked up.
    private func dialLoop(port: Int32, retry: TimeInterval) {
        while !isStopped {
            let s = connectToLoopback(port: port)
            if s < 0 {
                Thread.sleep(forTimeInterval: retry)
                continue
            }
            adopt(s)
            serve(s)
            finish(s)
            if isStopped { return }
            Thread.sleep(forTimeInterval: retry)
        }
    }

    /// Reads newline-delimited JSON until EOF, handing complete lines to `onLine`.
    private func serve(_ fd: Int32) {
        var framer = AgentLineFramer()
        var chunk = [UInt8](repeating: 0, count: 16384)
        var sawBytes = false
        while !isStopped {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            if !sawBytes {
                sawBytes = true
                callbacks.onFirstBytes()
            }
            for line in framer.consume(chunk[0..<n]) { callbacks.onLine(line) }
        }
    }

    private func connectToLoopback(port: Int32) -> Int32 {
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 { Darwin.close(s); return -1 }
        noSigPipe(s)
        return s
    }

    /// Without this, writing to a socket the agent already closed raises SIGPIPE and kills Jaca.
    private func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private func adopt(_ fd: Int32) {
        withLock { connFD = fd }
        callbacks.onConnected()
    }

    private func finish(_ fd: Int32) {
        let wasCurrent: Bool = withLock {
            guard connFD == fd else { return false }
            connFD = -1
            return true
        }
        // Not current means `close()` already claimed this fd; a second close would hit a
        // descriptor number the OS may have handed out again.
        guard wasCurrent else { return }
        // Ordered behind any queued write, so a frame written during teardown still reaches send().
        writeQueue.async { Darwin.close(fd) }
        // A close we asked for isn't a disconnection anyone needs to react to.
        if !isStopped { callbacks.onDisconnected() }
    }

    private func sendNow(_ json: String) -> WriteOutcome {
        let fd: Int32 = withLock { connFD }
        guard fd >= 0 else { return .droppedNoConnection }
        let bytes = Array((json + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                // SO_NOSIGPIPE is set on every fd we adopt, so this returns EPIPE.
                Darwin.send(fd, buffer.baseAddress! + offset, bytes.count - offset, 0)
            }
            if written <= 0 { return .failed(errno: errno) }
            offset += written
        }
        return .written
    }

    // MARK: - Plumbing

    private var isStopped: Bool { withLock { stopped } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func startThread(_ body: @escaping @Sendable () -> Void) {
        let t = Thread { body() }
        t.name = "jaca-agent-\(name)"
        withLock { thread = t }
        t.start()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// Resumes a continuation exactly once, whichever of the drain and the timeout gets there first.
private final class OnceContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
