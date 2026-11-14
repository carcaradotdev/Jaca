import Foundation

/// Decides which running captures a new capture replaces. The newest capture wins: the arbiter
/// never refuses a start, it only names what to stop first.
enum DeviceClaimArbiter {
    /// One running capture and what it holds.
    struct Running: Sendable, Hashable {
        let id: UUID
        let deviceID: String
        let claim: DeviceClaim?

        init(id: UUID, deviceID: String, claim: DeviceClaim?) {
            self.id = id
            self.deviceID = deviceID
            self.claim = claim
        }
    }

    /// The captures in `running` to stop before capture `id` starts with `claim` on `deviceID`.
    /// Pass only running captures. The rules apply per device:
    /// - A device-global claim (`.deviceProxy`, `.macSystemProxy`) stops every other claim.
    /// - `.appDivert(p)` stops `.appDivert(p)` and every device-global claim.
    /// - nil stops nothing, and a capture with a nil claim is never stopped.
    ///
    /// Captures on other devices never collide. So two simulators can share the Mac system proxy,
    /// which `MacSystemProxy` refcounts.
    static func decide(running: [Running], starting id: UUID, deviceID: String,
                       claim: DeviceClaim?) -> [UUID] {
        guard let claim else { return [] }
        return running.filter { other in
            guard other.id != id, other.deviceID == deviceID, let held = other.claim else { return false }
            return collides(claim, held)
        }
        .map(\.id)
    }

    /// Whether two claims on one device cannot run together.
    static func collides(_ a: DeviceClaim, _ b: DeviceClaim) -> Bool {
        if a.isDeviceGlobal || b.isDeviceGlobal { return true }
        return a == b
    }
}
