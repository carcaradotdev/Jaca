import Foundation

/// The registered capture sources. Adding a new way to capture means appending a
/// descriptor here (plus its `CaptureSource` file) — `NetworkSession` and the chooser
/// consume this list generically, so nothing already working changes.
///
/// Which descriptors a device is offered, and in which order, comes from the current
/// `HTTPDebuggingStrategy` (the network inspection mode), not from this list:
/// - Agent mode: `agent` on Android and the iOS Simulator, `browser` on this Mac.
/// - MITM mode: `mitm` on Android and the iOS Simulator, `companion` on a companion-only phone,
///   `browser` on this Mac.
@MainActor
enum CaptureSourceRegistry {
    static let all: [CaptureSourceDescriptor] = [companion, agent, mitm, browser]

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

    /// MITM through a proxy on this Mac. One descriptor for two routes, as for the agent:
    /// Android points its global `http_proxy` at the proxy over `adb reverse`, and the iOS
    /// Simulator goes through the macOS system proxy.
    static let mitm = CaptureSourceDescriptor(
        id: HTTPDebuggingSourceID.mitm, kind: .proxy,
        title: "Device proxy",
        detail: InterceptTransportID.mitmProxy.captureDetail,
        isAvailable: { device, _ in
            (device.platform == .android && !device.isCompanion) || device.platform == .iosSimulator
        },
        needsPackage: false,
        precheck: { ctx in
            ctx.device.platform == .iosSimulator
                ? await SimulatorProxyCaptureSource.precheck(device: ctx.device)
                : await DeviceProxyCaptureSource.precheck(device: ctx.device, adbURL: ctx.adbURL)
        },
        make: { ctx -> CaptureSource in
            if ctx.device.platform == .iosSimulator {
                return SimulatorProxyCaptureSource(device: ctx.device, ca: ctx.ca, intercept: ctx.intercept)
            }
            return DeviceProxyCaptureSource(device: ctx.device, adbURL: ctx.adbURL, ca: ctx.ca,
                                            intercept: ctx.intercept)
        },
    )

    /// The iOS Simulator route changes the whole Mac, so its chooser row says so before the
    /// start (`DeviceProxyCaptureSource` changes only the device).
    static let simulatorSystemProxyNote =
        "On the iOS Simulator this sets the Mac's system proxy while the capture runs. Other Mac apps pass through and are not recorded."   // COPY-PENDING

    /// A second line under a chooser row, for a source whose effect depends on the device.
    static func chooserNote(sourceID: String, device: Device) -> String? {
        sourceID == HTTPDebuggingSourceID.mitm && device.platform == .iosSimulator ? simulatorSystemProxyNote : nil
    }

    static let companion = CaptureSourceDescriptor(
        id: "companion", kind: .companion,
        title: "Companion stream",
        detail: InterceptTransportID.companionMetadata.captureDetail,
        isAvailable: { device, _ in device.companionID != nil },
        needsPackage: false,
        make: { ctx in
            guard let ca = ctx.ca else {
                // Unreachable by construction: a tab that can choose companion capture runs
                // in-process, where the app always has its CA.
                DaemonLog.error("companion capture requested without a CA; not starting")
                return InertCaptureSource()
            }
            return CompanionCaptureSource(device: ctx.device, hub: ctx.companion ?? CompanionHub(), ca: ca)
        },
    )

    static let browser = CaptureSourceDescriptor(
        id: "browser", kind: .browser,
        title: "Chrome browser",
        detail: "Opens a separate Chrome window. Jaca captures its traffic and can override responses.",
        isAvailable: { device, _ in device.platform == .mac },
        needsPackage: false,
        // The app always has its CA; jacad reads it when the capture opens and can fail to.
        make: { ctx in MacBrowserCaptureSource(ca: ctx.ca, intercept: ctx.intercept) },
    )

    /// Options offered for a device, in the order the strategy gives. `strategy` defaults to the
    /// persisted network inspection mode.
    static func options(for device: Device, context: DeviceContext?,
                        strategy: any HTTPDebuggingStrategy = HTTPDebuggingStrategies.current)
        -> [CaptureSourceDescriptor] {
        strategy.sourceIDs(for: device).compactMap { id in
            all.first { $0.id == id && $0.isAvailable(device, context) }
        }
    }

    static func descriptor(id: String) -> CaptureSourceDescriptor? { all.first { $0.id == id } }

    /// Default option for a device when none is chosen: the first one offered.
    static func defaultDescriptor(for device: Device, context: DeviceContext?,
                                  strategy: any HTTPDebuggingStrategy = HTTPDebuggingStrategies.current)
        -> CaptureSourceDescriptor? {
        options(for: device, context: context, strategy: strategy).first
    }
}

/// A source that captures nothing (see the companion descriptor's missing-CA branch).
@MainActor
final class InertCaptureSource: CaptureSource {
    func start(into sink: CaptureSink) {}
    func stop() {}
}
