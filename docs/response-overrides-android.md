# Response overrides on Android

**Status: shipped.** Make a **debuggable Android app** receive a response you control — without a
proxy, without installing a CA, and **without disabling certificate pinning**.

This page is the Android path and the shared rule engine. The iOS-Simulator path is
[`response-overrides-ios.md`](response-overrides-ios.md); what the desktop and both agents agree on
is [`divert-contract.md`](divert-contract.md).

Right-click any captured request → *Override response…*, or add one from the **Overrides** button
next to the search field. Rules are toggled on/off individually, apply on the app's **next
request** with no re-attach, and persist across restarts.

---

## Why this works when Charles/Proxyman don't

A MITM proxy sits on the network: it terminates TLS with its own CA, so the app must (a) trust a
user-installed CA and (b) not pin certificates. Plenty of apps fail both. `com.teya.ac.dev` fails
both — its `network_security_config.xml` never trusts user CAs, and it ships five hard-coded
`sha256/` pins.

Jaca's in-process agent intercepts **above TLS**, inside the app. It hooks
`OkHttpClient.interceptors()` and rewrites a matched request's URL to a loopback server on your
Mac before a connection is ever opened:

```
https://private-api.teya.xyz/lending/v1/companies/{uuid}/product-state
                                    ↓  (rewritten in-process, above TLS)
http://localhost:41234/lending/v1/companies/{uuid}/product-state
                                    ↓  (adb reverse)
                        Jaca's override server on your Mac
```

Two properties make this safe on a pinned app:

- **No TLS happens app-side**, so `CertificatePinner` never engages.
- The target is **cleartext to `localhost`**, which the app's own `network_security_config.xml`
  must permit (most debug builds already do).

On the way back the agent restores the original request onto the response, so the app — and
Jaca's own capture — still sees `private-api.teya.xyz`, not `localhost`.

### The layer rule — do not get this wrong

okhttp enforces two invariants on **network** interceptors:

1. must call `proceed()` exactly once, and
2. **must retain the same host and port.**

A network interceptor runs on an already-established connection, so rewriting the URL there throws
`IllegalStateException` on the OkHttp Dispatcher thread and **kills the app process**. That is not
hypothetical — it happened while building this (see [Provenance](#provenance)).

So the agent injects the *same* interceptor object into **both** lists and picks its role at
runtime from `chain.connection()`:

| `chain.connection()` | Layer | Position | What the agent does |
|---|---|---|---|
| `null` | application (`interceptors()`) | **appended** | rewrites the URL; no capture |
| non-null | network (`networkInterceptors()`) | **prepended** | captures/tees; **never** rewrites |

If the layer can't be determined it defaults to *network*, so an unexpected chain shape can never
trigger a rewrite.

**Position matters too.** On the application list the interceptor is *appended*, so the app's own
interceptors (auth, headers) run against the real URL before we repoint it. Prepending would make
a host-gated auth interceptor silently stop attaching its token.

---

## Architecture: rules never touch the device

The device is deliberately kept dumb. Its **entire** override vocabulary is:

```kotlin
Divert.configure(origin: String?, hosts: Set<String>, heartbeatSeconds: Int)
```

An origin, a set of hostnames, and how long that permission lasts. There are **no patterns, no
payloads, no status codes, no ordering, and nothing persisted** on the device. Matching,
precedence, bodies and headers all live desktop-side, which is why editing a rule takes effect on
the next request instead of requiring a rebuild and a re-attach.

> **The tripwire for review:** any change that adds a path, method, header, body, status, ordering
> or rule-id concept to `agent/kotlin/` (or `agent/iOS/`) has crossed that line. In practice it
> shows up in **`OverrideEndpoint`** (`Sources/Core/Intercept/Intercept.swift`) — the one type that
> builds the desktop→device message, produced from exactly one call site
> (`DivertCoordinator.push`), and whose key set is pinned by a test.

`Divert.origin` starts `null`, so a freshly attached agent is **read-only by construction**.

### The interception seam (reusable by design)

Every transport asks the same question and one shared pipeline executes the answer:

```swift
protocol InterceptResolving: Sendable {
    func resolve(_ request: InterceptedRequest,
                 capabilities: InterceptCapabilities) -> (InterceptDecision, InterceptSkipReason?)
}
```

`OverrideMatching.decide(_:transport:capabilities:masterEnabled:)` is **the clamp** — the single
place degradation is decided. A rule that a transport can't honour produces the same decision and
the same user-facing explanation everywhere, and the editor runs the clamp *speculatively while
you type* so you're warned before a request ever fails.

| Interception point | Reaches the desktop via | Capabilities | Status |
|---|---|---|---|
| `.agentDivert` | `OverrideServer` on `127.0.0.1:P`, `adb reverse tcp:P tcp:P` | `.desktopTerminated` | **shipped** |
| `.iosSimulatorDivert` | the same server, plain loopback, no tunnel | `.desktopTerminated` | **shipped** — see the [iOS doc](response-overrides-ios.md) |
| `.mitmProxy` (HTTPS decryption) | would be `ProxyHandler.forward` | `.desktopTerminated` | **not wired** — no pipeline yet |
| `.companionMetadata` | gRPC `StreamFlows` | `.observeOnly` | degrades, explains why |

Adding HTTPS decryption means calling `pipeline.run(_:capabilities:)` from that transport and
declaring what it supports — not reimplementing matching or precedence.

### The arming half

Both halves of the seam are now transport-neutral. **`DivertCoordinator`** (formerly
`AgentDivertCoordinator`) owns the override server, the control frames and the heartbeat, and knows
nothing about adb: how the device reaches our loopback port lives behind
**`protocol DivertTunnel`** — `AdbReverseTunnel` in `Core/Network/` (next to `AdbTunnelCleanup`,
because opening one creates OS-global state) and `SharedLoopbackTunnel` in `Core/Overrides/` (a
no-op: the simulator is already on the Mac's loopback, so `needsTunnelLedger` is false and nothing
is ever written to the ledger).

What every override surface renders is one enum, **`InterceptArmingState`**
(`Core/Intercept/InterceptArmingState.swift`), with one case per way this can be silently doing
nothing: `.idle`, `.waitingForAgent`, `.agentTooOld`, `.waitingForApp(appID:)`, `.detached(appID:)`,
`.active(port:hosts:)`, `.failed`. It replaced a `State` nested inside the coordinator *and* the
never-implemented `InterceptArming` protocol — a protocol with one conformer and one caller is not a
seam, and the readers were `if case` checks the compiler could not exhaustively police. They are
`switch`es now.

### Blast radius

Only hosts named by **enabled** rules are routed through the Mac. Everything else stays on the
device's own network, untouched. A request that reaches the override server and matches no rule is
bounced with `599` + `X-Jaca-Divert: retry-direct`, and the agent re-sends it directly — so VPN,
cookies, HTTP/2 and DNS are all preserved for traffic you aren't mocking.

A pattern that doesn't name a literal host (`**/product-state`, or any regex) derives **no** hosts,
and the editor asks you which to route. Jaca never routes "everything".

---

## Matcher semantics

One text field plus a method filter. Glob by default; regex when you need it.

| Rule | Behaviour |
|---|---|
| `*` | any characters **except** `/` — one path segment |
| `**` | any characters **including** `/` |
| Anchoring | the pattern must match the **whole** URL; `https://a.com/v1` does not match `/v1/users` |
| Scheme | omitted ⇒ either; `api.x.com/**` ≡ `*://api.x.com/**` |
| Port | compared **only if** the pattern names one |
| Case | scheme + host case-**insensitive**; path + query case-**sensitive** |
| Query | **ignored unless the pattern contains `?`**; then every `k=v` must be present (values may use `*`), extra request params are fine, order irrelevant |
| Fragment | never matched (never sent) |
| Methods | empty set == any |

**Precedence: the first *enabled* rule in list order wins** — a firewall table, not a specificity
score, so the winner is always visible. The editor's live preview counts how many captured
requests a pattern matches and how many are *shadowed* by an earlier rule, with a one-click
"Move this rule up".

**Generalize** rewrites UUID-shaped and numeric path segments to `*`, which is how you get from
one company's `product-state` to every company's without learning glob syntax first.

---

## Teardown: five layers

A stale `adb reverse` is worse than a stale forward — it points the app's `localhost:P` at a
listener that no longer exists. So teardown does not depend on Jaca being alive:

| # | Mechanism | Survives |
|---|---|---|
| L1 | Ordered `stop()`: disarm (**flushed** to `send(2)`) → close tunnel → close server | tab stop/close, source switch |
| L2 | `AdbTunnelCleanup.revertAll()` from `applicationWillTerminate` + SIGINT/SIGTERM/SIGHUP | graceful quit, ^C |
| L3 | **Agent socket-EOF disarm** | SIGKILL, Force Quit, crash, unplug |
| L4 | **Agent heartbeat expiry**, checked on the match path (not a timer thread, so Doze can't starve it) | Mac asleep, half-open socket |
| L5 | `TunnelLedger` reconcile at next launch | a prior SIGKILL |

Plus **fail-open**: if the tunnel is unreachable mid-request, the agent disarms and retries the
original request once. Verified — see Provenance.

This also fixed a **pre-existing** leak: `AgentController.stop()` removed its `adb forward` from a
detached `Task` that didn't survive `NSApp.terminate`, so quitting mid-capture stranded one
forward per session in the adb server, outliving Jaca itself.

---

## Prerequisites

| Need | Why |
|---|---|
| A **debuggable** app (`android:debuggable="true"`) | `run-as` + `attach-agent` only work on debug builds |
| App permits **cleartext to `localhost`** | otherwise the rewritten request is blocked by the platform |
| Android NDK 27.2.12479018 + CMake 3.22.1 | rebuilding `libsqueezeagent.so` |
| Kotlin (`brew install kotlin`) + `android-36` platform + build-tools | rebuilding the capture dex |

Check the cleartext precondition on any APK:

```bash
AAPT=~/Library/Android/sdk/build-tools/36.0.0/aapt2
$AAPT dump xmltree base.apk --file res/xml/network_security_config.xml
```

You want a `domain-config` with `cleartextTrafficPermitted=true` covering `localhost`. If the app
has none, add one to its **debug** build — still far lighter than the user-CA trust + pinning
disable a MITM proxy would demand.

---

## Smoke procedure

The okhttp layer split, the retry-direct bounce and the fail-open path can't be unit-tested (they
only exist inside a real app process), and getting them wrong kills the user's app. Verify them by
hand after touching `OkHttpHook.kt`, `Divert.kt` or `SqueezeReporter.kt`:

```bash
./scripts/all.sh                       # agent + app + launch
# In Jaca: pick the debuggable app → Agent capture → right-click a request → Override response…
adb logcat | grep -i squeeze
```

You must see:

```
Instrumented Lokhttp3/OkHttpClient;.networkInterceptors()Ljava/util/List;
Instrumented Lokhttp3/OkHttpClient;.interceptors()Ljava/util/List;
Kotlin capture loaded on isolated loader; handler installed
reporter listening on localabstract:squeeze_…
divert configured: origin=http://localhost:… hosts=[…]
divert: https://…real-host… -> http://localhost:…
```

Then check, in order:

1. the overridden endpoint returns your payload, and the row is badged in the list;
2. **editing the rule applies on the next request** — no force-stop, no re-attach;
3. an unmatched request on the same host still succeeds (599 bounce → direct retry, **one** row);
4. `kill -9` Jaca → the app keeps working (`host disconnected — divert disarmed`);
5. after a normal quit, `adb forward --list` and `adb reverse --list` are both empty.

**Zero app crashes is a release blocker.**

### Watching the raw feed without Jaca

The agent reports all traffic as newline-delimited JSON on its `localabstract` socket:

```bash
PORT=$(adb -s <serial> forward tcp:0 localabstract:squeeze_<name>)
nc localhost $PORT | jq -rc 'select(.type=="txn") | "\(.status) \(.method) \(.url)"'
```

The same socket is now **bidirectional** — writing a `{"type":"divert",…}` line to it is exactly
how Jaca arms the device.

---

## Platform support

Response overrides run on **Android** (the in-process agent's okhttp3 divert) and on the **iOS
Simulator** (the injected agent's `NSURLProtocol` divert). The rule engine, matcher, clamp,
persistence and UI are transport-neutral and shared by both.

| Transport | Seam modelled | Wired |
|---|---|---|
| `.agentDivert` (Android) | yes | **yes — shipping** |
| `.iosSimulatorDivert` | yes | **yes — shipping**, see [`response-overrides-ios.md`](response-overrides-ios.md) |
| `.mitmProxy` (HTTPS decryption) | yes | no — `ProxyServer` has no pipeline |
| `.companionMetadata` | yes | n/a — `.observeOnly`, flow metadata can't be overridden |

The iOS Simulator turned out to be structurally simpler than Android (no tunnel, no CA, no pinning
gate) but to have one problem Android doesn't: the agent dies with the app process, so an app the
user reopens outside Jaca comes back uninstrumented. iOS *physical devices* remain out of reach
short of the MITM proxy — injection needs `simctl`.

Transport-dependent wording lives in one place (`InterceptTransportCopy.swift`) and the "why this
row can't be overridden" decision in another (`OverrideRowGate`), both pure and unit-tested. The
reason is a landmine that was live for one commit: `httpStack` is an **Android** concept, and a row
gate that tested it for `okhttp3.` would disable *Override response…* on every iOS row the day the
iOS agent started reporting `"urlsession"`.

## Limitations

- **Only okhttp3.** okhttp2, `HttpURLConnection`, Cronet and HTTP/3 keep the read-only capture path.
- **Cookie-jar auth is lost on diverted requests.** okhttp's `BridgeInterceptor` runs after all
  application interceptors and loads cookies for the *rewritten* URL. Host-scoping is what makes
  this survivable.
- **Streaming responses aren't overridable.** SSE/gRPC requests are bounced with retry-direct: the
  desktop buffers whole bodies, so a streamed exchange would hang end-to-end.
- **One-shot/duplex request bodies are never diverted** — they can't be re-sent, so they must not
  be eligible for the bounce.
- **Diverted traffic is cleartext between app and Mac.** It's loopback over the adb tunnel, and the
  server binds `127.0.0.1` only. Fine for a debug session; never for anything else.
- **"Send and override" fetches from your Mac**, not the device, so origins reachable only from the
  device won't work. The editor says so.

---

## Provenance

The mechanism was proven in a Claude Code session against a real pinned app, then productised and
re-verified end to end.

| | |
|---|---|
| Original POC session | `1307b816-35a3-4b4f-9ff7-868913d43fac`, 2026-08-25 |
| Device | `emulator-5554`, `sdk_gphone16k_arm64`, Android 17 (SDK 37), arm64-v8a, 16 KB pages |
| App | `com.teya.ac.dev` 3.0.0 — `debuggable=true`, `targetSdk 36`, **5 hard-coded cert pins** |
| POC result | 3/3 requests diverted and served from a mock, 0 crashes |
| Productised + verified | 2026-08-26 |

The 2026-08-26 verification, against the same pinned app, confirmed:

- the agent advertises `override/1` in its hello frame, and applies a `divert` control frame live
  (`divert configured: origin=http://localhost:41234 hosts=[id.teya.xyz, private-api.teya.xyz]`);
- two pinned hosts were diverted with their original URLs preserved;
- **the app received a fabricated `299` response with our body at the real
  `https://id.teya.xyz/authn/anonymous/api/auth_requests`** — and the captured row reported that
  real HTTPS URL, not `localhost`;
- an unmatched request was bounced `599 retry-direct`;
- killing the desktop server produced `divert: tunnel unreachable, failing open and retrying direct`
  and the app kept working;
- closing the socket produced `host disconnected — divert disarmed`;
- **zero crashes**, and no `adb reverse` entries left behind.

### Dead ends worth remembering

- The agent `.so` was 4 KB-aligned and **could not load at all** on the 16 KB-page emulator
  (`program alignment (4096) cannot be smaller than system page size (16384)`). Fixed by
  `-Wl,-z,max-page-size=16384` in `agent/native/CMakeLists.txt`. **This regressed once** — the
  original POC documented the fix but it was never committed, and it resurfaced during
  productisation. The flag is now in the file with a comment explaining why it isn't optional.
- The first divert attempt ran on the **network** interceptor and crashed the app with
  *"must retain the same host and port"*. That is what forced the application/network split above.
- A fourth comma-separated field in the `attach-agent` spec would **silently break capture** on an
  older `.so`: `squeeze_agent.cc` assigns `socketName = opts.substr(c2 + 1)` — the entire remainder
  — so the agent would bind a `localabstract` name no `adb forward` matches. The control channel
  reuses the existing socket instead, which also avoids the `attach()` early-return that freezes
  anything carried in the spec for the process lifetime.

## See also

- `agent/kotlin/com/squeeze/capture/Divert.kt` — the entire on-device surface
- `agent/kotlin/com/squeeze/capture/OkHttpHook.kt` — layer detection, rewrite, bounce, fail-open
- `agent/kotlin/com/squeeze/capture/SqueezeReporter.kt` — the bidirectional control channel
- `Sources/Core/Intercept/` — the transport-neutral seam and pipeline
- `Sources/Core/Overrides/` — rules, matching, the clamp, the server, the tunnel coordinator
- `Sources/Model/OverridesModel.swift` — the single observable owner
- [`divert-contract.md`](divert-contract.md) — the frame, the 599 pair, the dead-man window
- [`response-overrides-ios.md`](response-overrides-ios.md) — the iOS-Simulator transport
- `README.md` — how the in-process agent works in general
