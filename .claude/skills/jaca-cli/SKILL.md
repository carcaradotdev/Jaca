---
name: jaca-cli
description: >-
  Operate the user's running Jaca sessions from a terminal with the `jaca` command: read device
  logs, list and inspect captured network requests, say what is failing, and create, enable,
  disable or remove response overrides. Use when the user asks what an app is logging, why a
  request fails, what a response body was, or wants a response mocked ("override this", "make
  that endpoint return 503") while Jaca is capturing.
---

# Driving Jaca with `jaca`

`jaca` talks to `jacad`, the daemon the Jaca app also talks to, so it sees the sessions that are
open in the app and what it changes shows up there.

## Before anything else

1. `jaca status` prints the daemon's pid and protocol. `jaca: command not found` means the link is
   not installed: `./scripts/install-cli.sh` (from the Jaca repo) puts it on PATH.
2. `jaca logs list` and `jaca net list` show the open sessions. Empty tables mean nothing is open
   in the daemon: the user has to open a log or network tab in Jaca first. Sessions only live in
   the daemon when the app runs with daemon areas on (`defaults read dev.srsouza.Jaca daemonAreas`).
   Both network inspection modes capture in the daemon. Only companion capture (a phone with the
   Jaca app and no adb) stays inside the app, out of reach.
3. `jaca net mode` prints the network inspection mode: `agent` (the in-process agent, one app)
   or `mitm` (a proxy that captures every app on an Android device or an iOS Simulator).
   Don't change the daemon areas or the mode yourself; tell the user what is missing.

## Rules of the road

- Add `--json` whenever you parse the output. Field names are stable; table columns carry the same
  names. Without it, ids are shortened to 8 characters.
- A session, request or rule argument is its id, any unique prefix of the id, or its name
  (sessions: the name, device id or package; rules: the rule name). When the argument fits more
  than one, the candidates are printed on stderr, the exit status is 1 and nothing is changed:
  pick one and retry with a longer prefix.
- Exit status: 0 done, 1 failed (stderr says why, or lists candidates), 2 the arguments did not
  parse (stderr is the usage).
- `Authorization`, `Proxy-Authorization`, `Cookie` and `Set-Cookie` values are removed from
  `net show` (`"redacted": true` in JSON). Pass `--raw` only when the user asks to see them, and
  don't repeat the values in your answer.
- `jaca <command> --help` prints the command's arguments and the params and result shapes of the
  daemon method behind it. `jaca overrides add --help` shows the shape of a rule.

## Find what is wrong

```bash
jaca net list --json                          # the open captures
jaca net requests --failed --json             # 4xx, 5xx and transport errors, every capture
jaca net requests pixel --host api.example.com --status 5xx -n 20
jaca net show 3fa2b1c0 --json                 # headers and bodies of one request
jaca logs tail --level error --since 10m      # one open session needs no name
jaca logs tail pixel --grep 'timeout|refused' -n 100
```

- `net requests` returns the newest matches, oldest first (100 unless `-n`). `--status` takes a
  code, a class or a range, comma-separated: `404,5xx,400-499`. A request still in flight has no
  `statusCode`; a transport failure has `error` instead.
- `net show` gives `requestBody` / `responseBody` as text, or `…BodyBase64` when the body is not
  UTF-8. Captured bodies stop at 1 MB.
- `logs tail` searches the daemon's replay buffer (the last 100k lines of the session). `--grep`
  is a case-insensitive regular expression over the tag and the message, `--level` is the lowest
  level kept (`verbose`, `debug`, `info`, `warn`, `error`, `fatal`), `--since` is an age (`30s`,
  `5m`, `2h`) or an ISO-8601 time. `--follow` keeps printing and never returns: don't use it in a
  one-shot command.
- Line a request up with the logs by time: `startedAt` on the request, `timestamp` on log lines.

## Override a response

```bash
jaca overrides list --json
jaca overrides add --from 3fa2b1c0 --json                      # replay the captured response
jaca overrides add --from 3fa2b1c0 --status 503 --body-file body.json --name "Orders down"
jaca overrides add --from 3fa2b1c0 --generalize                 # the path on any base URL
jaca overrides generalize "Orders down"                        # the same rewrite on an existing rule
jaca overrides disable "Orders down"
jaca overrides enable 9c41
jaca overrides rm 9c41
jaca overrides groups                                          # the groups, with their rule counts
jaca overrides mkgroup "Deals"
jaca overrides group 9c41 Deals                                # put a rule in a group
jaca overrides ungroup 9c41
jaca overrides disable --group Deals                           # every rule in it stops applying
jaca overrides rmgroup Deals                                   # its rules stay, in no group
```

- A **group** collects rules. A rule applies only when it and its group are both enabled; a rule
  keeps its own `enabled` while its group is off. The list order is the precedence: the rules of
  each group, in group order, then the rules in no group. `list` shows each rule's `group`.

- `add --from REQUEST` makes a rule that matches the request's method and URL (query dropped) and
  answers with the captured status, headers and body. `--status`, `--body-file` (`-` reads stdin)
  and `--name` replace those parts.
- `--generalize` (and `overrides generalize RULE`) rewrite the base URL of the pattern to `**`
  and keep the path as written, so one rule answers the endpoint from the device
  (`https://private-api.teya.xyz/lending/v1/…`) and from a browser on a dev server that proxies
  it under another base URL (`http://localhost:3000/private-api/lending/v1/…`). The device's
  host stays routed. An id the path names stays: a rule per mock deal keeps telling its deals
  apart. Generalize the rule made from the **device's** request, not the browser's: the
  browser's path carries the proxy prefix, which the device's path does not. In `mitm` mode the
  routed host limits the rule on a device, not in This Mac's Chrome capture, so the generalized
  rule still answers the browser.
- **A new rule is enabled and answers matching requests at once**, for every device and app. Pass
  `--disabled` unless the user asked for the override to take effect now, and say which pattern
  it matches when you report it.
- A warning on stderr after `add` (a streamed, truncated or binary body) means the rule may not
  reproduce the captured response. Pass it on.
- `overrides list` starts with `masterEnabled`: when it is `false` no rule applies, whatever its
  own `enabled` says. There is no command for the master switch; the user flips it in the app.
- `rm` deletes the rule for good. Ask first unless the user named the rule to delete.
- A rule only takes effect while a capture that supports overrides is running for that app; a
  rule with `hitCount` 0 after the app made the request has not matched (check the pattern and
  method) or nothing is armed.
- Overrides apply in both modes. In `mitm` mode a rule with routed hosts fires only on those
  hosts on a device (This Mac's Chrome capture is not limited), and a rule scoped to one app
  does not fire. Companion capture applies no rule.

## Network inspection mode and the CA

```bash
jaca net mode --json             # {"mode":"agent"} or {"mode":"mitm"}
jaca net mode mitm               # switch; only when the user asks
jaca net install-ca pixel --json # put Jaca's CA on the capture's device
```

- `jaca net mode agent|mitm` switches the mode for every device. The switch stops each capture
  the new mode does not offer and shows its chooser; it never starts one. Change the mode only
  when the user asks for it. Otherwise tell the user which mode the task needs.
- In `mitm` mode an HTTPS request that never shows up often means the device does not trust
  Jaca's CA, or the app pins its certificate (Jaca then passes that host through).
- `install-ca` changes the device. Run it only when the user asks. `outcome` is `installed`,
  `needsUser` (the CA is in the phone's Download folder; the user installs it in Settings) or
  `failed` with a `message`. `rebootAdvised: true` (iOS Simulator) means the simulator must
  reboot before its apps trust the CA: tell the user, and let them reboot it from the app or
  Herdr.

## Anything else

`jaca call METHOD [PARAMS_JSON]`, `jaca watch TOPIC...` and `jaca describe` are the raw daemon
client: `describe` lists every method with its schema. Prefer the subcommands; reach for `call`
only for something they don't cover, and never for `daemon.shutdown`, `network.close`,
`logs.close`, `overrides.setMaster`, `network.setMode`, `network.installCA` or
`network.rebootSimulator` unless the user asks.
