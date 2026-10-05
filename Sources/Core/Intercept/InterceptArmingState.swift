import Foundation

/// What every override surface renders about one armed transport.
///
/// One case per way overrides can be silently doing nothing — collapsing them into `.idle` made
/// "the agent never loaded", "the app lost its agent" and "nothing is wired here" read alike.
/// Lives in the seam rather than on the coordinator: transports publish it, the UI reads it.
enum InterceptArmingState: Sendable, Equatable {
    case idle
    /// Server bound and tunnel open, but the agent hasn't said hello — nothing on the device
    /// knows where to send anything yet.
    case waitingForAgent
    /// The agent's hello lacks `override/1` — a build older than this feature. It never reads its
    /// socket, so speaking to it would arm something that can't disarm itself.
    case agentTooOld
    /// iOS: the target app isn't running at all. Jaca never opens an app the user closed.
    case waitingForApp(appID: String)
    /// iOS: the app IS running, but without the agent in it (reopened outside Jaca).
    case detached(appID: String)
    case active(port: Int, hosts: Set<String>)
    case failed(String)

    /// How a simulator app's process presence reads as arming state (only probed while the
    /// agent's socket is down). Shared so the coordinator and the capture source — which publish
    /// it on the wired and unwired paths — can't name the same situation differently.
    static func forPresence(_ presence: SimulatorProcesses.Presence, appID: String) -> InterceptArmingState {
        switch presence {
        case .notBooted:
            return .failed("The simulator isn’t booted any more — start it and restart capture.")
        case .notRunning:
            return .waitingForApp(appID: appID)
        case .running:
            return .detached(appID: appID)
        }
    }
}
