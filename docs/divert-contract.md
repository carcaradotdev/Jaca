# The divert contract

One desktop producer, two device-side twins. This is the whole agreement between them.

| Role | File |
|---|---|
| **Producer** (the only one) | `Sources/Core/Intercept/Intercept.swift` — `OverrideEndpoint.divertFrame` |
| Consumer — Android | `agent/kotlin/com/squeeze/capture/Divert.kt` (+ `SqueezeReporter.kt` for the socket) |
| Consumer — iOS Simulator | `agent/iOS/JacaDivert.m` (+ `JacaNetChannel.m` for the socket) |
| Desktop-side header names | `OverrideHeaders` in `Intercept.swift` |

Change anything below and you must change all three. That is why this file exists: the two agents
are in different languages, on different platforms, with different clocks, and neither compiler can
see the other. **The desktop has exactly one encoder** (`divertFrame`, called from exactly one
place, `DivertCoordinator.push`) precisely so a drift has a single place to start.

---

## 1. The frame

Newline-delimited JSON, desktop → device, over the socket the agent already uses to report
transactions. There is no second socket and no second port in either direction.

```json
{"type":"divert","origin":"http://localhost:41234","hosts":["api.example.com","id.example.com"],"heartbeatSeconds":15}
```

Exactly four keys, and **that is the tripwire**. `OverrideEndpointFrameTests` asserts the key set
literally:

> the device must never learn about patterns, payloads, statuses or ordering

A field added here is a field the device learned about. Rules, matching, precedence, bodies,
status codes and delays all live on the desktop — which is *why* editing a rule applies on the
app's next request with no re-attach, and why an agent build never has to know what a rule is.

Wire details that are load-bearing:

- **`hosts` is sorted.** An unchanged rule set therefore produces a byte-identical frame every
  heartbeat, so "did anything change?" is a string comparison in a log.
- **Host strings are escaped as JSON string literals** by the producer. Hosts come from
  user-authored rules; a stray quote must not be able to produce a frame the device can't parse.
- **The frame is newline-free.** The wire is newline-delimited; a line that fails to parse is
  dropped by both agents without disturbing the framing of the next one.

### The control vocabulary

| `type` | Device does |
|---|---|
| `divert` | Reconfigure: origin, hosts, window. Also refreshes the dead-man timestamp. |
| `ping` | Refresh the dead-man timestamp only. |
| anything else | **Ignore.** Forward compatibility is a requirement, not a nicety: a newer desktop must be able to talk to an older agent inside an app the user cannot rebuild right now. |

Device → desktop, the agent sends exactly one control frame, once per connection, before anything
else:

```json
{"type":"hello","stage":1,"caps":["override/1"]}      // iOS   (kJacaHelloFrame)
{"type":"hello","pid":1234,"stage":4,"caps":["override/1"]}   // Android (SqueezeReporter)
```

`caps` is the negotiation. The desktop sends **no** divert frame until it has seen `override/1`
(`DivertCoordinator` publishes `.waitingForAgent` in the meantime, never `.active`), so an agent
built before this feature is a no-op rather than a hazard. A hello *without* `override/1` is not
silence — it becomes `.agentTooOld`, because "wait" and "rebuild your agent" are different
instructions to a user.

---

## 2. `origin == null` means divert **nothing**

Never "divert everything". There is one spelling of disarm, and the producer makes a second one
unrepresentable: `OverrideEndpoint.init` clears `origin` and `hosts` **together**, so an empty host
set can never arm a device and an absent origin can never leave a stale host list behind.

Both agents start with a nil origin, so a freshly attached/injected agent is **read-only by
construction** rather than by a flag. Android's predecessor shipped with `ENABLED = true`
hard-coded and a rebuild silently diverted a hard-coded endpoint; this default is the fix for that
class of mistake.

---

## 3. Host matching

- Membership in a set. Not a prefix, not a suffix, not a glob — one hash-set lookup.
- **Lowercased on both sides.** The desktop lowercases when deriving hosts from rules; each agent
  *also* lowercases the incoming request's host before the lookup. Duplicated on purpose: an
  invariant that only one side enforces is one refactor away from being enforced by nobody.
- Port is not part of the match. Hosts are hosts.
- Everything not in the set stays on the device's own network, untouched — that is the feature's
  blast radius, and it is why routing a whole host is safe.

---

## 4. The monotonic dead-man window

`heartbeatSeconds` is a *permission*, not a timer. The agent keeps diverting only while the desktop
has spoken within that window; the desktop re-states the **full endpoint** every
`heartbeatSeconds / 3` (`DivertCoordinator.heartbeatInterval`), so a heartbeat both feeds the switch
and repairs a desync.

Two rules that are easy to get wrong:

1. **Expiry is checked on the match path, never by a timer thread.** A suspended process, a Doze
   window, or a half-open socket can starve a timer; they cannot starve a check that runs as part
   of answering "should I divert this request?".
2. **Expiry disarms.** It does not merely decline this one request. Once the window lapses the
   object goes read-only, so nothing can half-arm afterwards.

The clock must be **monotonic and keep counting while the process is suspended**:

| Platform | Clock | Why not the obvious one |
|---|---|---|
| Android | `SystemClock.elapsedRealtime()` | Wall clock jumps with NTP and time-zone changes |
| iOS | `mach_continuous_time()` | `mach_absolute_time()` stops while the process is suspended, so a backgrounded app would wake believing the desktop had just spoken |

A non-positive window means "already expired" — fail-safe. The iOS side clamps with `MAX(0, …)`
rather than `MAX(1, …)` for exactly that reason; the clamp exists only to stop a negative value
sign-extending into a ~584-million-year window.

Three more teardown layers back this up, in order of how violent the failure is:
socket **EOF disarms** unconditionally (survives SIGKILL, Force Quit, crash); the window covers the
half-open socket where no EOF ever arrives; and a failed dial to the desktop makes the agent
**fail open** — disarm and retry the request directly, at most once.

---

## 5. `X-Jaca-Original-URL`

A diverted request is sent to the origin with its URL replaced by `<origin><path-and-query>`, and
the URL the app actually asked for carried in `X-Jaca-Original-URL`.

- The header is set **before** the URL is replaced, so the outbound request is never briefly
  repointed without it.
- The desktop recovers it with `AgentOriginalURL.recover(headers:uri:)`, falling back to
  `Host` + the origin-form URI. **Matching, capture and rule authoring all run on the recovered
  URL**, never on the loopback one.
- Path and query are preserved verbatim (percent-encoding included); **the fragment is dropped**,
  because fragments are never sent.
- On the way back the agent puts the original URL onto the response before handing it to the app,
  so cookies, logging, and anything reading `response.URL` still see the real host. The loopback URL
  never leaves the agent.
- Every `x-jaca-*` header is stripped before a request reaches a real origin
  (`OverrideHeaders.isJacaInternal`) and hidden from the Headers tab.

---

## 6. The 599 retry-direct pair

The desktop routes by **host**, but rules match by **URL**. So a request can be diverted and then
turn out to match nothing. The desktop must not fetch it — the device is about to send it itself,
and fetching here too would execute every unmatched request twice (duplicating POSTs). Instead it
bounces:

```
HTTP/1.1 599
X-Jaca-Divert: retry-direct
```

The agent recognises the pair, **cancels the exchange, re-sends the app's original request on the
app's own network, and drops the bounce from capture**. The user gets exactly one row: the real one.

Three things about this are not optional:

- **It is a pair, never the status alone.** `JacaIsRetryDirectBounce` requires both.
- **It also requires that *we* diverted this request** (`wasDiverted`). An origin legitimately
  answering 599 with that header on a request we never touched would otherwise loop forever.
- **599 is unassigned**, which is why it was chosen: it cannot collide with a real origin's
  semantics.

The desktop also bounces before touching upstream when the exchange can't survive the hop —
`Accept: text/event-stream` or `application/grpc` (`OverrideServer.isStreamingRequest`), and any
request whose original URL can't be recovered.

### Eligibility (agent-side)

A request is only ever diverted if it can be **replayed**, because both safety nets (the bounce and
the fail-open retry) re-send it:

| Excluded | Why |
|---|---|
| `Connection: upgrade` | WebSockets/h2c don't survive a buffered hop |
| A body we couldn't drain | Android: one-shot/duplex bodies. iOS: an `HTTPBodyStream` still present after the tap tried to read it — the order matters, so an ordinary upload stays divertible while an unreadable one does not |

---

## 7. What each side owns

| | Desktop | Device |
|---|---|---|
| Rules, patterns, precedence, bodies, statuses, delays | ✅ | ❌ never |
| Which hosts to route | decides | applies |
| Where to send them | decides | applies |
| How long that permission lasts | states | enforces |
| Whether the agent understands overrides at all | asks | answers (`caps`) |
| Disarming when the other side dies | can't (it's dead) | ✅ EOF + window + fail-open |

---

## Tests that pin this contract

| Claim | Test |
|---|---|
| The frame has exactly four keys, hosts sorted, escaping, `disarmed()` → literal `"origin":null` | `Tests/OverrideEndpointFrameTests.swift` |
| The iOS hello literal classifies as `override/1`; unknown frames are ignored | `Tests/AgentFrameTests.swift` |
| No frame before hello; `.agentTooOld` on a hello without `override/1`; the heartbeat re-states the full endpoint; an empty host set disarms | `Tests/DivertCoordinatorTests.swift` |
| Host lowercasing, expiry *disarming*, path+query, eligibility, the 599 pair needing `wasDiverted`, URL restore | `Tests/ObjC/JacaDivertTests.m` (target `JacaAgentTests`, runs on macOS) |

## See also

- [`response-overrides-android.md`](response-overrides-android.md) — the feature, its traps, and
  the Android path
- [`response-overrides-ios.md`](response-overrides-ios.md) — the iOS-Simulator path
