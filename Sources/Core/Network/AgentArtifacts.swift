import Foundation

/// How a network session is capturing traffic. One case per registered capture source
/// (see CaptureSourceRegistry) — used for the badge, persistence and chooser styling.
enum CaptureMode: Sendable, Equatable {
    case proxy
    case agent
    case companion

    var label: String {
        switch self {
        case .agent: return "in-process"
        case .companion: return "companion"
        case .proxy: return "proxy"
        }
    }

    /// Whether traffic in this mode reaches Jaca by being decrypted with **our CA** — which is
    /// what makes an `https` transaction proof the device trusts it. `.companion` qualifies (the
    /// phone tunnels TLS to `ProxyServer`); `.agent` doesn't, as it reads in-process buffers.
    var decryptsWithOurCA: Bool {
        switch self {
        case .proxy, .companion: return true
        case .agent: return false
        }
    }
}

/// Locates the Android agent artifacts (native .so + dexes) bundled into the app by the build
/// (`scripts/build.sh` copies `agent/out` into `Resources/`). arm64-v8a only — every dev runs
/// Apple-Silicon, and the device + emulator share that ABI, so there's no ABI matching to do.
enum AgentArtifacts {
    static func soURL() -> URL? { Bundle.main.url(forResource: "libsqueezeagent", withExtension: "so") }
    static var bootDexURL: URL? { Bundle.main.url(forResource: "squeezeagent-boot", withExtension: "dex") }
    static var captureDexURL: URL? { Bundle.main.url(forResource: "squeezeagent-capture", withExtension: "dex") }

    static var isAvailable: Bool { soURL() != nil && bootDexURL != nil && captureDexURL != nil }

    /// Shown when the Android agent isn't bundled — a dev tool, so it's explicit about how to build it.
    static let missingMessage = """
        The in-process agent isn't built into this app. Build it on macOS:

          sdkmanager "ndk;27.2.12479018" "cmake;3.22.1" "platforms;android-36"
          brew install kotlin
          ./scripts/all.sh

        Then relaunch Jaca. The agent needs the Android NDK/CMake + Kotlin; the app builds \
        without it, which is why this option was unavailable.
        """

    /// The iOS-Simulator network agent dylib, built into Resources by the "Build iOS Simulator
    /// network agent" build phase and injected via DYLD_INSERT_LIBRARIES. Bundle-only (no
    /// hardcoded source path) — the build phase always produces it when building with Xcode.
    static var iosNetworkAgentURL: URL? { Bundle.main.url(forResource: "JacaNetAgent", withExtension: "dylib") }
    static var iosNetworkAgentAvailable: Bool { iosNetworkAgentURL != nil }

    /// Shown when the iOS-Simulator agent dylib isn't bundled (it builds with the app via Xcode).
    static let iosMissingMessage = """
        The iOS-Simulator network agent isn't bundled. It builds with the app — rebuild with \
        ./scripts/build.sh (a full Xcode is required), then relaunch Jaca.
        """
}
