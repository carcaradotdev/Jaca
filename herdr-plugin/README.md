# Jaca for Herdr

Jaca's areas as Herdr panes and actions. The plugin holds no state of its own: every pane and
action is a client of `jacad`, the Jaca daemon, over `~/.jaca/jacad.sock`. The Jaca app and
these panes see the same data because they read the same daemon. See `docs/daemon-plan.md`.

Experimental. Standard library Go only.

## What it adds

| Kind | Id | What it does |
|---|---|---|
| pane | `devices` | A popup with the device list. `Enter` on a ready device shows its options (logs, network inspection, the database browser); `Enter` on an option opens it in a new tab named `Jaca log - <device>`, `Jaca network - <device>` or `Jaca database - <device>` and closes the popup. `j`/`k` or arrows move, `Esc` goes back a step and closes the popup from the device list, `q` quits. |
| pane | `logs` | The log viewer for the device chosen in `devices`, with the app log tab's tools. `1`–`6` set the minimum level (V…F), `/` edits the filter text, `r` toggles regex, `s` toggles system logs (not on Android), `P` edits the package id, `a` lists the installed apps to pick one, `c` clears the view, `C` clears the device buffer (Android), `p` or `space` pauses/resumes the stream, `j`/`k` and `PgUp`/`PgDn` scroll, `Shift+PgDn` (or `G`) follows the tail again, and scrolling up leaves it, `S` exports the lines the filter keeps to the file chosen in the macOS save dialog (named after the device, starting in Downloads), `y` opens the app's Copy format sheet as a popup (presets with an example each, the template and date format to edit, a live example; arrows or `Tab` move, `Enter` chooses, `Ctrl+S` or `⌘S` saves, `Esc` cancels, nothing is saved before Save), `?` shows the keys (any of `Esc`, `Enter`, `q`, `?` or a click closes it), `q` quits. The level chips, `.*`, `System logs`, `Export` and both fields are clickable, as are the arrow at the end of the package field (the installed apps) and `Help` and `Copy format` at the right of the status bar, the apps list too, and the wheel scrolls. A click on a log line selects it, and dragging extends the selection line by line; past the top or bottom of the lines the view scrolls that way. Letting go copies the selected lines whole, in the app's copy format (with `pbcopy`). The view holds still under a selection, and `Esc`, any key or a click outside the lines drops it. A right click opens the app's row menu on the selected lines (`Copy Line`, `Copy Message only`, `Copy Format…`, `Select All`); `Copy Format…` opens the Copy format popup, which saves to `~/.jaca/log-copy-format.json`, the file the app reads. For that menu the pane asks Herdr to send it right clicks (`herdr pane input --right-click pane`), so Herdr's own pane menu doesn't open on a right click in this pane. The pane draws this selection itself because it has the mouse for the toolbar, so the terminal can't select in it. In a field, `Enter` or `Esc` leaves it and `Ctrl-U` empties it; the package id applies on `Enter`. Opened without a device, it shows the picker first and streams in the same pane (`Esc` goes back). |
| pane | `network` | The app's network tab for the in-process agent ("Inspect Network (Agent HTTP)" in the device picker, Android and iOS Simulator), or for a Chrome window on this Mac ("This Mac", then "Inspect Network (Chrome)"), with response overrides. See [Network and overrides](#network-and-overrides). |
| pane | `tools` | A popup listing `Gradle` and `Xcode`. `Enter` or a click opens the chosen pane in a new tab named `Gradle - Jaca` or `Xcode - Jaca` and closes the popup. `j`/`k` or arrows move, `Esc` or `q` closes. Run outside Herdr, the chosen pane shows in place (`Esc` goes back). |
| pane | `database` | The app's Browse Database ("Browse Database" in the device picker): one app's local SQLite databases, read from a pulled snapshot. See [Database](#database). |
| pane | `cloud` | The app's Cloud Logging area: the home (gcloud sign-in, projects) and, in tabs it opens, the log sessions. See [Cloud Logging](#cloud-logging). |
| pane | `gradle` | The app's Gradle area: the folders of `~/.gradle/caches` with their sizes, then the live daemons from the daemon's `gradle.daemons` topic. See [Gradle and Xcode](#gradle-and-xcode). |
| pane | `xcode` | The app's Xcode area: the DerivedData folders with their sizes and kind (`LIVE`, `STALE`, `SHARED`). See [Gradle and Xcode](#gradle-and-xcode). |
| pane | `projects` | The app's Projects area: the projects Claude Code has run in and the folders you added, each opening to its checkouts, with the app's actions. See [Projects](#projects). |
| action | `gradle-kill-all` | Kills every running Gradle daemon. |
| action | `projects-clear-cache` | Clears build caches for the worktree in the Herdr context (the workspace's worktree, else the focused pane's directory). |
| startup | | `jaca-herdr ensure`: starts `jacad` if it isn't running. |

## Install

Full steps, including uninstalling: **[INSTALL.md](INSTALL.md)**. The short version:

Needs Go 1.22+ and a Jaca build that ships `jacad` (`Jaca.app/Contents/MacOS/jacad`).

```bash
cd herdr-plugin
go build -o bin/jaca-herdr ./cmd/jaca-herdr
herdr plugin link "$PWD"
herdr plugin pane open --plugin dev.srsouza.jaca --entrypoint devices
```

To open the device picker with a key, add a binding to `~/.config/herdr/config.toml` (pick a free
key) and run `herdr server reload-config`:

```toml
[[keys.command]]
key = "prefix+d"
type = "shell"
command = "herdr plugin pane open --plugin dev.srsouza.jaca --entrypoint devices"
```

The picker for the Gradle and Xcode panes takes a binding the same way:

```toml
[[keys.command]]
key = "prefix+shift+b"
type = "shell"
command = "herdr plugin pane open --plugin dev.srsouza.jaca --entrypoint tools"
```

`jacad` is looked up at `$JACAD_PATH`, then `/Applications/Jaca.app` and `~/Applications/Jaca.app`.
`JACA_DAEMON_DIR` points every piece (app, daemon, plugin) at another socket directory, which is
how to try a development build without touching the real one:

```bash
export JACA_DAEMON_DIR=~/.jaca/dev JACAD_PATH=/path/to/Debug/Jaca.app/Contents/MacOS/jacad
bin/jaca-herdr pane gradle
```

Remove it with `herdr plugin unlink dev.srsouza.jaca`.

## Network and overrides

The `network` pane captures requests and applies response overrides. It is a client of jacad's
`network.*` and `overrides.*` methods. How it captures depends on the app's network inspection
mode, which jacad owns (`network.mode`, `network.setMode`):

- Agent HTTPS debugging: the in-process agent captures one app.
- MITM HTTPS debugging: the device proxy captures every app on an Android device or an iOS
  Simulator through Jaca's proxy on the Mac.

- **Mode**: `M` opens a menu of the two modes, on the current one. Choosing the other one calls
  `network.setMode`, which stops the captures the new mode doesn't offer; the pane then shows
  the chooser again. The pane reads the mode when it opens and follows the `network.mode` topic,
  so a switch made in the app or in another pane shows here too.
- **Chooser**: a stopped capture with nothing chosen shows a row for each source the mode offers
  (the state's `offeredSourceIDs`): ` Inspect app ` for the agent, which opens the app list, and
  ` Device proxy ` for the device proxy, which starts at once with no app. `↑`/`↓` move between
  rows, `Enter` or a click chooses. A jacad that doesn't send the offered sources has the agent
  row alone.
- **Start**: `a` (or the app button) lists the installed apps; choosing one starts the capture.
  `p` or `space` stops and starts it. On the iOS Simulator starting relaunches the app. A device
  proxy capture has no app: `p` starts the device proxy again, and the toolbar's mode reads
  `proxy`.
- **Certificate banner**: while the device proxy needs Jaca's certificate on the device and it
  isn't there yet (`proxyNeedsSetup` and not `caReady`), a banner the width of the pane says so.
  `I` calls `network.installCA`: jacad installs the certificate into the system store of a
  rooted Android device, copies it to Download for the user to install on other Android devices,
  and adds it to an iOS Simulator's keychain. The banner shows the result. After a simulator
  install, `B` calls `network.rebootSimulator`, so the simulator's apps trust the certificate.
  `x` dismisses the banner (`network.clearProxyNeedsSetup`). `I` also works on any device proxy
  capture without the banner.
- **Attach banner**: when the app came back without the agent (the user reopened it), a
  warning block under the toolbar says so, with a ` R  Relaunch & re-attach ` button (`R`). On
  the iOS Simulator, in Agent HTTPS debugging, a switch beside it turns on the app's
  `Re-attach to iOS Simulator apps automatically` setting (written with `defaults`; jacad reads
  it each time it decides), so jacad relaunches the app without asking. It is off by default, as
  in the app: a relaunch throws away where the user was in their app.
- **List**: the path is cut in the middle, as in the app, so the end of an endpoint stays
  readable; a narrow list leaves out Size, then Host, then Time before it cuts the path short.
  `j`/`k` select, `Shift` with `↑`, `↓`, `PgUp` or `PgDn` selects a run of requests,
  `Backspace` deletes the selected ones from the list (here only; jacad keeps them, so they
  are still in an exported HAR), `/` filters by URL, host or method, `c` clears, `S` exports a
  HAR through the macOS save dialog, `C` copies the selected request's response body, `G` goes
  back to following new requests.
- **Timeline**: the strip above the list draws each request from its start to its end.
  Dragging across it shows only the requests in that time range; a click on it, the `×` at
  its right or `Esc` clears the range. It shows in panes of 24 rows or more.
- **Detail**: `Enter` (or `→`) opens the request beside the list, with the app's tabs
  (Overview, Headers, Request, Response, Timing), and gives it the keys: the arrows and `j`/`k`
  scroll it, `PgUp`/`PgDn` page it, `←`/`→`, `Tab` or `1`–`5` switch tabs. `Esc` closes the
  detail and gives the keys back to the list, which keeps the selection. A click on a request
  opens its detail with the keys on the list; a click in the detail gives it the keys. The side
  that has the keys has its headings in the accent, and the selected request is quieter while
  the detail has them. In the Request tab `C` copies the request body. Any text in the
  detail can be copied with the mouse: a drag selects it and copies on release (a value that
  wrapped over several lines comes back in one piece), a double click copies the whole value
  under the pointer, and a right click offers `Copy` for it. The `Copy` buttons of the bodies
  and header sections sit at the right of their line, drawn like the popups' close button.
- **Request menu**: a right click (or `m`) shows the app's menu: `Override response…` (or
  `Edit override “…”` and `Add another override…` when a rule already answers it), `Copy as cURL`,
  `Copy URL`, `Copy response body`, `Filter by this host`.
- **Device picker**: the network option is `Inspect Network (Agent HTTP)` or
  `Inspect Network (MITM HTTP)`, for the mode the picker reads with one `network.mode` call when
  it opens.
- **This Mac**: the device picker always lists This Mac. Its capture starts at once: jacad
  opens a separate Chrome window with its own profile, sends its traffic through a proxy on
  127.0.0.1 and applies the overrides to it. `b` (or the `Open Chrome` button) opens the window
  again after it was closed; stopping the capture closes it. There is no app to choose.
- **Copy as cURL**: `u`, the menu item, or the detail's `Copy cURL` button (at the right of the
  tabs) copies the request as a curl command that runs as-is, as the app's `CurlExport` builds it.
  The pane fetches the request body first when it doesn't hold it.
- **Overrides**: `o` (or the Overrides button) opens the rules: `Enter` edits, `n` is New
  override, `space` or `Shift+Enter` (or a click on a rule's switch) enables or disables, `d` duplicates, `x` or `Backspace` deletes, `K`/`J` move a rule up
  or down (the first enabled match wins), `m` pauses or resumes all of them.
  `P` does this from the request list and the request detail.
- **Override groups**: with a jacad that has groups, the list shows each group as one row above
  the rules in no group, and `N` (or the New group button) creates one and starts renaming it. On
  a group row, `Enter` (or a click on its name) opens the group's own popup, `space` or
  `Shift+Enter` turns the group and all its rules on or off, `r` renames it (`Enter` saves, `Esc`
  cancels), `x` or `Backspace` deletes it (its rules stay, in no group), and `K`/`J` move it. On a
  rule row, `g` moves the rule into a group or out of one. A right click on a row shows these as a
  menu.
- **A group's popup**: titled with the group's name, it holds the group's switch (`m`), its rules
  with the same keys as the list (`K`/`J` move a rule inside the group), and the New override
  (which makes a rule in the group), Rename group (`r`) and Delete group buttons. `Esc` goes back
  to the list.
- **Override a request**: `O` on a selected request opens the editor filled from it (its URL as
  the pattern, its method, and the response it got), or on the rule that already answers it.
- **Editor**: `Tab`/`Shift+Tab` move between fields, the arrows move inside a group of chips and
  `space` picks, `Ctrl+S` (or `⌘S`) saves, `Esc` closes without saving. Closing goes back to
  where the editor was opened from: the rules list, or the requests. In the body `Tab` indents two
  spaces (every selected line, when several are) and `Shift+Tab` takes a level off, so `Esc`
  first hands the keys back to moving between fields (then `Tab` and `Shift+Tab` move again),
  and a second `Esc` closes. The body is a multi-line editor:
  `Shift` with the arrows, `Home`, `End`, `PgUp` or `PgDn` selects, as does dragging with the
  mouse; typing or `Backspace` replaces the selection; `Alt` or `Ctrl` with `←`/`→` moves by
  word and `Alt+Backspace` deletes one; `Ctrl+A` selects everything, `Ctrl+C` copies and
  `Ctrl+X` cuts the selection; `Ctrl+Z` undoes and `Ctrl+Y` redoes. `⌘A`, `⌘C`, `⌘X`, `⌘Z` and `⇧⌘Z` do the
  same where the terminal passes them on (see below). One-line fields edit at a cursor the arrows move. In a
  pane of 120 columns and 30 rows or more the editor is the app's two-column sheet.

**⌘ keys.** A terminal keeps `⌘A`, `⌘C` and `⌘Z` for itself by default, so they never reach
the pane. Herdr forwards a `⌘` key it receives to the focused pane, and the editor reads it, so
the terminal only has to let them through. In Ghostty (`~/.config/ghostty/config`):

```
keybind = super+a=unbind
keybind = super+z=unbind
keybind = super+shift+z=unbind
keybind = performable:super+c=copy_to_clipboard
```

This changes Ghostty everywhere: `⌘A` no longer selects the whole screen and `⌘Z` no longer
undoes a closed tab; `⌘C` still copies a Ghostty selection when there is one.

Not carried over from the app: the JSON tree view (bodies show as
pretty-printed text), the match preview's example rows and shadow count, find in the body
editor, the app's device proxy section, the guided certificate install for a phone without root
(the pane copies the certificate to Download and says where to install it), and companion
capture. Regex patterns use Go's
engine, not the app's: lookaround and backreferences don't compile here though they run in the
app and in jacad.

Rule bodies over 4 KB are written to `~/.jaca/network-overrides/bodies/` by the pane, as the
app does; jacad has no method to upload one.

## Gradle and Xcode

The `gradle` and `xcode` panes work alike. One cursor moves over every row, and each row has a
button that takes two presses, as in the app: the first arms it for 3 seconds (`Kill` reads
`Confirm kill?`, `Delete` reads `Confirm?`), the second within that time confirms. Each row is
armed on its own. The result shows on the line above the status bar for 2.6 seconds, as the
app's toast does.

- **Keys**: `j`/`k` or arrows move, `PgUp`/`PgDn` move a page, `Enter`, `x` or `Backspace`
  press the selected row's button, `r` refreshes, `?` shows the keys (any of `Esc`, `Enter`,
  `q`, `?` or a click closes it), `q` quits.
- **Mouse**: a click selects a row, a click on a row's button presses it, the wheel scrolls,
  and `Help` at the right of the status bar opens the keys.
- **Gradle**: the cache folders (`gradle.caches`, measured with `du` when the pane opens, so
  the section reads `Calculating…` at first) and the daemons. Killing dims the daemon's row
  until jacad answers; a daemon that exited on its own meanwhile goes without a toast. `r` is
  the app's "Refresh Gradle daemons" and also measures the cache again, which the app does
  each time its area appears.
- **Xcode**: `xcode.list` sizes every folder with `du`, so the first scan takes a while. `r`
  is the app's "Rescan DerivedData". `S` (or the button at the top right, shown while there
  are stale entries) is the app's `Clean <n> stale`, two presses too: it deletes the stale
  folders one by one and then removes every stale row, as the app does; the toast counts the
  folders that were deleted, and a rescan lists any that weren't. jacad has no topic for
  DerivedData, so the pane removes the rows it deletes and otherwise changes only on a rescan.

In a narrow pane the name is cut first, then columns are left out: the JDK, heap and RAM tags, CPU,
uptime, PID and `BUSY`/`IDLE` in the Gradle pane, the workspace path, kind and size in the Xcode pane. The button goes
last.

## Cloud Logging

The `cloud` pane is the app's Cloud Logging area on jacad's `cloud.*` methods. It opens on the
home, in a popup (`Esc` closes it); opening a session closes the popup and switches to the
session's own tab, named `Jaca cloud - <project>`.

To open it with a key, in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+l"
type = "shell"
command = "herdr plugin pane open --plugin dev.srsouza.jaca --entrypoint cloud"
```

**Home.** The header shows what jacad found: `Signed in as …`, `Not signed in` or
`gcloud CLI not found`. Signed out, `Open Terminal` opens a Herdr tab running
`gcloud auth login` (jacad never runs it: it has no terminal to prompt in), and the home asks
jacad to re-read the account every 3 seconds until the login lands (for 10 minutes after the
last key or click; `r` asks at any time). `j`/`k` move between
projects, `←`/`→` or `Tab` choose a row's action and `Enter` presses it; `n` is New session,
`l` Log names, `e` Rename, `x` or `Backspace` Remove (two presses), `a` Add project, `u` From
URL…, `r` Re-check.

**Session.** `p` or `space` starts and stops, `c` clears, `f` toggles Follow tail (`G` turns
it on), `l` opens the log names, `t` the time range, `u` the share menu, `1`–`6` set the
minimum severity (All, D, I, W, E, C), `F` opens the Filters bar, `/` searches the loaded
logs, `↑`/`↓` and `PgUp`/`PgDn` move a selection over the entries (an open details panel
follows it; `j`/`k` scroll without selecting), `S` exports, `C` copies the selection, `y` sets the copy format. A click or `Enter`
opens an entry's details beside the list; there `j`/`k` move between fields, `Enter` opens a
field's actions (filter by a label or severity, open it in a new session, favorite a label),
and `[` `]` step between entries. Scrolling to the top loads older logs.

Changing what is sent to gcloud (the log name, the time range, the severity, the Filters bar's
conditions) restarts a running session, as in the app; the search box only filters what is
loaded.

**SQL.** `Q` switches between Logs and SQL, and `s` goes to the SQL editor. The statement
runs over the entries loaded in the session (jacad's `cloud.sessions.query`), with `Ctrl+R`,
or `⌘↩` where the terminal passes it on; once it has run it runs again every 2 seconds, as in
the app.
The bar has the app's Schema popup, the Labels menu (inserts a filter on a label), the
Templates menu (saved templates, starters, From current filter) and `Save…`. In the
editor `Tab` indents, `Esc` leaves it, and `Ctrl+C` copies the selection. A pane with fewer
than three rows to spare shows no SQL bar.

A confirming press has to be a separate press: the repeats of a held key don't confirm what
its first press armed. The pane reads how this Mac repeats keys (`InitialKeyRepeat` and
`KeyRepeat`, when it starts) and takes the same key for a repeat when one is due: right after
the last one, one interval after, or the first delay after (375 ms unless changed, from
40 ms before it to 60 ms after, so a second press that lands there has to be made again). Any other second press
of the same key waits a moment (150 ms at the usual repeat rate) and is dropped when a repeat
follows it. It then acts on the row it was pressed on, or on nothing when that row has moved.
What this cannot tell from two presses: a key held just past its first repeat and let go,
when that repeat came more than 40 ms early or 60 ms late.
This applies to every two-press button (Remove here; Kill, Delete and Clean in the Gradle and
Xcode panes). A click on a row that an update moved before it was drawn is dropped.

Not carried over from the app: the Ask Claude buttons (SQL and regex) and the label examples
sheet that sets what they send, the gcloud debug
console (it reads a log kept inside the app, which jacad has no method for), resizing the
detail panel, horizontal scrolling of long lines, syntax highlighting and autocomplete in the
SQL editor, the tab subtitle (`project · log · range`), selecting part of a value in the
detail panel, and the date pickers of an absolute range (two text fields read as
`2006-01-02 15:04`). A match mode is changed by pressing it until the wanted one shows, where
the app opens a menu. A pane does not survive a jacad restart: it exits, and is opened again.

## Projects

The `projects` pane is the app's Projects area on jacad's `projects.*` methods and its retained
`projects.state` topic. It opens in a tab; with the binding below the tab is named
`Projects - Jaca`.

```toml
[[keys.command]]
key = "prefix+f"
type = "shell"
command = "herdr plugin pane open --plugin dev.srsouza.jaca --entrypoint projects --focus --env JACA_HERDR_OWN_TAB=1"
```

- **List**: projects start closed. `Enter`, `Space` or a click on a project's name line opens
  and closes it; `→` opens, `←` closes, and `←` on a nested row goes to its parent. `t` (or
  `Tree` / `List` in the header) switches between the tree, which nests a project under the
  project whose folder contains it, and the flat list in jacad's order. The choice is the app's
  `jaca.projectsViewMode` setting, so the pane and the app share it.
- **Rows**: each row is two lines, the name with its tags and size, then the path (for a
  checkout the path, `from <base>` or `detached HEAD` / `branch gone`, and its age). The
  selected row shows its actions as buttons on the second line.
- **Actions**: `o` Open in Finder, `z` Open in Zed (when Zed is installed), `y` Copy name
  (checkouts), `c` Cache & worktree actions (checkouts), `h` Open in Herdr (Claude projects),
  `x` or `Backspace` Remove (folders you added; two presses, as in the app). `m`, `Enter` on a
  checkout, or a right click opens a menu with the same actions.
- **Cache & worktree actions**: `Clean cache` runs at once and closes the sheet, as in the app.
  `Delete worktree` takes two presses within 3 seconds. `Tab` moves between the buttons and
  `Enter` presses the focused one (`Close` at first), `Esc` closes. The main checkout has no
  delete. The sheet shows whole or not at all: a pane too short for it does not open it.
- **Disk usage**: the bar asks before sizes are computed. `C` is Calculate, `N` is Not now, `S`
  stops a running scan. The answer lasts until the pane closes; after Calculate, each
  completed rescan is sized again.
- **Folders**: `a` opens the macOS folder chooser and adds the folder. `r` rescans. The pane
  rescans by itself when it opens and the last scan is missing or older than 30 seconds.
- **Open in Herdr**: asks for the session name, then finds or creates the project's Space,
  opens a tab named after the session and runs the Claude command there. On a project root
  that is a git repo it fetches, fast-forwards and starts `--worktree <name>`; in a linked
  worktree, or a root without git, it runs the command in the folder. The first launch also
  asks for the command; `s` (or `Herdr settings`) changes it later. It is stored in the app's
  `jaca.herdr.claudeCommand` setting.
- A held key acts once: its repeats are dropped, and a second press of the same key acts after
  a moment (see Cloud Logging).

Not carried over from the app: the icons and avatars; action buttons on every row (only the
selected row shows them, since the labels are the app's tooltips and a terminal has no room for
them on each row); the hover-only Remove; animations (a worktree being deleted is dimmed, a
freed size is green); the toast icons; the multi-line command field (one line here). The
chooser has the app's message but not its `Add` button label, which AppleScript's
`choose folder` cannot set. Ages that jacad does not send are written as `3 min ago`, `2 hr ago`
and so on, in fixed-length units: the app's formatter follows the system's language and
region, and a date near a unit boundary can read one unit apart from its.

## Database

The `database` pane is the app's Database tab on jacad's `database.*` methods. It opens on the
installed apps; picking one lists its databases, pulls the first and shows the first table,
100 rows a page. What it shows is a snapshot: `Refresh` pulls the database again and goes back
to the first table. It reads only: jacad refuses a statement that is not read-only.

- **Toolbar**: `a` (or the app button) lists the apps, `d` opens the DB menu, `t` the Table menu
  (each table with its row count), `r` is Refresh.
- **SQL**: `s` (or a click) goes to the SQL box. `Enter` runs it, as in the app; `Ctrl+R`, or `⌘↩`
  where the terminal passes it on, runs it from anywhere. `Alt+Enter` breaks the line (the box
  grows to three rows), `Esc` leaves it, `Ctrl+C` copies the selection. A query lets go of the
  table: the Table control reads `—` and the pagination bar goes.
- **Rows**: `↑`/`↓` (or `j`/`k`), `PgUp`/`PgDn`, `Home`/`End` move the selection, `←`/`→` (or
  `h`/`l`, the wheel sideways or with `Shift`) scroll by column, the wheel scrolls. `[` or `p`
  is Prev, `]` or `n` is Next.
- **Row detail**: `Enter` or a click opens the row beside the grid, and again closes it. `Tab` or
  `1`/`2` switch between Fields and JSON, `PgUp`/`PgDn` scroll it, `C` (or the button) is Copy
  JSON, `Esc` closes it. Text in it is copied with the mouse as in the network pane's detail.
- `?` shows the keys, `q` quits. Opened without a device it shows the picker first.

As in the app, the option is offered for every ready device; a physical iOS device answers
`Database browsing isn't supported on this platform yet.`, and an Android app has to be
debuggable.

jacad bounds what a read returns, which the app does not: a query stops at 50000 rows, any
result at 64 MB, and a statement after 30 seconds. Its messages for these
(`The result has more than 50000 rows. Add a LIMIT to the query.`,
`The result is larger than 64 MB. Select fewer rows or columns.`) and for a session it no
longer has (`No database session …`, `No database pulled in session …`) have no app copy.
The pane asks jacad for one listing or pull at a time, re-opens its session every 4 minutes so
it is not reaped, and pulls again when jacad says the session or the copy is gone.

Not carried over from the app: the tab's name (`DB · <app>`), the checkmark on the picked app,
the grid's cell borders, selecting text in the grid, and the `Copied` label on the Copy JSON
button (the pane shows its `Copied` notice instead). The JSON is the app's, except that a
number between 1e15 and 2^54 is quoted, and keys of a nested object outside Latin-1 are in code
point order.

## Copying

Every copy in the log, network, database and Cloud Logging session panes (a button, a key, a menu item,
a selection released) shows `Copied` for a moment near the bottom of the pane, the app's
notice for it. A copy that fails shows the error instead.

## Colors

Herdr doesn't pass its theme to plugins, so the panes work it out the way Herdr does: the
built-in theme named under `[theme]` in `~/.config/herdr/config.toml`, with the colors of
`[theme.custom]` on top. Popups use what Herdr's own overlays use (`text` on `panel_bg`, an
`accent` border, and its ` esc close ` button at the top right, clickable), and the log colors are the theme's `red`, `green`, `yellow`, `blue`, `teal`
and `mauve`.

The built-in palettes are copied from Herdr's source into `cmd/jaca-herdr/herdrthemes.go`
(generated from v0.9.1's `src/app/state.rs`); regenerate it when Herdr adds or changes a theme.
A theme the table doesn't have, or `terminal`, leaves the terminal palette's colors.

The config is read when a pane starts, so a theme change shows in panes opened after it.
`auto_switch` and `[theme.custom.light]` / `[theme.custom.dark]` are not applied.

## Protocol

Newline-delimited JSON-RPC 2.0 on the socket. `jacad describe` lists every method and topic;
`jacad call METHOD [PARAMS_JSON]` and `jacad watch TOPIC...` are the quickest way to explore.
`protocolVersion` in `cmd/jaca-herdr/rpc.go` must match `DaemonProtocol.version` in the app.

## Copy

Every string a pane shows is taken from the app (the Gradle, Xcode, device list, device menu, log and
Projects views, the sidebar titles, `DeviceState.label`, `LogLevel.short`, the Projects toasts). In the Cloud Logging panes these have no app copy and are placeholders: the `?` popup labels
`Select row`, `Select action`, `Press`, `Start / Stop`, `Time range`, `Minimum severity`,
`Select entries`, `Details / row actions`, `Previous / next entry`,
`Switch between list and details`, `Close / back`, `Logs / SQL`, `SQL filter`,
`Copy Logs Explorer URL / Open in browser` (and `Scroll`, `Help`, `Quit` as in the
other panes); the `Help` button in the status bar; the tab name `Jaca cloud - <project>`; the
glyphs that stand in for the app's icon buttons (`▶ ■ ⌫ ⤓ ↗ ⟳ ⊕ ⊖ ▾ ▼ ▸ ★ ☆ ✓ ● ○`), the `│` gutter of the SQL editor and the `↓ <path>` note
after an export (the app shows nothing there); and the error
lines the client itself produces when Herdr or jacad returns something it can't read
(`herdr tab create: no pane_id`, and the decode errors in `cloudwire.go`). The row
`… <n> more lines — ⌘C copies all` is the app's string, though the key here is `C`; so is the
SQL bar's `⌘↩ to run · …` hint, where the key that always works is `Ctrl+R`. The ` esc close `
and ` esc back ` buttons stand where the app's sheets have `Cancel`. The client's own error
lines (`<method>: no reply from jacad after <time>`, `jacad closed the connection`) have no
app copy either. The log toolbar's field placeholders are the app's with a capital first letter. In the network pane's `?` popup, `Delete request`, `Select requests`, `Select request`, `Inspect request`, `Switch tab`, `Request menu`, `Follow new requests` and `Back` are placeholders too, as is the `network` pane title. The `R` in the attach banner's ` R  Relaunch & re-attach ` button is the key, like `esc` in ` esc close `; the label after it is the app's. The `M` menu uses the app's Settings titles, `Agent HTTPS debugging` and `MITM HTTPS debugging`; `inspection mode` (the `?` popup's label for `M`), ` Device proxy `, the certificate banner's prompt and its `installed` and `needsUser` results, and `Inspect Network (MITM HTTP)` are specified copy. The banner's texts while an install or a reboot runs, the simulator result that offers `B reboot`, and the result after a reboot are proposals that wait for sign-off (`// COPY-PENDING` in `netmode.go`). The switch beside it is labelled with the app's Settings title for the same setting, `Re-attach to iOS Simulator apps automatically`. In the database pane's `?` popup, `Row details` is a placeholder (the other labels are the app's, or placeholders the other panes use), as are the `database` pane title and the tab name `Jaca database - <device>`. In the Gradle and Xcode panes' `?` popups, `Select row` is a placeholder (the other labels are the app's buttons and tooltips, or the placeholders the log viewer already uses), as is the `tools` pane title, `Jaca`. Those two panes show nothing while a refresh the user asked for is running, because the app has no text for it. The `?` popup's labels are the app's where it has one; `Minimum level`, `Filter text`, `Regex`, `Package id`, `Pause / unpause`, `Scroll`, `Help` (also the popup's title and the status bar button) and `Quit` are placeholders that need specified copy. In the projects pane's `?` popup, `Expand / collapse`, `Row menu` and `Tree / List` are placeholders, as are the tab name `Projects - Jaca` and the `jaca: ` prefix in front of an error the app would swallow. The pane uses three of the app's strings where the app does not: `Herdr settings` (the button's accessibility label; its tooltip is longer), `Confirm?` as the row menu's label while Remove is armed, and the relative ages jacad does not send, which are approximated. The two action titles
and the `logs` pane title in `herdr-plugin.toml` are placeholders written for this prototype and
need specified copy.
