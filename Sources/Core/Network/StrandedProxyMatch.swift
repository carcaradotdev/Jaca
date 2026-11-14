import Foundation

/// Decides whether a device's global `http_proxy` is a proxy that Jaca left behind. The sidebar
/// shows its "Revert" banner only for such a value.
///
/// Jaca wrote two kinds of value:
/// - `<this Mac's LAN IP>:<port>` (`10.0.2.2` on an emulator), from builds before the device
///   proxy went through `adb reverse`.
/// - `127.0.0.1:<port>`, from the `mitm` device proxy. `DeviceProxyLedger` records each one.
enum StrandedProxyMatch {
    /// Whether `current` is a proxy value that Jaca wrote.
    /// - Parameters:
    ///   - current: the device's `http_proxy` value.
    ///   - hostAddress: the host the legacy proxy used for this device (`ProxyConfigurator.hostAddress`).
    ///   - ledgerValues: the ledger values for this device that no live capture holds.
    static func isOurs(current: String, hostAddress: String, ledgerValues: [String]) -> Bool {
        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ":0", value != "null" else { return false }
        if ledgerValues.contains(value) { return true }
        guard !hostAddress.isEmpty, !isLoopback(hostAddress) else { return false }
        return ProxyConfigurator.proxyHost(value) == hostAddress
    }

    /// The ledger entries of one device, split by whether a live capture holds them.
    struct LedgerSplit: Equatable, Sendable {
        /// Values that a running capture holds. The banner must not offer to revert these.
        var live: [String]
        /// Values that no running capture holds: the owner is dead, the entry is stale, or this
        /// process wrote it and no longer runs a source on its port.
        var stranded: [String]
    }

    /// Splits `entries` (one serial) into live and stranded values.
    /// - Parameters:
    ///   - ownPid: this process.
    ///   - armedPorts: the ports that a running device proxy source in this process holds on the serial.
    ///   - pidAlive: whether a pid runs.
    static func split(entries: [DeviceProxyLedger.Entry], ownPid: Int32, armedPorts: Set<Int>,
                      pidAlive: (Int32) -> Bool, now: Date) -> LedgerSplit {
        var result = LedgerSplit(live: [], stranded: [])
        for entry in entries {
            let held: Bool
            if entry.released {
                held = false
            } else if entry.pid == ownPid {
                held = armedPorts.contains(entry.port)
            } else {
                held = !DeviceProxyLedger.isAbandoned(entry: entry, pidAlive: pidAlive(entry.pid),
                                                      isOwnPid: false, now: now)
            }
            if held { result.live.append(entry.value) } else { result.stranded.append(entry.value) }
        }
        return result
    }

    /// A loopback host can't tell a legacy proxy apart from a live `adb reverse` proxy, so it
    /// never matches by host alone.
    static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
