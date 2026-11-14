import SwiftUI
import Lemonade
import AppKit

/// Guides the user through pointing a device at the proxy and trusting the CA,
/// with platform-specific steps and an honest note on the limits of proxy-based
/// capture (no call stack; cert-pinning / ATS can block interception).
struct NetworkSetupSheet: View {
    let session: NetworkSession
    /// Presents the automatic CA-install flow (owned by `NetworkSessionView`).
    var onInstallCA: () -> Void = {}
    /// Leaves MITM for the in-process agent: sets the inspection mode to agent, which stops
    /// this capture and shows the chooser.
    var onSwitchToAgent: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    /// The last iOS Simulator install or reboot result, shown under the actions.
    @State private var simulatorStep: SimulatorCAStep?

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            HStack {
                LemonadeUi.Text("Network capture setup",
                                textStyle: LemonadeTypography.shared.headingSmall,
                                color: LemonadeTheme.colors.content.contentPrimary)
                Spacer()
                LemonadeUi.Button(label: "Done", onClick: { dismiss() },
                                  variant: .neutral, type: .subtle, size: .small)
            }

            LemonadeUi.Notice(
                content: "Proxy address: \(session.hostAddress):\(session.boundPort)",
                voice: .info, title: "Proxy"
            )

            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                if session.device.platform == .android {
                    LemonadeUi.Button(label: "Install CA automatically", onClick: onInstallCA,
                                      leadingIcon: .smartphone, variant: .primary, type: .solid, size: .small)
                        .fixedSize()
                }
                if session.device.platform == .iosSimulator {
                    LemonadeUi.Button(label: "Install CA in Simulator",   // COPY-PENDING
                                      onClick: installInSimulator,
                                      leadingIcon: .smartphone, variant: .primary, type: .solid, size: .small)
                        .fixedSize()
                        .disabled(session.isInstallingCA)
                }
                if session.isInstallingCA {
                    ProgressView().controlSize(.small)
                        .transition(.opacity)
                }
                LemonadeUi.Button(label: "Export CA…", onClick: exportCA,
                                  leadingIcon: .download, variant: .neutral, type: .subtle, size: .small)
                    .fixedSize()
                Spacer()
                if session.agentAvailable {
                    LemonadeUi.Button(label: "Switch to Agent", onClick: onSwitchToAgent,
                                      variant: .neutral, type: .subtle, size: .small)
                        .fixedSize()
                }
            }

            if let step = simulatorStep {
                simulatorStepNotice(step)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
                    steps
                    limitations
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: simulatorStep)
        .animation(.easeInOut(duration: 0.2), value: session.isInstallingCA)
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 620, height: 560)
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    @ViewBuilder
    private var steps: some View {
        switch session.device.platform {
        case .android:
            stepSection("Android", [
                "Start proxy capture from the tab — Jaca then sets the device proxy while it runs (http_proxy = \(session.hostAddress):\(session.boundPort)) and reverts it when you stop.",
                "Tap “Install CA automatically”. On an emulator or rooted device Jaca installs it into the system trust store with no further steps; otherwise it opens the on-device dialog for you to confirm, and detects when it's done.",
                "On a non-rooted device only apps that trust user CAs (debug builds via network-security-config) can be intercepted. Rooted/emulator system-store installs are trusted by every app that doesn't pin certs.",
            ])
        case .iosSimulator:
            stepSection("iOS Simulator", [
                // COPY-PENDING: the two steps below replace the manual proxy and drag-in steps.
                "While the capture runs, Jaca points the Mac's system proxy at \(session.hostAddress):\(session.boundPort) and restores it when you stop. Only simulator traffic is decrypted; other Mac apps pass through and are not recorded.",   // COPY-PENDING
                "Click “Install CA in Simulator”, then reboot the simulator so its apps trust Jaca's certificate.",   // COPY-PENDING
                "ATS / cert pinning can still block interception unless the app trusts the CA.",
            ])
        case .iosDevice:
            stepSection("iOS Device", [
                "On the device: Settings → Wi-Fi → (i) → Configure Proxy → Manual → Server \(session.hostAddress), Port \(session.boundPort).",
                "Export and AirDrop/email the CA to the device, install the profile, then enable full trust in Settings → General → About → Certificate Trust Settings.",
                "ATS and cert pinning may block capture; there is no system-level per-app network inspector on iOS.",
            ])
        case .mac:
            EmptyView()   // the Chrome window needs no proxy setup
        }
    }

    private var limitations: some View {
        LemonadeUi.Notice(
            content: "Proxy capture gives you full URLs, headers, bodies and timing — but not the call stack that initiated each request (that needs in-process instrumentation, which a proxy can't provide). Apps that pin certificates or don't trust user-installed CAs won't be interceptable.",
            voice: .warning, title: "What proxy capture can and can't do"
        )
    }

    private func stepSection(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.Text(title.uppercased(), textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: LemonadeTheme.spaces.spacing200) {
                    LemonadeUi.Text("\(index + 1).",
                                    textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                                    color: LemonadeTheme.colors.content.contentBrand)
                    LemonadeUi.Text(item, textStyle: LemonadeTypography.shared.bodySmallRegular,
                                    color: LemonadeTheme.colors.content.contentSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func simulatorStepNotice(_ step: SimulatorCAStep) -> some View {
        switch step {
        case .installed:
            HStack(alignment: .center, spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Notice(
                    content: "Jaca's certificate is installed in the simulator. Reboot the simulator so its apps trust it.",   // COPY-PENDING
                    voice: .info
                )
                LemonadeUi.Button(label: "Reboot simulator",   // COPY-PENDING
                                  onClick: rebootSimulator,
                                  leadingIcon: .arrowRotateCw, variant: .neutral, type: .subtle, size: .small)
                    .fixedSize()
                    .disabled(session.isInstallingCA)
            }
        case .rebooted:
            LemonadeUi.Notice(
                content: "The simulator rebooted. Open the app again to capture its traffic.",   // COPY-PENDING
                voice: .info
            )
        case .failed(let message):
            LemonadeUi.Notice(content: message, voice: .critical)
        }
    }

    /// Adds the CA to the simulator keychain, through `jacad` when the capture runs there.
    private func installInSimulator() {
        Task {
            // nil: the daemon didn't answer, or an install already runs. Keep what is shown.
            guard let result = await session.installCA() else { return }
            simulatorStep = SimulatorCAStep(result)
        }
    }

    private func rebootSimulator() {
        Task {
            guard let result = await session.rebootSimulator() else { return }
            simulatorStep = SimulatorCAStep(reboot: result)
        }
    }

    private func exportCA() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "JacaProxyCA.pem"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? session.ca.exportRootCertificate(to: url)
        }
    }
}

/// What the setup sheet shows after a one-click iOS Simulator CA install or reboot. Pure, so the
/// mapping from the install result is unit-tested.
enum SimulatorCAStep: Equatable {
    /// The CA is in the simulator keychain. Apps see it after a reboot.
    case installed
    case rebooted
    /// The installer's own message. Nothing shows when it gave none.
    case failed(String)

    /// nil when the result has nothing to show: a failure with no message.
    init?(_ result: NetworkArea.InstallCAResult) {
        switch result.outcome {
        case .installed: self = .installed
        // The simulator has no manual install; treat it as a failure with what the installer said.
        case .needsUser, .failed:
            guard let message = result.message, !message.isEmpty else { return nil }
            self = .failed(message)
        }
    }

    init?(reboot result: Result<Void, SimulatorCAError>) {
        switch result {
        case .success: self = .rebooted
        case .failure(let error):
            guard !error.message.isEmpty else { return nil }
            self = .failed(error.message)
        }
    }
}
