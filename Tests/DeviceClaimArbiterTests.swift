import XCTest
@testable import Jaca

/// Which running captures a new capture stops. The newest capture wins.
final class DeviceClaimArbiterTests: XCTestCase {

    private let new = UUID()

    private func decide(_ running: [DeviceClaimArbiter.Running], device: String = "emu",
                        claim: DeviceClaim?) -> Set<UUID> {
        Set(DeviceClaimArbiter.decide(running: running, starting: new, deviceID: device, claim: claim))
    }

    private func running(_ claim: DeviceClaim?, on device: String = "emu") -> DeviceClaimArbiter.Running {
        DeviceClaimArbiter.Running(id: UUID(), deviceID: device, claim: claim)
    }

    // MARK: - Ported from NetworkArea.capturesToStop

    func test_sameAppOnTheSameDeviceIsReplaced() {
        let old = running(.appDivert(package: "com.app"))
        XCTAssertEqual(decide([old], claim: .appDivert(package: "com.app")), [old.id])
    }

    func test_otherAppOnTheSameDeviceKeepsRunning() {
        let other = running(.appDivert(package: "com.other"))
        XCTAssertEqual(decide([other], claim: .appDivert(package: "com.app")), [])
    }

    func test_sameAppOnAnotherDeviceKeepsRunning() {
        let elsewhere = running(.appDivert(package: "com.app"), on: "R5CT")
        XCTAssertEqual(decide([elsewhere], claim: .appDivert(package: "com.app")), [])
    }

    func test_aCaptureWithNoAppReplacesNothing() {
        let old = running(.appDivert(package: "com.app"))
        let proxy = running(.deviceProxy)
        XCTAssertEqual(decide([old, proxy], claim: nil), [])
    }

    func test_theStartingCaptureIsNeverStopped() {
        let me = DeviceClaimArbiter.Running(id: new, deviceID: "emu", claim: .appDivert(package: "com.app"))
        XCTAssertEqual(decide([me], claim: .appDivert(package: "com.app")), [])
        let meProxy = DeviceClaimArbiter.Running(id: new, deviceID: "emu", claim: .deviceProxy)
        XCTAssertEqual(decide([meProxy], claim: .deviceProxy), [])
    }

    // MARK: - Device proxy

    func test_deviceProxyStopsEveryClaimOnItsDevice() {
        let a = running(.appDivert(package: "com.a"))
        let b = running(.appDivert(package: "com.b"))
        let proxy = running(.deviceProxy)
        let none = running(nil)
        let elsewhere = running(.appDivert(package: "com.a"), on: "R5CT")
        XCTAssertEqual(decide([a, b, proxy, none, elsewhere], claim: .deviceProxy), [a.id, b.id, proxy.id])
    }

    func test_appDivertStopsADeviceProxy() {
        let proxy = running(.deviceProxy)
        let other = running(.appDivert(package: "com.other"))
        XCTAssertEqual(decide([proxy, other], claim: .appDivert(package: "com.app")), [proxy.id])
    }

    func test_deviceProxyOnAnotherDeviceKeepsRunning() {
        let proxy = running(.deviceProxy, on: "R5CT")
        XCTAssertEqual(decide([proxy], claim: .deviceProxy), [])
        XCTAssertEqual(decide([proxy], claim: .appDivert(package: "com.app")), [])
    }

    func test_aCaptureWithNoClaimIsNeverStopped() {
        let browser = running(nil)
        XCTAssertEqual(decide([browser], claim: .deviceProxy), [])
        XCTAssertEqual(decide([browser], claim: .appDivert(package: "com.app")), [])
    }

    // MARK: - Mac system proxy (simulator mitm)

    /// `MacSystemProxy` refcounts the system proxy, so simulators share it.
    func test_simulatorsOnDifferentDevicesShareTheMacSystemProxy() {
        let simA = running(.macSystemProxy, on: "SIM-A")
        XCTAssertEqual(decide([simA], device: "SIM-B", claim: .macSystemProxy), [])
    }

    func test_macSystemProxyOnTheSameSimulatorIsReplaced() {
        let old = running(.macSystemProxy, on: "SIM-A")
        XCTAssertEqual(decide([old], device: "SIM-A", claim: .macSystemProxy), [old.id])
    }

    func test_macSystemProxyAndAgentOnOneSimulatorCollide() {
        let agent = running(.appDivert(package: "com.app.ios"), on: "SIM-A")
        XCTAssertEqual(decide([agent], device: "SIM-A", claim: .macSystemProxy), [agent.id])
        let proxy = running(.macSystemProxy, on: "SIM-A")
        XCTAssertEqual(decide([proxy], device: "SIM-A", claim: .appDivert(package: "com.app.ios")), [proxy.id])
    }

    func test_macSystemProxyLeavesOtherSimulatorsAgents() {
        let agentB = running(.appDivert(package: "com.app.ios"), on: "SIM-B")
        XCTAssertEqual(decide([agentB], device: "SIM-A", claim: .macSystemProxy), [])
    }

    func test_collisionTable() {
        let p = DeviceClaim.appDivert(package: "p"), q = DeviceClaim.appDivert(package: "q")
        XCTAssertTrue(DeviceClaimArbiter.collides(p, p))
        XCTAssertFalse(DeviceClaimArbiter.collides(p, q))
        XCTAssertTrue(DeviceClaimArbiter.collides(p, .deviceProxy))
        XCTAssertTrue(DeviceClaimArbiter.collides(.deviceProxy, p))
        XCTAssertTrue(DeviceClaimArbiter.collides(.deviceProxy, .deviceProxy))
        XCTAssertTrue(DeviceClaimArbiter.collides(.macSystemProxy, .macSystemProxy))
        XCTAssertTrue(DeviceClaimArbiter.collides(.macSystemProxy, p))
    }
}
