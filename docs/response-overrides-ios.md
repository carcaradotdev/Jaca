# Response overrides on the iOS Simulator

**Status: shipped.** Right-click a captured request in an iOS-Simulator agent tab → *Override
response…*, exactly as on Android. Rules, matching, precedence and payloads are the same
desktop-side engine; only the transport differs.

Companion docs: [`response-overrides-android.md`](response-overrides-android.md) (the feature and
its traps) and [`divert-contract.md`](divert-contract.md) (what the desktop and the two agents
agree on).

| Target | Supported | Mechanism |
|---|---|---|
| **iOS Simulator** | **yes** | `NSURLProtocol` in the injected agent, diverting to a loopback server on the Mac |
| **iOS physical device** | no | Injection needs `simctl`. Only the MITM proxy applies there — which is the thing this feature exists to avoid needing |

---

## Why the Simulator is the easy case

Android spends most of its complexity on things that don't exist here:

| Android problem | iOS Simulator |
|---|---|
| `adb reverse` tunnel to reach the Mac | **nothing to open** — the simulator shares the Mac's loopback (`SharedLoopbackTunnel`) |
| Tunnel teardown, `TunnelLedger`, orphan reconcile | **not applicable** — nothing is created, so nothing can outlive a `SIGKILL`. Asserted twice: `DivertTunnelTests` and live case 5 |
| `network_security_config` must permit cleartext to localhost | no such gate |
| `CertificatePinner` would break a proxy | irrelevant — we're above TLS *and* we own the replay |
| okhttp3-only (okhttp2 / `HttpURLConnection` / Cronet untouched) | `NSURLProtocol` sees all `URLSession` / `NSURLConnection` traffic |
| Attach spec frozen per process (`attach()` early-returns) | the agent is re-injected on every launch |

The control channel is also inverted in our favour. On Android the agent *listens*; here it is a
TCP **client** that dials `127.0.0.1:$JACA_NET_PORT`, so Jaca writes divert frames back down the
very connection it already reads transactions from. No new socket, no new port.

What the Simulator has instead is a problem Android doesn't: **the agent lives and dies with the
app process**, and the user can restart their app without Jaca. That is what the re-attach layer
below exists for.

---

## The pieces

```
Sources/Core/Capture/IOSSimulatorAgentCaptureSource.swift   the CaptureSource; declares capabilities
Sources/Core/Network/IOSSimulatorAgentController.swift      composes the session (~200 lines, no sockets)
Sources/Core/Network/AgentLineChannel.swift                 the socket, framing, SO_NOSIGPIPE, flush
Sources/Core/Overrides/DivertCoordinator.swift              override server + tunnel + control frames
Sources/Core/Overrides/DivertTunnel.swift                   SharedLoopbackTunnel (a no-op, by design)
Sources/Core/Devices/SimulatorAppLauncher.swift             the single owner of `simctl launch`
Sources/Core/Network/SimulatorAgentLaunch.swift             the injection env + argv (pure)
Sources/Core/Network/SimulatorAttachSupervisor.swift        notices an app running without the agent
Sources/Core/Network/SimulatorReattachPolicy.swift          the three-way decision (pure)
agent/iOS/JacaNetAgent.m                                    the NSURLProtocol tap + divert client
agent/iOS/JacaNetChannel.{h,m}                              transport only: dial, hello, frames, EOF
agent/iOS/JacaDivert.{h,m}                                  the Divert.kt twin — state, window, targetFor
```

Everything above `DivertCoordinator` is shared with Android. The transport-specific parts are the
tunnel (which does nothing), the launcher, and the agent itself.

## The path a request takes

```
app: GET https://api.example.com/v1/thing
        ↓  NSURLProtocol tap (JacaNetAgent), above TLS, in-process
        ↓  host is in the routed set and the window is alive?  (JacaDivert)
   GET http://127.0.0.1:41234/v1/thing        X-Jaca-Original-URL: https://api.example.com/v1/thing
        ↓  plain loopback — the simulator IS on the Mac
   OverrideServer → InterceptPipeline → the same rules Android uses
        ↓
   a rule matched  → fabricated/edited response, stamped X-Jaca-Override
   nothing matched → 599 + X-Jaca-Divert: retry-direct → the agent re-sends it directly
        ↓
   the original URL is restored onto the response before the app sees it
```

The captured row reports `self.request` — the app's *original* request — so a diverted exchange is
still reported as the real `https://` URL, with none of Jaca's headers. Live case 1 asserts both
halves of that.

### Arm before launch

`IOSSimulatorAgentController.start()` binds the listener, claims the launcher, **starts the
coordinator**, and only then launches the app. The ordering is load-bearing: the override server and
the endpoint have to exist before the app's process does, or the app's very first request — usually
the one you wanted to override — sails straight past. `AgentController.run()` does the same on
Android for the same reason.

### One capability constant, two readers

`IOSSimulatorAgentCaptureSource.nativeCapabilities = .desktopTerminated` is threaded down —
source → controller → `DivertCoordinator` → `OverrideServer` → `pipeline.run(capabilities:)` — with
no default anywhere on that chain. The value the toolbar shows and the value the clamp applies are
provably the same constant (`OverrideClampTests`). A source constructed **without** `intercept:`
declares `[]` and can never arm.

---

## App lifetime: the failure this platform actually has

The dylib is injected with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`, so it is only in the process Jaca
launched. Quit the app and reopen it from the Home screen and it comes back **uninstrumented** —
and every desktop surface would happily keep claiming overrides were active.

Detection is event-driven and costs nothing while healthy:

| Signal | Then |
|---|---|
| `channel.onDisconnected` (socket EOF) | one `SimulatorProcesses.probe`, then 2 s → 4 s → 8 s → 15 s while unhealthy, cancelled the moment the agent reconnects |
| 6 s after a launch with no first bytes | the dylib never loaded — the status line says so and names the file |

**While the agent is connected there is no timer and no `simctl` spawn at all.** The POC polled
`simctl` every 2 s in the *idle* case, which is the common one.

The probe's answer becomes an arming state, so there is exactly one channel for "is this transport
working" rather than a second one bolted on beside it:

| Probe | State | UI |
|---|---|---|
| `.running(pid:)` while the socket is down | `.detached(appID:)` | Attach banner: **"Capture detached"**, one action *Relaunch & re-attach*. Amber bolt, row overrides blocked |
| `.notRunning` | `.waitingForApp(appID:)` | **"Capture paused" — open the app to resume.** No button: Jaca never reopens an app the user deliberately quit |
| `.notBooted` | `.failed(…)` | "The simulator isn't booted any more — start it and restart capture." |

`SimulatorReattachPolicy` is a pure truth table and the default is **`.askUser`**. Turning on
*Settings → Re-attach to iOS Simulator apps automatically* (`FeatureFlags.simulatorAutoReattachEnabled`,
default off) relaunches without the click — still announced in the status line, never silently, and
budgeted to two consecutive automatic relaunches so a dylib that can't load can't restart the user's
app forever.

### Who is allowed to launch the app

`SimulatorAppLauncher` is the single owner of `simctl launch` per `(udid, bundleID)`, because two
subsystems want to launch the same app with different environments:

- **Network** claims the key exclusively and supplies the injection environment. A second Network
  tab on the same app fails loudly (`.alreadyClaimed`) instead of stealing the port the first tab's
  agent is dialling.
- **Logs** keeps its own `--console-pty` process (it needs the PTY stream), but merges
  `environment(for:)` and calls `noteExternalLaunch`. Without that merge, opening a Logs tab would
  `--terminate-running-process` the app back without the agent — permanently, and silently.

---

## Proving it works

The one property this feature exists for — *the app received a body Jaca fabricated* — is invisible
from every desktop surface. The toolbar, the popover, the rule list and even the captured rows can
all look healthy while nothing is being diverted. The only place the truth exists is inside the
app's own response.

> **Note — the automated end-to-end proof was removed.** It was a committed Simulator probe app
> (`agent/iOS/OverrideProbe/`) driven by `Tests/LiveSimulatorOverrideTests.swift`. Because a
> Simulator app runs as a native macOS process, its ordinary Foundation call to locate its own
> container (`NSSearchPathForDirectoriesInDomains` → `getpwuid`) read `/private/etc/passwd`, which
> tripped endpoint security tooling. The fixture and its live suite were deleted rather than kept.
> **This leaves the feature without an automated end-to-end test** — the pure units below still
> cover the pieces, but nothing asserts the whole chain against a real app. If the proof is
> reinstated, have the harness pass the container path into the app (via `SIMCTL_CHILD_*`) instead
> of letting the app resolve it, so no user-domain lookup happens.

What the pure tests still cover:

- `Tests/ObjC/JacaDivertTests.m` — the agent's divert decisions (host match, the dead-man window,
  the 599 retry-direct pair, URL restore), run on the host.
- `Tests/DivertCoordinatorTests.swift` — arming, the pre-hello silence, teardown order, the
  start-after-stop guard, presence → state.
- `Tests/AttachDetectionTests.swift` — a lost agent surfaces even with overrides off.
- `Tests/OverrideEndpointFrameTests.swift`, `Tests/DivertTunnelTests.swift`,
  `Tests/OverrideClampTests.swift` — the frame contract, the tunnel, the capability clamp.

### Doing it by hand

```bash
./scripts/all.sh                 # build + launch Jaca
# Settings → enable "Response overrides"; pick a booted simulator + a debug app → Agent capture
# right-click a captured row → Override response…
grep -E 'divert|answered|bouncing' ~/.jaca/logs/jaca.log
xcrun simctl spawn booted log stream --predicate 'process == "YourApp"'
```

---

## Known limits

- **`NSURLProtocol` blind spots.** Background `URLSession` configurations, `WKWebView` (a separate
  networking process), and anything on raw sockets or a bundled stack (some Flutter/gRPC paths) are
  never seen — so they can't be captured *or* overridden. The capture-chooser copy no longer
  promises coverage it lacks.
- **Debug builds launched by Jaca only.** Injection is `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`;
  attaching to an already-running app isn't possible. That is the whole reason the re-attach layer
  exists.
- **Streaming responses aren't overridable.** SSE/gRPC requests are bounced with retry-direct — the
  desktop buffers whole bodies, so a streamed exchange would hang end-to-end.
- **Request bodies that can't be re-read are never diverted**, because both safety nets re-send the
  request.
- **Diverted traffic is cleartext between app and Mac.** It's loopback, and the server binds
  `127.0.0.1` only. Fine for a debug session; never for anything else.
- **Binary bodies are omitted, not fabricated.** The agent drops the body key for non-UTF-8 data and
  reports the true `requestSize`/`responseSize`, so a row says "no body captured" with a correct
  size instead of showing a placeholder that looks like real text.

## Deliberately not done

- **Simulator-wide `launchctl setenv DYLD_INSERT_LIBRARIES`** and **`LC_LOAD_DYLIB` bundle
  patching** — the only two true fixes for app lifetime, and both rejected: they load the dylib into
  SpringBoard and every daemon, or mutate the user's installed binary, and they leave persistent
  global state on a device Jaca doesn't own. That re-imports the whole tunnel-ledger/orphan-reconcile
  problem class that this platform is uniquely free of.
- **`CoreSimulator` private-API process notifications** — the right long-term push signal, but a new
  Xcode-fragile surface to replace a probe that is already idle-free and bounded.
- **Physical devices** — see the table at the top.

## See also

- [`divert-contract.md`](divert-contract.md) — the frame, the 599 pair, the window, host matching
- [`response-overrides-android.md`](response-overrides-android.md) — the feature, the rule engine,
  and the Android path
- `Tests/ObjC/JacaDivertTests.m` — the agent's decisions, tested on macOS
