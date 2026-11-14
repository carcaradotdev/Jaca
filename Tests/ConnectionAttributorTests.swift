import XCTest
@testable import Jaca

/// Only a connection from an iOS Simulator process may be decrypted, so the attributor must
/// never call a Mac process a simulator, and must never crash on a pid that exits mid-lookup.
final class ConnectionAttributorTests: XCTestCase {
    private let udid = "83682192-0F63-4379-B374-980D9AFE5FF7"

    // MARK: - KERN_PROCARGS2

    /// Builds a buffer in the kernel's layout: argc, the executable path, NUL padding, the
    /// arguments, then the environment.
    private func procArgs2(path: String, args: [String], env: [String], padding: Int = 3) -> [UInt8] {
        var bytes: [UInt8] = []
        let argc = UInt32(args.count)
        bytes += [UInt8(argc & 0xff), UInt8((argc >> 8) & 0xff), UInt8((argc >> 16) & 0xff), UInt8(argc >> 24)]
        bytes += Array(path.utf8) + [0] + [UInt8](repeating: 0, count: padding)
        for arg in args { bytes += Array(arg.utf8) + [0] }
        for entry in env { bytes += Array(entry.utf8) + [0] }
        bytes += [0, 0]
        return bytes
    }

    func test_procArgs2_parsesArgumentsAndEnvironment() {
        let bytes = procArgs2(path: "/usr/bin/nc", args: ["nc", "127.0.0.1", "9090"],
                              env: ["SIMULATOR_UDID=\(udid)", "HOME=/Users/me", "EMPTY=", "A=b=c"])
        let parsed = ProcArgs2Parser.parse(bytes)
        XCTAssertEqual(parsed.executable, "/usr/bin/nc")
        XCTAssertEqual(parsed.arguments, ["nc", "127.0.0.1", "9090"])
        XCTAssertEqual(parsed.environment["SIMULATOR_UDID"], udid)
        XCTAssertEqual(parsed.environment["HOME"], "/Users/me")
        XCTAssertEqual(parsed.environment["EMPTY"], "")
        XCTAssertEqual(parsed.environment["A"], "b=c")
    }

    /// Recent macOS hides the environment of another process: the buffer ends after the
    /// arguments.
    func test_procArgs2_withoutEnvironment() {
        let bytes = procArgs2(path: "/usr/bin/nc", args: ["nc"], env: [])
        XCTAssertEqual(ProcArgs2Parser.environment(from: bytes), [:])
    }

    func test_procArgs2_truncatedOrEmptyBufferNeverTraps() {
        XCTAssertEqual(ProcArgs2Parser.parse([]), .init())
        XCTAssertEqual(ProcArgs2Parser.parse([1, 0]), .init())
        let full = procArgs2(path: "/bin/x", args: ["x", "y"], env: ["K=V"])
        for length in 0..<full.count {
            _ = ProcArgs2Parser.parse(Array(full.prefix(length)))
        }
        // A negative argc.
        XCTAssertEqual(ProcArgs2Parser.parse([0xff, 0xff, 0xff, 0xff, 0x41, 0]).arguments, [])
    }

    // MARK: - Paths

    func test_udidFromPath_appBundle() {
        let path = "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/38BD9DC6-5F1F-48D3-9546-6056B15BC7EA/App.app/App"
        XCTAssertEqual(SimulatorProcessMatch.udid(fromPath: path), udid)
    }

    func test_udidFromPath_lowercaseIsNormalized() {
        let path = "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid.lowercased())/data/x"
        XCTAssertEqual(SimulatorProcessMatch.udid(fromPath: path), udid)
    }

    func test_udidFromPath_rejectsNonSimulatorPaths() {
        XCTAssertNil(SimulatorProcessMatch.udid(fromPath: "/Applications/Safari.app/Contents/MacOS/Safari"))
        XCTAssertNil(SimulatorProcessMatch.udid(fromPath: "/Users/me/Library/Developer/CoreSimulator/Devices/device_set.plist"))
        XCTAssertNil(SimulatorProcessMatch.udid(fromPath: "/Users/me/Library/Developer/CoreSimulator/Devices/not-a-uuid/data"))
        // The runtime root has no UDID; the ancestor walk handles it.
        XCTAssertNil(SimulatorProcessMatch.udid(fromPath:
            "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/nsurlsessiond"))
    }

    func test_udid_environmentWinsOverPath() {
        XCTAssertEqual(SimulatorProcessMatch.udid(environment: ["SIMULATOR_UDID": udid], executablePath: "/bin/sh"), udid)
        XCTAssertNil(SimulatorProcessMatch.udid(environment: ["SIMULATOR_UDID": "garbage"], executablePath: "/bin/sh"))
    }

    // MARK: - Ancestor walk

    private struct FakeProcess {
        var path: String?
        var parent: pid_t?
        var arguments: [String]? = nil
        var environment: [String: String]? = nil
    }

    private func probe(_ table: [pid_t: FakeProcess], owner: pid_t?,
                       ownerCalls: Counter = Counter(),
                       pathCalls: Counter = Counter()) -> ConnectionAttributor.Probe {
        probe(table, owners: { _ in owner }, ownerCalls: ownerCalls, pathCalls: pathCalls)
    }

    private func probe(_ table: [pid_t: FakeProcess], owners: @escaping @Sendable (UInt16) -> pid_t?,
                       ownerCalls: Counter = Counter(),
                       pathCalls: Counter = Counter()) -> ConnectionAttributor.Probe {
        ConnectionAttributor.Probe(
            owningPid: { port, _ in ownerCalls.increment(); return owners(port) },
            environment: { table[$0]?.environment },
            executablePath: { pathCalls.increment(); return table[$0]?.path },
            arguments: { table[$0]?.arguments },
            parentPid: { table[$0]?.parent }
        )
    }

    private var simulatorTable: [pid_t: FakeProcess] {
        let runtime = "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot"
        return [
            1: FakeProcess(path: "/sbin/launchd", parent: 0),
            500: FakeProcess(path: "\(runtime)/sbin/launchd_sim", parent: 1,
                             arguments: ["launchd_sim", "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"]),
            510: FakeProcess(path: "\(runtime)/usr/libexec/nsurlsessiond", parent: 500),
            520: FakeProcess(path: "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/X/App.app/App", parent: 500),
            600: FakeProcess(path: "/usr/bin/curl", parent: 601,
                             arguments: ["curl", "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data"]),
            601: FakeProcess(path: "/bin/zsh", parent: 1),
        ]
    }

    func test_simulatorDaemon_isAttributedThroughLaunchdSim() {
        XCTAssertEqual(SimulatorProcessMatch.udid(startingAt: 510, probe: probe(simulatorTable, owner: nil)), udid)
    }

    func test_simulatorApp_isAttributedByPath() {
        XCTAssertEqual(SimulatorProcessMatch.udid(startingAt: 520, probe: probe(simulatorTable, owner: nil)), udid)
    }

    /// Only `launchd_sim`'s arguments count: any Mac tool can take a device path as an argument.
    func test_macProcessWithADevicePathArgument_isNotASimulator() {
        XCTAssertNil(SimulatorProcessMatch.udid(startingAt: 600, probe: probe(simulatorTable, owner: nil)))
    }

    func test_vanishedPid_isNotASimulator() {
        XCTAssertNil(SimulatorProcessMatch.udid(startingAt: 9999, probe: probe(simulatorTable, owner: nil)))
    }

    func test_parentCycle_terminates() {
        let table: [pid_t: FakeProcess] = [10: FakeProcess(path: "/bin/a", parent: 11),
                                           11: FakeProcess(path: "/bin/b", parent: 10)]
        XCTAssertNil(SimulatorProcessMatch.udid(startingAt: 10, probe: probe(table, owner: nil)))
    }

    // MARK: - Attributor

    func test_attribute_returnsTheSimulatorOfTheOwningPid() {
        let attributor = ConnectionAttributor(probe: probe(simulatorTable, owner: 520), ownPid: 42)
        XCTAssertEqual(attributor.attribute(clientPort: 50000, listenerPort: 9090),
                       SimulatorAttribution(udid: udid, pid: 520))
    }

    func test_attribute_noOwnerOrOwnPidIsNil() {
        XCTAssertNil(ConnectionAttributor(probe: probe(simulatorTable, owner: nil), ownPid: 42)
            .attribute(clientPort: 50000, listenerPort: 9090))
        XCTAssertNil(ConnectionAttributor(probe: probe(simulatorTable, owner: 42), ownPid: 42)
            .attribute(clientPort: 50000, listenerPort: 9090))
        XCTAssertNil(ConnectionAttributor(probe: probe(simulatorTable, owner: 601), ownPid: 42)
            .attribute(clientPort: 50000, listenerPort: 9090))
    }

    func test_attribute_looksUpTheOwnerEveryTime_andCachesAncestryPerPidUntilTTL() {
        let ownerCalls = Counter()
        let pathCalls = Counter()
        let clock = TestClock()
        let attributor = ConnectionAttributor(
            probe: probe(simulatorTable, owner: 520, ownerCalls: ownerCalls, pathCalls: pathCalls),
            cacheTTL: 5, ownPid: 42, now: { clock.now })
        _ = attributor.attribute(clientPort: 50000, listenerPort: 9090)
        let pathsAfterFirst = pathCalls.value
        _ = attributor.attribute(clientPort: 50001, listenerPort: 9090)
        XCTAssertEqual(ownerCalls.value, 2, "the socket owner is resolved on every accept")
        XCTAssertEqual(pathCalls.value, pathsAfterFirst, "the same pid reuses its ancestry result")

        clock.advance(6)
        _ = attributor.attribute(clientPort: 50000, listenerPort: 9090)
        XCTAssertGreaterThan(pathCalls.value, pathsAfterFirst, "an expired pid entry is checked again")
    }

    /// A simulator connection closes and a Mac process reuses its ephemeral port within the TTL.
    /// The Mac process must not inherit the simulator's attribution.
    func test_attribute_reusedClientPortByAMacProcess_isNotASimulator() {
        let owner = Box<pid_t>(520)
        let attributor = ConnectionAttributor(
            probe: probe(simulatorTable, owners: { _ in owner.value }), cacheTTL: 5, ownPid: 42)
        XCTAssertEqual(attributor.attribute(clientPort: 51234, listenerPort: 9090)?.udid, udid)
        owner.value = 601
        XCTAssertNil(attributor.attribute(clientPort: 51234, listenerPort: 9090))
    }

    /// The real libproc path on this process: it must not trap, and our own pid is never a
    /// simulator.
    func test_liveProbe_neverTrapsOnMissingPids() {
        XCTAssertNil(LibProc.executablePath(pid: Int32.max))
        XCTAssertNil(LibProc.parentPid(pid: Int32.max))
        XCTAssertNil(LibProc.procArgs2(pid: Int32.max))
        XCTAssertFalse(LibProc.ownsSocket(pid: Int32.max, localPort: 1, remotePort: 2))
        XCTAssertNil(SimulatorProcessMatch.udid(startingAt: ProcessInfo.processInfo.processIdentifier,
                                                probe: .live))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}
