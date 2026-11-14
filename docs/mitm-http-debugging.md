# MITM HTTPS debugging

Jaca has two network inspection modes. The user picks one in Settings → Network inspection, in
Herdr with `M`, or with `jaca net mode`. The mode is global: it applies to every device.

| Mode | Wire name | How it captures |
|---|---|---|
| Agent HTTPS debugging (default) | `agent` | The in-process agent captures one debuggable app. |
| MITM HTTPS debugging | `mitm` | A proxy on the Mac captures every app on the device and decrypts HTTPS with Jaca's CA. |

The stored value is the `JacaDefaults` key `networkInspectionMode`. Its raw values
(`responseOverrides`, `httpsDecryption`) never change. The daemon socket, Herdr and the CLI use
only the wire names (`NetworkInspectionMode.wireName`).

## The Strategy shape

The code is in `Sources/Core/HTTPDebugging/`. It is Core only, so `jacad` builds it.

```swift
enum DeviceClaim { case appDivert(package: String), deviceProxy, macSystemProxy }

protocol HTTPDebuggingStrategy: Sendable {
    var mode: NetworkInspectionMode { get }
    func sourceIDs(for device: Device) -> [String]        // the chooser rows, in order
    func claim(device:sourceID:package:) -> DeviceClaim?  // what a running source holds
    func transport(device:sourceID:package:) -> InterceptTransportID
    var supportsAgentReattach: Bool { get }               // true only for the agent
}
struct AgentHTTPDebugging: HTTPDebuggingStrategy {}
struct MITMHTTPDebugging: HTTPDebuggingStrategy {}
HTTPDebuggingStrategies.strategy(for: mode)   // or .current, from the stored mode
```

The claim and the transport depend only on the source and the device (`HTTPDebuggingSources`).
A capture that started under the other mode keeps its claim until a switch stops it.

Sources offered per device:

| Device | `agent` mode | `mitm` mode |
|---|---|---|
| Android with adb | `agent` | `mitm` (device proxy) |
| Companion-only phone | none | `companion` |
| iOS Simulator | `agent` | `mitm` (Mac system proxy) |
| This Mac | `browser` | `browser` |
| iOS device | none | none |

Companion and `mitm` go to disjoint devices. An adb phone gets only the device proxy, so a VPN
capture and a global proxy never meet on one phone.

Pure helpers in the same folder:

- `DeviceClaimArbiter.decide` names the running captures that a new capture stops. The newest
  capture wins. Per device:
  - A device-global claim (`.deviceProxy`, `.macSystemProxy`) stops every other claim.
  - `.appDivert(p)` stops `.appDivert(p)` and every device-global claim.
  - A nil claim stops nothing.
- `ModeSwitchPlan.make` gives `.keep` or `.stopAndReopenChooser` for each open tab. A tab keeps
  its source when the new mode still offers it (`browser`). A switch never starts a capture,
  because a start can relaunch the user's app.

`NetworkCaptureState.offeredSourceIDs` carries the strategy's list to every client, so Herdr and
remote GUI tabs build the chooser from it. No client has its own copy of the table.

## Android: the device proxy

Source `DeviceProxyCaptureSource`, id `mitm`, kind `.proxy`. It needs no app.

Start:

1. Read the CA. If it is missing, show "Couldn’t read Jaca’s certificate. Check
   ~/.jaca/jacad.log." and stop.
2. Start `ProxyServer` on `127.0.0.1`, port 0, with the override pipeline for `.mitmProxy`.
3. Wait for `DeviceReleaseGate.settle(serial)`, so an earlier teardown on the device is done.
4. Read the current `http_proxy`.
5. Write the ledger entry (below).
6. Run `adb reverse tcp:P tcp:P`. The device's loopback port `P` now reaches the Mac.
7. Run `settings put global http_proxy 127.0.0.1:P`.

One route serves an emulator and a USB phone. The proxy never listens on the LAN.

Stop runs as one task that `DeviceReleaseGate` tracks:

1. Put back the previous proxy, or clear the proxy (`:0`, delete the keys, bounce Wi-Fi).
2. Read the device again to check.
3. Remove the reverse. Stop the server.
4. Remove the ledger entry, only when the revert worked. Otherwise the status reads
   "Couldn’t remove the device proxy. Use Revert in the sidebar."

The adb precheck of both the agent and the device proxy refuses a start while another live Jaca
process holds a ledger entry for the serial. A stale entry of this process is reverted first.

## iOS Simulator: the Mac system proxy

Source `SimulatorProxyCaptureSource`, id `mitm`. Simulator apps use the Mac's network, so the
capture points the macOS system proxy at Jaca.

- `SimulatorProxyHub` runs one `ProxyServer` on `127.0.0.1` for all simulator captures in the
  process. The first capture starts it; the last one to stop restores the system proxy, then
  stops the server.
- `MacSystemProxy` sets the web and secure web proxy to `127.0.0.1:P` on every enabled network
  service. It runs `/usr/sbin/networksetup` as the user. It never uses SCPreferences. A failed
  command comes back as an error on the status line, not as a throw.
- `MacSystemProxy` refcounts holders. Captures on two simulators share one lease. A second
  holder with another port fails.
- `ConnectionAttributor` finds the pid that owns each client socket (libproc). The process is a
  simulator process when one of these holds, for it or an ancestor up to `launchd_sim`:
  - its environment has `SIMULATOR_UDID` (`KERN_PROCARGS2`);
  - its executable path is under `CoreSimulator/Devices/<UDID>/`;
  - it is `launchd_sim`, and its arguments name the device folder.
- A connection from a simulator with a running capture is decrypted and recorded for that
  capture. Every other connection of the Mac is relayed raw and is never recorded.
- `UpstreamClient` sets `connectionProxyDictionary = [:]`, so Jaca's own upstream requests
  ignore the system proxy and never loop.

The lease file `~/.jaca/mac-system-proxy.json` holds the previous settings of each service. It
is written before any change. Restore is compare-and-restore: a protocol is reverted only while
it still reads `127.0.0.1:<our port>`, so a change the user made in between stays.

## Crash recovery

| Record | File | Reconciled |
|---|---|---|
| Device proxy ledger | `~/.jaca/network/device-proxies.json` | jacad start, app start, each adb precheck |
| Mac system proxy lease | `~/.jaca/mac-system-proxy.json` | jacad start, app start, each acquire |

- Device proxy reconcile reverts an entry only when its owner pid is dead (or the entry is older
  than 7 days), and the device still reads exactly the value Jaca wrote. An entry for an offline
  device stays until the device is back.
- The ledger is a separate file from `TunnelLedger`. An older build skips a tunnel entry with an
  unknown kind and would lose its cleanup.
- Both files decode tolerantly and skip a bad record (`CloudPersistence.decodeArray`).
- SIGINT, SIGTERM and SIGHUP restore the Mac system proxy synchronously
  (`MacSystemProxyCleanup.revertAll`). The app's quit path and jacad's stop path call it too.
  `ProxyCleanup` and `AdbTunnelCleanup` revert the device proxy and its reverse on app quit and
  on jacad stop.
- The sidebar Revert banner is the last backstop. It treats a value from a stale ledger entry as
  Jaca's (`StrandedProxyMatch`), and its revert puts back the entry's previous value.

## Who owns the mode

- **The `network` daemon area on.** jacad owns the mode (`NetworkModeController`). The app
  mirrors the retained topic `network.mode` (`RemoteNetworkMode`) and its setter calls
  `network.setMode`.
- **The area off.** The app owns the mode and runs the same `ModeSwitchPlan` over its tabs.
- After a switch, the switching process posts the distributed notification
  `dev.srsouza.Jaca.networkInspectionModeChanged`. The other process follows it.
- The mode does not move capture between processes. Capture runs in jacad when the `network`
  area is on (`DaemonConnector.networkRunsInDaemon`). Companion-only devices stay in the app.

A switch runs these steps, one switch at a time:

1. Publish `network.mode` with `switching: true`.
2. Stop each tab whose source the new mode does not offer, and show its chooser.
3. Wait for every device teardown (`DeviceReleaseGate.settleAll`, `SimulatorProxyHub.settle`).
4. Store the mode and post the notification.
5. Publish `network.mode` and every `net.state.<id>` again.

`network.open` and `network.select` wait until no switch runs.

## The CA install

The capture never installs the CA. The user starts the install.

| Device | Install |
|---|---|
| iOS Simulator | `xcrun simctl keychain <udid> add-root-cert <pem>`, then an offered reboot (`simctl shutdown`, `simctl boot`). |
| Android, `adb root` works | The headless install into the system store. |
| Android, no root | The CA goes to `Download/`; the user installs it (`CAInstallSheet` in the app). |

- GUI: the setup sheet. An Android tab uses the existing CA install sheet; a simulator tab has
  an install button and then a reboot button.
- Herdr: `I` calls `network.installCA`; `B` calls `network.rebootSimulator` after a simulator
  install; `x` dismisses the banner.
- CLI: `jaca net install-ca SESSION`.

A host that fails the TLS handshake twice with no success is relayed raw from then on
(`TLSPassthroughPolicy`), and the status line says so. A failure before any success sets
`proxyNeedsSetup`, which opens the setup sheet (or the Herdr banner).

## Daemon methods and topic

| Method | Params | Result |
|---|---|---|
| `network.mode` | none | `{mode: "agent" \| "mitm", switching}` |
| `network.setMode` | `{mode}` | `{}`, after the switch is done. An unknown name is `invalidParams`. |
| `network.installCA` | `{id}` | `{outcome: "installed" \| "needsUser" \| "failed", message?, rebootAdvised?}` |
| `network.rebootSimulator` | `{id}` | `{}`. Only for an iOS Simulator. |

Retained topic `network.mode`, data `{mode, switching}`.

`network.select` refuses a source that the mode does not offer on the device. Companion stays
refused in jacad.

## Overrides under MITM

Override services go to every capture in both modes. The proxy runs the same `InterceptPipeline`
as the browser capture. Under `.mitmProxy`, a rule with routed hosts fires only on those hosts
(`OverrideHostFilter`). A rule with no routed hosts fires on every host.

## Gaps

- App-scoped rules do not fire: a proxy does not know the app.
- No call stacks and no `httpStack`.
- HTTP/2, gRPC, `wss` and streaming responses do not work: the proxy buffers whole bodies.
- Apps that pin certificates pass through without decryption.
- On Android without root, apps that do not trust user CAs pass through.
- The Mac system proxy changes the whole Mac while a simulator capture runs. Other Mac traffic
  goes through Jaca raw. `networksetup` can need an admin user.
- Companion capture stays observe-only and runs in the app.
- A physical iOS device has no MITM source.
- `jacad` must not die without a restore: a SIGKILL leaves the proxy set until the next reconcile.
