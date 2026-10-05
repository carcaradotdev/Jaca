import XCTest
@testable import Jaca

/// The truth table behind "the inspector stops working when I close the app".
///
/// Every case here is a hazard that is close to impossible to reproduce by hand — you would have
/// to quit an app at exactly the right moment, or leave a session running while a launch is still
/// in flight. The policy is pure precisely so these can be asserted instead of hoped for.
final class SimulatorReattachPolicyTests: XCTestCase {

    private func decide(agentConnected: Bool = false,
                        presence: SimulatorProcesses.Presence = .running(pid: 42),
                        sinceLastLaunch: Duration? = .seconds(60),
                        grace: Duration = .seconds(8),
                        autoReattach: Bool = false,
                        stopped: Bool = false) -> SimulatorReattachDecision {
        SimulatorReattachPolicy.decide(agentConnected: agentConnected, presence: presence,
                                       sinceLastLaunch: sinceLastLaunch, grace: grace,
                                       autoReattach: autoReattach, stopped: stopped)
    }

    // MARK: - A live socket outranks everything

    /// The probe answer is seconds stale by construction (it costs a `simctl spawn`), so it must
    /// never be allowed to contradict a socket that is carrying traffic right now.
    func test_aConnectedAgentWinsOverEveryOtherFact() {
        for presence: SimulatorProcesses.Presence in [.notBooted, .notRunning, .running(pid: 7)] {
            for auto in [true, false] {
                for stopped in [true, false] {
                    XCTAssertEqual(decide(agentConnected: true, presence: presence,
                                          sinceLastLaunch: nil, autoReattach: auto, stopped: stopped),
                                   .doNothing(.agentConnected),
                                   "presence=\(presence) auto=\(auto) stopped=\(stopped)")
                }
            }
        }
    }

    // MARK: - Never open an app the user closed

    func test_anAppThatIsNotRunningIsNeverOpened() {
        XCTAssertEqual(decide(presence: .notRunning), .doNothing(.appNotRunning))
    }

    /// The dangerous variant: auto-reattach is ON. It still must not open a closed app — the
    /// preference removes a *click*, not the consent.
    func test_autoReattachStillDoesNotOpenAnAppTheUserClosed() {
        XCTAssertEqual(decide(presence: .notRunning, autoReattach: true),
                       .doNothing(.appNotRunning))
    }

    func test_aShutDownSimulatorIsLeftAlone() {
        XCTAssertEqual(decide(presence: .notBooted, autoReattach: true),
                       .doNothing(.simulatorNotBooted))
    }

    // MARK: - Launch grace

    /// The agent dials back a beat after the process exists, so our own launch looks exactly like
    /// a detached app for a second or two. Without the window the first probe would relaunch the
    /// app we had just launched — repeatedly.
    func test_aLaunchStillInFlightIsNotRelaunched() {
        XCTAssertEqual(decide(sinceLastLaunch: .seconds(3), autoReattach: true),
                       .doNothing(.launchInFlight))
        XCTAssertEqual(decide(sinceLastLaunch: .seconds(8), grace: .seconds(8), autoReattach: true),
                       .doNothing(.launchInFlight))
    }

    func test_pastTheGraceWindowTheLaunchNoLongerExcusesTheMissingAgent() {
        XCTAssertEqual(decide(sinceLastLaunch: .milliseconds(8_001), grace: .seconds(8)), .askUser)
    }

    /// Never launched by us at all — the user started the app themselves. There is no in-flight
    /// launch to wait for, so the answer is immediate.
    func test_neverHavingLaunchedItIsNotAGracePeriod() {
        XCTAssertEqual(decide(sinceLastLaunch: nil), .askUser)
    }

    // MARK: - Stopped sessions

    func test_aStoppedSessionNeverRelaunchesAnything() {
        XCTAssertEqual(decide(stopped: true), .doNothing(.stopped))
        XCTAssertEqual(decide(autoReattach: true, stopped: true), .doNothing(.stopped))
    }

    // MARK: - The actual decision

    func test_runningWithoutTheAgentAsksTheUserByDefault() {
        XCTAssertEqual(decide(presence: .running(pid: 91), autoReattach: false), .askUser)
    }

    func test_runningWithoutTheAgentRelaunchesOnlyWhenTheUserOptedIn() {
        XCTAssertEqual(decide(presence: .running(pid: 91), autoReattach: true),
                       .relaunchInstrumented)
    }

    /// The default is the feature: restarting somebody's app unasked was the POC's main UX debt.
    func test_theShippedDefaultIsToAsk() {
        XCTAssertFalse(FeatureFlags.simulatorAutoReattachEnabled,
                       "auto-reattach must ship off — asking is the default")
    }
}
