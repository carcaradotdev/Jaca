import Foundation

/// The device teardowns that are still running, by serial.
///
/// Stopping a capture source reverts the device (proxy, reverse, divert) in a task. The next
/// source on the same device must wait for that task, or it arms on top of a device that is
/// half torn down. So a stop calls `track`, every adb precheck awaits `settle(serial:)`, and a
/// mode switch awaits `settleAll()` before it persists.
@MainActor
final class DeviceReleaseGate {
    static let shared = DeviceReleaseGate()

    private struct Tracked {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var tasks: [String: [Tracked]] = [:]

    init() {}

    /// Serials with a teardown still running.
    var pendingSerials: Set<String> { Set(tasks.keys) }

    func isPending(serial: String) -> Bool { !(tasks[serial] ?? []).isEmpty }

    /// Records `task` as a teardown of `serial`. The record goes away when the task finishes.
    func track(serial: String, task: Task<Void, Never>) {
        let id = UUID()
        tasks[serial, default: []].append(Tracked(id: id, task: task))
        Task { [weak self] in
            await task.value
            self?.forget(serial: serial, id: id)
        }
    }

    /// Returns when every teardown of `serial` tracked so far has finished. Returns at once when
    /// none is tracked.
    func settle(serial: String) async {
        // A teardown can track another one while it runs, so loop until nothing is left.
        while let pending = tasks[serial], !pending.isEmpty {
            for tracked in pending { await tracked.task.value }
            for tracked in pending { forget(serial: serial, id: tracked.id) }
        }
    }

    /// Returns when every tracked teardown on every device has finished.
    func settleAll() async {
        while let serial = tasks.first(where: { !$0.value.isEmpty })?.key {
            await settle(serial: serial)
        }
    }

    private func forget(serial: String, id: UUID) {
        guard var list = tasks[serial] else { return }
        list.removeAll { $0.id == id }
        tasks[serial] = list.isEmpty ? nil : list
    }
}
