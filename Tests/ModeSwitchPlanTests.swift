import XCTest
@testable import Jaca

/// A mode switch keeps a tab whose source the new mode still offers, and sends every other tab
/// back to the chooser. It never starts a capture.
final class ModeSwitchPlanTests: XCTestCase {

    private static let android = Device(id: "emu", platform: .android, model: "Pixel", state: .connected)
    private static let companionOnly: Device = {
        var d = Device(id: "companion-1", platform: .android, model: "Phone", state: .connected)
        d.isCompanion = true
        d.companionID = "companion-1"
        return d
    }()
    private static let simulator = Device(id: "SIM", platform: .iosSimulator, model: "iPhone", state: .booted)

    private func capture(_ device: Device, _ sourceID: String?) -> ModeSwitchPlan.Capture {
        ModeSwitchPlan.Capture(id: UUID(), device: device, sourceID: sourceID)
    }

    func test_switchToMITM() {
        let androidAgent = capture(Self.android, "agent")
        let simulatorAgent = capture(Self.simulator, "agent")
        let browser = capture(.thisMac, "browser")
        let chooser = capture(Self.android, nil)
        let plan = ModeSwitchPlan.make(captures: [androidAgent, simulatorAgent, browser, chooser],
                                       to: MITMHTTPDebugging())
        XCTAssertEqual(plan[androidAgent.id], .stopAndReopenChooser)
        XCTAssertEqual(plan[simulatorAgent.id], .stopAndReopenChooser,
                       "under MITM the simulator offers mitm, not the agent")
        XCTAssertEqual(plan[browser.id], .keep)
        XCTAssertEqual(plan[chooser.id], .keep)
        XCTAssertEqual(plan.count, 4)
    }

    func test_switchToAgent() {
        let androidProxy = capture(Self.android, "mitm")
        let simulatorProxy = capture(Self.simulator, "mitm")
        let companion = capture(Self.companionOnly, "companion")
        let browser = capture(.thisMac, "browser")
        let plan = ModeSwitchPlan.make(captures: [androidProxy, simulatorProxy, companion, browser],
                                       to: AgentHTTPDebugging())
        XCTAssertEqual(plan[androidProxy.id], .stopAndReopenChooser)
        XCTAssertEqual(plan[simulatorProxy.id], .stopAndReopenChooser)
        XCTAssertEqual(plan[companion.id], .stopAndReopenChooser)
        XCTAssertEqual(plan[browser.id], .keep)
    }

    func test_aSourceTheModeStillOffersIsKept() {
        let agentTab = capture(Self.simulator, "agent")
        XCTAssertEqual(ModeSwitchPlan.make(captures: [agentTab], to: AgentHTTPDebugging())[agentTab.id], .keep)
        let mitmTab = capture(Self.android, "mitm")
        XCTAssertEqual(ModeSwitchPlan.make(captures: [mitmTab], to: MITMHTTPDebugging())[mitmTab.id], .keep)
    }

    /// A tab saved by an older build with the dropped `proxy` id must never start anything.
    func test_anUnknownSourceReopensTheChooser() {
        let old = capture(Self.android, "proxy")
        for strategy in [AgentHTTPDebugging(), MITMHTTPDebugging()] as [any HTTPDebuggingStrategy] {
            XCTAssertEqual(ModeSwitchPlan.make(captures: [old], to: strategy)[old.id], .stopAndReopenChooser)
        }
    }

    func test_noTabsMakesAnEmptyPlan() {
        XCTAssertTrue(ModeSwitchPlan.make(captures: [], to: MITMHTTPDebugging()).isEmpty)
    }
}
