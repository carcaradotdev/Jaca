import XCTest
@testable import Jaca

/// The Mac system proxy changes a setting of the whole Mac, so every test runs against a fake
/// `networksetup` and a temporary lease directory.
final class MacSystemProxyTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSystemProxyTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeProxy(_ mac: FakeNetworkSetup, ownPid: Int32 = 100,
                           alive: @escaping @Sendable (Int32) -> Bool = { _ in false }) -> MacSystemProxy {
        MacSystemProxy(directory: directory, run: mac.runner, isOwnerAlive: alive,
                       ownPid: ownPid, armsTerminationHook: false)
    }

    // MARK: - Parsers

    func test_enabledServices_skipsHeaderAndDisabledServices() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        USB 10/100/1000 LAN
        *Bluetooth PAN
        Thunderbolt Bridge
        Wi-Fi

        """
        XCTAssertEqual(NetworkSetupParser.enabledServices(output),
                       ["USB 10/100/1000 LAN", "Thunderbolt Bridge", "Wi-Fi"])
    }

    func test_proxySetting_parsesAllFields() {
        let output = """
        Enabled: Yes
        Server: proxy.corp.example
        Port: 8080
        Authenticated Proxy Enabled: 1
        """
        XCTAssertEqual(NetworkSetupParser.proxySetting(output),
                       MacProxySetting(enabled: true, server: "proxy.corp.example", port: 8080, authenticated: true))
    }

    func test_proxySetting_emptyServerIsOff() {
        let output = "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n"
        XCTAssertEqual(NetworkSetupParser.proxySetting(output), .off)
    }

    func test_proxySetting_errorOutputIsNil() {
        XCTAssertNil(NetworkSetupParser.proxySetting("** Error: Unable to find item in network database.\n"))
    }

    func test_errorText_dropsErrorPrefix() {
        let result = CommandRunner.Result(exitCode: 8, stdout: "** Error: Unable to find item in network database.\n", stderr: "")
        XCTAssertTrue(NetworkSetupParser.failed(result))
        XCTAssertEqual(NetworkSetupParser.errorText(result), "Unable to find item in network database.")
    }

    func test_restoreCommands() {
        let enabled = MacProxySetting(enabled: true, server: "corp", port: 8080)
        XCTAssertEqual(MacSystemProxyPlan.restoreCommands(service: "Wi-Fi", kind: .web, previous: enabled, port: 9090),
                       [["-setwebproxy", "Wi-Fi", "corp", "8080"]])

        let disabledWithServer = MacProxySetting(enabled: false, server: "corp", port: 8080)
        XCTAssertEqual(MacSystemProxyPlan.restoreCommands(service: "Wi-Fi", kind: .secureWeb,
                                                          previous: disabledWithServer, port: 9090),
                       [["-setsecurewebproxy", "Wi-Fi", "corp", "8080"],
                        ["-setsecurewebproxystate", "Wi-Fi", "off"]])

        XCTAssertEqual(MacSystemProxyPlan.restoreCommands(service: "Wi-Fi", kind: .web, previous: .off, port: 9090),
                       [["-setwebproxystate", "Wi-Fi", "off"]])
    }

    /// A previous setting that already pointed at our port is a leftover of a crash, so restore
    /// turns it off instead of leaving the Mac proxied to a dead listener.
    func test_restoreCommands_leftoverOfOurOwnProxyIsTurnedOff() {
        let leftover = MacProxySetting(enabled: true, server: "127.0.0.1", port: 9090)
        XCTAssertEqual(MacSystemProxyPlan.restoreCommands(service: "Wi-Fi", kind: .web, previous: leftover, port: 9090),
                       [["-setwebproxy", "Wi-Fi", "127.0.0.1", "9090"], ["-setwebproxystate", "Wi-Fi", "off"]])
    }

    // MARK: - Lease decode

    func test_lease_decodesOldSchemaWithMissingFields() throws {
        let json = """
        {"ownerPid": 4242, "port": 9090,
         "services": [{"name": "Wi-Fi", "web": {"enabled": true, "server": "corp", "port": 8080}},
                      {"web": {"enabled": true}},
                      {"name": "Ethernet"}]}
        """
        let lease = try MacSystemProxyLeaseFile.makeDecoder().decode(MacSystemProxyLease.self, from: Data(json.utf8))
        XCTAssertEqual(lease.ownerPid, 4242)
        XCTAssertEqual(lease.port, 9090)
        // The record without a name is skipped; the others load with defaults.
        XCTAssertEqual(lease.services.map(\.name), ["Wi-Fi", "Ethernet"])
        XCTAssertEqual(lease.services[0].web, MacProxySetting(enabled: true, server: "corp", port: 8080, authenticated: false))
        XCTAssertEqual(lease.services[0].secureWeb, .off)
        XCTAssertEqual(lease.services[1].web, .off)
    }

    func test_lease_roundTrips() {
        let lease = MacSystemProxyLease(ownerPid: 7, port: 9090, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                        services: [.init(name: "Wi-Fi", web: .off, secureWeb: .off)])
        XCTAssertTrue(MacSystemProxyLeaseFile.save(lease, to: directory))
        XCTAssertEqual(MacSystemProxyLeaseFile.load(from: directory), lease)
    }

    // MARK: - Acquire and release

    func test_acquire_setsEveryEnabledServiceAndWritesLeaseFirst() async throws {
        let mac = FakeNetworkSetup(services: ["Wi-Fi": .off, "Ethernet": .off], disabled: ["Bluetooth PAN"])
        let leaseURL = MacSystemProxyLeaseFile.url(in: directory)
        mac.onFirstSet = { XCTAssertTrue(FileManager.default.fileExists(atPath: leaseURL.path), "lease before change") }
        let proxy = makeProxy(mac)

        let result = await proxy.acquire(port: 9090)
        XCTAssertNoThrow(try result.get())

        let ours = MacProxySetting(enabled: true, server: "127.0.0.1", port: 9090)
        for name in ["Wi-Fi", "Ethernet"] {
            XCTAssertEqual(mac.setting(name, .web), ours)
            XCTAssertEqual(mac.setting(name, .secureWeb), ours)
        }
        XCTAssertFalse(mac.calls.contains { $0.contains("Bluetooth PAN") })

        let lease = try XCTUnwrap(MacSystemProxyLeaseFile.load(from: directory))
        XCTAssertEqual(lease.ownerPid, 100)
        XCTAssertEqual(lease.port, 9090)
        XCTAssertEqual(Set(lease.services.map(\.name)), ["Wi-Fi", "Ethernet"])
    }

    func test_refcount_secondReleaseRestores() async {
        let corp = MacProxySetting(enabled: true, server: "corp", port: 8080)
        let mac = FakeNetworkSetup(services: ["Wi-Fi": corp])
        let proxy = makeProxy(mac)

        _ = await proxy.acquire(port: 9090)
        _ = await proxy.acquire(port: 9090)
        let setsAfterAcquires = mac.setCount

        await proxy.release()
        XCTAssertEqual(mac.setting("Wi-Fi", .web).server, "127.0.0.1", "one holder is left")
        XCTAssertEqual(mac.setCount, setsAfterAcquires, "a second acquire and the first release change nothing")

        await proxy.release()
        XCTAssertEqual(mac.setting("Wi-Fi", .web), corp)
        XCTAssertEqual(mac.setting("Wi-Fi", .secureWeb), corp)
        XCTAssertNil(MacSystemProxyLeaseFile.load(from: directory))
        let holders = await proxy.holders
        XCTAssertEqual(holders, 0)
    }

    func test_acquire_otherPortWhileHeldFails() async {
        let mac = FakeNetworkSetup(services: ["Wi-Fi": .off])
        let proxy = makeProxy(mac)
        _ = await proxy.acquire(port: 9090)
        let second = await proxy.acquire(port: 9091)
        guard case .failure = second else { return XCTFail("expected failure") }
        XCTAssertEqual(mac.setting("Wi-Fi", .web).port, 9090)
    }

    func test_release_compareAndRestore_keepsAUserChange() async {
        let mac = FakeNetworkSetup(services: ["Wi-Fi": .off])
        let proxy = makeProxy(mac)
        _ = await proxy.acquire(port: 9090)

        // The user points the web proxy elsewhere while the capture runs.
        let users = MacProxySetting(enabled: true, server: "charles.local", port: 8888)
        mac.set("Wi-Fi", .web, users)

        await proxy.release()
        XCTAssertEqual(mac.setting("Wi-Fi", .web), users, "a setting the user changed is left alone")
        XCTAssertFalse(mac.setting("Wi-Fi", .secureWeb).enabled, "our secure web proxy is restored")
    }

    func test_acquire_networksetupFailureReturnsStderrAndRollsBack() async {
        let mac = FakeNetworkSetup(services: ["Wi-Fi": .off, "Ethernet": .off])
        mac.failSetFor = "Wi-Fi"
        let proxy = makeProxy(mac)

        let result = await proxy.acquire(port: 9090)
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(error.message.contains("requires admin"), error.message)
        XCTAssertFalse(mac.setting("Ethernet", .web).enabled, "a service changed before the failure is restored")
        XCTAssertNil(MacSystemProxyLeaseFile.load(from: directory))
        let holders = await proxy.holders
        XCTAssertEqual(holders, 0)
    }

    func test_acquire_noEnabledServiceFails() async {
        let mac = FakeNetworkSetup(services: [:], disabled: ["Wi-Fi"])
        let result = await makeProxy(mac).acquire(port: 9090)
        guard case .failure = result else { return XCTFail("expected failure") }
        XCTAssertNil(MacSystemProxyLeaseFile.load(from: directory))
    }

    // MARK: - Orphans

    func test_reconcileOrphan_restoresALeaseOfADeadOwner() async {
        let ours = MacProxySetting(enabled: true, server: "127.0.0.1", port: 9090)
        let corp = MacProxySetting(enabled: true, server: "corp", port: 8080)
        let mac = FakeNetworkSetup(services: ["Wi-Fi": ours])
        let lease = MacSystemProxyLease(ownerPid: 4242, port: 9090, createdAt: Date(),
                                        services: [.init(name: "Wi-Fi", web: corp, secureWeb: .off)])
        XCTAssertTrue(MacSystemProxyLeaseFile.save(lease, to: directory))

        let reverted = await makeProxy(mac, alive: { _ in false }).reconcileOrphan()
        XCTAssertEqual(reverted, 2)
        XCTAssertEqual(mac.setting("Wi-Fi", .web), corp)
        XCTAssertFalse(mac.setting("Wi-Fi", .secureWeb).enabled)
        XCTAssertNil(MacSystemProxyLeaseFile.load(from: directory))
    }

    func test_reconcileOrphan_leavesALeaseOfALiveOwner() async {
        let ours = MacProxySetting(enabled: true, server: "127.0.0.1", port: 9090)
        let mac = FakeNetworkSetup(services: ["Wi-Fi": ours])
        let lease = MacSystemProxyLease(ownerPid: 4242, port: 9090, createdAt: Date(),
                                        services: [.init(name: "Wi-Fi", web: .off, secureWeb: .off)])
        XCTAssertTrue(MacSystemProxyLeaseFile.save(lease, to: directory))

        let proxy = makeProxy(mac, alive: { $0 == 4242 })
        let reverted = await proxy.reconcileOrphan()
        XCTAssertEqual(reverted, 0)
        XCTAssertEqual(mac.setting("Wi-Fi", .web), ours)
        XCTAssertNotNil(MacSystemProxyLeaseFile.load(from: directory))

        let acquire = await proxy.acquire(port: 9090)
        guard case .failure = acquire else { return XCTFail("another live process holds the proxy") }
    }

    func test_reconcileOrphan_withoutLeaseDoesNothing() async {
        let mac = FakeNetworkSetup(services: ["Wi-Fi": .off])
        let reverted = await makeProxy(mac).reconcileOrphan()
        XCTAssertEqual(reverted, 0)
        XCTAssertTrue(mac.calls.isEmpty)
    }

    // MARK: - Synchronous exit path

    func test_syncRevert_restoresOnlyOurOwnLease() {
        let ours = MacProxySetting(enabled: true, server: "127.0.0.1", port: 9090)
        let mac = FakeNetworkSetup(services: ["Wi-Fi": ours])
        let lease = MacSystemProxyLease(ownerPid: 100, port: 9090, createdAt: Date(),
                                        services: [.init(name: "Wi-Fi", web: .off, secureWeb: .off)])
        XCTAssertTrue(MacSystemProxyLeaseFile.save(lease, to: directory))

        MacSystemProxyCleanup.revert(directory: directory, ownPid: 200, run: mac.handle)
        XCTAssertEqual(mac.setting("Wi-Fi", .web), ours, "another process's lease is not ours to restore")

        MacSystemProxyCleanup.revert(directory: directory, ownPid: 100, run: mac.handle)
        XCTAssertFalse(mac.setting("Wi-Fi", .web).enabled)
        XCTAssertNil(MacSystemProxyLeaseFile.load(from: directory))
    }
}

/// An in-memory `networksetup` that records every call.
final class FakeNetworkSetup: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: [String: [MacProxyKind: MacProxySetting]] = [:]
    private var order: [String]
    private let disabled: [String]
    private(set) var calls: [[String]] = []
    private(set) var setCount = 0
    var failSetFor: String?
    var onFirstSet: (() -> Void)?

    init(services: [String: MacProxySetting], disabled: [String] = []) {
        order = services.keys.sorted()
        self.disabled = disabled
        for (name, setting) in services {
            settings[name] = [.web: setting, .secureWeb: setting]
        }
    }

    var runner: MacSystemProxy.Runner {
        { [self] arguments in handle(arguments) }
    }

    func setting(_ service: String, _ kind: MacProxyKind) -> MacProxySetting {
        lock.lock(); defer { lock.unlock() }
        return settings[service]?[kind] ?? .off
    }

    func set(_ service: String, _ kind: MacProxyKind, _ value: MacProxySetting) {
        lock.lock(); defer { lock.unlock() }
        settings[service, default: [:]][kind] = value
    }

    func handle(_ arguments: [String]) -> CommandRunner.Result {
        lock.lock()
        calls.append(arguments)
        lock.unlock()
        guard let verb = arguments.first else { return fail("no verb") }

        if verb == "-listallnetworkservices" {
            let lines = ["An asterisk (*) denotes that a network service is disabled."]
                + order + disabled.map { "*" + $0 }
            return ok(lines.joined(separator: "\n") + "\n")
        }
        guard arguments.count >= 2 else { return fail("missing service") }
        let service = arguments[1]
        lock.lock()
        let known = settings[service] != nil
        lock.unlock()
        guard known else {
            return CommandRunner.Result(exitCode: 8, stdout: "** Error: Unable to find item in network database.\n", stderr: "")
        }

        for kind in MacProxyKind.allCases {
            switch verb {
            case kind.getVerb:
                let s = setting(service, kind)
                return ok("Enabled: \(s.enabled ? "Yes" : "No")\nServer: \(s.server)\nPort: \(s.port)\n"
                          + "Authenticated Proxy Enabled: \(s.authenticated ? 1 : 0)\n")
            case kind.setVerb:
                guard arguments.count >= 4, let port = Int(arguments[3]) else { return fail("bad args") }
                if failSetFor == service {
                    return CommandRunner.Result(exitCode: 14, stdout: "", stderr: "This operation requires admin rights.\n")
                }
                lock.lock()
                setCount += 1
                let first = setCount == 1
                let hook = onFirstSet
                lock.unlock()
                if first { hook?() }
                set(service, kind, MacProxySetting(enabled: true, server: arguments[2], port: port))
                return ok("")
            case kind.stateVerb:
                guard arguments.count >= 3 else { return fail("bad args") }
                var s = setting(service, kind)
                s.enabled = arguments[2] == "on"
                set(service, kind, s)
                return ok("")
            default:
                continue
            }
        }
        return fail("unknown verb \(verb)")
    }

    private func ok(_ stdout: String) -> CommandRunner.Result {
        CommandRunner.Result(exitCode: 0, stdout: stdout, stderr: "")
    }

    private func fail(_ message: String) -> CommandRunner.Result {
        CommandRunner.Result(exitCode: 1, stdout: "", stderr: message)
    }
}
