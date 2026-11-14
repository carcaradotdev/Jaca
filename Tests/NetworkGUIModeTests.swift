import XCTest
@testable import Jaca

/// The pure view decisions behind the GUI's inspection-mode changes: which chooser rows show,
/// the overrides idle line, and the iOS Simulator CA install result.
@MainActor
final class NetworkGUIModeTests: XCTestCase {

    private static let android = Device(id: "emulator-5554", platform: .android, model: "Pixel", state: .connected)
    private static let simulator = Device(id: "SIM-UDID", platform: .iosSimulator, model: "iPhone", state: .booted)
    private static let companionOnly: Device = {
        var d = Device(id: "companion-1", platform: .android, model: "Phone", state: .connected)
        d.isCompanion = true
        d.companionID = "companion-1"
        return d
    }()

    private func rows(_ device: Device, _ strategy: any HTTPDebuggingStrategy) -> CaptureChooserRows {
        CaptureChooserRows(sources: CaptureSourceRegistry.options(for: device, context: nil, strategy: strategy))
    }

    // MARK: - Chooser rows

    func test_agentMode_android_offersOnlyTheAgent() {
        let r = rows(Self.android, AgentHTTPDebugging())
        XCTAssertTrue(r.offersAgent)
        XCTAssertTrue(r.proxySources.isEmpty)
        XCTAssertFalse(r.hasCompanion)
    }

    func test_mitmMode_android_offersTheDeviceProxyRowAndHidesTheAgentPicker() {
        let r = rows(Self.android, MITMHTTPDebugging())
        XCTAssertFalse(r.offersAgent)
        XCTAssertEqual(r.proxySources.map(\.id), ["mitm"])
        XCTAssertEqual(r.proxySources.first?.title, "Device proxy")
        XCTAssertEqual(r.proxySources.first?.detail, InterceptTransportID.mitmProxy.captureDetail)
    }

    func test_mitmMode_simulator_offersTheDeviceProxyRow() {
        let r = rows(Self.simulator, MITMHTTPDebugging())
        XCTAssertFalse(r.offersAgent)
        XCTAssertEqual(r.proxySources.map(\.id), ["mitm"])
    }

    func test_mitmMode_companionOnly_offersOnlyTheCompanion() {
        let r = rows(Self.companionOnly, MITMHTTPDebugging())
        XCTAssertTrue(r.hasCompanion)
        XCTAssertTrue(r.proxySources.isEmpty)
        XCTAssertFalse(r.offersAgent)
    }

    // MARK: - Mobile-app hint

    func test_mobileAppHint_hiddenForAnAdbDevice() {
        XCTAssertFalse(CaptureChooserRows.showsMobileAppHint(
            companionCaptureEnabled: true, agentAvailable: false, isADBDevice: true,
            platform: .android, offersProxy: false))
    }

    func test_mobileAppHint_hiddenWhenAProxyRowShows() {
        XCTAssertFalse(CaptureChooserRows.showsMobileAppHint(
            companionCaptureEnabled: true, agentAvailable: false, isADBDevice: false,
            platform: .android, offersProxy: true))
    }

    func test_mobileAppHint_hiddenOnTheSimulator() {
        XCTAssertFalse(CaptureChooserRows.showsMobileAppHint(
            companionCaptureEnabled: true, agentAvailable: false, isADBDevice: false,
            platform: .iosSimulator, offersProxy: false))
    }

    func test_mobileAppHint_shownForAPhoneWithNoOtherWay() {
        XCTAssertTrue(CaptureChooserRows.showsMobileAppHint(
            companionCaptureEnabled: true, agentAvailable: false, isADBDevice: false,
            platform: .android, offersProxy: false))
        XCTAssertFalse(CaptureChooserRows.showsMobileAppHint(
            companionCaptureEnabled: false, agentAvailable: false, isADBDevice: false,
            platform: .android, offersProxy: false))
    }

    // MARK: - Overrides idle line

    func test_idleMessage_agentOnlyLineIsForTheCompanionOnly() {
        XCTAssertEqual(OverridesPopover.idleMessage(captureMode: .companion, hasRules: true),
                       "Overrides apply to in-process agent capture. Other transports will follow.")
        XCTAssertEqual(OverridesPopover.idleMessage(captureMode: .proxy, hasRules: true),
                       "Start capture to apply these overrides.")
        XCTAssertEqual(OverridesPopover.idleMessage(captureMode: .agent, hasRules: true),
                       "Start capture to apply these overrides.")
        XCTAssertEqual(OverridesPopover.idleMessage(captureMode: .proxy, hasRules: false), "")
    }

    // MARK: - Simulator CA step

    func test_simulatorStep_fromInstallResult() {
        XCTAssertEqual(SimulatorCAStep(NetworkArea.InstallCAResult(outcome: .installed, rebootAdvised: true)),
                       .installed)
        XCTAssertEqual(SimulatorCAStep(NetworkArea.InstallCAResult(outcome: .failed, message: "simctl failed")),
                       .failed("simctl failed"))
        XCTAssertNil(SimulatorCAStep(NetworkArea.InstallCAResult(outcome: .failed, message: nil)))
    }

    func test_simulatorStep_fromReboot() {
        XCTAssertEqual(SimulatorCAStep(reboot: .success(())), .rebooted)
        XCTAssertEqual(SimulatorCAStep(reboot: .failure(SimulatorCAError(message: "not booted"))),
                       .failed("not booted"))
        XCTAssertNil(SimulatorCAStep(reboot: .failure(SimulatorCAError(message: ""))))
    }
}
