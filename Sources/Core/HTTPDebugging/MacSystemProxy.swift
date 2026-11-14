import Foundation

// MARK: - Model

/// One protocol's proxy setting on one network service, as `networksetup -getwebproxy` prints it.
struct MacProxySetting: Codable, Equatable, Sendable {
    var enabled: Bool
    var server: String
    var port: Int
    var authenticated: Bool

    init(enabled: Bool, server: String, port: Int, authenticated: Bool = false) {
        self.enabled = enabled
        self.server = server
        self.port = port
        self.authenticated = authenticated
    }

    static let off = MacProxySetting(enabled: false, server: "", port: 0)
}

/// The two proxy protocols Jaca sets: HTTP ("web") and HTTPS ("secure web").
enum MacProxyKind: String, Codable, CaseIterable, Sendable {
    case web
    case secureWeb

    var getVerb: String { self == .web ? "-getwebproxy" : "-getsecurewebproxy" }
    var setVerb: String { self == .web ? "-setwebproxy" : "-setsecurewebproxy" }
    var stateVerb: String { self == .web ? "-setwebproxystate" : "-setsecurewebproxystate" }
}

/// The on-disk record of a Mac system proxy change, written before the change.
///
/// It holds the settings to restore. A process that dies without a restore leaves the lease
/// behind, and `MacSystemProxy.reconcileOrphan()` restores from it at the next start.
struct MacSystemProxyLease: Codable, Equatable, Sendable {
    struct Service: Codable, Equatable, Sendable {
        var name: String
        var web: MacProxySetting
        var secureWeb: MacProxySetting

        func previous(_ kind: MacProxyKind) -> MacProxySetting {
            kind == .web ? web : secureWeb
        }
    }

    var ownerPid: Int32
    var port: Int
    var createdAt: Date
    var services: [Service]
}

/// A failed Mac system proxy change, with the text the UI shows.
struct MacSystemProxyError: Error, Equatable, Sendable {
    let message: String
}

// MARK: - Tolerant decode

extension MacProxySetting {
    enum CodingKeys: String, CodingKey { case enabled, server, port, authenticated }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled       = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        server        = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
        port          = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        authenticated = try c.decodeIfPresent(Bool.self, forKey: .authenticated) ?? false
    }
}

extension MacSystemProxyLease.Service {
    enum CodingKeys: String, CodingKey { case name, web, secureWeb }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name      = try c.decode(String.self, forKey: .name)
        web       = (try? c.decodeIfPresent(MacProxySetting.self, forKey: .web)) ?? .off
        secureWeb = (try? c.decodeIfPresent(MacProxySetting.self, forKey: .secureWeb)) ?? .off
    }
}

extension MacSystemProxyLease {
    enum CodingKeys: String, CodingKey { case ownerPid, port, createdAt, services }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownerPid  = try c.decodeIfPresent(Int32.self, forKey: .ownerPid) ?? 0
        port      = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        services  = CloudPersistence.decodeArrayField(Service.self, in: c, forKey: .services)
    }
}

// MARK: - Pure logic

/// Parses `networksetup` output.
enum NetworkSetupParser {
    /// The enabled services from `-listallnetworkservices`. The first line is a note about the
    /// asterisk, and a disabled service starts with `*`.
    static func enabledServices(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty
                    && !line.hasPrefix("*")
                    && !line.hasPrefix("An asterisk (*)")
            }
    }

    /// The setting from `-getwebproxy` or `-getsecurewebproxy`, or nil when the output has no
    /// `Enabled:` line (for example `** Error: Unable to find item in network database.`).
    static func proxySetting(_ output: String) -> MacProxySetting? {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let enabled = fields["enabled"] else { return nil }
        return MacProxySetting(
            enabled: enabled.lowercased() == "yes",
            server: fields["server"] ?? "",
            port: Int(fields["port"] ?? "") ?? 0,
            authenticated: isOn(fields["authenticated proxy enabled"])
        )
    }

    /// True when the command failed. `networksetup` sometimes exits 0 and prints `** Error` on
    /// stdout.
    static func failed(_ result: CommandRunner.Result) -> Bool {
        result.exitCode != 0 || result.stdout.contains("** Error") || result.stderr.contains("** Error")
    }

    /// The error text of a failed command, without the `** Error:` prefix.
    static func errorText(_ result: CommandRunner.Result) -> String {
        let text = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = text
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("** Error:") { s = String(s.dropFirst("** Error:".count)) }
                return s.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return cleaned.isEmpty ? "networksetup exited with code \(result.exitCode)." : cleaned // COPY-PENDING
    }

    private static func isOn(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value == "1" || value == "yes"
    }
}

/// The `networksetup` commands Jaca runs, as pure functions of the state.
enum MacSystemProxyPlan {
    static let loopback = "127.0.0.1"

    /// True when `setting` is Jaca's proxy on `port`. Restore touches only such a setting, so a
    /// change the user made in the meantime is kept.
    static func pointsAtUs(_ setting: MacProxySetting?, port: Int) -> Bool {
        guard let setting else { return false }
        return setting.enabled && setting.server == loopback && setting.port == port
    }

    /// Sets both protocols on `service` to `127.0.0.1:port`. `-setwebproxy` also turns the
    /// protocol on.
    static func setCommands(service: String, port: Int) -> [[String]] {
        MacProxyKind.allCases.map { [$0.setVerb, service, loopback, String(port)] }
    }

    /// Puts `previous` back for one protocol.
    ///
    /// `networksetup` cannot clear the server field, so a protocol that had no server is only
    /// turned off. A password of an authenticated proxy is not in the lease; macOS keeps it in
    /// the Keychain under the server name.
    ///
    /// A previous setting that was already `127.0.0.1:port` is a leftover of an earlier Jaca run,
    /// so it is restored as off.
    static func restoreCommands(service: String, kind: MacProxyKind, previous: MacProxySetting,
                                port: Int) -> [[String]] {
        let hasServer = !previous.server.isEmpty && previous.port > 0
        if previous.enabled, hasServer, !pointsAtUs(previous, port: port) {
            return [[kind.setVerb, service, previous.server, String(previous.port)]]
        }
        if hasServer {
            return [[kind.setVerb, service, previous.server, String(previous.port)],
                    [kind.stateVerb, service, "off"]]
        }
        return [[kind.stateVerb, service, "off"]]
    }

    /// The restore commands for every protocol in `lease` whose current setting still points at
    /// the lease's port. `current` is nil for a protocol that could not be read (for example a
    /// service removed since); such a protocol is left alone.
    static func restorePlan(lease: MacSystemProxyLease,
                            current: (_ service: String, _ kind: MacProxyKind) -> MacProxySetting?) -> [[String]] {
        var commands: [[String]] = []
        for service in lease.services {
            for kind in MacProxyKind.allCases where pointsAtUs(current(service.name, kind), port: lease.port) {
                commands += restoreCommands(service: service.name, kind: kind,
                                            previous: service.previous(kind), port: lease.port)
            }
        }
        return commands
    }
}

/// Reads and writes the lease file.
enum MacSystemProxyLeaseFile {
    static let fileName = "mac-system-proxy.json"

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jaca")
    }

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func load(from directory: URL) -> MacSystemProxyLease? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        return try? makeDecoder().decode(MacSystemProxyLease.self, from: data)
    }

    static func save(_ lease: MacSystemProxyLease, to directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try makeEncoder().encode(lease)
            try data.write(to: url(in: directory), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func delete(in directory: URL) {
        try? FileManager.default.removeItem(at: url(in: directory))
    }

    /// Must mirror `makeEncoder()`, or `createdAt` fails to decode.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

// MARK: - The proxy owner

/// Points the macOS system web and secure web proxy at Jaca's listener while at least one
/// iOS Simulator capture runs, and restores the user's settings after the last one stops.
///
/// Every change goes through `/usr/sbin/networksetup`, run as the user. A non-admin user can get
/// a non-zero exit; that comes back as a `MacSystemProxyError`, never as a throw.
///
/// Safety:
/// - A lease file with the previous settings is written before any change.
/// - Restore is compare-and-restore: a protocol is reverted only while it still reads
///   `127.0.0.1:<our port>`.
/// - `reconcileOrphan()` restores a lease whose owner process is dead. Call it at app and jacad
///   start.
/// - SIGINT, SIGTERM and SIGHUP restore synchronously through `TerminationCleanup`. A quit path
///   calls `MacSystemProxyCleanup.revertAll()`.
actor MacSystemProxy {
    /// Runs `networksetup <arguments>`. A launch failure comes back as a non-zero exit code.
    typealias Runner = @Sendable (_ arguments: [String]) async -> CommandRunner.Result

    static let networksetup = URL(fileURLWithPath: "/usr/sbin/networksetup")

    static let shared = MacSystemProxy()

    static let liveRunner: Runner = { arguments in
        do {
            return try await CommandRunner.run(networksetup, arguments, timeout: 30)
        } catch {
            return CommandRunner.Result(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
    }

    /// True when `pid` is alive and still looks like a Jaca process. A recycled pid that now
    /// belongs to another program counts as dead.
    static let liveOwnerCheck: @Sendable (Int32) -> Bool = DeviceProxyLedger.liveOwnerCheck

    private let directory: URL
    private let run: Runner
    private let isOwnerAlive: @Sendable (Int32) -> Bool
    private let ownPid: Int32
    private let armsTerminationHook: Bool
    private let now: @Sendable () -> Date

    /// The number of captures that hold the proxy.
    private(set) var holders = 0
    /// The lease of the change this process made, while `holders > 0`.
    private(set) var activeLease: MacSystemProxyLease?
    private var tail: Task<Void, Never>?

    init(directory: URL = MacSystemProxyLeaseFile.defaultDirectory,
         run: @escaping Runner = MacSystemProxy.liveRunner,
         isOwnerAlive: @escaping @Sendable (Int32) -> Bool = MacSystemProxy.liveOwnerCheck,
         ownPid: Int32 = ProcessInfo.processInfo.processIdentifier,
         armsTerminationHook: Bool = true,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.run = run
        self.isOwnerAlive = isOwnerAlive
        self.ownPid = ownPid
        self.armsTerminationHook = armsTerminationHook
        self.now = now
    }

    /// The port the system proxy points at, while this process holds it.
    var activePort: Int? { activeLease?.port }

    /// Adds a holder. The first holder sets the system proxy to `127.0.0.1:port` on every
    /// enabled network service. A later holder with the same port only counts; a later holder
    /// with another port fails.
    func acquire(port: Int) async -> Result<Void, MacSystemProxyError> {
        await serialized { await $0.doAcquire(port: port) }
    }

    /// Removes a holder. The last holder restores the previous settings and deletes the lease.
    /// When a restore command fails, the lease stays on disk so a later reconcile can retry.
    @discardableResult
    func release() async -> Result<Void, MacSystemProxyError> {
        await serialized { await $0.doRelease() }
    }

    /// Restores a lease left by a dead process, or by this process when it holds nothing.
    /// Returns the number of protocol settings it reverted. Safe to call at any time.
    @discardableResult
    func reconcileOrphan() async -> Int {
        await serialized { await $0.doReconcile() }
    }

    // MARK: Serialization

    /// Runs operations one at a time. Actor methods interleave at each `await`, and two
    /// acquires must not both see `holders == 0`.
    private func serialized<T: Sendable>(_ operation: @escaping @Sendable (MacSystemProxy) async -> T) async -> T {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            return await operation(self)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    // MARK: Operations

    private func doAcquire(port: Int) async -> Result<Void, MacSystemProxyError> {
        guard port > 0, port <= Int(UInt16.max) else {
            return .failure(MacSystemProxyError(message: "The proxy port \(port) is not valid.")) // COPY-PENDING
        }
        if holders > 0 {
            guard activeLease?.port == port else {
                return .failure(MacSystemProxyError(
                    message: "The Mac system proxy is already in use on port \(activeLease?.port ?? 0).")) // COPY-PENDING
            }
            holders += 1
            return .success(())
        }

        _ = await doReconcile()
        // A lease that is still on disk holds settings nobody restored yet. A new lease would
        // record our own proxy as the "previous" setting, so stop here.
        if let existing = MacSystemProxyLeaseFile.load(from: directory) {
            if existing.ownerPid != ownPid, isOwnerAlive(existing.ownerPid) {
                return .failure(MacSystemProxyError(
                    message: "Another Jaca process controls the Mac system proxy.")) // COPY-PENDING
            }
            return .failure(MacSystemProxyError(
                message: "Jaca could not restore the Mac system proxy from an earlier run.")) // COPY-PENDING
        }

        let list = await run(["-listallnetworkservices"])
        if NetworkSetupParser.failed(list) { return .failure(failure(list)) }
        let names = NetworkSetupParser.enabledServices(list.stdout)
        guard !names.isEmpty else {
            return .failure(MacSystemProxyError(message: "No enabled network service was found.")) // COPY-PENDING
        }

        var services: [MacSystemProxyLease.Service] = []
        for name in names {
            var settings: [MacProxyKind: MacProxySetting] = [:]
            for kind in MacProxyKind.allCases {
                let result = await run([kind.getVerb, name])
                guard !NetworkSetupParser.failed(result),
                      let setting = NetworkSetupParser.proxySetting(result.stdout) else {
                    return .failure(failure(result))
                }
                settings[kind] = setting
            }
            services.append(.init(name: name, web: settings[.web] ?? .off, secureWeb: settings[.secureWeb] ?? .off))
        }

        let lease = MacSystemProxyLease(ownerPid: ownPid, port: port, createdAt: now(), services: services)
        guard MacSystemProxyLeaseFile.save(lease, to: directory) else {
            return .failure(MacSystemProxyError(
                message: "Could not write \(MacSystemProxyLeaseFile.url(in: directory).path).")) // COPY-PENDING
        }
        if armsTerminationHook { MacSystemProxyCleanup.arm(directory: directory) }

        for service in services {
            for command in MacSystemProxyPlan.setCommands(service: service.name, port: port) {
                let result = await run(command)
                if NetworkSetupParser.failed(result) {
                    // Undo the services already changed. The lease stays when the undo fails.
                    if await restore(lease).isEmpty {
                        MacSystemProxyLeaseFile.delete(in: directory)
                        if armsTerminationHook { MacSystemProxyCleanup.disarm() }
                    }
                    return .failure(failure(result))
                }
            }
        }

        holders = 1
        activeLease = lease
        return .success(())
    }

    private func doRelease() async -> Result<Void, MacSystemProxyError> {
        guard holders > 0 else { return .success(()) }
        holders -= 1
        guard holders == 0 else { return .success(()) }

        let lease = activeLease ?? MacSystemProxyLeaseFile.load(from: directory)
        activeLease = nil
        guard let lease else { return .success(()) }
        let errors = await restore(lease)
        guard errors.isEmpty else {
            return .failure(MacSystemProxyError(message: errors.joined(separator: " ")))
        }
        MacSystemProxyLeaseFile.delete(in: directory)
        if armsTerminationHook { MacSystemProxyCleanup.disarm() }
        return .success(())
    }

    private func doReconcile() async -> Int {
        guard let lease = MacSystemProxyLeaseFile.load(from: directory) else { return 0 }
        if lease.ownerPid == ownPid {
            guard holders == 0 else { return 0 }
        } else if isOwnerAlive(lease.ownerPid) {
            return 0
        }
        let plan = await currentPlan(lease)
        let errors = await execute(plan)
        guard errors.isEmpty else { return 0 }
        MacSystemProxyLeaseFile.delete(in: directory)
        return countReverted(plan)
    }

    // MARK: Helpers

    /// Compare-and-restore. Returns the error texts of the commands that failed.
    private func restore(_ lease: MacSystemProxyLease) async -> [String] {
        await execute(await currentPlan(lease))
    }

    private func currentPlan(_ lease: MacSystemProxyLease) async -> [[String]] {
        var current: [String: MacProxySetting] = [:]
        for service in lease.services {
            for kind in MacProxyKind.allCases {
                let result = await run([kind.getVerb, service.name])
                if !NetworkSetupParser.failed(result), let setting = NetworkSetupParser.proxySetting(result.stdout) {
                    current[Self.key(service.name, kind)] = setting
                }
            }
        }
        return MacSystemProxyPlan.restorePlan(lease: lease) { current[Self.key($0, $1)] }
    }

    private func execute(_ plan: [[String]]) async -> [String] {
        var errors: [String] = []
        for command in plan {
            let result = await run(command)
            if NetworkSetupParser.failed(result) { errors.append(NetworkSetupParser.errorText(result)) }
        }
        return errors
    }

    /// The number of protocol settings a plan reverts: one per protocol, whether it takes one
    /// or two commands.
    private func countReverted(_ plan: [[String]]) -> Int {
        Set(plan.compactMap { command -> String? in
            guard command.count >= 2, let kind = MacProxyKind.allCases.first(where: {
                command[0] == $0.setVerb || command[0] == $0.stateVerb
            }) else { return nil }
            return Self.key(command[1], kind)
        }).count
    }

    private func failure(_ result: CommandRunner.Result) -> MacSystemProxyError {
        MacSystemProxyError(
            message: "Could not change the Mac system proxy: \(NetworkSetupParser.errorText(result))") // COPY-PENDING
    }

    private static func key(_ service: String, _ kind: MacProxyKind) -> String {
        "\(kind.rawValue)\u{0}\(service)"
    }
}

// MARK: - Termination

/// The synchronous restore for process exit. `TerminationCleanup` calls `revertAll()` from its
/// signal handler; the app's `applicationWillTerminate` and jacad's stop path call it too.
///
/// It restores only a lease this process owns, with the same compare-and-restore rule.
enum MacSystemProxyCleanup {
    private static let lock = NSLock()
    private static var armedDirectory: URL?

    static func arm(directory: URL) {
        lock.lock()
        armedDirectory = directory
        lock.unlock()
        TerminationCleanup.install()
    }

    static func disarm() {
        lock.lock()
        armedDirectory = nil
        lock.unlock()
    }

    static func revertAll() {
        lock.lock()
        let directory = armedDirectory
        armedDirectory = nil
        lock.unlock()
        guard let directory else { return }
        revert(directory: directory,
               ownPid: ProcessInfo.processInfo.processIdentifier,
               run: runSynchronously)
    }

    /// Restores the lease in `directory` when `ownPid` owns it. Deletes the lease when every
    /// command succeeds. Separate from `revertAll()` so a test can pass a fake runner.
    static func revert(directory: URL, ownPid: Int32, run: ([String]) -> CommandRunner.Result) {
        guard let lease = MacSystemProxyLeaseFile.load(from: directory), lease.ownerPid == ownPid else { return }
        let plan = MacSystemProxyPlan.restorePlan(lease: lease) { service, kind in
            let result = run([kind.getVerb, service])
            guard !NetworkSetupParser.failed(result) else { return nil }
            return NetworkSetupParser.proxySetting(result.stdout)
        }
        var failed = false
        for command in plan {
            if NetworkSetupParser.failed(run(command)) { failed = true }
        }
        if !failed { MacSystemProxyLeaseFile.delete(in: directory) }
    }

    private static func runSynchronously(_ arguments: [String]) -> CommandRunner.Result {
        let process = Process()
        process.executableURL = MacSystemProxy.networksetup
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return CommandRunner.Result(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandRunner.Result(exitCode: process.terminationStatus,
                                    stdout: String(decoding: stdout, as: UTF8.self),
                                    stderr: String(decoding: stderr, as: UTF8.self))
    }
}
