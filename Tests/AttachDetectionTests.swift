import XCTest
@testable import Jaca

/// Losing the injected agent stops **capture**, not just overrides. These tests pin the two places
/// that used to make that invisible: the presence→state mapping, and the fact that a session with
/// no override services still reports a detached agent.
@MainActor
final class AttachDetectionTests: XCTestCase {

    private func makeSession(overrides: OverridesModel? = nil) throws -> NetworkSession {
        let ca = try XCTUnwrap(try? CertificateAuthority())
        let device = Device(id: "SIM-UDID", platform: .iosSimulator, model: "iPhone 17", state: .connected)
        return NetworkSession(device: device, ca: ca, adbURL: nil, overrides: overrides)
    }

    // MARK: - The presence mapping

    /// Shared by the coordinator (overrides on) and the capture source (overrides off), so both
    /// paths must name the same situation identically — they render through the same UI.
    func test_presenceMapsToTheSameStateForBothPaths() {
        XCTAssertEqual(InterceptArmingState.forPresence(.running(pid: 42), appID: "com.example.App"),
                       .detached(appID: "com.example.App"))
        XCTAssertEqual(InterceptArmingState.forPresence(.notRunning, appID: "com.example.App"),
                       .waitingForApp(appID: "com.example.App"))
        guard case .failed = InterceptArmingState.forPresence(.notBooted, appID: "com.example.App") else {
            return XCTFail("a shut-down simulator must read as a failure, not as a missing app")
        }
    }

    // MARK: - The overrides-off configuration

    /// The regression this exists for: `FeatureFlags.responseOverridesEnabled` defaults to **off**,
    /// so `divert` is nil and nothing writes `armings[target]`. Routing detach through the
    /// coordinator therefore meant that in the DEFAULT configuration a tab whose app had been
    /// reopened outside Jaca showed a green running dot, no banner, and no way to re-attach —
    /// exactly the "armed but silently doing nothing" failure this layer exists to break.
    func test_detachIsReportedWithNoOverrideServicesWired() throws {
        let session = try makeSession(overrides: nil)
        XCTAssertEqual(session.armingState, .idle)

        session.capture(didChangeAttach: .detached(appID: "com.example.App"))

        XCTAssertEqual(session.attachState, .detached(appID: "com.example.App"))
        XCTAssertEqual(session.armingState, .detached(appID: "com.example.App"),
                       "with overrides off the session must still surface a lost agent")
    }

    /// A recovered session has to drop the banner, or it stays up for the rest of the tab's life.
    func test_theAgentComingBackClearsTheDetachedState() throws {
        let session = try makeSession(overrides: nil)
        session.capture(didChangeAttach: .waitingForApp(appID: "com.example.App"))
        XCTAssertEqual(session.armingState, .waitingForApp(appID: "com.example.App"))

        session.capture(didChangeAttach: .idle)

        XCTAssertEqual(session.armingState, .idle)
    }

    /// The banner is gated on a *running* source, so a stopped tab can never show it — a stale
    /// "relaunch to re-attach" on a tab the user already stopped is noise, not a warning.
    func test_aStoppedSessionNeverShowsTheBanner() throws {
        let session = try makeSession(overrides: nil)
        session.capture(didChangeAttach: .detached(appID: "com.example.App"))
        XCTAssertFalse(session.showsAttachBanner)
    }
}

/// `simctl launch` is claimed per (udid, bundleID), and the ordering of claim vs release is what
/// makes a stop-then-start restart work.
final class SimulatorLaunchClaimTests: XCTestCase {

    private func key(_ suffix: String) -> SimulatorAppLauncher.Key {
        .init(udid: "UDID-\(suffix)", bundleID: "com.example.App")
    }

    /// A second Network tab on the same app must fail loudly rather than silently stealing the
    /// claim, which would leave the first tab's agent dialling a port nobody listens on.
    func test_aSecondOwnerCannotStealALiveClaim() async throws {
        let launcher = SimulatorAppLauncher()
        let k = key("steal")
        try await launcher.claim(k, owner: "tab-A", childEnvironment: [:])

        do {
            try await launcher.claim(k, owner: "tab-B", childEnvironment: [:])
            XCTFail("a second owner took a claim that was already held")
        } catch let error as SimulatorAppLauncher.ClaimError {
            XCTAssertEqual(error, .alreadyClaimed(owner: "tab-A"))
        }
    }

    /// The restart path: `NetworkSession.restartForInterceptChange()` stops and starts in one
    /// straight line with no suspension between, so the release has to be ordered *before* the
    /// next claim. It is `nonisolated` for exactly this reason — when it was `await`ed from the
    /// old controller's teardown Task, the new controller's claim always won the race and the
    /// restart died with "another Network tab is already capturing…" while the tab still
    /// reported itself as running.
    func test_aReleasedClaimCanBeRetakenImmediatelyByANewOwner() async throws {
        let launcher = SimulatorAppLauncher()
        let k = key("restart")
        try await launcher.claim(k, owner: "tab-A", childEnvironment: ["A": "1"])

        launcher.release(k, owner: "tab-A")          // synchronous, on the caller's thread
        try await launcher.claim(k, owner: "tab-B", childEnvironment: ["B": "1"])

        XCTAssertEqual(launcher.environment(for: k), ["B": "1"])
    }

    /// Owner-checked, so a slow teardown can't drop the claim a newer session already took.
    func test_releasingAsTheWrongOwnerIsANoOp() async throws {
        let launcher = SimulatorAppLauncher()
        let k = key("owner")
        try await launcher.claim(k, owner: "tab-A", childEnvironment: ["A": "1"])

        launcher.release(k, owner: "tab-B")

        XCTAssertEqual(launcher.environment(for: k), ["A": "1"])
    }
}
