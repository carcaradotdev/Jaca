import Foundation

/// The registered capture sources. Adding a new way to capture means appending a
/// descriptor here (plus its `CaptureSource` file) — `NetworkSession` and the chooser
/// consume this list generically, so nothing already working changes.
@MainActor
enum CaptureSourceRegistry {
    // Proxy was dropped: only the on-device companion VPN can attribute traffic per app,
    // so companion is the device-wide source. Agent stays for per-app deep-inspection.
    static let all: [CaptureSourceDescriptor] = [companion, agent]

    static let agent = CaptureSourceDescriptor(
        id: "agent", kind: .agent,
        title: "In-process agent",
        // One chooser row, two transports: the copy has to be true on Android *and* on the
        // Simulator, where NSURLProtocol never sees WKWebView, background sessions or raw sockets.
        detail: InterceptTransportID.agentChooserDetail,
        // Offered for a debuggable Android device or any iOS Simulator. Whether the agent is
        // actually built/bundled is checked in the precheck, so a missing agent fails with build
        // instructions instead of silently disappearing from the chooser.
        isAvailable: { device, _ in
            (device.platform == .android && !device.isCompanion) || device.platform == .iosSimulator
        },
        needsPackage: true,
        precheck: { ctx in
            ctx.device.platform == .iosSimulator
                ? await IOSSimulatorAgentCaptureSource.precheck(device: ctx.device, bundleID: ctx.targetPackage)
                : await AgentCaptureSource.precheck(device: ctx.device, adbURL: ctx.adbURL, package: ctx.targetPackage)
        },
        make: { ctx -> CaptureSource in
            if ctx.device.platform == .iosSimulator {
                return IOSSimulatorAgentCaptureSource(device: ctx.device, bundleID: ctx.targetPackage ?? "",
                                                      intercept: ctx.intercept)
            }
            return AgentCaptureSource(adbURL: ctx.adbURL, serial: ctx.device.id,
                                      package: ctx.targetPackage ?? "", intercept: ctx.intercept)
        },
    )

    static let companion = CaptureSourceDescriptor(
        id: "companion", kind: .companion,
        title: "Companion stream",
        detail: InterceptTransportID.companionMetadata.captureDetail,
        isAvailable: { device, _ in device.companionID != nil },
        needsPackage: false,
        make: { ctx in CompanionCaptureSource(device: ctx.device, hub: ctx.companion ?? CompanionHub(), ca: ctx.ca) },
    )

    /// Options offered for a device, in display order. The companion (device-wide HTTPS
    /// decryption) source is gated behind the experimental feature flag — off by default, so
    /// network inspection offers only the in-process Agent.
    static func options(for device: Device, context: DeviceContext?) -> [CaptureSourceDescriptor] {
        let decryption = FeatureFlags.httpsDecryptionEnabled
        return all.filter { $0.isAvailable(device, context) && (decryption || $0.kind == .agent) }
    }

    static func descriptor(id: String) -> CaptureSourceDescriptor? { all.first { $0.id == id } }

    /// Default option for a device when none is chosen: companion (device-wide) when
    /// available, otherwise the first option (agent).
    static func defaultDescriptor(for device: Device, context: DeviceContext?) -> CaptureSourceDescriptor? {
        let opts = options(for: device, context: context)
        return opts.first { $0.kind == .companion } ?? opts.first
    }
}
