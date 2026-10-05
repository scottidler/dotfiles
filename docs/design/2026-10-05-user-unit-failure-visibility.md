# Design Document: User-Unit Failure Visibility (slack-deliver silent 4-week outage)

**Author:** Scott Idler (drafted with Claude)
**Date:** 2026-10-05
**Status:** Implemented
**Review Passes Completed:** 5/5

## Summary

- `slack-deliver.service` (a user unit on desk) failed every minute from 2026-09-08 15:02:03 to today, `status=203/EXEC`: its `ExecStart` named `~/.local/bin/slack`, a binary deleted that afternoon. 38,027 failures, zero alerts.
- Four independent gaps let it run silent: nothing alerts on a failed user unit, nothing checked references before the delete, slack-cli hardcodes `~/.local/bin` into the unit it ships, and no `slack doctor` exists to look.
- Fix all four, across three repos (Scott, 2026-10-05: "lets do it all"): a fleet-wide `OnFailure=` -> ntfy drop-in (dotfiles), a SessionStart failed-unit check and a delete-reference guard (claude), and `slack doctor` + `slack scheduled install-timer` + a queue-time check (slack-cli). Then fix unit ownership in dotfiles so every unit has exactly one owner.

## Problem Statement

### Background

- slack-cli's scheduled follow-ups (`slack write --at ... --follow-up`) queue replies to `$XDG_STATE_HOME/slack/follow-ups.json` (`src/config.rs:368-372`) when the parent has no thread root (`MODE_QUEUED`, `src/command/write/follow_ups.rs:138-140`). Slack cannot schedule a reply to a message that does not exist yet.
- `slack scheduled deliver` (`src/command/scheduled.rs:840`) posts them once the parent fires. It is a one-shot: "Meant to run on a timer, on the machine that scheduled the parent" (`src/cli.rs:562`). slack-cli has no daemon.
- The timer is not installed by slack-cli. The README (`README.md:155-167`) tells the user to `cp contrib/systemd/slack-deliver.{service,timer}` into `~/.config/systemd/user/`. Both the contrib unit (`contrib/systemd/slack-deliver.service:6`) and the skill template (`plugin/skills/scheduled/SKILL.md:139`) hardcode `ExecStart=%h/.local/bin/slack scheduled deliver`, because `bin/install` installs to `~/.local/bin` (`bin/install:17`).
- Scott installs with cargo: the binary is `~/.cargo/bin/slack`. desk's unit was hand-copied from the template on 2026-09-07.

### What happened (evidence)

- 2026-09-07: unit installed; `~/.local/bin/slack` existed as a stale v0.8.0 copy, ahead of `~/.cargo/bin` on PATH (positions 25 vs 28). The unit ran it.
- 2026-09-08: session `4038a806` (okta-auth `offline_access` release) found the stale copy shadowing v0.11.0 and ran `rm -v ~/.local/bin/slack` (transcript line 2181). Nobody grepped for what referenced the path.
- 2026-09-08 15:02:03: first `Failed at step EXEC spawning /home/saidler/.local/bin/slack: No such file or directory`. Every minute since. Live state today: `ActiveState=failed Result=exit-code ExecMainStatus=203`.
- Agents masked it: the MCP `scheduled_deliver` tool (`src/mcp.rs:485`) runs the same delivery inside a session, so follow-ups posted whenever a session happened to call it. The queue is empty today (`{"sets":{}}`), nothing stranded.
- The rails `rm` rule would not have caught it even today: it shipped 2026-09-13 (after the delete), and `DELETE_FLAGS = /^-[rRf]+$/` (`claude/HOME/.claude/skills/rails/hooks/index.ts:296`) passes `rm -v` through untouched.

### Problem

A user unit can fail forever without anyone being told, and the inputs that break units (a deleted binary, a hardcoded install path) are invisible to every test and guard we run.

### Goals

- Any failed user service on any host dotfiles deploys produces an ntfy alert, deduplicated per unit, with a bounded retry if ntfy is unreachable; the SessionStart check is the backstop when every retry fails (Scott, 2026-10-05, option B).
- A Claude session on a host with a failed user service is told so at start (Scott, option B).
- A shell command that deletes or moves a path referenced by a user unit, a `.desktop` launcher, the crontab, or a `~/bin` symlink is denied before it runs (Scott, option B).
- `slack doctor` reports the deliver timer's health, the binary it runs, its last result, stranded queue sets, and PATH shadowing (Scott, 2026-10-05: "slack doctor could catch it").
- `slack scheduled install-timer` renders the unit from the running binary's path, so no hardcoded install path survives (Scott, option B).
- A queued follow-up write refuses when the deliver timer cannot deliver it (Scott, option B).
- Every user unit on desk has exactly one owner: the tool that installs it, or dotfiles. Never both (Scott, option B: "all 25 user units tracked"; research on 2026-10-05 changed the how, installer entries instead of symlinks, not the scope).

### Non-Goals

- **Excluded:** a fleet-wide duplicate-command-on-PATH lint. Raised in discussion, not in Scott's chosen option. `slack doctor` covers slack's own shadowing.
- **Excluded:** system (root) units. The incident class is user units; system units already surface in `systemctl --failed` and are rarely hand-written here.
- **Excluded:** macOS launchd support in `install-timer`. It refuses with a message on non-Linux. Scott's hosts are Linux; slack-cli's CI runs tests on ubuntu only.
- **Parked (revisit if the topic is abused):** moving the ntfy topic out of the public dotfiles repo into `keep`. It is already a plaintext literal at `HOME/.local/bin/swap-watch.sh:4-5`; this doc reuses it and does not widen the exposure class.
- **Parked (revisit when ripr becomes primary):** deciding which host runs host-role units (borg, cortex, sb-harvest, eratosthenes, slack-deliver). This doc builds the executable gate (`primary-host`, Phase 7); the migration plan decides which host carries the marker.
- **Parked (revisit if anyone runs a non-default queue path):** slack queue identity. A scheduling process with a non-default `follow_ups_path` or `XDG_STATE_HOME` and a timer with the default would watch different queues. One user, default paths today.

## Proposed Solution

### Overview

Four layers, each catching what the one before misses:

| Layer | Catches | Repo |
|---|---|---|
| `OnFailure=` drop-in -> ntfy | any user service entering `failed`, within a minute | dotfiles |
| SessionStart failed-unit check | failures that predate the alert, or an alert missed on the phone | claude |
| DELETE-REF guard | the agent action that breaks a unit, before it runs | claude |
| `slack doctor` + `install-timer` + queue check | slack's own install defect and its user-facing symptom | slack-cli |

Plus an ownership cleanup in dotfiles so the units being alerted on are reproducible.

### Unit ownership rule

- A unit written by a tool's installer is owned by that tool. dotfiles never symlinks it. Overrides go in a drop-in (precedent: `HOME/.config/systemd/user/clyde-enrich.service.d/dormant-after.conf`, whose comment says exactly this).
- Why it matters: installers rewrite their unit. `clyde bootstrap` uses `write_atomic` (rename, `clyde/src/bootstrap.rs:1188,1248`), which replaces a dotfiles symlink with a regular file and silently untracks it. eratosthenes (`src/service.rs:518`), borg (`borg/src/service.rs:266`), cortex (`cortex/src/daemon.rs:967`), sb-harvest (`borg/src/harvest/timer.rs:134`) and aka (`src/bin/aka.rs:351`) use `std::fs::write`, which follows the symlink and writes the rendered unit into the PUBLIC dotfiles repo.
- dotfiles owns only units no tool writes: today `firefox-volume-keeper.service` (plus its script) and the existing tracked set (riki, sccache, swap-watch, sweep-repos-watchdog).
- Tool-owned units get a manifest `script:` entry that calls the installer, so a new host reproduces them.
- Host-role units (work that must run on exactly one host) are gated by an executable check, not a comment: their `script:` entries start with `primary-host || exit 0`. `HOME/bin/primary-host` exits 0 only if `~/.config/primary-host` exists and holds `$(hostname -s)`; otherwise it prints why and exits 1. The marker is a plain local file, not tracked, so moving primary from desk to ripr is moving one file.

### Architecture

**Layer 1: failure alert (dotfiles)**

- `HOME/.config/systemd/user/service.d/10-onfailure.conf`: `[Unit] OnFailure=notify-failure@%n.service`. A top-level `type.d/` drop-in applies to every user service (`man systemd.unit`, Example 3 is this exact design). systemd 259 on desk and ripr.
- `HOME/.config/systemd/user/notify-failure@.service`: oneshot, `ExecStart=%h/.local/bin/notify-failure %i`.
- Recursion guard: `HOME/.config/systemd/user/notify-failure@.service.d/10-onfailure.conf`, same name as the top-level drop-in. Per the man page, a `type.d/` file "applies to a unit only if there are no drop-ins or masks with that name in directories with higher precedence". Form (empty file vs `/dev/null` link) is settled by Phase 0.
- `HOME/.local/bin/notify-failure`: reads systemd's `MONITOR_SERVICE_RESULT`, `MONITOR_EXIT_CODE`, `MONITOR_EXIT_STATUS` and `MONITOR_INVOCATION_ID` (set for OnFailure units, no race against a later `systemctl show`) and POSTs one ntfy message: host, unit, result, status, and the command to read the log (`journalctl --user -u <unit> -n 20`). No journal lines are sent: the topic is public and services can log secrets. Dedup: a stamp file per unit in `${XDG_STATE_HOME:-$HOME/.local/state}/notify-failure/`; a repeat inside `NOTIFY_FAILURE_WINDOW` seconds (unit `Environment=`, default 3600) is dropped and counted, and the next alert after the window reports the suppressed count. A failed POST is retried 3 times (5s, 30s, 120s backoff); if all fail, no stamp is written, the notifier exits 0 and logs to the journal, and the SessionStart check is the only remaining signal for a unit that fails once and stays failed.
- ntfy send extracted to `HOME/.local/bin/ntfy-send` (topic, title, priority, tags, body), `curl -fsS --max-time 10`, exit non-zero on HTTP error or timeout (swap-watch's current `curl -s ... || true` hides both). `swap-watch.sh`'s `send_alert()` (`:66-69`) is rewired to call it, so the topic lives in one place.
- Add a `script:` entry that enables swap-watch (today enabled by hand; no manifest line).

**Layer 2: SessionStart check (claude)**

- `HOME/.claude/hooks/user-units-check.sh`, modeled on `hooks-preflight.sh`: runs `systemctl --user list-units --type=service --state=failed --no-legend --plain`, emits `hookSpecificOutput.additionalContext` naming each failed unit and its `ExecMainStatus`, silent (no output) when none, never exits non-zero.
- `--type=service` is mandatory: desk shows 27 failed `app-com.google.Chrome-*.scope` units today; without the filter the hook is noise from day one.
- Silent when healthy keeps it at zero tokens, which matters to queued program chunk H (always-on context budget).

**Layer 3: DELETE-REF guard (claude)**

- A new rule in `HOME/.claude/hooks/intent-guard.sh`, not rails. intent-guard's charter is irreversible actions, it is bash with an existing test matrix, and queued chunk I edits rails `index.ts`.
- Matches statement heads `rm`, `rkvr rmrf`, `mv` (every source operand; `mv -t DIR src...` handled), `cargo uninstall <pkg>` (resolved to the package's installed binaries via `~/.cargo/.crates2.json`: `slack-cli` -> `~/.cargo/bin/slack`, which a name-based mapping would miss). Operands after `--` are paths; flags are skipped.
- For each operand: expand `~`/`$HOME`, make absolute. Reference sources:
  - user unit directories under `$HOME` from `systemd-analyze --user unit-paths` (today `~/.config/systemd/user`, `~/.local/share/systemd/user`), scanned recursively following symlinks (dotfiles-owned units are symlinks; GNU `grep -r` would skip them), skipping `*.bak`, `*.orig`, `*~` (`clyde-enrich.service.clyde.bak` exists today); lines `Exec[A-Za-z]*=` (covers ExecStart/Pre/Post, ExecStop*, ExecReload, ExecCondition), `EnvironmentFile=`, `Condition*Path*=`, `Assert*Path*=`; `%h` expanded to `$HOME`
  - `Exec=` and `TryExec=` lines in `~/.local/share/applications/*.desktop` and `~/.config/autostart/*.desktop` (today `claude-code-url-handler.desktop:4` runs `~/.local/bin/claude`)
  - `crontab -l`. "no crontab for" is an empty source; any other read error denies (fail closed), never "no references"
  - symlink targets of `~/bin/*`
- A hit on the operand, or on a path under an operand directory, denies with the referencing file and line. No hit allows.
- Matches both the typed `rm` and the rails-rewritten `rkvr rmrf`, so hook order does not matter.
- Blind spot, accepted: deletes that are not shell statements (a Python `os.remove`, a tool's own cleanup) are not seen. Layers 1-2 are the backstop for those.

**Layer 4: slack-cli**

- `slack doctor` (new `src/command/doctor.rs`; `scheduled.rs` is 1382 lines against the 1500-line bloat gate, `.otto.yml:24`). Pattern: clyde's pure `diagnose(paths)` over injected paths (`clyde/src/doctor.rs:487-488`, `:643-730`) + sb's `Finding { severity, message, fix }` and exit 1 only on Error (`sb/src/cli/checks.rs:10,29`, `doctor.rs:22,52`) + a `Systemd` trait wrapping `systemctl --user show -p` (clyde `bootstrap.rs:137-166`). Checks:
  - timer unit present and enabled (Warn if absent: not every user schedules follow-ups)
  - service `ExecStart` binary exists (Error) and equals the invoked binary (Warn), both sides `canonicalize`d (`current_exe` resolves symlinks, `invoked_path()` may not)
  - last `Result`/`ExecMainStatus`: Error on 203/EXEC or any non-success; the message distinguishes "cannot run" (203, missing binary) from "ran and reported a set needing a human" (exit 1 per `src/cli.rs:560-562`)
  - queued sets past `post_at` with undelivered follow-ups (Error)
  - another `slack` earlier on PATH than the invoked one, including `/usr/bin/slack` (the desktop app) (Warn)
  - Okta token valid or refreshable (Error if neither)
  - non-Linux: systemd checks skipped with one Info line
- `slack scheduled install-timer [--dry-run]` (new `src/command/scheduled/timer.rs`): renders both units with `ExecStart=<invoked_path()> scheduled deliver` (`src/command/watch/suggest.rs:278`), writes atomically, `daemon-reload`, `enable --now`. An existing unit (hand-copied, or a dotfiles symlink) is replaced, and the command prints the old `ExecStart` it replaced. Refuses a path under `target/`. This is stricter than the eratosthenes precedent, which only warns (`src/service.rs:479-486`): a unit pinned to a build dir breaks on the next `cargo clean`. Refuses on non-Linux with a message.
- Queue-time check, placed in `schedule_signed` before the `chat_schedule_message` call (`src/command/write/schedule.rs:122`) and the queue write (`:149`), on `thread_ts.is_none() && !bodies.is_empty()` (the `MODE_QUEUED` case). Because MCP calls `schedule_signed` directly (`src/mcp/helpers.rs:481`), one gate covers both surfaces. Refusal means no parent is scheduled and the queue is unchanged.
  - Predicate, refuse only when nothing can deliver: timer unit absent, timer not enabled, timer not active, or the service's `ExecStart` binary missing or not executable (203 class). A last run that exited 1 because one set needs a human does NOT refuse; doctor reports that.
  - Non-Linux: no systemd, no gate; the write proceeds and prints one line naming `slack scheduled deliver` as the manual deliverer.
  - `MODE_SCHEDULED` (thread root known, Slack posts it) is unaffected. The CLI exits 1 naming `slack scheduled install-timer`; MCP returns the same text as a tool error. Kill switch: `SLACK_SKIP_TIMER_CHECK=1` skips the gate (for a host that deliberately delivers only through agent sessions); the refusal message names it.
- Delete `contrib/systemd/`; README, `plugin/skills/scheduled/SKILL.md:139` point at `install-timer`. `bin/install`'s `~/.local/bin` destination stays (a valid prebuilt-binary target); only the hardcoded unit path goes.

### Data Model

- `$XDG_STATE_HOME/notify-failure/<unit>.stamp`: `<epoch-of-last-alert> <suppressed-count>`, one line.
- slack doctor `Finding { check: &'static str, severity: Severity { Info, Warn, Error }, message: String, fix: Option<String> }`; output yaml on a TTY, json when piped (house TTY-detect rule).

### API Design

- `notify-failure <unit>`; env `NOTIFY_FAILURE_WINDOW` (seconds).
- `ntfy-send --title T --priority P [--tag X]... BODY` (repeated `--tag`, no comma lists; joined into ntfy's `Tags` header inside the script).
- `slack doctor [--format yaml|json]`; exit 0 unless any Error.
- `slack scheduled install-timer [--dry-run]`; exit 1 on non-Linux or a `target/` path.

### Implementation Plan

**H (before Phase 0, no code):** leave desk's broken `slack-deliver` as-is until Phase 0 uses it as a live 203/EXEC fixture, then fix its `ExecStart` to `%h/.cargo/bin/slack`, `daemon-reload`, `reset-failed`. Success: after the next tick, `systemctl --user show slack-deliver.service -p Result -p ExecMainStatus` prints `Result=success` and `ExecMainStatus=0`. Phase 7 replaces it with the installer's unit.

#### Phase 0: Prove the systemd behavior (dotfiles, operator-run spike)
**Model:** sonnet
- Zero repo code, run by the implementing agent with Scott's go-ahead (it changes the live user manager; every step is reversible by deleting the probe files and `daemon-reload`). Install a probe `notify-failure@.service` that only logs, the top-level drop-in, and the guard, by hand in `~/.config/systemd/user/`; `daemon-reload`.
- Measure: (a) `OnFailure` resolves on slack-deliver; (b) one 203/EXEC tick of slack-deliver produces exactly one notifier run; (c) how many OnFailure runs a `Restart=always` crash-looper produces in 60s (no presumed answer: the default `RestartMode=normal` passes through the failed state, `man systemd.service`, so it may fire per crash); size `NOTIFY_FAILURE_WINDOW` against the result; (d) empty guard file vs `/dev/null` link: which yields `OnFailure=` empty on the notifier; (e) count of user services inheriting the drop-in (`systemctl --user show '*' -p Id -p OnFailure` after reload), recorded; (f) a SessionStart probe hook that runs `systemctl --user is-system-running` returns a state word, not a bus error.
- Paste numbers into this doc's Phase 0 results. Remove the probes.
- **Success criteria:** `systemctl --user show slack-deliver.service -p OnFailure` prints `OnFailure=notify-failure@slack-deliver.service.service`; `systemctl --user show notify-failure@x.service -p OnFailure` prints `OnFailure=`; one 203 tick logs exactly one probe run; (c) and (e) numbers and (f) output pasted into the doc.

### Phase 0 results

Run 2026-10-05 on desk (systemd 259 (259.5-0ubuntu3.4)), user manager state `degraded` before and after. Probes were a `notify-failure@.service` whose `ExecStart` appended `unit/result/status/code` from `MONITOR_*` to a scratch log, plus `service.d/10-onfailure.conf` (`OnFailure=notify-failure@%n.service`). All probe units, drop-ins and the scratch log are removed (`systemctl --user list-unit-files | rg -i 'probe|notify-failure'` -> no match, rc 1; `systemctl --user list-units --all 'notify-failure*' 'probe*'` -> 0 lines).

**(a) OnFailure resolves on slack-deliver: PASS.**

```
$ systemctl --user show slack-deliver.service -p OnFailure     # before the drop-in
OnFailure=
$ systemctl --user show slack-deliver.service -p OnFailure     # after daemon-reload
OnFailure=notify-failure@slack-deliver.service.service
```

**(b) One 203/EXEC tick = exactly one notifier run: PASS.** Two consecutive timer ticks, two `203/EXEC` failures, two notifier runs, one per tick:

```
05:59:00 slack-deliver.service: Failed at step EXEC spawning /home/saidler/.local/bin/slack: No such file or directory
05:59:00 slack-deliver.service: Triggering OnFailure= dependencies.
05:59:00 Starting notify-failure@slack-deliver.service.service - PROBE notify failure for slack-deliver.service...
06:00:00 (same four lines)
probe log:
05:59:00.500945765 unit=slack-deliver.service result=exit-code status=203 code=exited
06:00:00.262825125 unit=slack-deliver.service result=exit-code status=203 code=exited
```

`MONITOR_SERVICE_RESULT=exit-code`, `MONITOR_EXIT_STATUS=203`, `MONITOR_EXIT_CODE=exited` are all present in the notifier's environment. Note `$VAR` and `%` in an `ExecStart=` must be written `$$VAR` and `%%` or systemd expands them (empty) before the shell sees them; Phase 1's unit must do the same or run a script file.

**(c) Crash-looper, `Restart=always`, default `RestartMode`: the notifier fires once per crash.**

```
probe-loop.service   (RestartSec default 100ms, ExecStart=/bin/false)
  5 notifier runs between 06:00:21.85 and 06:00:22.78, then the unit sits in failed (NRestarts=5, Result=exit-code).
  The default StartLimitBurst=5/10s ends the loop in under a second.
probe-loop5.service  (RestartSec=5, ExecStart=/bin/false), run 60s (06:01:31 -> 06:02:31)
  12 notifier runs, one per crash, ~5.2s apart; unit still in activating/auto-restart (NRestarts=11) when stopped.
```

Sizing: the notifier's own dedup is what bounds this, not systemd. **Recommended `NOTIFY_FAILURE_WINDOW`: 3600 (keep the doc's default).** It collapses the 12-in-60s loop to one alert plus a suppressed count of 11, and the 100ms loop to one alert. Any `RestartSec` under an hour alerts once per hour per unit. Untested: while a notifier instance is still inside its 5s/30s/120s retry backoff, a repeat `OnFailure=` start for the same instance should be a no-op join on the active job; the probe notifier returned instantly so this was not exercised. Phase 1's test should cover it.

**(d) Guard form: both work; ship the regular-file form (empty or comment-only).** Measured on the notifier and on two visible-effect fixtures (the notifier alone cannot discriminate, see the finding below).

```
no guard at all:
  notify-failure@x.service                        OnFailure=
  (DropInPaths lists service.d/10-onfailure.conf, yet OnFailure is empty)
empty regular file  probe-v.service.d/10-onfailure.conf:
  probe-v.service                                 OnFailure=        (inherited value suppressed)
comment-only file ("# guard: masks service.d/10-onfailure.conf"):
  probe-v.service                                 OnFailure=
/dev/null symlink   probe-u.service.d/10-onfailure.conf -> /dev/null  (probe-u had explicit OnFailure=probe-v.service):
  probe-u.service                                 OnFailure=probe-v.service   (only the explicit one; inherited suppressed)
notify-failure@.service.d/10-onfailure.conf (empty file):
  notify-failure@x.service                        OnFailure=
```

Finding that changes the risk table: **systemd 259 already refuses a self-chaining `OnFailure=` even with no guard.** A unit whose `OnFailure=` expands to an instance of its own template via `%n` or `%i` is dropped silently (no journal warning): `probe-w@a.service` with `OnFailure=probe-w@%n.service` and `probe-z@a.service` with `OnFailure=probe-z@%i.service` both showed only the inherited `notify-failure@...` value, while an explicit `OnFailure=probe-t@other.service` on `probe-t@a.service` was kept. Recursion test with no guard: a notifier that logs then `exit 1`, started as `notify-failure@x.service`, wrote exactly one log line and triggered no second notifier (journal: `Failed to start notify-failure@x.service`, nothing after). The mechanism is observed, not read from source. The guard is therefore belt and braces; keep it because it makes the intent explicit and does not depend on that unspecified behavior. Form chosen: **a regular file** (zero bytes or a one-line comment, both measured). It tracks cleanly in git and `manifest`'s recursive `link` links a plain file, where a `/dev/null` symlink would be linked as a symlink to a symlink.

**(e) Services inheriting the drop-in: 127 of 128.** Queried every non-template service unit file known to the user manager (`systemctl --user list-unit-files --type=service`, 141 entries, minus 13 `@.service` templates and the probes) with `systemctl --user show <names> -p Id -p LoadState -p OnFailure`: 126 `loaded`, 1 `masked`, 1 `error`. 127 carry `OnFailure=notify-failure@<unit>.service`; the one empty is the masked `org.gnome.SettingsDaemon.Smartcard.service` (-> /dev/null). That includes the GNOME/snap/gvfs/xdg desktop services, `app-*@autostart.service`, and template instances (`git-maintenance@daily.service` showed `OnFailure=notify-failure@git-maintenance@daily.service.service`). Plain `show '*'` returned only 59 services (it lists units currently in memory) and under-counts; use the unit-file list. Every one of these can now alert, so launch-day volume is whatever of them fails; today's known failer is `eratosthenes.service`.

**(f) A hook-style `systemctl --user is-system-running` returns a state word, with the right environment:**

```
$ bash -c 'echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unset}"; systemctl --user is-system-running; echo rc=$?'
XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
degraded
rc=1
```

Two things Phase 2 must handle: the exit code is 1 for `degraded` (so the hook cannot treat non-zero as failure; it must read stdout), and a bus failure also exits 1 but prints to stderr with empty stdout. Measured failures for the test fixtures:

```
$ env -i HOME=/home/saidler PATH=/usr/bin:/bin systemctl --user is-system-running     # no XDG_RUNTIME_DIR
Failed to connect to user scope bus via local transport: $DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined (...)
$ (inside the Claude Bash sandbox)
Failed to connect to user scope bus via local transport: No data available
```

Hook rule: empty stdout from `is-system-running` means "cannot ask", stay silent, exit 0.

**H (slack-deliver ExecStart fix): PASS.** `~/.config/systemd/user/slack-deliver.service` was a regular file (not a symlink), done after (a)-(f) used it as the live 203 fixture. `ExecStart` changed to `%h/.cargo/bin/slack scheduled deliver`, `daemon-reload`, `reset-failed`, next tick 06:05:00:

```
$ systemctl --user show slack-deliver.service -p Result -p ExecMainStatus
Result=success
ExecMainStatus=0
06:05:00 slack[3072700]: no follow-ups due
06:05:00 Finished slack-deliver.service - slack: deliver queued follow-ups whose scheduled parent has fired.
```

**Success criteria:**

- `show slack-deliver.service -p OnFailure` prints `OnFailure=notify-failure@slack-deliver.service.service`: PASS (a).
- `show notify-failure@x.service -p OnFailure` prints `OnFailure=`: PASS (d), with the guard and, as found, without it.
- One 203 tick logs exactly one probe run: PASS (b).
- (c), (e), (f) numbers pasted: PASS.

#### Phase 1: Failure alert (dotfiles)
**Model:** sonnet
- `service.d/10-onfailure.conf`, `notify-failure@.service`, the guard drop-in (form from Phase 0), `notify-failure`, `ntfy-send`; rewire `swap-watch.sh`; `script:` entries `notify-failure` (daemon-reload) and `swap-watch` (enable timer).
- Script tests in `bin/` driven by `.otto.yml test`: stamp-window dedup and suppressed-count, with `curl` stubbed on PATH.
- **Success criteria:** `systemd-analyze --user verify ~/.config/systemd/user/notify-failure@.service` exits 0 (drop-in `.conf` files cannot be passed to verify; it rejects them with `Invalid argument`); `systemctl --user show notify-failure@x.service -p OnFailure` prints `OnFailure=`; a forced probe failure sends exactly one POST (stub log), a second inside the window sends none and the stamp count reads 1; a stub returning HTTP 500 three times leaves no stamp.

#### Phase 2: SessionStart check (claude)
**Model:** sonnet
- `user-units-check.sh` + `user-units-check-test.sh` (fixture `systemctl` on PATH), lint-list entry (`.otto.yml:11+`) and manifest link in the same phase (chunk B rule). Settings registration is an operator step (settings.json is write-denied).
- **Success criteria:** no failed services -> empty stdout, exit 0; one failed service -> additionalContext naming it; failed scopes only -> empty stdout. Expect it to fire on desk from day one (eratosthenes.service is failed today); that is the hook working.

#### Phase 3: DELETE-REF guard (claude)
**Model:** opus
- Rule in `intent-guard.sh`, matrix rows in `intent-guard-test.sh`, reference fixtures under `$TMPDIR`.
- **Success criteria:** `rm -v ~/.local/bin/slack` with a fixture unit `ExecStart=%h/.local/bin/slack` -> deny naming the unit file; `cargo uninstall slack-cli` with the same fixture and a `.crates2.json` fixture -> deny; a fixture `.desktop` `Exec=` reference -> deny; a reference only in a `*.bak` -> allow; same with no reference -> allow; `bash ~/repos/scottidler/claude/HOME/.claude/hooks/intent-guard-test.sh` -> 0 failures.

#### Phase 4: `slack doctor` (slack-cli)
**Model:** opus
- Module, trait, checks, fixture tests (fake `Systemd`, temp queue file, temp PATH dirs).
- **Success criteria:** fixture `ExecMainStatus=203` -> Error, exit 1; fixture with a second `slack` earlier on PATH -> Warn, exit 0; healthy fixture -> exit 0.

#### Phase 5: `install-timer` + path cleanup (slack-cli)
**Model:** sonnet
- Command, `--dry-run`, Linux-gated `systemd-analyze --user verify` test on the rendered unit (asserts exit code; stderr carries unrelated noise), delete `contrib/systemd/`, README and SKILL.md rewrites.
- **Success criteria:** rendered unit passes verify (exit 0) in a test that runs under `otto ci`, or, if Phase 5 measures that GitHub runners lack the needed environment, an `#[ignore]`d test plus an explicit `cargo test -- --ignored` step in `.otto.yml` (`.otto.yml:74-76` runs plain `cargo test --all-features` today); `test ! -e contrib/systemd` succeeds; `rg -n 'ExecStart=%h/.local/bin/slack' plugin README.md bin` exits 1 (no matches).

#### Phase 6: Queue-time refusal + release (slack-cli)
**Model:** sonnet
- `MODE_QUEUED` gate in `schedule_signed` (before `:122`), MCP error path, README/plugin lockstep (fleet-plugins rule). PR, `bump release`, merge, `bump finish`, install.
- **Success criteria:** queued write with a missing-binary timer fixture -> exit 1 naming `install-timer`, zero `chat_schedule_message` calls on the fake, queue file unchanged, on both the CLI and the MCP entry; a timer whose last run exited 1 (set needs a human) -> write proceeds; `MODE_SCHEDULED` write with the missing-binary fixture -> succeeds; installed `slack --version` equals the new tag.

#### Phase 7: Ownership cleanup (dotfiles, after Phase 6 is installed)
**Model:** sonnet
- `HOME/bin/primary-host` + a test (marker present and matching -> 0; absent or another host -> 1 with a reason). Write `~/.config/primary-host` on desk.
- Track `firefox-volume-keeper.service` + script. Retire dead `ydotoold.service` (superseded by the packaged user unit `/usr/lib/systemd/user/ydotool.service`, enabled at `manifest.yml:829`) via `rkvr rmrf`.
- `script:` entries calling each installer (spellings verified by the round-1 panel from `--help` and source):
  - portable: `aka daemon --install`, `git maintenance start`
  - host-role, each starting `primary-host || exit 0`: `slack scheduled install-timer`, `clyde bootstrap --install-timer --skip-statusline` (plain `clyde bootstrap` does not install timers, `clyde/src/bootstrap.rs:54`). It is clyde's only installer, and every run also migrates the permit DB, permit/cost config and pricing and repoints the permit hook in `settings.json`/`settings.local.json` (`bootstrap.rs:319-352`); no flag limits it to units. Accepted as clyde's installer behavior; `--skip-statusline` keeps it off the statusline, which the claude repo owns. Observed on desk 2026-10-05: `clyde bootstrap --install-timer --skip-statusline --dry-run` -> `0 step(s) WOULD be performed ... (nothing to migrate: already on clyde or no legacy state found)`, so on desk it is a no-op, `eratosthenes service install`, `sb borg daemon --install`, `sb cortex daemon --install` and `sb borg harvest --install` (these two write only; the entry adds `systemctl --user daemon-reload` and `enable --now`)
- Before running any installer on a host, remove any dotfiles symlink for a tool-owned unit (none exist today; the step makes it explicit).
- On desk: run `slack scheduled install-timer` to replace the hand-copied unit.
- **Success criteria:** `systemd-analyze --user verify $(find ~/.config/systemd/user -maxdepth 1 \( -name '*.service' -o -name '*.timer' \) ! -lname /dev/null)` exits 0 (masked units excluded: see the amendment under Acceptance Criteria); `find ~/.config/systemd/user -maxdepth 1 -type l -lname '*/dotfiles/*' -printf '%f\n' | sort` lists only the dotfiles-owned set: firefox-volume-keeper.service, notify-failure@.service, riki.service, sccache.service, swap-watch.service, swap-watch.timer, sweep-repos-watchdog.service.

## Acceptance Criteria

- [ ] `systemctl --user show slack-deliver.service -p OnFailure` prints `OnFailure=notify-failure@slack-deliver.service.service`.
  - Observed on main (2026-10-05): `OnFailure=`
- [ ] `systemd-analyze --user verify $(find ~/.config/systemd/user -maxdepth 1 \( -name '*.service' -o -name '*.timer' \) ! -lname /dev/null); echo $?` prints `0`.
  - Amended at finalization (2026-10-05): the original glob `~/.config/systemd/user/*.service` also matches `org.gnome.SettingsDaemon.Smartcard.service -> /dev/null`, a GNOME mask dated 15 Apr, and verify always rejects a masked unit (`Unit org.gnome.SettingsDaemon.Smartcard.service is masked.`, rc 1) whatever this doc changes. The original observed-on-main line quoted only the slack-deliver error. Masked units are excluded; nothing this doc owns is a `/dev/null` link.
  - Observed after Phase 7 (2026-10-05): `rc=0` (one unrelated warning from `/usr/lib/systemd/user/spice-vdagent.service:23`)
  - Observed on main: `1`, `slack-deliver.service: Command /home/saidler/.local/bin/slack is not executable: No such file or directory`
- [ ] `rg -c 'DELETE-REF' ~/repos/scottidler/claude/HOME/.claude/hooks/intent-guard.sh` prints a count `>= 1`, and `intent-guard-test.sh` passes with zero failures.
  - Observed on main: no match (exit 1)
- [ ] `slack doctor --help` and `slack scheduled install-timer --help` exit 0.
  - Observed on main (v0.14.7): both exit 2 (unrecognized subcommand)
- [ ] In slack-cli, `rg -n 'ExecStart=%h/.local/bin/slack' plugin README.md bin` exits 1 (no matches) and `test ! -e contrib/systemd` exits 0.
  - Observed on main (2026-10-05): rg exits 0 with 1 match, `plugin/skills/scheduled/SKILL.md:139`; `test ! -e contrib/systemd` exits 1 (the contrib unit with the same hardcoded path still exists)

## Resolved Decisions

- 2026-10-05, Scott: scope is all three repos in one doc (option B).
- 2026-10-05, research: the "~25 hand-written units" premise was wrong; most are installer-written. Ownership rule above replaces "track all units in dotfiles".
- 2026-10-05: delete guard lives in intent-guard, not rails (charter, test matrix, chunk I collision).
- 2026-10-05: queue-time check refuses (fail closed), does not warn. A queued follow-up with no working deliverer never posts; a warning scrolls by. Both panel seats agreed (round 1). Predicate narrowed to "nothing can deliver" so one stuck set does not block every new write.
- 2026-10-05, round 1: installer spellings closed by the staff seat (Phase 7 list). Host-role gating made executable (`primary-host`). DELETE-REF reference set widened (Exec*, Condition/Assert paths, `.desktop`, unit-path dirs, symlink-following).
- 2026-10-05, round 2: A1 withdrawn by the architect, staff accepted every Phase 7 bullet; staff's one cheap-win (clyde bootstrap side effects) folded into Phase 7 with desk's dry-run output. Attribution source: this session's transcript (`c8b92da7`), option A/B definitions and doctor's listed checks.
- 2026-10-05, round 1, pushback to architect A1 (Phase 7 is scope creep): option B, which Scott chose, includes option A's "all 25 user units tracked". The ownership cleanup is that requirement, re-shaped by research. The doctor Okta check and `git maintenance start` come from the same option (doctor's "usual checks", and git-maintenance@ is one of the 25 units).
- 2026-10-05: `install-timer` refuses on non-Linux rather than writing launchd (non-goal above).

## Alternatives Considered

### Alternative 1: Symlink every unit from dotfiles
- **Description:** the original idea: move all ~25 units into `HOME/.config/systemd/user/`.
- **Pros:** one place to read every unit.
- **Cons:** installers rewrite their unit; `write_atomic` untracks the link, `fs::write` writes rendered units into the public repo.
- **Why not chosen:** two owners for one file. Drop-ins give overrides without the fight.

### Alternative 2: Delete guard in rails
- **Description:** extend `rmRewrite` (`index.ts:442`) to check references.
- **Pros:** rails already parses `rm`.
- **Cons:** rails sees only `rm` heads, not `rkvr rmrf`/`mv`/`cargo uninstall`; collides with queued chunk I.
- **Why not chosen:** intent-guard covers every head and has the test matrix.

### Alternative 3: Poll-based monitor instead of OnFailure
- **Description:** a timer that runs `systemctl --user --failed` and alerts.
- **Pros:** catches units that fail before the drop-in loads.
- **Cons:** a second unit to fail silently; latency; reinvents what systemd does natively.
- **Why not chosen:** OnFailure is event-driven and built in; the SessionStart check already covers the "failed before the alert existed" case.

## Technical Considerations

### Dependencies

- Ship order forced: Phase 0 -> Phase 1. Phases 4 -> 5 -> 6 (released, installed) -> Phase 7's slack entry. Phases 1, 2-3, 4-6 are otherwise independent.
- Cross-repo operator steps: settings.json registration (Phase 2), tatari-skills `marketplace.json` pin bump for slack-cli `plugin/` (after Phase 6), a log line in `claude/docs/design/2026-09-13-setup-audit-program.md` recording this out-of-program work (precedent: D2).
- Repos: dotfiles and claude are ungated and PUBLIC; slack-cli is gated (classic protection + workflows): PR flow.
- No new crates expected in slack-cli (std::process, existing eyre/serde/log); confirm per phase with `cargo add` only if needed.

### Performance

- intent-guard already pays ~510ms per Bash call across guards (header `:5-8`); the new rule only reads unit files when a delete head matches.
- `notify-failure` runs only on failure. slack doctor shells out to `systemctl` a handful of times.

### Security

- Public repos: no secrets in any new file. The ntfy topic is already public (parked non-goal).
- `notify-failure` sends only host, unit name, result and exit status, never journal content, so a service that logs a secret cannot leak it through the alert.

### Testing Strategy

- Every success criterion above is a named test or a command. Tests must bite: each phase breaks its check once (remove the guard rule, invert the dedup) and shows the test failing.
- slack-cli: Linux-only tests gated with `#[cfg(target_os = "linux")]` (first platform code in the repo); CI runs tests on ubuntu, macOS only builds.

### Rollout Plan

- desk first. ripr gets Layers 1-2 through its normal manifest link; host-role installer entries are not run there until the migration plan says so.

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Alert flood on launch (eratosthenes still fails several times a day; system user services inherit the drop-in) | High | Med | per-unit dedup window; Phase 0 counts inheriting services; first alerts are triaged, not silenced |
| Notifier recursion (notifier fails, alerts on itself) | Low | High | same-name guard drop-in, verified in Phase 0 |
| DELETE-REF false positive blocks a legitimate cleanup | Med | Low | deny names the referencing file; fix the reference first, which is the point |
| Installer `fs::write` through a leftover dotfiles symlink | Med | Med | Phase 7's explicit link-removal step runs before any installer |
| An unscoped manifest run on ripr starts host-role daemons and double-processes | Med | High | `primary-host || exit 0` gate in every host-role entry; ripr has no marker until the migration moves it |
| `systemd-analyze --user verify` fails on GitHub runners (no user manager) | Med | Low | Phase 5 measures it in CI; fall back to a `#[ignore]`d test run locally by `otto ci` |
| Queue-time refusal blocks a host that delivers only via agent sessions | Low | Low | `SLACK_SKIP_TIMER_CHECK=1`, named in the refusal |

## Open Questions

None. Phase 0's measurements are a phase deliverable with pass criteria, not an open question.

## References

- Incident session: clyde `4038a806` (2026-09-08), transcript line 2181
- `man systemd.unit`: top-level `type.d/` drop-ins, Example 3
- Precedents: `clyde/src/doctor.rs`, `clyde/src/bootstrap.rs`, `second-brain/main/sb/src/cli/checks.rs`, `eratosthenes/src/service.rs`, `claude/HOME/.claude/hooks/hooks-preflight.sh`
- `claude/docs/design/2026-09-13-setup-audit-program.md` (chunks H, I collision notes)
