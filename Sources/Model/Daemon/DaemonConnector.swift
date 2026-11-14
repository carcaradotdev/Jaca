import Foundation
import Observation

/// An area that can run in the daemon instead of in-process.
enum DaemonArea: String, CaseIterable, Sendable {
    case gradle, xcode, projects, devices, logs, cloudLogging, network
}

/// The app's single connection to `jacad`: which areas use it, the live client, and the
/// connect / spawn / handshake / reconnect logic. Every area model reads this one owner.
///
/// Daemon mode is opt-in per area while the daemon is experimental. Enable it with
///
///     defaults write dev.srsouza.Jaca daemonAreas -array gradle xcode projects
///
/// or `JACA_DAEMON_AREAS=gradle,xcode` (`all` enables every area) in the environment. An area
/// whose daemon can't be reached keeps working in-process, so turning this on never leaves a
/// screen empty.
@MainActor
@Observable
final class DaemonConnector {
    static let shared = DaemonConnector()

    enum State: Equatable {
        case idle
        case connecting
        case connected(pid: Int32)
        case unavailable(String)
    }

    private(set) var state: State = .idle
    let enabledAreas: Set<DaemonArea>

    @ObservationIgnored private var client: DaemonClient?
    @ObservationIgnored private var connecting: Task<DaemonClient?, Never>?
    @ObservationIgnored private var lastFailure: ContinuousClock.Instant?
    @ObservationIgnored private let paths: DaemonPaths
    @ObservationIgnored private let executable: URL?

    static let areasKey = "daemonAreas"

    init(paths: DaemonPaths = .default,
         executable: URL? = DaemonLauncher.bundledExecutable,
         enabledAreas: Set<DaemonArea>? = nil) {
        self.paths = paths
        self.executable = executable
        self.enabledAreas = enabledAreas ?? Self.configuredAreas()
    }

    func isEnabled(_ area: DaemonArea) -> Bool { enabledAreas.contains(area) }

    /// Where network capture (and so the override runtime) runs: in `jacad` when the `network`
    /// area is enabled, in the app otherwise. The inspection mode does not move it. Companion-only
    /// devices still capture in the app (`AppModel.makeNetworkSession`), because the companion
    /// links live there. There is one override engine and one writer of the rule library.
    func networkRunsInDaemon() -> Bool {
        isEnabled(.network)
    }

    /// The areas turned on by `JACA_DAEMON_AREAS` (wins when set) or the `daemonAreas` default.
    static func configuredAreas(environment: [String: String] = ProcessInfo.processInfo.environment,
                                defaults: UserDefaults = .standard) -> Set<DaemonArea> {
        let names: [String]
        if let env = environment["JACA_DAEMON_AREAS"] {
            names = env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            names = defaults.stringArray(forKey: areasKey) ?? []
        }
        if names.contains("all") { return Set(DaemonArea.allCases) }
        return Set(names.compactMap(DaemonArea.init(rawValue:)))
    }

    // MARK: - Connection

    /// A connected, handshaken client, or nil when the daemon can't be reached (the caller
    /// then works in-process). After a failure, retries are held off for a few seconds so a
    /// dead daemon doesn't add a spawn attempt to every call.
    func connectedClient() async -> DaemonClient? {
        if let client, !client.isClosed { return client }
        if let connecting { return await connecting.value }
        if let lastFailure, ContinuousClock.now - lastFailure < .seconds(5) { return nil }

        state = .connecting
        let task = Task { await self.establish() }
        connecting = task
        let result = await task.value
        connecting = nil
        return result
    }

    private func establish() async -> DaemonClient? {
        do {
            var (client, hello) = try await connectAndGreet()
            if let expected = expectedBuildID, DaemonBuild.isOlder(hello.buildID, than: expected) {
                // A daemon from an older build is still running (the app was rebuilt or
                // updated under it). Replace it with the one this app ships.
                DaemonLog.info("daemon build \(hello.buildID) is older than \(expected); restarting it")
                try await replace(client)
                (client, hello) = try await connectAndGreet()
            }
            self.client = client
            lastFailure = nil
            state = .connected(pid: hello.pid)
            client.onClose { [weak self] in
                Task { @MainActor in self?.connectionClosed(client) }
            }
            return client
        } catch {
            DaemonLog.error("daemon unavailable: \(error.localizedDescription)")
            lastFailure = .now
            state = .unavailable(error.localizedDescription)
            return nil
        }
    }

    /// Connects (spawning if needed) and says hello. A daemon speaking another protocol
    /// version is from another build: it is replaced once.
    private func connectAndGreet() async throws -> (DaemonClient, DaemonServer.HelloResult) {
        let client = try await DaemonLauncher.connect(paths: paths, executable: executable)
        do {
            return (client, try await hello(client))
        } catch let error as RPCError where error == .disconnected {
            // Accepted just as the daemon stopped for idleness: it's exiting, so spawn the next.
            DaemonLog.info("daemon closed the connection during hello; retrying")
            try await waitForExit()
            let fresh = try await DaemonLauncher.connect(paths: paths, executable: executable)
            return (fresh, try await hello(fresh))
        } catch let error as RPCError where error.code == RPCError.versionMismatchCode {
            DaemonLog.info("daemon protocol differs: \(error.message); restarting it")
            try await replace(client)
            let fresh = try await DaemonLauncher.connect(paths: paths, executable: executable)
            return (fresh, try await hello(fresh))
        }
    }

    private func hello(_ client: DaemonClient) async throws -> DaemonServer.HelloResult {
        // Bounded: a daemon that accepts but never answers must not hang every area's connect.
        try await client.call(
            "hello", DaemonServer.HelloParams(protocolVersion: DaemonProtocol.version, client: "Jaca.app"),
            timeout: DaemonDefaults.shortCallTimeout)
    }

    /// Asks a running daemon to exit and waits for it to release the socket.
    private func replace(_ client: DaemonClient) async throws {
        let _: RPCEmpty? = try? await client.call("daemon.shutdown")
        client.close()
        try await waitForExit()
    }

    private var expectedBuildID: String? {
        guard let executable, FileManager.default.fileExists(atPath: executable.path) else { return nil }
        return DaemonBuild.id(forExecutable: executable)
    }

    /// Waits for the old daemon to release its socket after `daemon.shutdown`.
    private func waitForExit() async throws {
        for _ in 0..<30 {
            if !FileManager.default.fileExists(atPath: paths.socket.path) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        DaemonLog.error("the old daemon still holds \(paths.socket.path) after 3s; connecting anyway")
    }

    private func connectionClosed(_ closed: DaemonClient) {
        guard client === closed else { return }
        client = nil
        state = .idle
    }

    // MARK: - Calls

    /// Calls `method` on the daemon. Returns nil when the daemon is unreachable or the call
    /// failed, after logging why. `request` tells the two apart.
    func call<P: Encodable & Sendable, R: Decodable & Sendable>(_ method: String, _ params: P, as type: R.Type = R.self) async -> R? {
        guard let client = await connectedClient() else { return nil }
        do {
            return try await client.call(method, params, as: type)
        } catch {
            DaemonLog.error("\(method) failed: \(error.localizedDescription)")
            return nil
        }
    }

    func call<R: Decodable & Sendable>(_ method: String, as type: R.Type = R.self) async -> R? {
        await call(method, RPCEmpty(), as: type)
    }

    /// For mutations: nil only when the daemon is unreachable (the caller may then do the work
    /// in-process); a call that reached the daemon and failed throws instead, so the work is
    /// never done twice.
    func request<P: Encodable & Sendable, R: Decodable & Sendable>(_ method: String, _ params: P, as type: R.Type = R.self) async throws -> R? {
        guard let client = await connectedClient() else { return nil }
        do {
            return try await client.call(method, params, as: type)
        } catch let error as RPCError where error.code == RPCError.disconnectedCode {
            DaemonLog.error("\(method): daemon disconnected mid-call")
            throw error
        }
    }

    /// Delivers each event on `topics` to `handler` until the returned task is cancelled,
    /// resubscribing after a reconnect. `onSubscribed` runs after every (re)subscription (open
    /// or backfill state that the daemon may have lost); `onUnavailable` runs each time the
    /// daemon can't be reached, so the caller can do the work in-process meanwhile.
    func watch(_ topics: [String],
               onUnavailable: @escaping @MainActor () -> Void = {},
               onSubscribed: @escaping @MainActor () async -> Void = {},
               _ handler: @escaping @MainActor (DaemonEventLine) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let client = await self.connectedClient(),
                   let stream = try? await client.subscribe(topics) {
                    // Subscribed before any catch-up work, so nothing published meanwhile is missed.
                    await onSubscribed()
                    for await event in stream {
                        if Task.isCancelled { return }
                        handler(event)
                    }
                } else {
                    onUnavailable()
                }
                // Disconnected or unreachable: back off, then try again.
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
