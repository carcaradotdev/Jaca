import XCTest
@testable import Jaca

/// Who owns a target's coordinator, and whose arming state the UI shows.
///
/// `InterceptTarget` is `(deviceID, package)`, so it is *identical* across a stop/start of the
/// same app — and shared by two tabs opened on the same app. Every bug this suite pins down comes
/// from that reuse: a late teardown or a second tab writing over a registration that is still in
/// use, after which rule edits stop routing with the toolbar still reading as armed.
@MainActor
final class OverrideCoordinatorRegistryTests: XCTestCase {

    private final class SilentWriter: AgentControlWriter, @unchecked Sendable {
        func write(_ json: String) {}
        func flush(timeout: Duration) async {}
    }

    private final class NoopTunnel: DivertTunnel, @unchecked Sendable {
        func origin(forLocalPort port: Int) -> String { "http://stub:\(port)" }
        func open(localPort port: Int) async throws {}
        func close(localPort port: Int) async {}
        var needsTunnelLedger: Bool { false }
    }

    private let target = InterceptTarget(deviceID: "sim-1", package: "com.example.app")

    private func makeCoordinator(_ services: InterceptServices) -> DivertCoordinator {
        DivertCoordinator(transport: .iosSimulatorDivert(bundleID: "com.example.app"),
                          deviceID: target.deviceID,
                          appID: target.package,
                          capabilities: .desktopTerminated,
                          tunnel: NoopTunnel(),
                          writer: SilentWriter(),
                          onStateChange: { services.reportArming(target: self.target,
                                                                 coordinator: $0, state: $1) })
    }

    /// The registry hands work to the main actor, so let those hops land.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// Opening a second tab on the same simulator + app must not unregister the first.
    ///
    /// Both controllers register in `init`, *before* taking the launcher claim — so the newcomer
    /// registered over the live tab and only then discovered the app was already claimed. That
    /// orphaned the live coordinator: `republish()` could no longer reach it, so host and rule
    /// edits silently stopped routing while the tab still showed itself as armed.
    func test_aSecondTabDoesNotEvictTheLiveCoordinator() async {
        let model = OverridesModel()
        let services = model.services()
        let live = makeCoordinator(services)
        let newcomer = makeCoordinator(services)

        services.register(target: target, coordinator: live)
        await settle()
        services.reportArming(target: target, coordinator: live, state: .waitingForAgent)
        await settle()

        services.register(target: target, coordinator: newcomer)
        await settle()
        // The newcomer's claim fails, and it says so — that report must not reach the live tab.
        services.reportArming(target: target, coordinator: newcomer,
                              state: .failed("another Network tab is already capturing"))
        await settle()

        XCTAssertEqual(model.arming(for: target), .waitingForAgent,
                       "a second tab's failure overwrote the live tab's arming state")
    }

    /// …and closing that second tab must not take the live tab's registration with it.
    func test_closingTheSecondTabLeavesTheLiveTabRegistered() async {
        let model = OverridesModel()
        let services = model.services()
        let live = makeCoordinator(services)
        let newcomer = makeCoordinator(services)

        services.register(target: target, coordinator: live)
        services.register(target: target, coordinator: newcomer)
        await settle()
        services.reportArming(target: target, coordinator: live, state: .waitingForAgent)
        await settle()

        services.deregister(target: target, coordinator: newcomer)
        await settle()

        XCTAssertEqual(model.arming(for: target), .waitingForAgent,
                       "closing a rejected second tab cleared the live tab's arming state")
    }

    /// The restart case must still work: a coordinator that has already been stopped is replaced,
    /// because its deregistration is still in flight behind a flush.
    func test_aStoppedCoordinatorIsReplacedByTheRestart() async {
        let model = OverridesModel()
        let services = model.services()
        let outgoing = makeCoordinator(services)
        let incoming = makeCoordinator(services)

        services.register(target: target, coordinator: outgoing)
        await settle()
        await outgoing.stop()                       // the tab is restarting
        services.register(target: target, coordinator: incoming)
        await settle()

        services.reportArming(target: target, coordinator: incoming, state: .waitingForAgent)
        await settle()
        XCTAssertEqual(model.arming(for: target), .waitingForAgent,
                       "the restarted tab never took over the registration")

        // The outgoing coordinator's teardown lands last and must change nothing.
        services.reportArming(target: target, coordinator: outgoing, state: .idle)
        services.deregister(target: target, coordinator: outgoing)
        await settle()
        XCTAssertEqual(model.arming(for: target), .waitingForAgent,
                       "a late teardown clobbered the coordinator that replaced it")
    }
}
