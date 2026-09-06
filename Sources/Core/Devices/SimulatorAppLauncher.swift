import Foundation

/// The single owner of `simctl launch` for a simulator app.
///
/// Logs (under `--console-pty`) and Network (with the agent dylib injected) launch the same app
/// with different environments, and both pass `--terminate-running-process` — so whoever went
/// second evicted the first, permanently killing capture in the Logs-after-Network order. The
/// child environment lives here instead, and every launcher merges it.
actor SimulatorAppLauncher {
    static let shared = SimulatorAppLauncher()

    struct Key: Hashable, Sendable {
        let udid: String
        let bundleID: String
    }

    enum ClaimError: Error, Equatable {
        case alreadyClaimed(owner: String)
    }

    private struct Claim {
        let owner: String
        let environment: [String: String]
    }

    /// Claims and launch timestamps, behind a lock rather than in actor storage because
    /// `LogSource.start()` is synchronous and can't await — hence the `nonisolated` accessors.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var claims: [Key: Claim] = [:]
        var launches: [Key: Date] = [:]
    }

    private let state = State()

    // MARK: - Ownership

    /// Exclusive, for owners that inject into the app. A second Network tab on the same app must
    /// fail loudly — silently taking the claim leaves the first tab's agent dialling a dead port,
    /// stuck at "arming…". Re-claiming as the same owner refreshes the environment.
    func claim(_ key: Key, owner: String, childEnvironment: [String: String]) throws {
        state.lock.lock()
        defer { state.lock.unlock() }
        if let existing = state.claims[key], existing.owner != owner {
            throw ClaimError.alreadyClaimed(owner: existing.owner)
        }
        state.claims[key] = Claim(owner: owner, environment: childEnvironment)
    }

    /// Owner-checked, so a stopping session can't drop the claim a newer one took.
    ///
    /// `nonisolated` is load-bearing here: `restartForInterceptChange()` stops and starts with no
    /// suspension between, so a release deferred into the old teardown `Task` would lose to the
    /// new `claim` and the restart would die with "another Network tab is already capturing…".
    nonisolated func release(_ key: Key, owner: String) {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard state.claims[key]?.owner == owner else { return }
        state.claims[key] = nil
    }

    /// The `SIMCTL_CHILD_*` variables every launcher must pass for this app, or empty when nobody
    /// has claimed it. Merge into the launch environment via `SimulatorAgentLaunch.launchEnvironment`.
    nonisolated func environment(for key: Key) -> [String: String] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.claims[key]?.environment ?? [:]
    }

    // MARK: - Launching

    @discardableResult
    func launch(_ key: Key, terminateRunning: Bool) async -> Bool {
        stamp(key)
        let r = try? await CommandRunner.run(
            AppleToolchain.xcrun,
            SimulatorAgentLaunch.arguments(udid: key.udid, bundleID: key.bundleID,
                                           terminateRunning: terminateRunning),
            environment: SimulatorAgentLaunch.launchEnvironment(
                childEnvironment: environment(for: key))
        )
        return r?.exitCode == 0
    }

    /// Recorded by a subsystem that spawned the app itself — Logs needs its own PTY-attached
    /// process, so it can only report the launch, not delegate it.
    nonisolated func noteExternalLaunch(_ key: Key) { stamp(key) }

    func lastLaunch(_ key: Key) -> Date? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.launches[key]
    }

    /// Stamped *before* the spawn: its only reader is the re-attach grace window, which exists to
    /// suppress a second launch while one is in flight.
    private nonisolated func stamp(_ key: Key) {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.launches[key] = Date()
    }
}
