import Foundation

/// What to do about an app that is (or isn't) running without the Jaca agent in it.
enum SimulatorReattachDecision: Equatable {
    case doNothing(Reason)
    /// The user opted into automatic re-attachment. Still announced in the status line —
    /// restarting somebody's app is never silent.
    case relaunchInstrumented
    /// The default: publish `.detached` and let the user press the banner's one button.
    case askUser

    enum Reason: Equatable {
        case agentConnected
        case appNotRunning
        case launchInFlight
        case stopped
        case simulatorNotBooted
    }
}

/// Pure, because the dangerous rows — relaunching an app the user quit, or one still starting —
/// are exactly the ones that can't be reproduced by hand.
enum SimulatorReattachPolicy {

    /// - Parameters:
    ///   - agentConnected: whether the agent's socket is live *right now*.
    ///   - presence: what `launchctl list` says about the target process.
    ///   - sinceLastLaunch: how long ago we (or Logs) launched this app. `nil` = never.
    ///   - grace: how long a launch is assumed to still be in flight.
    ///   - autoReattach: the user's opt-in preference.
    ///   - stopped: the owning capture session has been torn down.
    static func decide(agentConnected: Bool,
                       presence: SimulatorProcesses.Presence,
                       sinceLastLaunch: Duration?,
                       grace: Duration = .seconds(8),
                       autoReattach: Bool,
                       stopped: Bool) -> SimulatorReattachDecision {
        // A live socket outranks a stale probe: the process answer costs a `simctl spawn` and is
        // seconds old, while the socket is what capture actually flows over.
        if agentConnected { return .doNothing(.agentConnected) }

        // The tab is gone: relaunching an app for a session that no longer exists is pure damage.
        if stopped { return .doNothing(.stopped) }

        switch presence {
        case .notBooted:
            // Booting a simulator on the user's behalf is a much bigger act than re-attaching.
            return .doNothing(.simulatorNotBooted)
        case .notRunning:
            // **Jaca never opens an app the user closed.** Quitting is a deliberate act, and a
            // tool that reopens it minutes later reads as malware from the user's side.
            return .doNothing(.appNotRunning)
        case .running:
            break
        }

        // A launch we started is still in flight: the agent dials back a beat after the process
        // exists, so without this window the first probe would relaunch the app.
        if let sinceLastLaunch, sinceLastLaunch <= grace { return .doNothing(.launchInFlight) }

        // Running, no agent, not our own launch: the user reopened it outside Jaca.
        return autoReattach ? .relaunchInstrumented : .askUser
    }
}
