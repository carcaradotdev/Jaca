import Foundation
import Observation

/// The network inspection mode that `jacad` owns, mirrored in the app while the `network` daemon
/// area is enabled. It reads the retained topic `network.mode`, and `set(_:)` asks the daemon to
/// switch. The daemon persists the mode, so the app never writes it while this mirror runs.
@MainActor
@Observable
final class RemoteNetworkMode {
    /// The daemon's mode. nil until the daemon first answers.
    private(set) var mode: NetworkInspectionMode?
    /// True while the daemon stops captures and waits for their devices to be released.
    private(set) var switching = false

    /// Runs after each event that changes `mode`, with the new mode.
    @ObservationIgnored var onModeChange: ((NetworkInspectionMode) -> Void)?

    @ObservationIgnored private let daemon: DaemonConnector
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    init(daemon: DaemonConnector) {
        self.daemon = daemon
    }

    /// Starts to mirror the topic. Calling it again does nothing.
    func start() {
        guard watchTask == nil else { return }
        watchTask = daemon.watch([NetworkModeController.topic], onSubscribed: { [weak self] in
            await self?.fetch()
        }) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
    }

    /// Asks the daemon to switch to `target`, and returns when the switch is done.
    /// - Returns: `.reachedDaemon` when the daemon took the call, `.unreachable` when no daemon
    ///   answered (the caller may then switch in-process), `.failed` with the daemon's message
    ///   when it refused the call or the connection broke.
    @discardableResult
    func set(_ target: NetworkInspectionMode) async -> SetOutcome {
        do {
            let params = NetworkArea.SetModeParams(mode: target.wireName)
            guard try await daemon.request("network.setMode", params, as: RPCEmpty.self) != nil else {
                // No daemon owns the mode now, so the last mode it reported is stale. The app
                // reads its own applied mode until a daemon reports again.
                forget()
                return .unreachable
            }
            // Read the daemon's mode, not `target`: a newer switch from another client can
            // already be done, and the topic event for it can arrive before this response.
            await fetch()
            return .reachedDaemon
        } catch {
            DaemonLog.error("network.setMode failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    enum SetOutcome: Equatable { case reachedDaemon, unreachable, failed(String) }

    /// Drops the mirrored mode, for when no daemon answers. No `onModeChange`: nothing changed
    /// on the daemon's side.
    func forget() {
        mode = nil
        switching = false
    }

    private func handle(_ event: DaemonEventLine) {
        switch event.topic {
        case NetworkModeController.topic:
            guard let state = try? event.decode(NetworkModeController.State.self) else { return }
            apply(state)
        case "events.dropped":
            Task { [weak self] in await self?.fetch() }
        default:
            break
        }
    }

    private func fetch() async {
        guard let state = await daemon.call("network.mode", as: NetworkModeController.State.self) else { return }
        apply(state)
    }

    /// Applies one `network.mode` payload. Pure state change, so it is also the test entry point.
    func apply(_ state: NetworkModeController.State) {
        if switching != state.switching { switching = state.switching }
        // An unknown name comes from a newer daemon. Keep the last known mode.
        guard let next = NetworkInspectionMode(wireName: state.mode) else {
            DaemonLog.error("network.mode: unknown mode \(state.mode)")
            return
        }
        guard next != mode else { return }
        mode = next
        onModeChange?(next)
    }
}
