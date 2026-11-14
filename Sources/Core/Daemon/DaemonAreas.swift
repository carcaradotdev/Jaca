import Foundation

/// Registers every area's methods and topics on a server. The one place that lists what the
/// daemon serves; `jacad serve` and the in-process test server both call it.
enum DaemonAreas {
    @MainActor
    static func install(on server: DaemonServer) {
        GradleArea.install(on: server)
        XcodeArea.install(on: server)
        ProjectsArea.install(on: server)
        DevicesArea.install(on: server)
        LogsArea.install(on: server)
        CloudArea.install(on: server)
        DatabaseArea.install(on: server)
        let network = installNetwork(on: server)
        // jacad owns the mode while it runs the network area, but the app owns it when that
        // area is off there, so follow the app's changes too.
        network.controller.observeExternalChanges()
        server.router.register("daemon.diagnostics", "What this daemon can reach: the app bundle, bundled agents, private frameworks.") { (_: RPCEmpty, _) in
            await Diagnostics.current()
        }
    }

    /// Installs the overrides and network areas and the mode controller. The override engine
    /// arms the captures and seeds rules from what they captured. Its services go to every
    /// capture in both modes: under MITM a rule fires on the device proxy too.
    @MainActor
    @discardableResult
    static func installNetwork(on server: DaemonServer, store: NetworkModeStore = .live,
                               settle: @escaping @MainActor () async -> Void = NetworkModeController.settleDevices)
        -> (captures: NetworkArea.Captures, controller: NetworkModeController) {
        let captures = NetworkArea.Captures(bus: server.bus, orphanTimeout: DaemonDefaults.orphanTimeout)
        let overrides = OverridesArea.install(on: server, captures: captures)
        let controller = NetworkModeController(captures: captures, bus: server.bus, store: store, settle: settle)
        NetworkArea.install(on: server, captures: captures, controller: controller,
                            interceptServices: interceptServices(from: overrides))
        return (captures, controller)
    }

    /// The override services for every new capture source. They do not depend on the mode.
    @MainActor
    static func interceptServices(from overrides: OverridesEngine) -> () -> InterceptServices? {
        { [weak overrides] in overrides?.services() }
    }

    struct Diagnostics: Codable, Sendable, Equatable {
        var appBundle: String
        var androidAgentBundled: Bool
        var iosSimulatorAgentBundled: Bool
        /// Apple's private LoggingSupport + MobileDevice load (physical iOS structured logs).
        var loggingSupportAvailable: Bool
        var adbPath: String?

        @MainActor
        static func current() -> Diagnostics {
            Diagnostics(
                appBundle: JacaBundle.app.bundlePath,
                androidAgentBundled: AgentArtifacts.isAvailable,
                iosSimulatorAgentBundled: AgentArtifacts.iosNetworkAgentAvailable,
                loggingSupportAvailable: JacaOSLogStream.isAvailable(),
                adbPath: AndroidToolchain.adbURL(override: JacaDefaults.shared.string(forKey: DevicesEngine.adbPathKey))?.path)
        }
    }
}
