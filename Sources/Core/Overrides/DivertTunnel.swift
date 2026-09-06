import Foundation

/// Whatever has to exist for the device to reach a loopback port on the Mac, and how the device
/// names that port. adb lives entirely behind this seam, so `Core/Overrides/` never learns that
/// one transport needs a subprocess and a ledger while another needs nothing.
protocol DivertTunnel: Sendable {
    /// The origin the *device* must be told to send to — not always `127.0.0.1`: Android reaches
    /// the Mac through its own loopback, which `adb reverse` bridges.
    func origin(forLocalPort port: Int) -> String

    /// Makes `port` reachable from the device. Throws `DivertTunnelError`, whose `userMessage` is
    /// rendered verbatim, so the transport that knows what failed is the one that words it.
    func open(localPort port: Int) async throws

    /// Idempotent: teardown runs from normal stop, a failed start and cleanup alike.
    func close(localPort port: Int) async

    /// True when opening creates OS-global state that can outlive a `SIGKILL`, and so needs a
    /// `TunnelLedger` entry plus an orphan reconcile next launch. Shared loopback leaks nothing.
    var needsTunnelLedger: Bool { get }
}

/// A tunnel failure the user can act on, worded by the transport that knows what failed (the adb
/// stderr line, say) rather than a generic "couldn't open the tunnel".
struct DivertTunnelError: Error {
    let userMessage: String
}

/// The iOS Simulator shares the Mac's loopback: nothing to open, remove, or leak — so the
/// stranded-tunnel hazards `AdbTunnelCleanup` exists for can't happen here.
struct SharedLoopbackTunnel: DivertTunnel {
    func origin(forLocalPort port: Int) -> String { "http://127.0.0.1:\(port)" }
    func open(localPort: Int) async throws {}
    func close(localPort: Int) async {}
    var needsTunnelLedger: Bool { false }
}
