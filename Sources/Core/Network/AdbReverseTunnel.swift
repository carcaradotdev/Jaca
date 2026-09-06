import Foundation

/// `adb reverse` — the Android side of the divert tunnel, and the only adb-aware divert code in
/// the product. Opening one creates state inside the adb server that outlives Jaca, and a
/// stranded reverse fails every diverted request until removed by hand — hence the ledger entry
/// on open and the deregister on close.
struct AdbReverseTunnel: DivertTunnel {
    let adbPath: String
    let serial: String

    /// The device reaches us over its own loopback, which `adb reverse` bridges to ours.
    func origin(forLocalPort port: Int) -> String { "http://localhost:\(port)" }

    var needsTunnelLedger: Bool { true }

    /// Same port on both sides: adb only prints one when asked to allocate it, and an
    /// OS-allocated local port can't collide with anything already forwarded.
    static func openArguments(serial: String, port: Int) -> [String] {
        ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"]
    }

    static func removeArguments(serial: String, port: Int) -> [String] {
        ["-s", serial, "reverse", "--remove", "tcp:\(port)"]
    }

    func open(localPort port: Int) async throws {
        let result = await run(Self.openArguments(serial: serial, port: port))
        guard result.exitCode == 0 else {
            JacaLog.error("override", "adb reverse tcp:\(port) failed — \(result.text)")
            throw DivertTunnelError(userMessage: "adb reverse tcp:\(port) failed — \(result.text)")
        }
        AdbTunnelCleanup.register(adbPath: adbPath, serial: serial, kind: .reverse, port: port)
        JacaLog.info("override", "adb reverse tcp:\(port) ok (\(serial))")
    }

    func close(localPort port: Int) async {
        _ = await run(Self.removeArguments(serial: serial, port: port))
        AdbTunnelCleanup.deregister(adbPath: adbPath, serial: serial, kind: .reverse, port: port)
    }

    private func run(_ args: [String]) async -> (exitCode: Int32, text: String) {
        guard let result = try? await CommandRunner.run(URL(fileURLWithPath: adbPath), args) else {
            return (-1, "couldn't run adb")
        }
        let text = (result.stderr + " " + result.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.exitCode, text.isEmpty ? "exit \(result.exitCode)" : text)
    }
}
