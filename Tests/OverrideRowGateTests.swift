import XCTest
@testable import Jaca

/// The row gate decides whether "Override response…" is offered on a captured row. It lived as a
/// `private func` on `NetworkSessionView` with an okhttp3-only rule, so it had no test at all —
/// and the day the iOS agent starts reporting `httpStack: "urlsession"`, that rule would disable
/// the menu item on **every single iOS row** with a sentence about okhttp3.
///
/// These are the cases that keep both platforms honest.
final class OverrideRowGateTests: XCTestCase {

    private func reason(transport: InterceptTransportID,
                        arming: InterceptArmingState = .active(port: 1, hosts: ["a.com"]),
                        hasRunningSource: Bool = true,
                        overridesAvailable: Bool = true,
                        featureEnabled: Bool = true,
                        url: String = "https://a.com/v1/users",
                        httpStack: String? = nil) -> String? {
        OverrideRowGate.unavailableReason(transport: transport,
                                          arming: arming,
                                          hasRunningSource: hasRunningSource,
                                          overridesAvailable: overridesAvailable,
                                          featureEnabled: featureEnabled,
                                          url: url,
                                          httpStack: httpStack)
    }

    // MARK: - The landmine

    /// The iOS agent hooks `URLSession`, so every row it reports is divertible by construction.
    /// `httpStack` is an Android concept and must not be consulted here at all.
    func test_iosSimulatorRowIsSeedable_evenThoughItsStackIsNotOkhttp3() {
        XCTAssertNil(reason(transport: .iosSimulatorDivert(bundleID: "com.example.App"),
                            httpStack: "urlsession"))
    }

    func test_iosSimulatorRowWithNoReportedStackIsSeedable() {
        XCTAssertNil(reason(transport: .iosSimulatorDivert(bundleID: "com.example.App"),
                            httpStack: nil))
    }

    /// The one arming state that genuinely means "this row's app can't receive an override until
    /// the user acts", so it names the app and says what to do.
    func test_iosSimulatorDetachedExplainsTheRelaunch_namingTheApp() {
        let message = reason(transport: .iosSimulatorDivert(bundleID: "com.example.App"),
                             arming: .detached(appID: "com.example.App"))
        XCTAssertEqual(message,
                       "com.example.App is running without the Jaca agent — relaunch it to resume.")
    }

    // MARK: - Android behaviour must stay meaningful

    /// Keeps `OverrideAuthoringTests.test_missingHttpStackDecodesAsNilNotEmpty` load-bearing: an
    /// agent built before `httpStack` existed reports nothing, and *unknown* must never block.
    func test_androidRowWithUnknownStackIsSeedable() {
        XCTAssertNil(reason(transport: .agentDivert(package: "com.example"), httpStack: nil))
    }

    func test_androidOkhttp3RowIsSeedable() {
        XCTAssertNil(reason(transport: .agentDivert(package: "com.example"), httpStack: "okhttp3"))
    }

    func test_androidNonOkhttpRowIsBlocked_withTheStacksHumanName() {
        let message = reason(transport: .agentDivert(package: "com.example"),
                             httpStack: "urlconnection")
        XCTAssertEqual(message,
                       "This request came from HttpURLConnection, not okhttp3 — Jaca can't divert it.")
    }

    // MARK: - The other transports never say "stack"

    func test_companionRowExplainsCompanionCapture_neverAStack() {
        let message = reason(transport: .companionMetadata, httpStack: "urlsession")
        XCTAssertEqual(message,
                       "Overrides apply to in-process agent capture. Companion capture will follow.")
        XCTAssertFalse(message!.contains("okhttp"))
    }

    /// The proxy terminates the connection and never learns which client stack sent the request,
    /// so a stack sentence there would be a guess presented as a fact.
    func test_proxyRowIsSeedable_whateverStackTheRowCarries() {
        for stack in ["urlsession", "okhttp3", "urlconnection", nil] {
            XCTAssertNil(reason(transport: .mitmProxy, httpStack: stack),
                         "proxy rows must never be gated on an agent-reported stack")
        }
    }

    // MARK: - Reasons that precede the transport

    func test_overridesUnavailableAndFeatureOffHaveTheirOwnMessages() {
        XCTAssertEqual(reason(transport: .mitmProxy, overridesAvailable: false),
                       "Response overrides aren't available.")
        XCTAssertEqual(reason(transport: .mitmProxy, featureEnabled: false),
                       "Turn on Response overrides in Settings first.")
    }

    /// Companion flow-metadata rows are `"host:port"` — there is no method, path or body to
    /// override, so the row is refused before any transport question is asked.
    func test_flowMetadataRowIsNotAnHTTPRequest() {
        XCTAssertEqual(reason(transport: .companionMetadata, url: "api.example.com:443"),
                       "This row is flow metadata, not an HTTP request.")
    }

    // MARK: - Nothing running

    /// Arming states describe a *live* session. With capture stopped there is nothing to relaunch
    /// and nothing to wait for, and authoring a rule from an already-captured row is exactly what
    /// the user should be able to do.
    func test_stoppedCaptureDoesNotSurfaceAnArmingReason() {
        XCTAssertNil(reason(transport: .iosSimulatorDivert(bundleID: "com.example.App"),
                            arming: .detached(appID: "com.example.App"),
                            hasRunningSource: false))
    }

    /// …but a row that could never be diverted stays refused whether or not capture is running:
    /// that fact is about the row, not about the session.
    func test_stoppedCaptureStillBlocksANonDivertibleAndroidRow() {
        XCTAssertNotNil(reason(transport: .agentDivert(package: "com.example"),
                               arming: .idle,
                               hasRunningSource: false,
                               httpStack: "urlconnection"))
    }

    // MARK: - Transport copy

    /// On the Simulator the Mac *is* the app's network, so the Android caution ("origins reachable
    /// only from the device won't work") is false — and scaring people off a working action is
    /// worse than saying nothing.
    func test_simulatorHasNoOriginExplainerAndNamesNoTunnel() {
        let ios = InterceptTransportID.iosSimulatorDivert(bundleID: "com.example.App")
        XCTAssertTrue(ios.originExplainer.isEmpty)
        XCTAssertFalse(ios.divertScopeHelp.lowercased().contains("tunnel"))
        XCTAssertFalse(ios.divertScopeHelp.lowercased().contains("adb"))
        XCTAssertEqual(ios.portLabel(port: 41234), "127.0.0.1:41234")
    }

    /// The Android device only reaches that port because `adb reverse` put it there; printing a
    /// bare "127.0.0.1:P" sends people hunting for a listener the phone can't see.
    func test_androidNamesItsTunnelAndItsPort() {
        let android = InterceptTransportID.agentDivert(package: "com.example")
        XCTAssertEqual(android.portLabel(port: 41234), "via adb reverse :41234")
        XCTAssertTrue(android.divertScopeHelp.contains("adb reverse"))
        XCTAssertFalse(android.originExplainer.isEmpty)
    }

    /// `NSURLProtocol` never sees `WKWebView`, background `URLSession` configurations or raw
    /// sockets. The chooser must not promise coverage the transport doesn't have.
    func test_simulatorCaptureDetailDoesNotPromiseCallStacks() {
        let ios = InterceptTransportID.iosSimulatorDivert(bundleID: "com.example.App")
        XCTAssertFalse(ios.captureDetail.contains("call stack"))
        XCTAssertTrue(ios.captureDetail.contains("URLSession"))
        XCTAssertFalse(InterceptTransportID.agentChooserDetail.contains("debuggable app in-process — no proxy or CA, with call stacks"))
    }

    /// Every surface reads the same sentence for the same state; `.idle` and `.active` are the
    /// two that are not blocking anything.
    func test_onlyTheSilentlyDoingNothingStatesCarryAMessage() {
        XCTAssertNil(InterceptArmingState.idle.blockedMessage)
        XCTAssertNil(InterceptArmingState.active(port: 1, hosts: []).blockedMessage)
        for state: InterceptArmingState in [.waitingForAgent, .agentTooOld,
                                            .waitingForApp(appID: "com.example.App"),
                                            .detached(appID: "com.example.App"),
                                            .failed("boom")] {
            XCTAssertFalse(state.blockedMessage?.isEmpty ?? true,
                           "every blocking state needs wording: \(state)")
        }
    }
}
