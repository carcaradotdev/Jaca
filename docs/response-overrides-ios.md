# Response overrides on iOS — feasibility and POC plan

**Status: not implemented.** Response overrides currently run on **Android only**. This document
records what would be involved on iOS, what is already prepared, and what is not — so a POC can
start from evidence rather than from scratch.

Companion doc: [`response-overrides-android.md`](response-overrides-android.md) (the shipped
Android feature).

---

## Summary

| Target | Feasible? | Mechanism | Notes |
|---|---|---|---|
| **iOS Simulator** | **Yes — easier than Android** | `NSURLProtocol` in the injected agent | No tunnel, no CA, no pinning problem |
| **iOS physical device** | **No** (as an in-process divert) | — | Can't inject without a jailbreak; only the MITM proxy applies, which needs CA trust + no pinning |

The Simulator case is genuinely simpler than Android. The physical-device case loses the entire
property that makes this feature worth having.

---

## Why the Simulator is easier than Android

Android's implementation spends most of its complexity on things that **do not exist** here:

| Android problem | iOS Simulator |
|---|---|
| `adb reverse` tunnel to reach the Mac | **None needed** — the simulator shares the Mac's loopback |
| Tunnel teardown, `TunnelLedger`, orphan reconcile | **Not applicable** — nothing to leak |
| `network_security_config` must permit cleartext to localhost | **No such gate** |
| `CertificatePinner` would break a proxy | **Irrelevant** — we're above TLS *and* we own the replay |
| okhttp3-only (okhttp2 / `HttpURLConnection` / Cronet untouched) | `NSURLProtocol` covers all `URLSession` / `NSURLConnection` traffic |
| Attach spec frozen per process (`attach()` early-returns) | Agent re-injected on every launch |

### The hook point is better

`agent/iOS/JacaNetAgent.m` registers an `NSURLProtocol` subclass and replays each request through
a private `NSURLSession` (`startLoading`, line ~100). `NSURLProtocol` is *designed* to let the
subclass supply the response — the URL-loading system will accept whatever
`URLProtocol:didReceiveResponse:` / `didLoadData:` / `didFinishLoading:` hands it.

So there are two possible strategies, and the choice matters:

1. **Replay through the desktop override server** (mirrors Android) — point the replay request at
   `http://127.0.0.1:<overridePort>` carrying `X-Jaca-Original-URL`. Rules, payloads and matching
   stay on the desktop. **Recommended.**
2. **Fabricate locally in `startLoading`** — technically the shortest path, but it requires the
   payload and matcher to live in the agent, which breaks the rule this feature is built around
   (see *The tripwire* in [`response-overrides-android.md`](response-overrides-android.md)). **Don't.**

### The control channel is already half-built — and inverted in our favour

On Android the agent **listens** (`LocalServerSocket`), and making it bidirectional was a
deliberate piece of work. On iOS it is the other way round:

```objc
// JacaNetAgent.m:4-5 — "On load it connects back to Jaca on 127.0.0.1:$JACA_NET_PORT"
```

The agent is a **TCP client** and Jaca is the server, so Jaca can already write down the same
connection it is reading transactions from. No new socket, no new port, no protocol negotiation.

---

## What is already prepared

These exist and are unit-tested today:

- **`InterceptTransportID.iosSimulatorDivert(bundleID:)`** — the transport case, with a label used
  in degradation messages.
- **Redirect policy is already keyed for it.** `InterceptServices.pipeline(for:deviceID:appID:)`:
  ```swift
  case .agentDivert, .iosSimulatorDivert: policy = .follow(max: 5)
  case .mitmProxy, .companionMetadata:    policy = .doNotFollow
  ```
  (Divert *must* follow redirects on the Mac, or the app leaves the tunnel chasing a 3xx.)
- **`OverrideServer` binds `127.0.0.1`** — directly reachable from the simulator.
- **`AgentOriginalURL.recover(headers:uri:)`** is transport-neutral: `X-Jaca-Original-URL` first,
  `Host` + origin-form URI as fallback.
- **The entire rule layer** — `OverrideRule`, `OverrideMatching` (glob/regex + the clamp),
  `OverrideCompiler`, `OverrideResolver`, `OverrideRuleStore`, `ResponseEditing`,
  `InterceptPipeline` — plus all the UI. None of it knows what a device is.
- **`InterceptPipeline.UnmatchedPolicy.handBack`** — the "don't fetch, let the device send it"
  behaviour the bounce depends on.

---

## What is NOT prepared

Be honest with the estimate; these are real:

1. **`IOSSimulatorAgentCaptureSource` is not wired.** It takes no `intercept:` parameter and
   declares no `interceptCapabilities`, so it reports `[]` and every rule clamps to "can't run
   here". `CaptureSourceRegistry` passes `intercept:` to the Android source only.
2. **`IOSSimulatorAgentController` has no arming** — no override server start, no endpoint push.
3. **`JacaNetAgent.m` has no divert code.** Its socket is read-only reporting today; nothing
   parses inbound control frames, and `startLoading` always replays to the real URL.
4. **The arming half of the seam is hard-typed to Android.** This is the main structural blocker:
   ```swift
   // InterceptServices.swift:25,27
   var onArmingChange:        (InterceptTarget, AgentDivertCoordinator.State) -> Void
   var onRegisterCoordinator: (InterceptTarget, AgentDivertCoordinator?) -> Void
   // CaptureSource.swift:47
   var arming: AgentDivertCoordinator? { get }
   ```
   `AgentDivertCoordinator` is the adb-specific type (it owns `adb reverse`). The
   *resolve/execute* half of the seam is genuinely transport-neutral; the *arming* half is not.

   Note an `InterceptArming` protocol **already exists** at `Intercept.swift:194` — but nothing
   conforms to it and nothing calls it, so it is currently dead code rather than a working seam.
   The refactor is: make `AgentDivertCoordinator` actually conform, generalise `State` (or expose
   it as a small neutral enum), and change the three signatures above to use the protocol.

---

## POC plan

Goal: **prove an iOS Simulator app receives a response Jaca fabricated**, with rules staying
desktop-side. Cut everything else.

### Step 0 — shortcut the plumbing

Don't build arming, don't refactor the seam, don't touch the UI. Pass the override port the same
way the reporting port already travels:

```swift
// IOSSimulatorAgentController.swift — alongside the existing SIMCTL_CHILD_* vars
env["SIMCTL_CHILD_JACA_OVERRIDE_PORT"] = String(overrideServerPort)
env["SIMCTL_CHILD_JACA_OVERRIDE_HOSTS"] = "api.example.com"   // comma-separated
```

Frozen per launch, which is fine for a POC. (Live updates come later over the existing socket —
see *Step 4*.)

### Step 1 — divert in `startLoading`

In `JacaNetAgent.m`, before building the replay request:

```objc
// Only for hosts the desktop named; everything else replays untouched.
if (jacaShouldDivert(req.URL.host)) {
    NSURL *original = req.URL;
    NSString *target = [NSString stringWithFormat:@"http://127.0.0.1:%d%@",
                        gOverridePort, jacaPathAndQuery(original)];
    [req setValue:original.absoluteString forHTTPHeaderField:@"X-Jaca-Original-URL"];
    req.URL = [NSURL URLWithString:target];
}
```

### Step 2 — honour the retry-direct bounce

The desktop answers `599` + `X-Jaca-Divert: retry-direct` for anything no rule matches. In
`URLSession:dataTask:didReceiveResponse:`, detect that pair and **re-issue the original request**
instead of passing the 599 up to the app. Also drop that exchange from the reported transaction,
so the retry is the only row (Android does this via `SqueezeTracker.cancel()`).

### Step 3 — fail open

If the replay to `127.0.0.1:<port>` errors (connection refused — Jaca quit), retry the original
URL once and stop diverting. On Android this is what stops a dead desktop from bricking the app;
the same reasoning applies here even though there's no tunnel to go stale.

### Step 4 — (after the POC works) live rule updates

Replace the env var with control frames on the socket the agent already holds open. Jaca is the
server, so it can just write:

```json
{"type":"divert","origin":"http://127.0.0.1:41234","hosts":["api.example.com"],"heartbeatSeconds":15}
```

Reuse `AgentDivertCoordinator.divertFrame(origin:hosts:heartbeatSeconds:)` verbatim — the wire
format is already transport-neutral and unit-tested (`TunnelLedgerTests`).

### Verifying

The Android smoke procedure transfers directly. The decisive check is the same one used there:
capture must report the **real** `https://` URL while the body is the fabricated one. Run the app,
then:

```bash
grep -E 'answered|bouncing' ~/.jaca/logs/jaca.log
```

---

## Lessons from Android that carry over

- **Fail-open and a dead-man switch matter even without a tunnel.** The failure mode that hurt
  most was "armed but silently doing nothing".
- **A keepalive must be able to *re-arm*, not just refresh a timer.** Android's original bare
  `ping` couldn't repair a desync, so one lapsed window killed overrides permanently. If iOS gets
  a heartbeat, send the full endpoint frame.
- **Never let the UI claim overrides are active when nothing is armed.** Check that the transport
  actually wired up, not just that rules exist.
- **Don't infer the HTTP stack from a call stack.** On Android, `callStack` deliberately strips
  okhttp frames, so testing it for `okhttp3.` disabled the feature on every row. The agent reports
  `httpStack` explicitly instead. iOS has no equivalent ambiguity (`NSURLProtocol` sees
  everything), so the context menu should simply not gate on it.

## Known limits on iOS Simulator

- `NSURLProtocol` does **not** see: background `URLSession` configurations, `WKWebView` traffic
  (separate networking process), or anything using raw sockets / a bundled stack (some
  Flutter/gRPC paths).
- Injection needs `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`, so it's **debug builds launched by Jaca**
  only — attaching to an already-running app isn't possible.

## See also

- [`response-overrides-android.md`](response-overrides-android.md) — the shipped Android feature and its traps
- `agent/iOS/JacaNetAgent.m` — the `NSURLProtocol` interceptor
- `Sources/Core/Network/IOSSimulatorAgentController.swift` — injection + env plumbing
- `Sources/Core/Intercept/` — the transport-neutral seam
