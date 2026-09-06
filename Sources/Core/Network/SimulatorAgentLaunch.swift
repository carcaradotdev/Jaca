import Foundation

/// Pure: everything `simctl launch` needs to inject the network agent, and nothing that touches
/// a process — because the detail that silently disables the feature is a string prefix. `simctl`
/// forwards only `SIMCTL_CHILD_*`, so a typo launches the app perfectly and captures nothing.
enum SimulatorAgentLaunch {
    /// `DYLD_INSERT_LIBRARIES` loads the agent into the app; `JACA_NET_PORT` tells it which
    /// loopback port to dial back on (the simulator shares the Mac's loopback).
    static func childEnvironment(agentDylib: URL, port: UInt16) -> [String: String] {
        [
            "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": agentDylib.path,
            "SIMCTL_CHILD_JACA_NET_PORT": String(port),
        ]
    }

    /// `--terminate-running-process` must precede the udid, or `simctl` merely foregrounds an
    /// already-running app: same process, no injection, no capture.
    static func arguments(udid: String, bundleID: String, terminateRunning: Bool) -> [String] {
        var args = ["simctl", "launch"]
        if terminateRunning { args.append("--terminate-running-process") }
        args.append(contentsOf: [udid, bundleID])
        return args
    }

    /// The environment for `xcrun` itself: child keys win, but the toolchain's own survives —
    /// notably `DEVELOPER_DIR`, without which `xcrun` finds no `simctl` under the CommandLineTools.
    /// Every simulator launch merges through here, so no subsystem can drop the injection.
    static func launchEnvironment(base: [String: String] = AppleToolchain.environment(),
                                  childEnvironment: [String: String]) -> [String: String] {
        base.merging(childEnvironment) { _, child in child }
    }
}
