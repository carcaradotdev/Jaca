# Jaca daemon: experimental plan

Move Jaca's business logic into a long-running background process (`jacad`) so more than one
front end can drive it. The SwiftUI app becomes one client. A Herdr plugin, rendering Jaca's
areas as terminal panes, becomes a second one.

Status: experimental, on branches `exp/daemon` and `exp/daemon-overrides` (the latter also
carries response overrides; see the last section). Nothing merges to `main` until an area works
end to end through the daemon. Last updated: 2026-11-11.

## Progress

| Phase | State |
|---|---|
| 0. Core compiles on its own | Done, with a different approach (see "Changes from the first draft"). |
| 1. Protocol and daemon skeleton | Done. |
| 2. Gradle, Xcode, Projects | Done. |
| 3. Herdr plugin prototype | Done (Gradle pane + two actions). Not linked into Herdr yet. |
| 4. Devices | Done. |
| 5. Log streaming | Done. Physical iOS untested (no device here); the private frameworks load in `jacad`. |
| 6. Cloud logging | Done. Tested with a scripted poller, not against GCP. |
| 7. Network capture | Done for the in-process agent and MITM (device proxy, iOS Simulator system proxy). Companion capture stays in the app (see below). |
| 7b. Response overrides | Done on branch `exp/daemon-overrides` (see below). |
| 7c. Database browsing | Daemon side written (`DatabaseArea`, see "Database browsing in the daemon"). Not built or run yet; the app still browses in-process. |
| 8. Herdr plugin, full | Partly done: `devices` (a picker popup), `logs` (the log tab's filters, package picker and status bar), `network` (agent capture with response overrides), `gradle` and `projects` panes, `tools` (a picker for Gradle and Xcode), `xcode` and `cloud` (the home and the log sessions) panes, two actions. |
| 9. `jaca` command line | Done (see "The `jaca` command line"). Run against an in-process daemon and, read-only, against a live one; not against a device capture. |

### Trying it

Daemon mode is per area and off by default:

```bash
defaults write dev.srsouza.Jaca daemonAreas -array gradle xcode projects devices
# or for one run:
JACA_DAEMON_AREAS=all ./path/to/Jaca.app/Contents/MacOS/Jaca
```

`JACA_DAEMON_DIR` moves the socket, lock and log (default `~/.jaca`). It does not isolate a second
`jacad serve`: that daemon still uses the real history database, caches and settings, and it
empties `~/Library/Caches/Jaca/net-bodies-jacad` (the running daemon's spilled bodies) when it
creates its captures. `Jaca.app/Contents/MacOS/jacad` is also the CLI:
`jacad describe`, `jacad call gradle.list`, `jacad watch projects.state`, `jacad status`, `jacad stop`.

### Changes from the first draft

- **No `JacaCore` framework.** A framework would need `public` on everything the app uses. The
  `jacad` tool target compiles `Sources/Core` directly instead, and the app keeps compiling all of
  `Sources/`. The tool target builds Core without Model and Features, so a Core → Model
  dependency fails the build, which was the point of phase 0. The one existing dependency
  (`DeviceContext`) moved into `Core/Devices/`. The Objective-C bridge works unchanged: a tool
  target can use the bridging header.
- **`@MainActor` is not a blocker.** `jacad` runs the main run loop, so the main actor exists
  there as in the app. Engines stay `@MainActor`.
- **Binary location:** `Jaca.app/Contents/MacOS/jacad`, next to the app executable, so
  `DaemonLauncher.bundledExecutable` resolves the same way from the app, the tests and `jacad`.
- **Settings:** no `config.json`. `JacaDefaults.shared` is the app's `UserDefaults` domain
  from either process (`.standard` in the app, `UserDefaults(suiteName: "dev.srsouza.Jaca")` in
  `jacad`), synchronized by `cfprefsd`. No import step and no second copy.
- **Engines.** Where an area model held domain logic, it moved into a Core engine
  (`ProjectsEngine`, `DevicesEngine`) with no view state. The app's model runs the engine
  in-process, or mirrors the daemon's engine through a retained topic. One implementation serves
  both modes; the model keeps view state (selection, toasts, approval prompts).
- **Schema:** `api.describe` returns every method and topic with a one-line summary instead of
  a hand-written JSON Schema file.
- **No new user-facing strings.** Daemon mode is switched with `defaults`/an environment
  variable, not a Settings toggle, and an unreachable daemon falls back to in-process work instead
  of showing an error state. Both need copy from a ticket before they get UI.
- **Herdr TUI: Go, standard library only.** Rust isn't installed here; Go is. `stty` and ANSI
  escapes cover a prototype without fetching modules.
- **Request ordering.** Requests on one connection run one at a time, in arrival order, so a
  client can pipeline "open" then "select". Slow read-only methods (`du` listings, gcloud calls,
  SQL, body and range fetches) are registered `concurrent: true` and run alongside.
- **Sessions outlive the app.** Log, cloud and network sessions in the daemon are keyed by the
  tab's id, which is now persisted in `TabDescriptor.sessionID`. A relaunched app reattaches and
  backfills from the daemon's replay buffer (100k lines / entries) without restarting the stream
  or re-querying gcloud. A session no client has watched for 10 minutes is closed
  (`JACAD_ORPHAN_SECONDS`; it applies to log, cloud and network sessions). While a session runs, the daemon doesn't idle out.
- **Log filtering stays in the client.** The daemon owns the stream (source, reconnects, markers,
  PID tracking, body prettifying, crash markers, history). Level, text, regex, system-log and
  exclusion filters are the viewer's, since the app tab and a Herdr pane can filter differently.
  One behavior change: crash markers are injected for crashes of the targeted app regardless of
  the tab's text filter (before, a crash hidden by the filter got no marker).
- **Network bodies stay in the daemon.** Transactions stream without bodies; `network.body`
  fetches them when a row is opened, and HAR export runs in the daemon.
- **Companion capture stays in the app.** With "HTTPS debugging" chosen under Settings → Network
  inspection (an experimental opt-in), or a
  companion-only device, network tabs capture in-process. Moving `CompanionRegistry` means moving
  the gRPC links, mDNS discovery, the CA and onboarding, and nothing here could test it: no phone,
  and the Local Network permission question for a spawned helper is still open. `jacad` never
  loads the MITM CA (`CaptureContext.ca` is optional), so it can't trigger the Keychain migration
  prompt or mint a CA that devices don't trust.
- **Resources:** `JacaBundle.app` resolves `Jaca.app` from `jacad` too, so the bundled agents
  and APK are found. `jacad call daemon.diagnostics` reports what the daemon can reach.

### Measured

- Emulator logcat backlog through the daemon to a Python client: ~33k lines/s, 204k lines in
  6.2s, no dropped batches.
- App + daemon with one emulator log tab after the backlog: app ~450 MB RSS, `jacad` ~350 MB
  (both hold the lines: the app's 500k ring and the daemon's 100k replay).
- iOS Simulator agent capture of Safari driven from `jacad`: transactions streamed, a body
  fetched on demand.

### Pre-existing issues found on the way (not changed here)

- `AndroidDeviceProvider.queryAVDName` splits on `"\n"`, but `adb` prints `\r\n`, which Swift
  treats as one character: emulator models show as `"Name\r\nOK"`.
- `IOSDeviceProvider` lists simulators `devicectl` reports as "simulated" as iOS devices.
- `consumeLoop` is main-actor isolated, so every log line is iterated on the main thread; its
  `await state.isRunning` calls suggest it was meant to run off-main. Kept as is.

## Goals

- One process owns devices, log streams, network capture, cloud logging, and the maintenance
  areas. Every front end reads the same state.
- A documented, language-neutral wire protocol, so a client written in Rust or Go (a Herdr
  plugin) is as capable as the Swift app.
- The SwiftUI app keeps working throughout. Each area moves to the daemon on its own, behind a
  switch, with the in-process path kept until the daemon path is proven.

## Non-goals

- Porting the SwiftUI views. The Herdr plugin is a new TUI, written from scratch.
- Remote or multi-user access. The socket is local and owned by the user.
- Changing the companion wire protocol (`proto/companion.proto`). The daemon takes over the
  desktop side of it unchanged.

## Where the code stands

Measured on `main` at `0e5d0ba`.

| Layer | Lines | Notes |
|---|---|---|
| `Sources/Core/` | 10,677 | No SwiftUI. Services, sources, parsers, proxy, gRPC link. |
| `Sources/Model/` | 4,468 | All `@MainActor @Observable`. Mixes orchestration with view state. |
| `Sources/Features/` | 10,140 | SwiftUI views. Mostly render Core value types. |

What already fits a daemon:

- Core has no references to `AppModel`, `LogSession` or `NetworkSession` outside comments.
- Backends sit behind small protocols: `LogSource` (returns `AsyncStream<LogLine>`),
  `DeviceProvider`, `CaptureSource`.
- `HistoryStore`, `CloudLogDatabase`, `NetworkBodyCache` and `GcloudDebugLog` are actors.
- The MITM CA key is a 0600 file under `~/Library/Application Support/Jaca/ca/`, not a
  Keychain item (`CertificateAuthority.swift:26`), so a second signed binary can read it
  without the code-signature ACL prompt.

What has to change:

1. **One module.** The `Jaca` target in `project.yml` globs all of `Sources/`. A daemon needs
   Core as its own target that both binaries link.
2. **One compile-time Core → Model dependency.** `CaptureContext` and `CaptureSourceDescriptor`
   take a `DeviceContext`, which lives in `Sources/Model/DeviceContext.swift`
   (`CaptureSource.swift:10,48`, `CaptureSourceRegistry.swift:48,57`).
3. **Main-actor types inside Core.** `CaptureContext`, `CaptureSink`, `CaptureSource`,
   `CaptureSourceDescriptor` (`Core/Capture/CaptureSource.swift`) and `CompanionHub`
   (`Core/Companion/CompanionHub.swift:8`).
4. **No wire format.** `LogLine` and `NetworkTransaction` are `Sendable` but not `Codable`.
   Events flow through closures (`CaptureSink`, `onChange`) and `AsyncStream`s.
5. **Orchestration in `Model/`.** `LogSession` holds the line buffer, exclusions, crash
   tracking and history persistence next to `displayMap`, `scrollTarget`, `followTail` and
   `collapsedBodies`. `NetworkSession`, `CloudLogSession` and `ProjectsModel` have the same mix.
6. **Settings in the app's `UserDefaults` domain.** `httpsDecryptionEnabled`,
   `logExclusions`, `logPrettifyJSONBodies`, `retentionDays`, `adbPath`, `openTabs`,
   `jaca.projectFolders`, `jaca.herdr.claudeCommand`, and others. A daemon with its own bundle
   id reads a different domain.
7. **AppKit in Core.** `Core/Companion/QRCode.swift` returns an `NSImage`.
8. **Objective-C bridge on the app target.** `JacaOSLog.{h,m}` (LoggingSupport private API)
   is exposed through `Sources/Jaca-Bridging-Header.h`. Framework targets can't use a bridging
   header.

## Target architecture

The sections from here on are the original draft. Where they differ from the sections above (method
and topic names, the bundle path, the plugin's pane and action names, the unavailable state), the
sections above and the code are current: `gradle.deleteCache`, topics `gradle.daemons`,
`projects.state` and `devices.list`, `api.describe`, `Contents/MacOS/jacad`, panes `devices`,
`gradle` and `projects`, actions `gradle-kill-all` and `projects-clear-cache`, and a silent
in-process fallback when the daemon can't be reached.

```mermaid
flowchart LR
    subgraph clients[Clients]
        app[Jaca.app<br/>SwiftUI]
        cli[jacad call<br/>CLI]
        herdr[Herdr plugin<br/>TUI panes]
    end
    sock[(~/.jaca/jacad.sock<br/>NDJSON JSON-RPC)]
    subgraph daemon[jacad]
        rpc[RPC server + event bus]
        state[Area owners<br/>devices, logs, network,<br/>cloud, projects, gradle, xcode]
        core[JacaCore<br/>services, sources, proxy,<br/>companion link, stores]
    end
    app --> sock
    cli --> sock
    herdr --> sock
    sock --> rpc --> state --> core
```

- **`JacaCore`**: a framework target built from `Sources/Core/`. Linked by the app, the daemon
  and the tests.
- **`jacad`**: a command-line target. `jacad serve` runs the daemon. `jacad call <method>
  [json]` sends one request and prints the response, which is what Herdr plugin actions will
  invoke.
- **Area owners** in the daemon: plain actors, not `@Observable`. They hold what `Model/`
  holds today minus view state, and publish changes as events.
- **The app**: `Model/` keeps its `@Observable @MainActor` types. For a migrated area the model
  reads from a daemon client instead of calling Core. Views don't change.

## Decisions

**Transport: a Unix domain socket with newline-delimited JSON-RPC 2.0.** Herdr uses the same
shape (`~/.config/herdr/herdr.sock`, JSON envelopes), `HerdrService.swift` already drives it,
and plugin actions are argv commands, so a client that works from a shell with `jq` matters.
XPC was ruled out because non-Swift clients can't speak it. gRPC over the socket was the other
candidate: the repo already has grpc-swift and protobuf, and HTTP/2 flow control handles log
backpressure. It was set aside because it can't be called from a shell script. Revisit if log
streaming can't keep up in phase 5.

**Socket path: `~/.jaca/jacad.sock`.** `~/.jaca` already holds Jaca state, and macOS limits
`sun_path` to 104 bytes, which rules out long Application Support paths. Mode 0600.

**Framing and messages.**

- Request: `{"jsonrpc":"2.0","id":1,"method":"gradle.list","params":{}}`
- Response: `{"jsonrpc":"2.0","id":1,"result":{...}}` or `{"jsonrpc":"2.0","id":1,"error":{"code":...,"message":"..."}}`
- Event, pushed on a connection that called `events.subscribe`:
  `{"jsonrpc":"2.0","method":"event","params":{"topic":"devices.changed","data":{...}}}`
- Method names are `<area>.<verb>`, matching Herdr's style.
- The first call on every connection is `hello` with the client's protocol version. The daemon
  answers with its own version and build commit. On a mismatch the app restarts the daemon;
  other clients show the mismatch and stop.

**Lifecycle: spawned on demand for the experiment.** A client that can't connect starts
`jacad serve` detached and retries for a few seconds. The daemon exits after a configurable
idle period with no clients and no running capture or log session. Registering it as a login
item through `SMAppService` is deferred: ad-hoc signatures change on every build and would
break the registration.

**The daemon is the only writer** of every persisted file (`~/.jaca/…`,
`~/Library/Caches/Jaca/…`, the history database, the CA). The app stops writing any of them
for an area once that area is migrated.

**Settings move to a daemon-owned config file** (`~/.jaca/config.json`), readable and writable
through `config.get` / `config.set` and announced through a `config.changed` event. On first
start the daemon imports the existing values from the app's `UserDefaults` domain
(`dev.srsouza.Jaca`) once. The file follows the migration rules in `CLAUDE.md`: tolerant
`init(from:)`, `CloudPersistence.decodeArray` for arrays, and a test that decodes an old-schema
file.

**Failure handling.** Nothing in the daemon may crash on client input. A malformed request, an
unknown method, a missing field or an unknown id gets an error response and the connection
stays open. A service failure becomes an error response or an event with an error state. On the
client side, a missing or dead daemon puts the area in a visible "daemon unavailable" state
with a retry control, and the app falls back to the in-process path while that path still
exists.

**Wire types.** Every type that crosses the socket gets `Codable` with the same tolerant decode
as persisted models, so a newer daemon and an older client (or the reverse) degrade instead of
failing. Golden JSON fixtures under `Tests/Fixtures/jacad/` pin the encoding. The protocol is
described in a hand-written JSON Schema at `proto/jacad.schema.json`, and a test checks every
fixture against it. `jacad call api.schema` prints it, like `herdr api schema`.

## Phases

Each phase ends with something runnable. Estimates are rough working days.

### Phase 0: split Core into `JacaCore` (2–3 days)

Useful on its own: it enforces the layer rule at compile time.

- Add a `JacaCore` framework target in `project.yml` sourcing `Sources/Core/`. Point `Jaca`
  at `Sources/App`, `Sources/Model` and `Sources/Features`, and add the dependency.
- Move `DeviceContext`'s capability data into a Core value type (for example
  `DeviceCapabilities`) that `CaptureContext` and the registry take. `DeviceContext` in
  `Model/` keeps the polling and holds that value.
- Change `QRCode.image` to return PNG `Data`. The view makes the `NSImage`.
- Replace the bridging header with a module map for `JacaOSLog.h` inside `JacaCore`. Check it
  against the `investigate-loggingsupport` skill: physical-device logs must still stream.
- Add `public` where the app uses Core API. Expect this to be the bulk of the diff.

Done when: the app builds and behaves as before, `JacaTests` pass (skipping the live suites),
and `Sources/Core` fails to compile if it imports a Model type.

### Phase 1: protocol and daemon skeleton (2–3 days)

- `jacad` command-line target linking `JacaCore`, built into
  `Jaca.app/Contents/Helpers/jacad`.
- Socket server on SwiftNIO (already a dependency): NDJSON framing, JSON-RPC dispatch, per
  connection subscriptions, `hello`, `ping`, `api.schema`, `events.subscribe`.
- Idle shutdown and the stale-socket check (a leftover socket file with nothing listening is
  removed, then bound).
- `jacad call` for one-shot requests.
- A small Swift client in the app (`Model/Daemon/DaemonClient.swift`): connect or spawn,
  handshake, request/response by id, an `AsyncStream` per event topic, and reconnect.
- The config file and the one-time `UserDefaults` import.
- A setting to turn daemon mode on per area, off by default.

Done when: `jacad call ping` works from a shell, and the codec and config migration tests pass.

### Phase 2: stateless areas (2–3 days)

Gradle daemons, Xcode DerivedData, and Projects. Their services already do the work off the
main actor and their models are mostly caches.

- Daemon owners wrap `GradleDaemonService`, `DerivedDataService`, `ProjectsScanner`,
  `ProjectsCache`, `GitService`, `CacheCleaner` and `FolderWatcher`.
- Methods: `gradle.list`, `gradle.kill`, `gradle.clearCache`, `xcode.list`, `xcode.delete`,
  `projects.list`, `projects.refresh`, `projects.addFolder` (takes a path; the open panel stays
  in the app), `projects.clearCache`, `projects.deleteWorktree`.
- Events: `gradle.changed`, `xcode.changed`, `projects.changed`, and per-row size patches as
  `du` results land.
- The cache-first behavior from `CLAUDE.md` moves into the daemon. The app still renders the
  last result immediately: it caches the last `*.list` response locally, read-only.
- Stays in the app: `NSOpenPanel`, open in Finder, Zed and Herdr, sheets, and the Update area
  (it rebuilds the app, so it belongs to the app).

Done when: all three areas work in daemon mode with the same behavior, and killing `jacad`
mid-refresh shows the unavailable state and recovers on retry.

### Phase 3: Herdr plugin prototype (2–3 days)

Done this early to test the protocol against a non-Swift client before the hard phases.

- Plugin directory `herdr-plugin/` with a manifest: a `startup` command that runs
  `jacad call ping` (which spawns the daemon), and one pane `jaca-gradle` with
  `placement: "tab"`.
- A TUI binary that subscribes to `gradle.changed`, renders the daemon table, and kills a
  daemon on a keypress.
- Actions: `jaca.gradle.killAll` (`contexts: ["global"]`) and `jaca.projects.clearCache`
  (`contexts: ["workspace"]`), which reads `worktree.checkout_path` from the invocation context.
- Link it with `herdr plugin link herdr-plugin`.

Open: the TUI language. Rust with ratatui matches Herdr. Go with Bubble Tea is quicker to
write. Pick one here and keep it.

Done when: the Gradle pane in Herdr and the Gradle area in the app show the same daemons, and
killing one from either side updates both.

### Phase 4: devices (2 days)

- Move `AndroidDeviceProvider`, `SimulatorDeviceProvider`, `IOSDeviceProvider` and the merge
  logic from `AppModel` into a daemon `DevicesOwner`. Per-device capability and installed-app
  polling (today in `DeviceContext`) moves with it.
- Methods: `devices.list`, `devices.apps`. Event: `devices.changed`.
- `Device` is already `Codable`. Add the tolerant decode.
- Companion devices join in phase 7. Until then the app merges them in as today.

Done when: the sidebar device list comes from the daemon and adb connect and disconnect show up
live.

### Phase 5: log streaming (4–6 days)

The largest `Model/` split and the one most likely to regress.

- Daemon `LogSessionOwner` per session: owns the `LogSource` (and the console source), the
  line buffer, `LogFilter`, exclusions, `CrashDetector`, the app-alive tracking, and history
  persistence through `HistoryStore`.
- Methods: `logs.open` (device, bundle id, filter; returns a session id), `logs.close`,
  `logs.setFilter`, `logs.range` (lines by seq for scrollback), `logs.search`.
- Event: `logs.lines` with a batch of lines, sent on the same timer-flush cadence the app uses
  today. When a client falls behind, the daemon drops whole batches for that client, counts
  them, and reports the count in the next batch. The app already has `droppedCount` to show it.
- `LogLine` gets `Codable` with tolerant decode, plus golden fixtures including multi-line
  bodies and JSON bodies.
- Stays in the app: `displayMap`, `scrollTarget`, `followTail`, `collapsedBodies`, `listEpoch`,
  body prettifying for display, copy formats.
- Measure with a chatty emulator before and after: CPU in both processes, and end-to-end
  latency from the logcat line to the rendered row.

Done when: logcat, simulator and physical-device streams match in-process mode, the UI does not
stutter under a chatty device, and restarting the app reattaches to a still-running session.

### Phase 6: cloud logging (3–4 days)

- Daemon owners for `CloudLoggingRegistry` (gcloud detection and auth, projects, log names,
  labels) and each `CloudLogSession` (the `CloudLogPoller`, `CloudLogDatabase`, the query).
- `CloudRegexAssistant`, `CloudSqlAssistant` and `ClaudeCodeCLI` stay callable from the app. The
  views that call them directly today go through their model instead.
- The persisted stores (`CloudProjectStore`, `CloudTemplateStore`) move with the daemon as
  their only writer. The existing `CloudMigrationTests` must keep passing.

Done when: cloud log tabs work in daemon mode and survive an app relaunch without re-querying.

### Phase 7: network capture and the companion (6–8 days)

- Remove `@MainActor` from `CaptureContext`, `CaptureSink`, `CaptureSource`,
  `CaptureSourceDescriptor` and `CompanionHub`. Replace with an actor or explicit queues.
  Every capture source changes: proxy, Android agent, iOS Simulator agent, companion.
- Move `CompanionRegistry`, `CompanionSetupModel`'s transport side, `ProxyServer`,
  `CertificateAuthority` and `NetworkBodyCache` into the daemon.
- Methods: `network.open`, `network.close`, `network.sources` (the capture options for a
  device), `network.start`, `network.body` (lazy, like `ensureBodies` today),
  `network.exportHAR`, `companion.list`, `companion.pushCA`, `companion.onboarding` (the QR
  payload and PNG).
- Events: `network.transactions` (batched, bodies omitted), `network.status`, `companion.changed`.
- `NetworkTransaction` gets `Codable` and fixtures.
- Local network permission: the app declares `NSLocalNetworkUsageDescription` and
  `NSBonjourServices`. Check which process macOS attributes the daemon's mDNS browse to when
  the app spawns it. If the daemon needs its own grant, it needs an embedded Info.plist with
  both keys, and the build step that injects `NSBonjourServices` has to cover it too.

Done when: proxy, agent and companion capture all work in daemon mode, the CA isn't
regenerated, and HAR export matches in-process output.

### Phase 8: Herdr plugin, full (open-ended)

Add panes as the daemon side lands: `jaca-devices`, `jaca-logs` (per device, `split`
placement), `jaca-cloud-logs`, `jaca-projects`, `jaca-network`. Use `pane.graphics.set` for the
companion QR code. Add a `link_handlers` entry so URLs in agent output can open a matching
cloud-log or network view.

## Rough total

Phases 0 to 7: about 5 to 6 weeks of focused work. Phases 5 and 7 carry most of the risk.
Phase 8 depends on how far the TUI goes.

## Risks

- **Two processes to keep in sync.** The in-app updater rebuilds the app. It must also stop the
  old daemon, or the `hello` version check has to catch the mismatch. Test that path in
  phase 1.
- **Private API from a helper.** LoggingSupport and MobileDevice are loaded with `dlopen`. They
  should load the same way from a command-line tool, but verify in phase 0 before building on
  it.
- **UI tests.** `JACA_UITEST` and `JACA_AUTO_SESSION` configure `AppModel`. In daemon mode
  they need a daemon started with an isolated config directory, or they keep running
  in-process.
- **Flaky suites.** `AppModelIntegrationTests` and the live suites are already unstable.
  Compare against a baseline run before blaming a phase.
- **Scope creep in phase 0.** Adding `public` touches many files. Keep it mechanical and
  don't refactor in the same change.

## Open questions

- TUI language for the Herdr plugin (phase 3).
- Whether the in-process path is deleted after an area is proven, or kept as a no-daemon mode.
  Keeping it doubles the surface to test.
- Whether `jacad` should also run outside the app bundle (installed with Homebrew next to
  `herdr`) for users who only want the plugin.

## Response overrides in the daemon (branch `exp/daemon-overrides`)

`exp/daemon-overrides` is `feat/override-http-ios` at `407e9ae` with `exp/daemon` merged in
(`05df09b`), followed by review fixes. It replaced an earlier version (kept as
`exp/daemon-overrides-v1`) that cherry-picked three override commits onto `exp/daemon`.

**Where it runs.** Overrides are armed by the capture source, so the runtime lives with the
capture. `OverridesEngine` (Core) holds the rule library, master switch, hit counts, per-target
arming state, the resolver, and the divert coordinators. The app's `OverridesModel` keeps its API:
with the `network` area off it runs the engine in-process; with it on, `jacad` runs the engine
(`OverridesArea`, retained `overrides.state`), daemon captures get its `services()`, and the model
mirrors the state and compiles the mirrored rules locally for the editor's match previews and
"can't run here" hints. Rule edits go through `overrides.save/remove/setEnabled/duplicate/move/
setMaster`, in order.

**Capture state.** `NetworkCaptureState` gained what the toolbar and attach banner read from the
running source: `attachState`, `interceptWired`, `interceptCapabilities`, `hasRunningSource`.
`network.restartForInterceptChange` and `network.relaunchToAttach` reach the daemon's source.

**Settings.** `networkInspectionMode` (which replaced `responseOverridesEnabled`, now only read
to migrate), `networkOverridesMasterEnabled` and `simulatorAutoReattachEnabled` read
`JacaDefaults.shared`, so `jacad` sees the app's values. So does the verbose-logging toggle.

**Tunnels.** `jacad` reconciles tunnels left by a dead process when it starts and reverts its own
(`AdbTunnelCleanup`, `ProxyCleanup`) when it stops. The ledger is keyed by pid, so the app's and
the daemon's reconciliation leave each other's live tunnels alone.

**Verified.** A rule saved through `jacad` answered Safari's `bag.itunes.apple.com` requests on the
iOS Simulator with 418 while the agent capture ran in the daemon: the transactions carry the rule
id, the hit count and `active` arming (with the rule's host) reached `overrides.state`.

**One switch.** Where network capture runs is decided by the `network` daemon area alone
(`DaemonConnector.networkRunsInDaemon`): on, capture and the override engine run in `jacad`; off,
they run in the app. The network inspection mode no longer moves them. Companion-only devices
still capture in the app, because the companion links live there. So there is always exactly one
override engine and one writer of `rules.json`. The mode and its switch are in "MITM HTTPS
debugging in the daemon" below.

**Limits.** Android divert through the daemon is untested here (no agent build). The tab migration
on toggle has no automated test (it needs a full `AppModel`).

**Merge notes.**
- (v1 only) `3362a79` accidentally reverted #50 (`ProjectsModel.swift`, `DirectorySizer.swift`,
  `ProjectsAreaView.swift`, and deleted `DirectorySizerTests.swift`); its files match the pre-#50
  versions exactly, and the wip commit restores them. The merge keeps #50.
- `OverrideRuleStore.collectGarbage` deleted any unreferenced blob, including one written for a
  seeded rule still open in the editor, whenever another rule was saved. It now keeps blobs younger
  than 24 hours. This affected the in-process app too.
- `JACA_OVERRIDES_DIR` moves the rule library; the new daemon tests use it. The branch's existing
  `OverrideAuthoringTests` still save into the real `~/.jaca/network-overrides`.
- `jacad stop` now returns once the daemon has exited.

**Review fixes.** Rounds of review after the rebuild changed these behaviors:
- Two processes can write the same files, so `OverridesEngine` and `CloudEngine` re-read
  `rules.json` / `projects.json` and templates (by modification date) before each mutation, and
  the override engine re-reads the master switch from defaults. The app asks `jacad` to
  `overrides.reload` on every (re)subscription and `cloud.reload` when it hands the cloud area
  back. An unreadable `rules.json` is never saved over.
- Remote feeds hold live batches while they refill a gap reported by `events.dropped` (logs and
  cloud), and network clears drop upserts published before the clear until it lands.
- A log tab that falls back in-process closes its daemon copy, ends its own history run, and
  carries the daemon's PIDs over.
- Demand hooks (device discovery, project watching, polled topics) follow the subscriber set when
  they run, so a start and stop arriving out of order can't leave a topic without its producer.
- The server closes a connection that stays unwritable for 60 s.
- jacad registers its areas before binding the socket; package and device ids are validated
  where they enter jacad; cloud SQL is checked read-only by SQLite itself; the daemon directory
  is created user-only and the socket bound under umask 077.

**Known limits after review.**
- `SimulatorAppLauncher` coordinates the Logs stdout launch and the Network agent launch within
  one process. With the `logs` area on and the `network` area off, simulator log tabs run in
  jacad and agent capture in the app, so a log tab start can relaunch the app without the
  agent's environment.
- A log session jacad recreates after a restart re-reads the device buffer; the lines are new
  seqs, so they show again with no marker explaining it (the marker needs specified copy).
- An unreadable `rules.json` stops override saves (to keep the user's file) with only a log
  line; showing it in the popover needs specified copy.
- A pending call has no deadline except `hello` and the CLI's short commands; a protocol-version
  mismatch still replaces the running daemon regardless of which build is newer.

## MITM HTTPS debugging in the daemon

The end-to-end flow and the strategy shape are in [mitm-http-debugging.md](mitm-http-debugging.md).
This section lists what the daemon added.

**Mode owner.** With the `network` area on, `NetworkModeController` (`Core/Daemon/Areas/`) owns
the network inspection mode. It is the only writer of `networkInspectionMode` and runs one switch
at a time:

1. Publish `network.mode` with `switching: true`.
2. Stop each capture the new mode does not offer (`ModeSwitchPlan`) and show its chooser.
3. Wait for the device teardowns (`DeviceReleaseGate.settleAll`, `SimulatorProxyHub.settle`).
4. Store the mode and post `dev.srsouza.Jaca.networkInspectionModeChanged`.
5. Publish `network.mode` and every `net.state.<id>` again (`offeredSourceIDs` changed).

`network.open` and `network.select` wait for the switch. jacad also follows the notification, for
a mode the app stored while it owned the mode. The app mirrors the topic (`RemoteNetworkMode`).

**Methods and topic.**

| Method | Params | Result |
|---|---|---|
| `network.mode` | none | `{mode: "agent" \| "mitm", switching}` |
| `network.setMode` | `{mode}` | `{}` when the switch is done. Another name is `invalidParams`. |
| `network.installCA` | `{id}` | `{outcome: "installed" \| "needsUser" \| "failed", message?, rebootAdvised?}` |
| `network.rebootSimulator` | `{id}` | `{}`. `invalidParams` for a device that is not an iOS Simulator. |

Retained topic `network.mode`, data `{mode, switching}`. `NetworkCaptureState` gained
`offeredSourceIDs` (tolerant decode), which Herdr and remote GUI tabs build the chooser from.

**Other changes.**
- `network.select` refuses a source the mode does not offer on the device. Companion is refused
  as before.
- A restored tab whose source is not offered opens at the chooser.
- A new capture stops the running captures whose device claims collide (`DeviceClaimArbiter`).
- The CA loads on first use for any device, and jacad never migrates it from the Keychain
  (`allowKeychainMigration: false`), so it shows no prompt.
- Override services go to every capture in both modes.
- At start, before `listen`, jacad reconciles the device proxy ledger and the Mac system proxy
  lease. At stop it reverts its own.
- A pending device teardown keeps the daemon busy, so it does not idle out with a device still
  pointed at its proxy.

**Limits.** The device proxy on a USB phone and the system-store install on API 34+ are not
checked on hardware yet. A SIGKILL leaves a proxy set until the next jacad or app start.

## Database browsing in the daemon (`DatabaseArea`)

The app's read-only "Browse Database" feature (`DatabaseService`) served to a terminal client. The
app's own Database tab still runs in-process (`DatabaseSession`); there is no `database` entry in
`daemonAreas` because the app does not mirror this area.

A session belongs to one device. The client lists an app's databases, pulls one into a temp dir
(`jaca-db-<UUID>`), then reads that copy. The copy is a snapshot: pull again to refresh.

| Method | Params | Result |
|---|---|---|
| `database.open` | `{id, device}` | `{id, existed}`. Idempotent by id. |
| `database.databases` | `{id, package}` | `[{name, path}]`. The session keeps this list for the package. |
| `database.pull` | `{id, package, database}` (`database` is a `path` listed for `package`) | `[{name, rowCount}]`. Replaces the session's copy and deletes the previous one. |
| `database.rows` | `{id, database, table, limit, offset}` (`database` is the pulled `path`) | `{columns, rows}`. `limit` is clamped to 1...1000 (100 when absent), `offset` to 0 or more. |
| `database.query` | `{id, database, sql}` (`database` is the pulled `path`) | `{columns, rows}`, at most 50000 rows. Refuses anything but SELECT / WITH / PRAGMA / EXPLAIN. |
| `database.close` | `{id}` | `Bool`: whether it existed. Deletes the copy. |

- **Only listed paths are pulled.** The session keeps one listing per package. `database.pull` looks
  its `database` up in the listing for its `package`; any other string is an error and never
  reaches adb. The device id and the package are validated where they enter (`DaemonInput`; an
  empty package is refused too).
- **Reads name their database.** A session holds one copy, the last pull to finish. `rows` and
  `query` fail with `No database pulled in session <id>.` when `database` is not that copy's path,
  so a client whose pull was overtaken by another does not get rows from the other database. The
  check is by path only: two packages with the same relative path (Android's `databases/app.db`)
  are not told apart, so a client pulls for one package at a time per session.
- **Bounded reads** (`DatabaseArea.maxQueryRows`, `maxResultBytes`, `readDeadline`; the app's own
  reads and `cloud.sessions.query` are not bounded by these):
  - `query` over 50000 rows: `The result has more than 50000 rows. Add a LIMIT to the query.`
  - `rows` or `query` over 64 MB of cell text: `The result is larger than 64 MB. Select fewer rows or columns.`
  - a statement running for 30 s, or one whose session is closed or reaped meanwhile, is stopped
    from SQLite's progress handler and fails with `SQLite: interrupted`.
  - a step that fails is an error (`SQLite: <message>`), never a short result.
- **Errors.** A missing session (`No database session <id>.`), an unlisted path
  (`No database <path> in session <id>.`) and a read of a database that is not the pulled one are
  `failed` (-32000). A `DBError` from the service (not debuggable, adb or SQLite failures, the
  read-only refusal) is `failed` with its own description. A bad device id or package, or a
  missing field, is `invalidParams` (-32602).
- **Ordering.** `databases`, `pull`, `rows` and `query` are concurrent methods, so they do not wait
  for an `open` sent just before them on the same connection. A client waits for each response
  before the call that depends on it.
- **Lifetime.** The area has no topics, so no subscriber tells the daemon a client is still there.
  Every call marks its session as used when it starts and when it ends; one unused for
  `JACAD_ORPHAN_SECONDS` (default 600) is closed and its copy deleted, even under a call that has
  run that long. An open session keeps the daemon from idling out.
- **Temp dirs.** A pull that fails removes the directory it made (`DatabaseService.pull`, so the
  app's tab too).
- **Limit.** Areas have no shutdown hook, so a copy still held when the daemon stops stays in the
  temp dir until the system clears it.

## The `jaca` command line

`jacad` run under the name `jaca` is a client with subcommands. The app's own executable is
`Contents/MacOS/Jaca` and the filesystem is case-insensitive, so `jaca` is a symlink on `PATH` to
the bundled `jacad` (`scripts/install-cli.sh`, run by `all.sh --install`), and `main.swift` reads
`argv[0]`. `DaemonLauncher.bundledExecutable` resolves the link before it looks for `jacad`.

```
jaca devices
jaca logs list
jaca logs tail [SESSION] [-n COUNT] [--grep PATTERN] [--level LEVEL] [--since TIME] [--follow]
jaca net list
jaca net requests [SESSION] [-n COUNT] [--host HOST] [--status STATUS] [--method METHOD] [--failed]
jaca net show REQUEST
jaca net mode [agent | mitm]
jaca net install-ca SESSION
jaca overrides list
jaca overrides add --from REQUEST [--name NAME] [--status CODE] [--body-file PATH] [--disabled]
jaca overrides enable | disable | rm RULE
jaca call | watch | status | stop | describe          (as jacad)
jaca ... [--json] [--raw] [--no-spawn] [--help]
```

Code: `Sources/Core/CLI/` (`CLIParser`, `CLIResolver`, `CLIRedaction`, `CLITable`, `CLIRunner`),
all in Core so the tests reach it. The agent-facing workflow is `.claude/skills/jaca-cli/`.

**Methods added for it.**

| Method | Params | Result |
|---|---|---|
| `network.list` | none | `[{id, name, device, state, transactionCount}]`, one per open capture. `name` is the device model. |
| `network.search` | `{id?, host?, method?, status?, failed?, idPrefix?, limit?}` | Compact rows `{id, session, method, url, host, statusCode?, error?, startedAt, durationMs?, requestBytes, responseBytes, overriddenByRuleID?}`: the newest matches, oldest first. Without `id` it searches every capture. `status` is `[{min, max}]`; `failed` is a transport error or a status of 400 or more. `limit` is clamped to 1...1000 (100 when absent). |
| `network.transaction` | `{id, transaction}` | The transaction with headers and bodies (spilled ones read back), or null when either id is unknown. |
| `logs.search` | `{id, grep?, minLevel?, since?, limit?}` | `[LogLine]`: the newest matching replay lines, oldest first. `grep` is a case-insensitive regular expression over tag and message (matched as text when it does not compile). A crash marker passes `minLevel`. `limit` is clamped to 1...5000 (200 when absent). |
| `overrides.createFromTransaction` | `{id, transaction, name?, statusCode?, body?, enabled?}` | `{rule, warning?}`, or null when the transaction is unknown. Seeds with `OverrideSeeding.rule` (what the app's "create override" does) and saves. `body` is base64. |

`devices.list` changed: with nobody subscribed to the topic it now runs discovery once (up to 10 s)
instead of returning an empty list, and is a concurrent method.

`logs.search` filters in the daemon, unlike the viewers ("Log filtering stays in the client"
above): a one-shot search would otherwise pull the whole replay (100k lines) across the socket,
past `maxLineBytes` for a chatty session.

**Schemas.** `api.describe` methods carry optional `params` and `result` (`DaemonSchema`, a JSON
Schema subset; `required` is what a request must send). Declared for the devices, logs, network
and overrides areas (`DaemonSchemas.swift`); gradle, xcode, projects, cloud, database and the
built-ins have none yet. They are written by hand: `DaemonSchemaTests` encodes a value of each
type and fails on a key its schema lacks. `jaca <command> --help` prints the schemas of the
methods behind the command.

**Output.** A table whose column names are the JSON field names, or `--json`. Nothing else is
printed: an empty result is the header alone. A SESSION, REQUEST or RULE is an id, a unique id
prefix, or a name (sessions: name, device id, package; rules: the rule name). When several fit,
they are listed on stderr and the exit status is 1. `net show` removes the values of
`Authorization`, `Proxy-Authorization`, `Cookie` and `Set-Cookie` (`redacted: true` in JSON)
unless `--raw`. Exit status 2 with the usage on stderr for arguments that do not parse.

**Copy not specified yet.** The five new methods have an empty summary, a redacted header value
is shown empty (`CLIRedaction.placeholder`), and a request or rule that nothing fits prints the
empty table rather than a sentence. Unknown sessions reuse `No log session <x>.` and
`No network capture <x>.`.

`jaca net mode` prints the mode as a `mode` column (`--json`: `{"mode": …}`); with an argument it
calls `network.setMode` first. An unknown mode prints the usage and exits with 2. `jaca net
install-ca SESSION` prints the `network.installCA` result and exits with 1 when `outcome` is
`failed`.

**Limits.**
- Sessions exist in the daemon only for areas the app runs there, so `logs list` and `net list`
  are empty with `daemonAreas` off.
- Both network inspection modes capture in `jacad`: the agent, the MITM device proxy on Android,
  the iOS Simulator through the Mac system proxy, and This Mac's Chrome. Response overrides apply
  in both. Companion capture (a phone with the companion app and no adb, offered only in MITM
  mode) stays in the app, so `net list`, `net requests` and `net show` do not see it.
- A rule body given with `--body-file` is not checked against `OverrideSeeding.warning`.
- No command opens, starts or closes a session, or flips the master switch.

**Running the tests next to a live daemon.** The unit tests are hosted by the app. With
`daemonAreas` set in defaults the host connects to `~/.jaca/jacad.sock`, and a host built later
than the running daemon replaces it with its own `jacad`. Pass
`TEST_RUNNER_JACA_DAEMON_AREAS=none` to `xcodebuild test` to keep the host away from it.
