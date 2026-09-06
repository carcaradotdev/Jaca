# Overriding a response with the in-process agent (experimental)

How to make a **debuggable Android app** receive a response you control, without a proxy,
without installing a CA, and **without disabling certificate pinning**.

> **Status: experimental proof of concept.** One hard-coded endpoint, a compile-time flag,
> and a Python mock server. There is no UI and nothing is persisted. The mechanism is proven
> end-to-end (see [Provenance](#provenance)); the productisation is not built yet.

---

## Why this works when Charles/Proxyman don't

A MITM proxy sits on the network: it terminates TLS with its own CA, so the app must (a) trust
a user-installed CA and (b) not pin certificates. Plenty of apps fail both. `com.teya.ac.dev`
fails both — its `network_security_config.xml` never trusts user CAs, and it ships five
hard-coded `sha256/` pins.

The in-process agent intercepts **above TLS**, inside the app, so neither matters. It hooks
`OkHttpClient.interceptors()` and rewrites the request's URL to a local mock server before a
connection is ever opened:

```
https://private-api.teya.xyz/lending/v1/companies/{uuid}/product-state?locale=en
                                    ↓  (rewritten in-process)
http://localhost:8099/lending/v1/companies/{uuid}/product-state?locale=en
                                    ↓  (adb reverse tcp:8099)
                          mock server on your Mac
```

Two properties make this safe on a pinned app:

- **No TLS happens app-side**, so `CertificatePinner` never engages.
- The target is **cleartext to `localhost`**, which this app's `network_security_config.xml`
  already permits. No CA, no app change.

On the way back the agent restores the original request onto the response, so the app (and
Jaca's own capture) still sees `private-api.teya.xyz`, not `localhost`.

### The layer rule — do not get this wrong

okhttp enforces two invariants on **network** interceptors:

1. must call `proceed()` exactly once, and
2. **must retain the same host and port.**

A network interceptor runs on an already-established connection, so rewriting the URL there
throws `IllegalStateException` on the OkHttp Dispatcher thread and **kills the app process**.
That is not hypothetical — it happened while building this (see [Provenance](#provenance)).

So the agent injects the *same* interceptor object into **both** lists and picks its role at
runtime from `chain.connection()`:

| `chain.connection()` | Layer | What the agent does |
|---|---|---|
| `null` | application (`interceptors()`) | rewrites the URL; no capture |
| non-null | network (`networkInterceptors()`) | captures/tees; **never** rewrites |

If the layer can't be determined it defaults to *network*, so an unexpected chain shape can
never trigger a rewrite.

---

## Prerequisites

| Need | Why |
|---|---|
| A **debuggable** app (`android:debuggable="true"`) | `run-as` + `attach-agent` only work on debug builds |
| App permits **cleartext to `localhost`** | otherwise the rewritten request is blocked by the platform |
| Android NDK 27.2.12479018 + CMake 3.22.1 | rebuilding `libsqueezeagent.so` |
| Kotlin (`brew install kotlin`) + `android-36` platform + build-tools | rebuilding the capture dex |
| Python 3 | the mock server |

Check the cleartext precondition on any APK:

```bash
AAPT=~/Library/Android/sdk/build-tools/36.0.0/aapt2
$AAPT dump xmltree base.apk --file res/xml/network_security_config.xml
```

You want a `domain-config` with `cleartextTrafficPermitted=true` covering `localhost`. If the
app has none, add one to its **debug** build — still far lighter than the user-CA trust +
pinning-disable changes a MITM proxy would demand.

---

## Overriding a value

### 1. Point the rule at your endpoint

`agent/kotlin/com/squeeze/capture/PocDivert.kt`:

```kotlin
const val ENABLED = true                                   // master switch
private const val MATCH_ORIGIN   = "https://private-api.teya.xyz"
private const val MATCH_PATH     = "/lending/v1/companies/"
private const val MATCH_ENDPOINT = "/product-state"
private const val LOCAL_ORIGIN   = "http://localhost:8099"
```

A request is diverted when its URL starts with `MATCH_ORIGIN` **and** contains both
`MATCH_PATH` and `MATCH_ENDPOINT`. Path and query carry over untouched, so the rule still
fires for a different company UUID or locale.

Set `ENABLED = false` to make the agent purely read-only again.

### 2. Set the response payload

`scripts/mock-server.py` — edit `PAYLOAD` (a plain Python dict, serialised as JSON) and `PORT`
if you change `LOCAL_ORIGIN`. It answers **any** path with that payload, so matching happens in
the agent, not here.

### 3. Rebuild the agent

Only the dex is needed for a rule/payload change. Rebuild the `.so` too if you touched
`agent/native/`:

```bash
./agent/build-dex.sh                      # capture + boot dex
./agent/build.sh                          # libsqueezeagent.so (only if native changed)

cp agent/out/squeezeagent-capture.dex Resources/
cp agent/out/squeezeagent-boot.dex     Resources/
cp agent/out/arm64-v8a/libsqueezeagent.so Resources/
```

`build-dex.sh` prints harmless `kotlin.Metadata` warnings from d8 (Kotlin 2.4 vs R8's 2.2
support). A successful run ends with `-> out/squeezeagent-capture.dex`.

### 4. Start the mock server and the tunnel

```bash
python3 scripts/mock-server.py &
adb -s <serial> reverse tcp:8099 tcp:8099
```

`adb reverse` makes the **device's** `localhost:8099` reach your Mac, so this works on physical
devices as well as emulators.

### 5. Attach the agent

**Close Jaca first** — see [Gotchas](#gotchas).

```bash
S=<serial>; PKG=<your.package>; TMP=/data/local/tmp; CC=/data/data/$PKG/code_cache

adb -s $S shell am force-stop $PKG
adb -s $S shell monkey -p $PKG -c android.intent.category.LAUNCHER 1
sleep 6
PID=$(adb -s $S shell pidof $PKG | tr -d '\r')

for f in libsqueezeagent.so squeezeagent-boot.dex squeezeagent-capture.dex; do
  adb -s $S push Resources/$f $TMP/$f
done
adb -s $S shell "run-as $PKG rm -rf code_cache/libsqueezeagent.so \
  code_cache/squeezeagent-boot.dex code_cache/squeezeagent-capture.dex code_cache/squeeze_opt"
for f in libsqueezeagent.so squeezeagent-boot.dex squeezeagent-capture.dex; do
  adb -s $S shell "run-as $PKG sh -c 'cat > $CC/$f' < $TMP/$f"
done
adb -s $S shell "run-as $PKG chmod 444 \
  code_cache/squeezeagent-boot.dex code_cache/squeezeagent-capture.dex"   # ART rejects writable dex

adb -s $S shell "cmd activity attach-agent $PID \
  '$CC/libsqueezeagent.so=$CC/squeezeagent-boot.dex,$CC/squeezeagent-capture.dex,squeeze_manual'"
```

### 6. Verify

```bash
adb -s $S logcat -d | grep -E 'SqueezeAgent: (Instrumented|Kotlin capture loaded|re-attach)'
```

You **must** see all of:

```
Instrumented Lokhttp3/OkHttpClient;.networkInterceptors()Ljava/util/List;
Instrumented Lokhttp3/OkHttpClient;.interceptors()Ljava/util/List;
Kotlin capture loaded on isolated loader; handler installed
```

If you see `re-attach: reporter re-pointed to …` instead of `Kotlin capture loaded`, your new
dex was **not** loaded — see [Gotchas](#gotchas).

Then exercise the endpoint in the app:

```bash
adb -s $S logcat -d | grep 'POC divert'
```

```
SqueezeAgent: POC divert: https://private-api.teya.xyz/... -> http://localhost:8099/...
```

and the mock server logs the request with the `X-Jaca-Original-URL` it received.

---

## Watching every endpoint without Jaca

The agent reports **all** traffic (not just the diverted request) as newline-delimited JSON on
the `localabstract:squeeze_<name>` socket — the same feed Jaca's UI reads. Nothing about that
socket needs Jaca: forward it and read it yourself. This is the whole read-only capture, usable
standalone.

```bash
S=<serial>
PORT=$(adb -s $S forward tcp:0 localabstract:squeeze_manual)   # the name you attached with
nc localhost $PORT | jq -rc 'select(.type=="txn") | "\(.status) \(.method) \(.url)"'
```

```
200 GET  https://private-api.teya.xyz/v1/companies?offset=50&limit=50
200 POST https://id.teya.xyz/oauth/v2/oauth-token/cat
403 GET  https://private-api.teya.xyz/merchant-account/v2/business-accounts/…/balances
200 POST https://api.eu.amplitude.com/2/httpapi
```

Each JSON line carries the full transaction, so you can pull whatever you need:

| Field | |
|---|---|
| `type` | `"txn"` (skip other control lines) |
| `method`, `url`, `status`, `error` | the request line + outcome |
| `startedAt`, `responseAt`, `finishedAt` | epoch seconds |
| `requestHeaders`, `responseHeaders` | objects |
| `requestBody`, `responseBody` | strings (bounded; see [Gotchas](#gotchas)) |
| `requestSize`, `responseSize` | byte counts |
| `callStack` | the frames that made the request — the agent's party trick |

Bodies and call stacks too:

```bash
nc localhost $PORT | jq -rc 'select(.type=="txn") |
  "\(.status) \(.method) \(.url)\n  from: \(.callStack[0] // "?")\n  <- \(.responseBody[0:200])"'
```

What you lose without Jaca is the **UI**, not the data: the timeline, JSON-tree view, header
copy, SQLite history, and per-app filtering all live desktop-side. The socket is the raw feed.

---

## Stopping

The agent lives **inside** the app process, so there's nothing to kill separately — end the
process and the agent, the divert, and the capture socket all go with it:

```bash
S=<serial>; PKG=<your.package>

adb -s $S shell am force-stop $PKG          # detaches the agent (divert + capture stop)
adb -s $S forward --remove-all              # drop the capture-socket forward
adb -s $S reverse --remove tcp:8099         # drop the mock tunnel
pkill -f scripts/mock-server.py             # stop the mock server on the Mac
```

Notes:

- **The app auto-restarts.** Android relaunches a force-stopped app on the next tap/intent, but
  the new process comes up **clean** — no agent, no divert — until you attach again. So
  `force-stop` alone is enough to stop the override; you don't need to keep the app closed.
- **Nothing persists across reboot.** The agent is never installed; it's staged into
  `code_cache` and loaded per attach.
- **To leave no trace**, also remove the staged artifacts (optional — they're inert unless
  attached):
  ```bash
  adb -s $S shell "run-as $PKG rm -rf code_cache/libsqueezeagent.so \
    code_cache/squeezeagent-boot.dex code_cache/squeezeagent-capture.dex code_cache/squeeze_opt"
  ```
- **`ENABLED = false` + rebuild** turns the divert off at the source while keeping read-only
  capture — the clean way to stop diverting but keep watching endpoints.

---

## Gotchas

**Close Jaca while testing.** `AgentController` re-attaches whenever the app's pid changes. If a
capture tab is open it will stage *its own* bundled dex over yours and win the race.

**Re-attaching never reloads the dex.** `SqueezeAgent.attach()` returns early when capture is
already loaded, only re-pointing the reporter socket:

```java
if (captureInstance != null) { /* re-point socket only */ return; }
```

So a changed rule needs `am force-stop` and a fresh attach — not just another `attach-agent`.
(This is a strong argument for keeping rules **desktop-side** in the real implementation, where
an edit takes effect on the next request with no re-attach at all.)

**`ENABLED` is compile-time and currently `true`.** Anyone who rebuilds and installs Jaca gets
the divert silently. Gate this before shipping.

**Diverted traffic is not TLS-protected between app and Mac.** It's cleartext over the adb
tunnel. Fine for a debug session; never for anything else.

**Only okhttp3.** The rewrite is skipped unless the request class is `okhttp3.Request`. okhttp2
and `HttpURLConnection` keep the plain read-only capture path.

**Streaming/QUIC.** Anything that doesn't flow through okhttp3's interceptor chain (Cronet,
native stacks, HTTP/3) is untouched.

---

## What productising this looks like

The POC deliberately hard-codes what the real feature should own:

1. **Rules move desktop-side** — matcher + response stored and edited in Jaca, so an edit
   applies on the next request with no rebuild and no re-attach.
2. **A Swift mock server replaces `scripts/mock-server.py`**, reusing `UpstreamClient` to pass
   unmatched requests through to the real origin.
3. **`AgentController` manages `adb reverse`** alongside the `adb forward` it already sets up.
4. **The agent gets one flag, not a rule set** — `attach-agent`'s spec string already carries
   the socket name, so a `divert:<port>` field needs no new protocol or control channel.
5. **Short-circuit becomes available.** Now that the application-interceptor layer is hooked,
   returning a canned response with no server at all is legal — useful for offline mocking and
   error injection.

---

## Provenance

Built and verified in a Claude Code session against a real pinned app.

| | |
|---|---|
| **Claude Code session id** | `1307b816-35a3-4b4f-9ff7-868913d43fac` |
| Date | 2026-08-25 |
| Device | `emulator-5554`, `sdk_gphone16k_arm64`, Android 17 (SDK 37), arm64-v8a, 16 KB pages |
| App | `com.teya.ac.dev` 3.0.0 — `debuggable=true`, `targetSdk 36`, 5 hard-coded cert pins |
| Endpoint | `GET /lending/v1/companies/{uuid}/product-state?locale=en` |
| Result | 3/3 requests diverted and served from the mock, **0** crashes |

Two dead ends worth remembering, both hit during this session:

- The agent `.so` was 4 KB-aligned and **could not load at all** on this 16 KB-page emulator
  (`program alignment (4096) cannot be smaller than system page size (16384)`). Fixed by
  `-Wl,-z,max-page-size=16384` in `agent/native/CMakeLists.txt`.
- The first divert attempt ran on the **network** interceptor and crashed the app with
  `must retain the same host and port`. That is what forced the application-interceptor split
  described above.

## See also

- `agent/kotlin/com/squeeze/capture/PocDivert.kt` — the rule
- `agent/kotlin/com/squeeze/capture/OkHttpHook.kt` — layer detection, rewrite, request restore
- `agent/native/squeeze_agent.cc` — where both okhttp hooks are registered
- `scripts/mock-server.py` — the payload
- `README.md` — how the in-process agent works in general
