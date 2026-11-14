import Foundation

// jacad: the Jaca background daemon and its command-line client.
//
//   jacad serve [--idle SECONDS]        run the daemon (normally started on demand)
//   jacad call METHOD [PARAMS_JSON]     one request; prints the result JSON
//   jacad watch TOPIC...                subscribe; prints each event as a JSON line
//   jacad status | stop | describe      shorthands for daemon.status, daemon.shutdown, api.describe
//
// Client commands start the daemon if it isn't running, unless --no-spawn is given.
// See docs/daemon-plan.md.
//
// Invoked as `jaca` (a symlink to this binary on PATH, see scripts/install-cli.sh) it is the
// command line over those calls: `jaca devices`, `jaca logs tail`, `jaca net requests`,
// `jaca overrides add`… (`CLIParser`, `CLIRunner`). The app's own executable is `Jaca`, and the
// filesystem is case-insensitive, so `jaca` can't be a second binary next to it.

setvbuf(stdout, nil, _IOLBF, 0)

/// The name this binary was run as: `jacad`, or `jaca` through the symlink.
let program = URL(fileURLWithPath: CommandLine.arguments.first ?? "jacad").lastPathComponent == "jaca" ? "jaca" : "jacad"

func printError(_ text: String) {
    FileHandle.standardError.write(Data("\(text)\n".utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    printError("\(program): \(message)")
    exit(code)
}

let usage = program == "jaca" ? CLIUsage.text(under: [], program: program) : """
usage: jacad serve [--idle SECONDS]
       jacad call METHOD [PARAMS_JSON] [--no-spawn]
       jacad watch TOPIC... [--no-spawn]
       jacad status | stop | describe [--no-spawn]
"""

var args = Array(CommandLine.arguments.dropFirst())
/// What `jaca` was asked for; nil as `jacad`, and for the client commands both names share.
var invocation: CLIInvocation?
if program == "jaca" {
    let parsed = CLIParser.parse(args)
    if case .daemonCommand = parsed.command {} else { invocation = parsed }
}
let noSpawn = invocation?.noSpawn ?? args.contains("--no-spawn")
args.removeAll { $0 == "--no-spawn" }

/// Signal sources, held for the life of the process.
var signalSources: [DispatchSourceSignal] = []

/// Runs `body` on the main actor and keeps the main run loop alive for it. Client commands
/// exit when `body` returns; `serve` never returns from it.
func runMain(_ body: @escaping @MainActor () async -> Int32) -> Never {
    Task { @MainActor in exit(await body()) }
    RunLoop.main.run()
    exit(0)
}

func tryConnect() async throws -> DaemonClient {
    let client = try await DaemonLauncher.connect(spawn: !noSpawn)
    let _: DaemonServer.HelloResult = try await client.call(
        "hello", DaemonServer.HelloParams(protocolVersion: DaemonProtocol.version, client: "\(program)-cli"),
        timeout: DaemonDefaults.shortCallTimeout)
    return client
}

func connect() async -> DaemonClient {
    do {
        return try await tryConnect()
    } catch {
        fail(error.localizedDescription)
    }
}

if let invocation {
    switch invocation.command {
    case .usage(let path):
        printError(CLIUsage.text(under: path, program: program))
        exit(2)
    case .help(let path):
        print(CLIUsage.text(under: path, program: program))
        // The whole command list stands alone; a command or a group adds what its methods take and return.
        if path.isEmpty { exit(0) }
    default:
        break
    }
    runMain {
        let client: DaemonClient
        if case .help = invocation.command {
            // The usage is already printed: help without a daemon stops there.
            guard let reached = try? await tryConnect() else { return 0 }
            client = reached
        } else {
            client = await connect()
        }
        let runner = CLIRunner(client: client, program: program, json: invocation.json, raw: invocation.raw,
                               out: { print($0) }, err: printError)
        return await runner.run(invocation.command)
    }
}

guard let command = args.first else { fail(usage, code: 2) }
args.removeFirst()

/// Prints a response line's `result` as compact JSON, or its error to stderr (returns 1).
func printResult(_ line: Data) -> Int32 {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        fail("unreadable response")
    }
    if let error = object["error"] as? [String: Any] {
        let message = error["message"] as? String ?? "error"
        printError("\(program): \(message)")
        return 1
    }
    let result = object["result"] ?? NSNull()
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    return 0
}

/// `timeout` bounds the wait for the response (nil: `jacad call` runs methods that can take minutes).
func call(_ method: String, _ paramsText: String?, timeout: Duration? = nil) async -> Int32 {
    var params: Data?
    if let paramsText {
        // Re-serialized compactly: the wire is one message per line, so pasted multi-line JSON
        // would otherwise be split into fragments the daemon can't answer.
        guard let object = try? JSONSerialization.jsonObject(with: Data(paramsText.utf8), options: [.fragmentsAllowed]),
              let compact = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else {
            fail("PARAMS_JSON is not valid JSON")
        }
        params = compact
    }
    let client = await connect()
    do {
        // An error response arrives as a thrown RPCError and is reported by `fail` below.
        return printResult(try await client.callRaw(method, paramsJSON: params, timeout: timeout))
    } catch {
        fail(error.localizedDescription)
    }
}

switch command {
case "serve":
    var idle: TimeInterval = 300
    if let v = ProcessInfo.processInfo.environment["JACAD_IDLE_SECONDS"].flatMap(TimeInterval.init) { idle = v }
    // The flag wins over the environment.
    if let i = args.firstIndex(of: "--idle") {
        guard i + 1 < args.count, let v = TimeInterval(args[i + 1]) else { fail(usage, code: 2) }
        idle = v
    }
    // Leave the spawning app's session so quitting (or killing) it doesn't take the daemon along.
    setsid()
    signal(SIGPIPE, SIG_IGN)
    let server = DaemonServer(paths: .default, idleTimeout: idle)
    runMain {
        server.onStop = {
            // Tunnels and device proxies this daemon's captures set up (the app does the same
            // on quit); a SIGKILLed daemon is reconciled on the next start instead.
            AdbTunnelCleanup.revertAll()
            ProxyCleanup.revertAll()
            MacSystemProxyCleanup.revertAll()
            exit(0)
        }
        // Before anything binds or spawns, so an early SIGTERM still runs the cleanup in `onStop`.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { server.stop() }
            source.resume()
            signalSources.append(source)
        }
        do {
            try server.prepare()
            // Before listening: a client reconnecting the moment the socket appears must find
            // every area's methods registered.
            DaemonAreas.install(on: server)
            // After `prepare`, which takes the lock, so no other jacad reconciles at the same
            // time; before `listen`, so no capture arms a device that still holds a proxy that
            // a killed Jaca process left behind.
            let adb = AndroidToolchain.adbURL(override: JacaDefaults.shared.string(forKey: DevicesEngine.adbPathKey))
            let reverted = await DeviceProxyLedger.reconcileOrphans(adbPath: adb?.path)
            if !reverted.isEmpty { DaemonLog.info("reverted stranded device proxies on \(reverted.joined(separator: ", "))") }
            let macReverted = await MacSystemProxy.shared.reconcileOrphan()
            if macReverted > 0 { DaemonLog.info("reverted \(macReverted) stranded Mac system proxy settings") }
            try server.listen()
        } catch DaemonServer.StartError.alreadyRunning {
            DaemonLog.info("another jacad holds the lock; exiting")
            return 0
        } catch {
            DaemonLog.error(error.localizedDescription)
            return 1
        }
        // Serve until stopped; `onStop` exits the process.
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }

case "call":
    guard let method = args.first else { fail(usage, code: 2) }
    let params = args.count > 1 ? args[1] : nil
    runMain { await call(method, params) }

case "status":
    runMain { await call("daemon.status", nil, timeout: DaemonDefaults.shortCallTimeout) }

case "describe":
    runMain { await call("api.describe", nil, timeout: DaemonDefaults.shortCallTimeout) }

case "stop":
    runMain {
        guard let client = try? await DaemonClient.connect() else { return 0 }   // not running
        let code: Int32
        do {
            code = printResult(try await client.callRaw("daemon.shutdown", paramsJSON: nil, timeout: DaemonDefaults.shortCallTimeout))
        } catch let error as RPCError where error.code == RPCError.disconnectedCode {
            code = 0   // it closed the connection: already stopping (idle), wait for it below
        } catch {
            printError("\(program): \(error.localizedDescription)")
            return 1
        }
        // Return once the daemon is gone, so a command run right after can't reach it mid-exit.
        let socket = DaemonPaths.default.socket.path
        for _ in 0..<50 where FileManager.default.fileExists(atPath: socket) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if FileManager.default.fileExists(atPath: socket) {
            printError("\(program): still running after 2.5s")
            return 1
        }
        return code
    }

case "watch":
    guard !args.isEmpty else { fail(usage, code: 2) }
    let topics = args
    runMain {
        let client = await connect()
        do {
            for await event in try await client.subscribe(topics) {
                if let text = String(data: event.line, encoding: .utf8) {
                    print(text.trimmingCharacters(in: .newlines))
                }
            }
            fail("connection closed")
        } catch {
            fail(error.localizedDescription)
        }
    }

default:
    fail(usage, code: 2)
}
