import XCTest
@testable import Jaca

/// The source table per device and mode, and the claim and transport of each source.
final class HTTPDebuggingStrategyTests: XCTestCase {

    private static let android = Device(id: "emulator-5554", platform: .android, model: "Pixel", state: .connected)
    private static let companionOnly: Device = {
        var d = Device(id: "companion-1", platform: .android, model: "Phone", state: .connected)
        d.isCompanion = true
        d.companionID = "companion-1"
        return d
    }()
    /// An adb phone that also runs the companion app. It is not companion-only.
    private static let adbWithCompanion: Device = {
        var d = Device(id: "R5CT", platform: .android, model: "Galaxy", state: .connected)
        d.companionID = "companion-2"
        return d
    }()
    private static let simulator = Device(id: "SIM-UDID", platform: .iosSimulator, model: "iPhone", state: .booted)
    private static let iosDevice = Device(id: "00008110", platform: .iosDevice, model: "iPhone", state: .connected)
    private static let mac = Device.thisMac

    private let agent = AgentHTTPDebugging()
    private let mitm = MITMHTTPDebugging()

    // MARK: - Source table

    func test_agentSources() {
        XCTAssertEqual(agent.sourceIDs(for: Self.android), ["agent"])
        XCTAssertEqual(agent.sourceIDs(for: Self.adbWithCompanion), ["agent"])
        XCTAssertEqual(agent.sourceIDs(for: Self.companionOnly), [])
        XCTAssertEqual(agent.sourceIDs(for: Self.simulator), ["agent"])
        XCTAssertEqual(agent.sourceIDs(for: Self.mac), ["browser"])
        XCTAssertEqual(agent.sourceIDs(for: Self.iosDevice), [])
    }

    func test_mitmSources() {
        XCTAssertEqual(mitm.sourceIDs(for: Self.android), ["mitm"])
        XCTAssertEqual(mitm.sourceIDs(for: Self.adbWithCompanion), ["mitm"],
                       "an adb phone gets only the device proxy, even with the companion app")
        XCTAssertEqual(mitm.sourceIDs(for: Self.companionOnly), ["companion"])
        XCTAssertEqual(mitm.sourceIDs(for: Self.simulator), ["mitm"])
        XCTAssertEqual(mitm.sourceIDs(for: Self.mac), ["browser"])
        XCTAssertEqual(mitm.sourceIDs(for: Self.iosDevice), [])
    }

    func test_companionIsOfferedOnlyOnACompanionOnlyDevice() {
        for device in [Self.android, Self.adbWithCompanion, Self.simulator, Self.mac, Self.iosDevice] {
            XCTAssertFalse(mitm.sourceIDs(for: device).contains("companion"), device.id)
            XCTAssertFalse(agent.sourceIDs(for: device).contains("companion"), device.id)
        }
        XCTAssertTrue(mitm.sourceIDs(for: Self.companionOnly).contains("companion"))
    }

    func test_sourceIDsMatchTheRegistry() {
        XCTAssertEqual(HTTPDebuggingSourceID.agent, "agent")
        XCTAssertEqual(HTTPDebuggingSourceID.mitm, "mitm")
        XCTAssertEqual(HTTPDebuggingSourceID.browser, "browser")
        XCTAssertEqual(HTTPDebuggingSourceID.companion, "companion")
    }

    // MARK: - Mode and reattach

    func test_modeAndReattach() {
        XCTAssertEqual(agent.mode, .agentHTTPSDebugging)
        XCTAssertEqual(mitm.mode, .mitmHTTPSDebugging)
        XCTAssertTrue(agent.supportsAgentReattach)
        XCTAssertFalse(mitm.supportsAgentReattach)
    }

    func test_strategyForMode() {
        XCTAssertEqual(HTTPDebuggingStrategies.strategy(for: .agentHTTPSDebugging).mode, .agentHTTPSDebugging)
        XCTAssertEqual(HTTPDebuggingStrategies.strategy(for: .mitmHTTPSDebugging).mode, .mitmHTTPSDebugging)
    }

    // MARK: - Claim

    func test_claims() {
        for strategy in [agent, mitm] as [any HTTPDebuggingStrategy] {
            XCTAssertEqual(strategy.claim(device: Self.android, sourceID: "agent", package: "com.app"),
                           .appDivert(package: "com.app"))
            XCTAssertEqual(strategy.claim(device: Self.simulator, sourceID: "agent", package: "com.app.ios"),
                           .appDivert(package: "com.app.ios"))
            XCTAssertNil(strategy.claim(device: Self.android, sourceID: "agent", package: nil),
                         "an agent with no app chosen diverts nothing")
            XCTAssertNil(strategy.claim(device: Self.android, sourceID: "agent", package: ""))
            XCTAssertEqual(strategy.claim(device: Self.android, sourceID: "mitm", package: nil), .deviceProxy)
            XCTAssertEqual(strategy.claim(device: Self.simulator, sourceID: "mitm", package: nil), .macSystemProxy)
            XCTAssertNil(strategy.claim(device: Self.mac, sourceID: "browser", package: nil))
            XCTAssertNil(strategy.claim(device: Self.companionOnly, sourceID: "companion", package: nil))
            XCTAssertNil(strategy.claim(device: Self.android, sourceID: "proxy", package: nil),
                         "an id saved by an older build holds nothing")
        }
    }

    // MARK: - Transport

    func test_transports() {
        for strategy in [agent, mitm] as [any HTTPDebuggingStrategy] {
            XCTAssertEqual(strategy.transport(device: Self.android, sourceID: "agent", package: "com.app"),
                           .androidAgent(package: "com.app"))
            XCTAssertEqual(strategy.transport(device: Self.simulator, sourceID: "agent", package: "com.app.ios"),
                           .iosSimulatorAgent(bundleID: "com.app.ios"))
            XCTAssertEqual(strategy.transport(device: Self.android, sourceID: "mitm", package: nil), .mitmProxy)
            XCTAssertEqual(strategy.transport(device: Self.simulator, sourceID: "mitm", package: nil), .mitmProxy)
            XCTAssertEqual(strategy.transport(device: Self.mac, sourceID: "browser", package: nil), .mitmProxy)
            XCTAssertEqual(strategy.transport(device: Self.companionOnly, sourceID: "companion", package: nil),
                           .companionMetadata)
            XCTAssertEqual(strategy.transport(device: Self.android, sourceID: "proxy", package: nil),
                           .companionMetadata, "an unknown source applies no rule")
        }
    }
}
