import Foundation

/// Where the network inspection mode is stored, and how other processes learn that it changed.
/// Tests pass `memory`, so they never change the user's setting.
struct NetworkModeStore: Sendable {
    var read: @Sendable () -> NetworkInspectionMode
    var write: @Sendable (NetworkInspectionMode) -> Void
    /// Tells the other Jaca processes that the stored mode changed.
    var announce: @Sendable () -> Void

    /// The distributed notification posted after each switch. Its object is the pid of the
    /// process that switched, so that process can ignore its own post.
    static let changedNotification = Notification.Name("dev.srsouza.Jaca.networkInspectionModeChanged")

    static let live = NetworkModeStore(
        read: { FeatureFlags.networkInspectionMode },
        write: { FeatureFlags.networkInspectionMode = $0 },
        announce: {
            DistributedNotificationCenter.default().postNotificationName(
                changedNotification, object: String(ProcessInfo.processInfo.processIdentifier),
                userInfo: nil, deliverImmediately: true)
        })

    /// A store in memory, starting at `initial`. It announces nothing.
    static func memory(_ initial: NetworkInspectionMode) -> NetworkModeStore {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var value: NetworkInspectionMode
            init(_ value: NetworkInspectionMode) { self.value = value }
            func get() -> NetworkInspectionMode { lock.withLock { value } }
            func set(_ new: NetworkInspectionMode) { lock.withLock { value = new } }
        }
        let box = Box(initial)
        return NetworkModeStore(read: { box.get() }, write: { box.set($0) }, announce: {})
    }
}

/// The owner of the network inspection mode while jacad runs the network area.
///
/// A switch runs these steps, one switch at a time:
/// 1. Publish `network.mode` with `switching: true`.
/// 2. Stop each capture whose source the new mode does not offer, and show its chooser.
/// 3. Wait until every device teardown is done (`DeviceReleaseGate`, and the simulator proxy
///    hub, which releases the Mac system proxy).
/// 4. Persist the mode and announce it to the other processes.
/// 5. Publish `network.mode` again, and the state of every capture, whose offered sources
///    changed.
///
/// A switch never starts a capture. `network.select` and `network.open` wait for `idle()`.
@MainActor
final class NetworkModeController {
    enum Phase: String, Sendable { case ready, switching }

    /// The payload of `network.mode`, the method and the retained topic.
    struct State: Codable, Sendable, Equatable {
        /// The wire name: "agent" or "mitm".
        var mode: String
        var switching: Bool
    }

    static let topic = "network.mode"

    let captures: NetworkArea.Captures
    let bus: DaemonEventBus
    private let store: NetworkModeStore
    private let settle: @MainActor () async -> Void

    private(set) var mode: NetworkInspectionMode
    private(set) var phase: Phase = .ready
    /// The last queued switch. Each switch waits for the one before it.
    private var chain: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init(captures: NetworkArea.Captures, bus: DaemonEventBus, store: NetworkModeStore = .live,
         settle: @escaping @MainActor () async -> Void = NetworkModeController.settleDevices) {
        self.captures = captures
        self.bus = bus
        self.store = store
        self.settle = settle
        mode = store.read()
        captures.modeController = self
        publish()
    }

    /// Waits for the teardowns that stopped captures started.
    static func settleDevices() async {
        await DeviceReleaseGate.shared.settleAll()
        await SimulatorProxyHub.shared.settle()
    }

    var strategy: any HTTPDebuggingStrategy { HTTPDebuggingStrategies.strategy(for: mode) }
    var isSwitching: Bool { phase == .switching }
    var state: State { State(mode: mode.wireName, switching: isSwitching) }

    /// Switches to `target` and returns when the switch is done. Calls queue in order.
    func setMode(_ target: NetworkInspectionMode) async {
        await enqueue { await $0.runSwitch(to: target, persist: true) }
    }

    /// Returns when no switch is queued or running.
    func idle() async {
        while let current = chain {
            await current.value
            if chain == current { return }
        }
    }

    /// Follows a mode that another process stored (the app, when it owns the mode). Call once,
    /// in jacad only.
    func observeExternalChanges() {
        guard observer == nil else { return }
        let ownPid = String(ProcessInfo.processInfo.processIdentifier)
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NetworkModeStore.changedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? String) != ownPid else { return }
            Task { @MainActor [weak self] in await self?.adoptStoredMode() }
        }
    }

    /// Runs a switch to the stored mode, without storing or announcing it again.
    func adoptStoredMode() async {
        await enqueue { controller in
            await controller.runSwitch(to: controller.store.read(), persist: false)
        }
    }

    private func enqueue(_ work: @escaping @MainActor (NetworkModeController) async -> Void) async {
        let previous = chain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
        chain = task
        await task.value
    }

    private func runSwitch(to target: NetworkInspectionMode, persist: Bool) async {
        guard target != mode else { return }
        DaemonLog.info("network inspection mode: \(mode.wireName) -> \(target.wireName)")
        phase = .switching
        publish()

        let plan = ModeSwitchPlan.make(captures: captures.modeSwitchCaptures(),
                                       to: HTTPDebuggingStrategies.strategy(for: target))
        for (id, action) in plan where action == .stopAndReopenChooser {
            DaemonLog.info("network capture \(id): its source is not offered in \(target.wireName); stopping it")
            captures.sessions[id]?.engine.reopenChooser()
        }
        await settle()

        if persist {
            store.write(target)
            store.announce()
        }
        mode = target
        phase = .ready
        captures.refreshOffered()
        publish()
    }

    private func publish() {
        bus.publish(Self.topic, state, retain: true)
    }
}
