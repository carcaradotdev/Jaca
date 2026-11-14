import XCTest
@testable import Jaca

/// The app's mirror of the mode that jacad owns, and the in-process CA install a tab runs when
/// the daemon is off. No daemon runs: the connector points at a missing directory.
@MainActor
final class RemoteNetworkModeTests: XCTestCase {
    private func connector() -> DaemonConnector {
        DaemonConnector(paths: DaemonPaths(directory: URL(fileURLWithPath: "/nonexistent")),
                        executable: nil, enabledAreas: [.network])
    }

    // MARK: - RemoteNetworkMode

    func test_apply_setsTheModeAndTellsTheAppOnce() {
        let mirror = RemoteNetworkMode(daemon: connector())
        var changes: [NetworkInspectionMode] = []
        mirror.onModeChange = { changes.append($0) }

        mirror.apply(.init(mode: "mitm", switching: false))
        mirror.apply(.init(mode: "mitm", switching: false))

        XCTAssertEqual(mirror.mode, .mitmHTTPSDebugging)
        XCTAssertEqual(changes, [.mitmHTTPSDebugging])
    }

    func test_apply_switchingFollowsThePayload() {
        let mirror = RemoteNetworkMode(daemon: connector())
        mirror.apply(.init(mode: "agent", switching: true))
        XCTAssertTrue(mirror.switching)
        mirror.apply(.init(mode: "mitm", switching: false))
        XCTAssertFalse(mirror.switching)
        XCTAssertEqual(mirror.mode, .mitmHTTPSDebugging)
    }

    func test_apply_anUnknownModeKeepsTheLastOne() {
        let mirror = RemoteNetworkMode(daemon: connector())
        mirror.apply(.init(mode: "agent", switching: false))
        mirror.apply(.init(mode: "future", switching: false))
        XCTAssertEqual(mirror.mode, .agentHTTPSDebugging)
    }

    func test_set_withNoDaemon_isUnreachable() async {
        let mirror = RemoteNetworkMode(daemon: connector())
        let outcome = await mirror.set(.mitmHTTPSDebugging)
        XCTAssertEqual(outcome, .unreachable)
        XCTAssertNil(mirror.mode, "a mode the daemon never confirmed is not mirrored")
    }

    /// jacad exits after it reported a mode. The app then switches in-process, so the mirror
    /// must stop answering with the daemon's old mode.
    func test_set_withNoDaemon_forgetsTheLastReportedMode() async {
        let mirror = RemoteNetworkMode(daemon: connector())
        mirror.apply(.init(mode: "agent", switching: true))
        let outcome = await mirror.set(.mitmHTTPSDebugging)
        XCTAssertEqual(outcome, .unreachable)
        XCTAssertNil(mirror.mode)
        XCTAssertFalse(mirror.switching)
    }

    // MARK: - In-process CA install

    private func withCA(_ body: (CertificateAuthority) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteNetworkModeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(try CertificateAuthority(directory: dir))
    }

    private func fakeInstall(rooted: HeadlessCAOutcome = .installed, pushed: Bool = true,
                             simulator: Result<Void, SimulatorCAError> = .success(())) -> NetworkCAInstall {
        NetworkCAInstall(androidRooted: { _, _, _ in rooted },
                         androidPush: { _, _, _ in pushed },
                         simulatorInstall: { _, _ in simulator },
                         simulatorReboot: { _ in .success(()) })
    }

    private let android = Device(id: "emulator-5554", platform: .android, model: "Pixel", state: .connected)
    private let simulator = Device(id: "SIM-1", platform: .iosSimulator, model: "iPhone", state: .booted)

    func test_installLocally_rootedAndroid_installs() async throws {
        try await withCA { ca in
            let result = await NetworkSession.installCALocally(
                device: android, ca: ca, adbURL: URL(fileURLWithPath: "/adb"), install: fakeInstall())
            XCTAssertEqual(result, .init(outcome: .installed))
        }
    }

    func test_installLocally_notRooted_pushesAndNeedsTheUser() async throws {
        try await withCA { ca in
            let result = await NetworkSession.installCALocally(
                device: android, ca: ca, adbURL: URL(fileURLWithPath: "/adb"),
                install: fakeInstall(rooted: .notRooted, pushed: true))
            XCTAssertEqual(result.outcome, .needsUser)
        }
    }

    func test_installLocally_withoutAdb_fails() async throws {
        try await withCA { ca in
            let result = await NetworkSession.installCALocally(device: android, ca: ca, adbURL: nil,
                                                               install: fakeInstall())
            XCTAssertEqual(result, .init(outcome: .failed, message: NetworkArea.adbMissingMessage))
        }
    }

    func test_installLocally_simulator_advisesAReboot() async throws {
        try await withCA { ca in
            let result = await NetworkSession.installCALocally(device: simulator, ca: ca, adbURL: nil,
                                                               install: fakeInstall())
            XCTAssertEqual(result, .init(outcome: .installed, rebootAdvised: true))
        }
    }

    func test_installLocally_thisMac_isUnsupported() async throws {
        try await withCA { ca in
            let mac = Device(id: "mac", platform: .mac, model: "Mac", state: .connected)
            let result = await NetworkSession.installCALocally(device: mac, ca: ca, adbURL: nil,
                                                               install: fakeInstall())
            XCTAssertEqual(result.outcome, .failed)
        }
    }
}
