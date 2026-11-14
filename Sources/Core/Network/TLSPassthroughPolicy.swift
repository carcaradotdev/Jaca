import Foundation

/// Decides which hosts the MITM proxy decrypts. A host that fails the TLS handshake
/// `threshold` times, with no successful handshake, rejects Jaca's certificate (a pinned app, or
/// a device without the CA). The proxy then relays that host's TLS raw, so the app keeps working.
/// A host that succeeded once is never passed through.
///
/// Thread-safe: `ProxyServer` reports handshakes from its event loops.
final class TLSPassthroughPolicy: @unchecked Sendable {
    enum Verdict: Sendable, Equatable {
        /// Nothing changed.
        case unchanged
        /// `host` reached the threshold just now and is relayed raw from now on.
        case passthroughAdded(String)
    }

    private struct HostState {
        var failures = 0
        var succeeded = false
    }

    let threshold: Int
    private let lock = NSLock()
    private var hosts: [String: HostState] = [:]
    private var passthrough: Set<String> = []
    private var succeededOnce = false

    init(threshold: Int = 2) {
        self.threshold = max(1, threshold)
    }

    /// Records one handshake for `host`. Returns `.passthroughAdded` once per host, the first
    /// time it reaches the threshold.
    @discardableResult
    func record(host: String, ok: Bool) -> Verdict {
        let key = Self.key(host)
        lock.lock(); defer { lock.unlock() }
        var state = hosts[key] ?? HostState()
        if ok {
            state.succeeded = true
            succeededOnce = true
        } else {
            state.failures += 1
        }
        hosts[key] = state
        guard !state.succeeded, state.failures >= threshold, !passthrough.contains(key) else {
            return .unchanged
        }
        passthrough.insert(key)
        return .passthroughAdded(host)
    }

    /// Whether the proxy should decrypt `host`. False once the host is passed through.
    func shouldDecrypt(_ host: String) -> Bool {
        let key = Self.key(host)
        lock.lock(); defer { lock.unlock() }
        return !passthrough.contains(key)
    }

    /// Whether any host completed a handshake: the client trusts the CA.
    var anySuccess: Bool {
        lock.lock(); defer { lock.unlock() }
        return succeededOnce
    }

    /// Forgets every host, so each one is decrypted again. Call it after the CA is installed on
    /// the device: a host that failed before the install failed because the device didn't
    /// trust the CA, not because it pins.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        hosts.removeAll()
        passthrough.removeAll()
        succeededOnce = false
    }

    /// The hosts relayed raw, sorted.
    var passthroughHosts: [String] {
        lock.lock(); defer { lock.unlock() }
        return passthrough.sorted()
    }

    private static func key(_ host: String) -> String { host.lowercased() }
}
