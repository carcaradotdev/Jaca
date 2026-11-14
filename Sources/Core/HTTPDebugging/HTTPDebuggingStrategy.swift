import Foundation

/// The capture source ids a strategy can offer. They match the ids in `CaptureSourceRegistry`.
enum HTTPDebuggingSourceID {
    static let agent = "agent"
    static let mitm = "mitm"
    static let browser = "browser"
    static let companion = "companion"
}

/// What a running capture holds on its device. Two captures with colliding claims cannot run on
/// one device at the same time; `DeviceClaimArbiter` decides which ones stop.
enum DeviceClaim: Sendable, Hashable {
    /// The agent: an `adb reverse` (or the simulator loopback) for one app.
    case appDivert(package: String)
    /// MITM on Android: the global `http_proxy` setting and its `adb reverse`.
    case deviceProxy
    /// MITM on the iOS Simulator: the macOS system proxy. `MacSystemProxy` refcounts it, so
    /// captures on different simulators share it.
    case macSystemProxy

    /// Whether the claim changes the whole device, not one app.
    var isDeviceGlobal: Bool {
        switch self {
        case .appDivert: return false
        case .deviceProxy, .macSystemProxy: return true
        }
    }
}

/// How one `NetworkInspectionMode` debugs HTTP: which sources it offers per device, and what a
/// running source holds and where it intercepts.
protocol HTTPDebuggingStrategy: Sendable {
    var mode: NetworkInspectionMode { get }
    /// The source ids offered for a device, in chooser order. Empty when the device has none.
    func sourceIDs(for device: Device) -> [String]
    /// What a running source holds on its device. nil when it holds nothing device-wide.
    func claim(device: Device, sourceID: String, package: String?) -> DeviceClaim?
    /// The interception point for the clamp, the copy and the row gate.
    func transport(device: Device, sourceID: String, package: String?) -> InterceptTransportID
    /// Whether Jaca may put the agent back into a relaunched app.
    var supportsAgentReattach: Bool { get }
}

extension HTTPDebuggingStrategy {
    /// The claim and the transport depend only on the source and the device, not on the mode. A
    /// capture started under the other mode still runs until a switch stops it, and the arbiter
    /// has to see its claim in the meantime.
    func claim(device: Device, sourceID: String, package: String?) -> DeviceClaim? {
        HTTPDebuggingSources.claim(device: device, sourceID: sourceID, package: package)
    }

    func transport(device: Device, sourceID: String, package: String?) -> InterceptTransportID {
        HTTPDebuggingSources.transport(device: device, sourceID: sourceID, package: package)
    }
}

/// The in-process agent: one app at a time, with response overrides.
struct AgentHTTPDebugging: HTTPDebuggingStrategy {
    var mode: NetworkInspectionMode { .agentHTTPSDebugging }
    var supportsAgentReattach: Bool { true }

    func sourceIDs(for device: Device) -> [String] {
        if device.isCompanion { return [] }
        switch device.platform {
        case .android, .iosSimulator: return [HTTPDebuggingSourceID.agent]
        case .mac: return [HTTPDebuggingSourceID.browser]
        case .iosDevice: return []
        }
    }
}

/// Man-in-the-middle: a proxy that sees every app on the device.
struct MITMHTTPDebugging: HTTPDebuggingStrategy {
    var mode: NetworkInspectionMode { .mitmHTTPSDebugging }
    var supportsAgentReattach: Bool { false }

    func sourceIDs(for device: Device) -> [String] {
        // A companion-only phone has no adb, so the device proxy cannot reach it. Companion and
        // mitm are offered on disjoint devices, so a VPN capture and a global proxy never meet.
        if device.isCompanion { return [HTTPDebuggingSourceID.companion] }
        switch device.platform {
        case .android, .iosSimulator: return [HTTPDebuggingSourceID.mitm]
        case .mac: return [HTTPDebuggingSourceID.browser]
        case .iosDevice: return []
        }
    }
}

enum HTTPDebuggingStrategies {
    static func strategy(for mode: NetworkInspectionMode) -> any HTTPDebuggingStrategy {
        switch mode {
        case .agentHTTPSDebugging: return AgentHTTPDebugging()
        case .mitmHTTPSDebugging: return MITMHTTPDebugging()
        }
    }

    /// The strategy for the persisted mode.
    static var current: any HTTPDebuggingStrategy { strategy(for: FeatureFlags.networkInspectionMode) }
}

/// Claim and transport per source. Pure, so both strategies share them.
enum HTTPDebuggingSources {
    static func claim(device: Device, sourceID: String, package: String?) -> DeviceClaim? {
        switch sourceID {
        case HTTPDebuggingSourceID.agent:
            // An agent with no app chosen diverts nothing yet.
            guard let package, !package.isEmpty else { return nil }
            return .appDivert(package: package)
        case HTTPDebuggingSourceID.mitm:
            switch device.platform {
            case .android: return .deviceProxy
            case .iosSimulator: return .macSystemProxy
            case .iosDevice, .mac: return nil
            }
        default:
            // The browser touches nothing on a device, and the companion VPN is the only capture
            // its device is offered.
            return nil
        }
    }

    static func transport(device: Device, sourceID: String, package: String?) -> InterceptTransportID {
        switch sourceID {
        case HTTPDebuggingSourceID.agent:
            return device.platform == .iosSimulator
                ? .iosSimulatorAgent(bundleID: package ?? "")
                : .androidAgent(package: package ?? "")
        case HTTPDebuggingSourceID.mitm, HTTPDebuggingSourceID.browser:
            return .mitmProxy
        default:
            // Companion, and any id this build does not know (a tab saved by another build). The
            // companion transport applies no rule, so an unknown source never claims a rule fires.
            return .companionMetadata
        }
    }
}
