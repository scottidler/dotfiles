# Design Document: Stop-Time Failure Alerts (cortex stop stall, harvest exit 130, shutdown and restart noise)

**Author:** Scott Idler (drafted with Claude)
**Date:** 2026-10-10
**Status:** In Review
**Review Passes Completed:** 5/5

## Summary

- The `OnFailure=` -> ntfy alerter (`2026-10-05-user-unit-failure-visibility.md`) works. On ripr it sent 6 alerts between 2026-10-09 15:15 and 2026-10-10 14:43 (plus 1 dedup-suppressed). None needed a human. With desk's cortex alerts and one code-read defect, they fall into four classes.
- Two are alerter gaps, both in dotfiles: units killed while the system shuts down, and a unit that fails at login and recovers on its own `Restart=`.
- Two are second-brain defects that the alerter correctly reports: cortex ignores SIGTERM for as long as its current tick runs (SIGKILL after 90s, on desk and ripr), and `sb borg harvest` exits 130 on SIGTERM, which systemd counts as a failure.
- Fix all four in one doc (Scott, 2026-10-10: "for the whole thing"): suppress alerts while the system is stopping, `RestartMode=direct` on the one self-healing unit, stop check points through cortex's tick work plus a configured `TimeoutStopSec`, and `SuccessExitStatus=130` on the harvest unit.

## Problem Statement

### Background

- Every user service on desk and ripr carries `OnFailure=notify-failure@%n.service` through the `service.d/10-onfailure.conf` drop-in. `notify-failure` dedups per unit inside a 3600s window and POSTs to the public `escote-alerts` topic.
- systemd 259 on both hosts. `Linger=yes` for `saidler` on both, so a GNOME logout does not stop the user manager.
- cortex (`sb cortex daemon --start`) and borg are long-running user daemons; `sb-harvest` is a 03:00 oneshot. Their units are rendered by `sb` (`vault::systemd::ServiceUnit`, `vault/src/systemd.rs:100`) and written by `sb ... --install`; dotfiles `manifest.yml:841-846` runs the installers. `sb doctor` diffs installed units against the rendering (`sb/src/cli/checks.rs:207`), so a unit hand edit shows as drift.

### What happened (evidence, ripr journal unless noted)

| Time | Alert | Class | Evidence |
|---|---|---|---|
| 10-09 15:15:44 | `app-com.mitchellh.ghostty.service` status=1, `snap.snapd-desktop-integration...` status=2 | 1: shutdown | logind `The system will power off now!` at 15:15:43 |
| 10-09 17:48:36 | `snap.snapd-desktop-integration...` status=2 | 2: login race | boot at 17:45:08; `Failed to open display`, restarted 2s later and stayed up |
| 10-10 10:30:19 | `org.gnome.Shell@ubuntu.service` `result=timeout status=KILL`, snapd status=2 | 1: shutdown | logind `The system will reboot now!` at 10:30:14 |
| 10-10 10:32:26 | snapd status=2 (suppressed by dedup) | 2: login race | same `Failed to open display`, `Scheduled restart job, restart counter is at 1`, then up |
| 10-10 14:43:45 | `cortex.service` `result=timeout` | 3: cortex stall | `sb` reinstalled 14:42:14, stop 14:42:15, `State 'stop-sigterm' timed out. Killing.` at 14:43:45 |

- desk (journal): cortex `State 'stop-sigterm' timed out` on 2026-10-05 17:34, 18:32 and 2026-10-10 12:03. Class 3 is on both hosts.
- Class 4 (harvest) has not fired yet. It is read from code: `sb borg harvest` is not a long-running daemon (`sb/src/cli.rs:55-63`), so `sb/src/main.rs:26-28` installs `vault::process::install_interrupt_handler`, whose handler `_exit(130)`s (`vault/src/process.rs:178-182`). A stop mid-harvest (a reboot near 03:00) gives `result=exit-code status=130` and an alert.

### Root cause, class 3 (cortex)

- SIGTERM is observed only between `select!` arms. `Shutdown` (`cortex/src/shutdown.rs`) installs one long-lived tokio listener, which replaces the default terminate action. The loop polls it `biased;` first (`cortex/src/daemon.rs:230-235`). Every arm then runs its work inline under `block_in_place` (`daemon.rs:249, 269, 273, 299, 323, 346, 364, 382, 402, 425, 443`), and nothing inside the work looks at the signal.
- Prior art fixed the lost-signal half and named this half as open: `docs/design/2026-10-05-quality-review-fixes-implementation-notes.md:1219` (second-brain): "SIGTERM is still only observed between ticks, so a tick longer than systemd's stop timeout ... would still be SIGKILLed mid-work."
- The embed tick has no tick bound. `daemon_tick_with_model` (`cortex/src/embed.rs:375-407`) loops `process_batch` until `scanned == 0`. `max-chunks-per-tick` (`DEFAULT_MAX_CHUNKS_PER_TICK`, `embed.rs:70-84`) is applied inside each `process_batch` (`embed.rs:802, 912`), so it bounds one batch, not the tick. Its doc comment says it "bounds the tick's WALL CLOCK"; Scott's `cortex.yml` says "Hard ceiling on chunks embedded per tick". Code and both statements disagree.
  - ripr, 13:46:40 -> 13:54:32: one tick, several capped batches, `embedded=1331`.
  - The incident tick: batches began 14:36:51, 14:40:08, 14:43:24. SIGTERM arrived 14:42:15; the batch finished at 14:43:07, and the loop started another batch at 14:43:24 instead of returning to `select!`. SIGKILL at 14:43:45.
- One embed sub-batch is one candle call and cannot be interrupted. Its size is `embed.max-chunks-per-call` (config, default 64, `embed.rs:68`, `cortex/src/config.rs:288`; `cortex.yml` does not set it). Measured over the last 10 days of `inference progress` lines (the `in <n>s` value is cumulative per batch; per-sub-batch time is the difference):
  - ripr: 93 sub-batches, worst 32.0s, worst 0.50 s/chunk.
  - desk: 513 sub-batches, worst 249.9s, worst 3.90 s/chunk.
  - Time is linear in chunk count: desk 2026-10-10, a 64-chunk sub-batch took 149.1s (2.33 s/chunk) and the following 42-chunk one 98.2s (2.34 s/chunk).
  - So on desk a single uninterruptible call can run 2.8x systemd's 90s default, and no check point between calls can fix that alone.
- Other uninterruptible calls inside a tick: Fabric subprocess per note (classify fallback, fact, entities; `fabric_timeout_secs` / `fact_timeout_secs` default 120), intel's LLM HTTP call (`llm_timeout_secs` default 120, `cortex/src/llm.rs:46`), tags classifier HTTP (`distillers/src/tags.rs:205`, 30s; this is what classify calls on both hosts, `cortex.yml` `tags.classifier: classifier-dev`).

### Problem

Alerts that need no human train the phone to ignore the topic, and the one alert class that marks a defect (cortex) fires on every restart of a busy cortex (every `sb` deploy). Every logged class 3 event was a service restart. At reboot, Ubuntu's 5s `user@.service` stop deadline (below) defeats any cortex stop budget today, SIGKILLing a busy cortex with no alert possible; this design raises it.

### Goals

- A user unit that fails while the system manager is stopping (reboot, power off) sends no alert; the suppression is logged to the journal (Scott, 2026-10-10: "is this fixed?" on the screenshot of class 1 and 2 alerts).
- `snap.snapd-desktop-integration.snapd-desktop-integration.service` alerts only when systemd gives up restarting it, not on a failure its own `Restart=` recovers (same ask).
- On a service stop (`systemctl --user stop|restart cortex`, every `sb` deploy) and on an orderly reboot or power off, cortex exits cleanly before both its own stop timeout and the user manager's, from any arm, on desk and ripr, without leaving a half-applied multi-file change (Scott: "targetted fix on cortex?", then "for the whole thing").
- cortex's embed tick honors `max-chunks-per-tick` across the whole tick, as its doc comment and Scott's `cortex.yml` comment state (bug fix; panel round 1 confirmed).
- `sb-harvest` stopped by systemd is not a failure (Scott: "does borg and oracle and harvest need the fix as well?").

### Non-Goals

- **Excluded:** borg and oracle. Verified, not assumed: borg's daemon installs no SIGTERM handler (workspace grep for `SignalKind|ctrl_c(|signal_hook|ctrlc::|sigaction` hits only `cortex/src/shutdown.rs` and `vault/src/process.rs`; teloxide 0.17's `enable_ctrlc_handler` at `dispatcher.rs:585` hooks SIGINT only), so it dies on the default action at once (ripr 14:42:15, same-second stop). oracle has no systemd unit on either host and `sb oracle serve` gets the interrupt handler.
- **Excluded:** making every user unit stop cleanly. gnome-shell's own `TimeoutStopSec=5` (`/usr/lib/systemd/user/org.gnome.Shell@.service:30`) is GNOME's; class 1 suppression covers it, and raising the user@ deadline does not lengthen it.
- **Excluded:** fixing snapd-desktop-integration's display race. Snap-owned, upstream; it self-heals in 2s.
- **Excluded:** suppression during a GNOME logout without reboot. Not in the alerts Scott asked about, and none exists in the journal. With `Linger=yes` the user manager keeps running, so `is-system-running` reports `running`; no logout-only alert exists in the journal.
- **Excluded:** making a candle inference call itself interruptible. `max-chunks-per-call` already bounds it from config.
- **Excluded:** power loss, and SIGKILL outside an orderly stop. No stop budget covers them; per-file `write_atomic` is the floor.

## Proposed Solution

### Overview

| Class | Fix | Repo |
|---|---|---|
| 1 shutdown | `notify-failure` skips when the system manager reports `stopping` | dotfiles |
| 2 login race | drop-in `RestartMode=direct` on the snapd unit | dotfiles |
| 3 cortex | stop handle + check points through tick work; embed tick cap per tick; `TimeoutStopSec` from config | second-brain |
| 3 cortex | `embed.max-chunks-per-call: 16` bounds the one call check points cannot split | dotfiles (`cortex.yml`) |
| 3 cortex | `user@.service` stop deadline raised 5s -> 210s so reboot honors cortex's budget | dotfiles (`manifest.yml` script) |
| 4 harvest | `SuccessExitStatus=130` in the rendered unit | second-brain |

### Architecture

**Class 1: shutdown suppression (`HOME/.local/bin/notify-failure`)**

- After taking the per-unit flock, before reading the stamp: `state="$(timeout 5 systemctl is-system-running 2>/dev/null)"`. If `stopping`, log `notify-failure: <unit>: suppressed (system stopping)` and exit 0. The stamp is not touched, so dedup state survives.
- `timeout 5`: the system bus can be going away mid-shutdown; a hung probe must not hold the per-unit lock. A timeout yields empty output, which alerts.
- System manager, not `--user`: the question is "is the host going down", which PID 1 answers. `is-system-running` without `--user` needs no privilege (ripr, from the user session: `running`). Spike B (Phase 6 reboot) proves it reads `stopping` at the moment an OnFailure handler runs during a reboot.
- Any other value (`running`, `degraded`, `starting`, empty on error) alerts as today. Fail open toward alerting: a broken probe must never silence alerts.
- Accepted cost: a genuine failure in the last seconds before a reboot is not alerted. Class 3 is fixed at the source, and its regression test (Phase 2) guards it, not the alert.

**Class 2: restart-recovered unit (`HOME/.config/systemd/user/snap.snapd-desktop-integration.snapd-desktop-integration.service.d/10-restart-direct.conf`)**

- `[Service]` `RestartMode=direct`. Per `systemd.service(5)` (v254+): during auto-restart the unit "transitions to the activating state directly ... OnSuccess= and OnFailure= are skipped."
- `[Unit]` `StartLimitIntervalSec=60`. The unit ships `Restart=on-failure`, `RestartSec=2s`, `StartLimitBurst=5`, `StartLimitIntervalSec=10s`, `SuccessExitStatus=1` (`systemctl --user show` on ripr; fragment `/etc/systemd/user/...`). With 2s gaps the 6th start lands past 10s and the window resets, so a unit that fails forever never hits the shipped limit, and `direct` would hide it forever. With a 60s window, 5 failed starts in ~10s hit the limit, the unit enters `failed`, and OnFailure must alert once; Phase 0 Spike A proves that with these exact values.
- Per-unit, never fleet-wide: cortex has `Restart=on-failure`, `RestartSec=5`, default start limit 5 in 10s, so a crash loop restarting every 5s never hits the limit. Fleet-wide `direct` would silence exactly the 2026-10-05 incident class.
- dotfiles owns drop-ins for units it does not own (ownership rule, 2026-10-05 doc; precedent `clyde-enrich.service.d/dormant-after.conf`). Deployed to both hosts; desk has the unit too (`LoadState=loaded`).

**Class 3: cortex stops at check points**

- Stop handle (`cortex/src/shutdown.rs`): `Shutdown::listen()` stays the one listener. A new `StopHandle` (an `Arc<AtomicBool>` plus a `tokio::sync::Notify`) is created first thing in the daemon run, before the startup sweep. A spawned task owns `Shutdown`, awaits `recv()`, sets the flag and notifies. The `select!` stop arm awaits the notify. Same shape as `applying` (`daemon.rs:94`, passed into `VaultWatcher::start`); no new crate.
  - The prior doc installed the listener after the startup sweep on purpose: with no check points, the default action killed a startup sweep at once. With check points, a graceful startup stop is strictly better, so the handle goes first.
- Stop write contract. A stop never corrupts; it is not "no writes". For every check point the doc and the tests name three lists:
  - completed writes that survive (earlier notes, earlier batches, sentinels already written);
  - pending writes that are dropped (the stopped batch's embedding rows, the stopped note's classification, entities' in-memory proposals);
  - cleanup writes that are mandatory (relink of moves and renames already made).
  - A stopped step returns a distinct `Stopped` outcome, never counted as `failed`, and never produces a `needs-review` write or a fallback call.
- Check points, every one a read of the flag:
  - embed: top of the `daemon_tick_with_model` batch loop, and between sub-batches in `embed_in_sub_batches` (`embed.rs:1059-1104`). Survives: examined sentinels, which are written before inference (`embed.rs:779-782`) and already exist on today's error path; the next tick re-selects stale notes either way. Dropped: the stopped batch's embedding rows, which persist only after all sub-batches (`embed.rs:1008-1012`).
  - action cycle (`configured_actions_with_scanner`, `daemon.rs:530-841`): between actions.
  - classify (`cortex/src/classify.rs:413-625`): per note, before the classifier call, and before any fallback call (primary -> fallback chain, `classify.rs:146-165`). A stopped loop still runs its post-loop `update_wikilinks_batch` (`:608-612`) for the moves already made. A classifier failure observed after the flag is set is discarded, never turned into `mark_needs_review` (`:483-486`).
  - naming (`cortex/src/naming.rs:177-210`): per note before the rename; a stopped loop still runs the batch relink (`:210`) for renames already made. The `?` early returns on `create_dir_all` / `rename` (`:182, :204`) skip that relink today (pre-existing); the same restructure makes an error mid-loop relink completed renames before returning the error.
  - fact (`cortex/src/memgraph.rs:109-128`): per note. Writes are per note (`insert_edges`); there is no watermark (`take(limit)` over eligible notes, `:109`), so a stopped run is safe but not resumable: the next run re-selects from the start.
  - graph (`cortex/src/graph.rs:216-263`): per note. Incremental runs resume by watermark. A first full build clears edges first, so a stop mid-build leaves a partial graph until the next 900s graph tick rebuilds it.
  - entities (`cortex/src/entities.rs:112`): per note; a stopped pass drops its in-memory proposals and writes nothing. Same all-or-nothing outcome as today's error path; the next scheduled run redoes it.
  - intel (`cortex/src/intel.rs:493-513`): before the Fabric fallback that follows a failed LLM call. Without it the path is LLM 120s + Fabric 120s = 240s with no check point.
  - quality (rayon `par_iter`), sweep, link, duplicates, lint sub-appliers other than naming, state, broken-links, cold, association (`daemon.rs:390`; disabled by default and not enabled in `cortex.yml`): checked around the action only. Each is per-file atomic (`vault::note::write_atomic`, `vault/src/note.rs:112-119`: fsynced temp, rename, parent fsync) or read-only, and short (a full ripr cycle is ~45-50s).
- Subprocess children at stop: the rendered cortex unit sets `KillMode=mixed`. Today it sets none (`daemon.rs:898-921`), so the default `control-group` SIGTERMs every process in the cgroup, Fabric children included (`process_group(0)`, `vault/src/process.rs:64`, does not leave the cgroup). A killed Fabric call returns a failure that classify turns into a `needs-review` write: the corruption the Alternatives section rejects already happens on every stop. With `mixed`, SIGTERM goes to cortex's main process only; an in-flight call finishes (bounded by its timeout), cortex reaches the next check point and exits, and systemd SIGKILLs whatever remains. The discard-after-flag rule above is the second guard.
- Embed tick cap: one allowance of `max-chunks-per-tick` per tick, shared across kinds in their run order (`embed.rs:375`, summary first). Each `process_batch` receives the remaining allowance, not the full cap, so a tick cannot overshoot by a batch. The tick ends when the allowance hits 0 or the backlog is empty. A single note larger than the whole cap is still embedded alone (the deliberate exception at `embed.rs:1011-1016`), so the bound is <= max(cap, largest single note). Summary embeds one text per note (`summary_embed_text`, `embed.rs:625`) and today takes no tick cap at all (only the transcript and claim batches cap, `:802, :912`); it now draws 1 from the allowance per note. The backlog drains across ticks and the other arms interleave between them.
- Bound the uninterruptible embed call: dotfiles `cortex.yml` sets `embed.max-chunks-per-call: 16`. At desk's worst measured 3.90 s/chunk that is ~62s; ripr ~8s. Throughput is unchanged (time is linear in chunks, measured above), and peak inference memory drops 4x (the key exists to bound memory, `embed.rs:60-67`).
- Reboot deadline (dotfiles): a `manifest.yml` script entry writes `/etc/systemd/system/user@.service.d/zz-cortex-stop.conf` with `[Service]` `TimeoutStopSec=210` via `sudo tee`, then `sudo systemctl daemon-reload` (precedent: `manifest.yml:946-951`, the oomd drop-in).
  - Today `user@1000.service` has `TimeoutStopUSec=5s` / `KillMode=mixed` from Ubuntu's `/usr/lib/systemd/system/user@.service.d/timeout.conf` (ripr and desk; ripr journal `10:30:20 Stopping user@1000.service`, `10:30:25 ... State 'stop-sigterm' timed out. Killing.`). Any user service still running 5s into the manager's stop is SIGKILLed, whatever its own `TimeoutStopSec`.
  - The name must sort after `timeout.conf`: drop-ins apply in filename order across directories, and desk's `systemctl show user@1000 -p DropInPaths` lists `10-login-barrier`, `10-oomd-user-service-defaults`, `20-oomd-pressure-limit`, then `timeout.conf` last. A `50-*.conf` would leave the deadline at 5s.
  - 210 = cortex's 180 + 30 for the manager to finish its own stop.
  - Cost: raises the stop ceiling for every user service on the host. It is a ceiling, not a wait: an idle cortex adds nothing, and `reboot.target` / `poweroff.target` allow `JobTimeoutUSec=30min` (desk).
  - Why owned and not parked: a reboot mid-loop leaves damage nothing repairs. naming's renames (`naming.rs:177-206`) and classify's copy+remove moves (`classify.rs:559-560`) relink only after the loop (`naming.rs:209`, `classify.rs:610`); the applied list lives in memory, the next naming run sees valid slugs, and the next classify pass skips classified notes (`classify.rs:736-739`). broken-links reports, never repairs.
- Stop timeout: `daemon.stop-timeout-secs` (default 180) renders `TimeoutStopSec=` in the cortex unit.
  - Why a number at all: check points cannot interrupt an in-flight call. With a check point before every fallback, the longest stretch with no check point is one call: a Fabric or LLM call at its 120s default timeout; an embed call ~62s worst on desk; a classifier call 30s.
  - Fail loudly: `sb cortex daemon --install` refuses when `stop-timeout-secs` < (largest of the six per-call timeouts) + 30, naming both keys. The six, by config path: `fabric.timeout-secs`, `entities.fabric-timeout-secs`, `graph.fact-timeout-secs`, `actions.intel.fabric-timeout-secs`, `actions.intel.llm-timeout-secs`, `tags.classifier.timeout-secs` (`cortex/src/config.rs:85, 188, 389, 711-718`; `distillers/src/tags.rs:194`).
  - The guard validates the config the service loads, `vault::paths::cortex_config()` (the path `desired_systemd_unit` pins, `daemon.rs:934`), not whatever `--config` the install ran with.
  - A timeout raised later followed by a plain `restart` skips the install guard, so `sb doctor` runs the same check and reports it as an Error naming both keys.
  - `sb doctor` also reports an Error when the effective `user@<uid>.service` `TimeoutStopUSec` is below `stop-timeout-secs` + 30, or cannot be read. That ties the hardcoded 210 in the manifest to the config value: raising one without the other is caught.
  - The embed call has no timeout key to check, so it stays a measured bound (above), re-proved by Acceptance 1 on desk.

**Class 4: harvest**

- `borg/src/harvest/timer.rs` `render_units` adds `SuccessExitStatus=130` to the `ServiceUnit` it builds (`:66`). The interrupt handler's 130 means "stopped by SIGINT/SIGTERM"; under systemd only a stop delivers that.
- Narrow on purpose: changing `on_interrupt` to re-raise SIGTERM (exit 143 by signal) would change every interactive `sb` command and the `vault/tests/interrupt.rs` contract. See Alternatives.

### Data Model

- `vault::systemd::ServiceUnit` gains three optional fields, each omitted from the rendering when unset: `timeout_stop_sec: Option<u64>` -> `TimeoutStopSec=<n>`, `kill_mode: Option<KillMode>` -> `KillMode=<mixed|...>`, `success_exit_status: Vec<i32>` (omitted when empty) -> `SuccessExitStatus=<space-joined>`. borg's unit (`borg/src/service.rs:249`) leaves both unset, so its rendering is byte-identical.
- `cortex` daemon config gains `stop-timeout-secs: u64` (default 180).

### API Design

- `cortex::shutdown::StopHandle`: `fn is_stopped(&self) -> bool`, `async fn stopped(&self)`, `Clone`. Passed by reference into the tick functions that take check points.
- `StopHandle::never()`: a handle no signal sets. Every non-daemon caller of a function that gains a `&StopHandle` parameter (one-shot `sb cortex ...` commands, tests) passes it, so CLI behavior is unchanged; their Ctrl-C keeps going through `install_interrupt_handler`.
- `Stopped` outcome per stage (embed batch, action, classify loop); exact enum shape left to the implementer, constrained by: never counted as failed, never writes.

### Implementation Plan

Ship order: Phase 0 first; Phase 1 (dotfiles) is independent of Phases 2-6 (second-brain). Then release `sb` and run the installers (operator steps below).

#### Phase 0: Prove RestartMode=direct still alerts at the start limit (zero code)
**Model:** sonnet
- Spike A, ripr, no reboot: a throwaway user unit with the snapd unit's exact timing plus the drop-in: `ExecStart=sh -c 'exit 2'` (exit 1 is success for the snapd unit, so the spike must fail with another status), `SuccessExitStatus=1`, `Restart=on-failure`, `RestartSec=2s`, `StartLimitBurst=5`, `StartLimitIntervalSec=60`, `RestartMode=direct`, `OnFailure=` a throwaway recorder unit, plus a same-named `10-onfailure.conf` guard drop-in so the fleet drop-in cannot POST to ntfy. Count recorder activations. Second run with the shipped `StartLimitIntervalSec=10` to record the silent-forever case the override exists for (stop it by hand after 60s).
- Spike B (the `is-system-running` proof) runs in Phase 6's single reboot, not here, so Scott reboots once. Shipping Phase 1's check before that proof is safe: it is fail-open, so if the value is never `stopping` it suppresses nothing and alerts exactly as today.
- Remove every spike unit after.
- If Spike A shows 0 activations at the start limit, the snapd drop-in is cut from Phase 1 and the class 2 fix goes back to Scott; it never ships a drop-in that silences a unit outright.- **Success criteria:**
  - Spike A, 60s window: recorder activated exactly 1 time, after the 5th failed start, 0 times before it.
  - Spike A, 10s window: recorder activated 0 times in 60s (documents why the override is required).

#### Phase 1: dotfiles alerter changes
**Model:** sonnet
- `notify-failure`: the `is-system-running` check above.
- `bin/notify-failure-test.sh`: `newcase` adds a `systemctl` stub on the case PATH (mode file, default `running`); new cases:
  - `stopping`: stub prints `stopping` and exits 1 (the command's behavior in that state): no POST, stamp unchanged, journal line.
  - `probe error`: stub exits 1 with no output: alert sent.
  - `probe hang`: stub sleeps past the 5s timeout: alert sent, script returns within ~6s.
- The snapd `RestartMode=direct` drop-in. No manifest change: `link:` is `recursive: True` over `HOME` (`manifest.yml:4-6`), and the existing `notify-failure` script entry runs `daemon-reload`.
- `HOME/.config/sb/cortex.yml`: `embed.max-chunks-per-call: 16`, with a comment citing the desk measurement. Takes effect on the next cortex restart; independent of the second-brain phases.
- `manifest.yml` script entry for `zz-cortex-stop.conf` (above), with a comment citing the DropInPaths order.
- **Success criteria:**
  - `bash bin/notify-failure-test.sh` passes, with the new cases included.
  - The `stopping` case fails against a copy of `notify-failure` with the check removed (`NOTIFY_FAILURE=` override).
  - `systemctl --user show snap.snapd-desktop-integration.snapd-desktop-integration.service -p RestartMode` prints `RestartMode=direct` on ripr after `daemon-reload` (observed on main: `RestartMode=normal`).
  - After a cortex restart, desk `cortex.log` `inference progress` lines show sub-batches of <= 16 chunks.
  - `systemctl show user@1000.service -p TimeoutStopUSec` prints `TimeoutStopUSec=3min 30s` on desk and ripr.

#### Phase 2: Stop handle and listener task
**Model:** opus
- `StopHandle` in `shutdown.rs`, created before the startup sweep; the `select!` stop arm awaits it.
- `cortex/tests/shutdown.rs`: new case where the child's work is a 30s `block_in_place` loop polling the flag every 100ms. The existing cases stay.
- **Success criteria:**
  - `cargo test --test shutdown` (in `cortex/`) prints `ok` for the new case under SIGTERM and SIGINT, each exiting 0 within 2s of the signal.
  - With the flag never set (break the listener task), the new case fails.

#### Phase 3: Embed check points and per-tick cap
**Model:** opus
- Check points at the batch loop and between sub-batches; `Stopped` outcome; cumulative `max-chunks-per-tick`. Fix the `embed.rs:70-84` doc comment only if the code still disagrees with it.
- Tests use a counting test `EmbeddingModel` (trait `vault/src/embedding.rs:78`, `MockEmbedder` `:310`) on `SearchIndex::open_memory()` (precedent `cortex/src/embed/tests.rs:389-440`).
- **Success criteria:**
  - Flag set after sub-batch 1 of 3: exactly 1 `embed_batch` call, 0 embedding rows written (sentinels may exist, per the contract).
  - Flag preset: the tick returns before any `process_batch` call.
  - With cap 512, notes of <= 512 chunks each and a 1300-chunk backlog across kinds, one tick embeds <= 512 chunks; a single 600-chunk note is embedded alone in its tick.

#### Phase 4: Action-cycle check points
**Model:** opus
- Between actions; classify and naming per note with relink-on-stop; fact, graph, entities per note.
- **Success criteria:**
  - Classify with the flag set after note 1 of 3: notes 2 and 3 are untouched, note 1 is classified and moved, referrers of note 1 are relinked, and the fixture vault has 0 broken wikilinks.
  - Naming, same shape; plus a `rename` forced to fail on note 2 still relinks note 1's rename before returning the error.
  - A classifier failure returned after the flag is set produces no `needs-review` write and no fallback call.
  - intel: LLM stub fails after the flag is set; the Fabric stub is never called.
  - No action after the stop point runs (test-double scanner records calls).

#### Phase 5: Unit rendering: TimeoutStopSec and SuccessExitStatus
**Model:** sonnet
- `ServiceUnit` fields; cortex renders `TimeoutStopSec` from `stop-timeout-secs` and `KillMode=mixed`; the install guard and the matching `sb doctor` check; harvest renders `SuccessExitStatus=130`; the annotated example config gains `stop-timeout-secs`.
- **Success criteria:**
  - Rendering tests: cortex unit contains `TimeoutStopSec=180` and `KillMode=mixed` by default; harvest unit contains `SuccessExitStatus=130`; borg unit unchanged byte for byte.
  - `sb cortex daemon --install` with `stop-timeout-secs: 100` and default 120s timeouts exits non-zero naming `stop-timeout-secs` and `fabric.timeout-secs`; `sb doctor` on the same config reports an Error naming both.
  - Unit test: the doctor user@ check reports an Error for an injected `TimeoutStopUSec` of 5s, and for an unreadable value; passes at 210s with `stop-timeout-secs: 180`.

#### Phase 6: Live proof
**Model:** sonnet
- After release and installers (operator steps), on ripr and desk: restart cortex while an embed tick is mid-batch (watch `cortex.log` for `inference progress`).
- One reboot of ripr by Scott, set up beforehand:
  - Spike B: a throwaway unit whose `ExecStart` ignores SIGTERM (`sh -c 'trap "" TERM; sleep infinity'`, `TimeoutStopSec=2`) with `OnFailure=` a recorder that writes the stdout of `systemctl is-system-running` to a file first thing. Guarded from the fleet drop-in by a same-named `10-onfailure.conf`.
  - cortex mid-call with a rename or move waiting on its relink: a fixture note set in the vault that classify or naming will move, and a stub-slow classifier or Fabric (test config) so the reboot lands mid-call.
  - Remove the spike unit and fixture after.
- **Success criteria:**
  - Spike B: the recorded stdout is `stopping` (the command exits non-zero in that state; stdout is what counts). If not, the class 1 check is inert; revise the doc before claiming class 1 fixed.
  - Reboot: the previous boot's journal (`journalctl --user -b -1 -u cortex.service`) has `received shutdown signal` and no `stop-sigterm timed out`, and every link to the moved fixture notes resolves (`sb cortex` broken-links reports 0 for them).
  - Acceptance Criteria 1 and 2.

#### Operator steps (not phases)
- Release `sb` per the repo's release path (`bump --gates` decides shipit vs release-driver).
- On desk and ripr: `sb cortex daemon --install`, `sb borg harvest --install`, `systemctl --user daemon-reload`, `systemctl --user restart cortex.service`. (manifest entries `sb-cortex-daemon` etc. run these; `primary-host` gates them.)
- `manifest` apply of dotfiles on both hosts for Phase 1, then `systemctl --user restart cortex.service` so `max-chunks-per-call: 16` loads (the manifest's `enable --now`, `manifest.yml:846`, does not restart a running cortex).

#### Rollback
- Phase 1: `git revert <phase-1 commit>` (drop-in, `notify-failure`, `cortex.yml`, manifest entry), then `manifest` apply, `sudo rm /etc/systemd/system/user@.service.d/zz-cortex-stop.conf`, `sudo systemctl daemon-reload`, `systemctl --user daemon-reload`, `systemctl --user restart cortex.service`.
- second-brain: reinstall the previous `sb` release, rerun `sb cortex daemon --install` and `sb borg harvest --install`, `daemon-reload`, restart cortex.

## Acceptance Criteria

- [ ] On desk and ripr, for the 7 days after the rollout restart: `journalctl --user -u cortex.service --since <rollout> | grep -c "stop-sigterm"` prints `0`, and `journalctl --user -u cortex.service --since <rollout> | grep -c "received shutdown signal"` prints >= 1 (at least one stop was exercised). Phase 6 also forces one stop mid-embed on desk (a restart while `cortex.log` shows `inference progress` within the last 30s) and records it.
  - Observed on main: ripr 2026-10-10 14:43:45 `cortex.service: State 'stop-sigterm' timed out. Killing.`; desk the same line on 2026-10-05 (17:34, 18:32) and 2026-10-10 12:03.
- [ ] `systemctl --user show cortex.service -p TimeoutStopUSec -p KillMode` prints `TimeoutStopUSec=3min` and `KillMode=mixed` on desk and ripr.
  - Observed on main: `TimeoutStopUSec=1min 30s`, `KillMode=control-group` on ripr and desk.
- [ ] `systemctl show user@1000.service -p TimeoutStopUSec` prints `TimeoutStopUSec=3min 30s` on desk and ripr.
  - Observed on main: `TimeoutStopUSec=5s` on ripr and desk.
- [ ] `grep -c '^SuccessExitStatus=130$' ~/.config/systemd/user/sb-harvest.service` prints `1` on desk and ripr.
  - Observed on main: `0` on ripr, `0` on desk.
- [ ] `bash bin/notify-failure-test.sh` in dotfiles reports 0 failed and includes a `stopping` case.
  - Observed on main: `17 passed, 0 failed`, no `stopping` case.
- [ ] `cargo test --test shutdown` in second-brain `cortex/` passes and includes the 30s-work case.
  - Observed on main: `shutdown harness: SIGTERM ok`, `shutdown harness: SIGINT ok` (existing cases only).

## Resolved Decisions

- 2026-10-10: one doc for all four classes (Scott: "for the whole thing").
- 2026-10-10: borg and oracle excluded on code evidence (see Non-Goals).
- 2026-10-10, panel round 1 (Architect + Staff Engineer; synthesis `/tmp/review-panel/tewNb5NE/synthesis.md`), all folded in, no pushbacks:
  - reboot gives the user manager 5s (must-fix 1); first folded as "scope to service stops, park reboot", superseded by round 2 below
  - snapd drop-in adds `StartLimitIntervalSec=60`; Spike A uses the unit's exact timing (must-fix 2)
  - check point before every fallback call; guard bounds one call, six keys by path; doctor runs the guard (must-fix 3, cheap wins)
  - stop write contract as survive / drop / mandatory-cleanup lists; fact has no watermark; naming `?` early returns relink first (must-fix 4)
  - `KillMode=mixed` plus discard-after-flag (must-fix 5)
  - tick-wide embed allowance shared across kinds, oversized-note exception kept; association named; probe-hang and stopping-with-exit-1 test cases; restart and rollback steps (cheap wins)
  - Q1 (per-tick cap) closed below.
- 2026-10-10, panel round 2 (both seats independently): own the user@ deadline, do not park. Parking broke the no-deferral-without-say-so rule (Scott's scope: "for the whole thing"), and reboot-time damage self-repairs nowhere (naming and classify relink only after the loop). Folded: `zz-cortex-stop.conf` at 210s (name sorts after vendor `timeout.conf`), doctor check of user@ vs `stop-timeout-secs`, user@ acceptance criterion, reboot test merged with Spike B into one reboot in Phase 6, gnome-shell's own stop timeout corrected to 5s, rollback.
- 2026-10-10, per-tick cap: both seats confirm the per-tick cap is a bug against the `embed.rs:70-84` doc comment and Scott's `cortex.yml` comment ("Hard ceiling on chunks embedded per tick"), and that it belongs here. In scope as a bug fix (Phase 3).

## Alternatives Considered

### Raise TimeoutStopSec only
- **Description:** set cortex `TimeoutStopSec` high, no check points.
- **Pros:** one line.
- **Cons:** the embed tick is unbounded across batches (1300+ chunks, minutes on ripr, far longer on desk); no finite number is safe. Hides the stall.
- **Why not chosen:** does not fix the defect; kept only as the floor for uninterruptible calls.

### spawn_blocking and abandon the work on stop
- **Description:** run tick work off-thread and exit without waiting.
- **Pros:** instant stop.
- **Cons:** process exit kills rayon/candle threads mid-step: SIGKILL by another name. Leaves classify/naming half-applied.
- **Why not chosen:** no safer than today.

### Kill in-flight Fabric groups on stop (`vault::process::kill_registered`)
- **Description:** cut a 120s Fabric call short at SIGTERM.
- **Pros:** lower stop latency for LLM-bound passes.
- **Cons:** a killed Fabric call returns a failure that classify turns into a `needs-review` write (`classify.rs:483-486`); every caller would need to discard results after a stop. intel's HTTP LLM call cannot be cut this way anyway, so `TimeoutStopSec` must cover 120s regardless.
- **Why not chosen:** saves latency the stop timeout already covers. Note this kill is what today's default `KillMode=control-group` already does on every stop; the doc removes it with `KillMode=mixed` rather than adopting it.

### Fleet-wide RestartMode=direct
- **Description:** put `RestartMode=direct` in `service.d/`.
- **Why not chosen:** silences crash loops that never hit the start limit (cortex, `RestartSec=5` vs 5-in-10s). That is the 2026-10-05 silent-outage class.

### Re-raise SIGTERM in `on_interrupt` (exit by signal, 143)
- **Description:** fix harvest by making every `sb` command die by SIGTERM instead of exiting 130.
- **Pros:** systemd treats death-by-SIGTERM as clean with no unit change; 143 is the shell convention.
- **Cons:** changes every interactive command's exit code and the `vault/tests/interrupt.rs` contract, for one unit.
- **Why not chosen:** wider blast radius than the problem.

### Reboot deadline: rejected ways to avoid owning user@'s 5s
- **Smaller user@ deadline** (covering check-point latency, not a full call): a reboot during a call of up to 120s still SIGKILLs mid-loop. Shrinks the window, does not close it.
- **Unit ordering** (stop cortex before other user units): ordering does not extend the manager's own 5s.
- **Relink after each move/rename** instead of after the loop: hardens the code, but a SIGKILL between the move and its relink still breaks links. Shrinks the window; not needed once the deadline covers the budget.
- **Intent log replayed at start**: closes the window even for SIGKILL and power loss, but costs a journal format, replay, and its tests, against one drop-in file. Revisit if power-loss damage is ever observed.

### Suppress on `systemctl --user is-system-running`
- **Why not chosen:** with `Linger=yes` the user manager does not track system shutdown state first; the system manager is the authoritative "rebooting" signal. Spike B (Phase 6) proves the system manager value.

## Technical Considerations

### Dependencies
- systemd >= 254 for `RestartMode=` (259 on both hosts).
- No new crates.

### Performance
- Embed: the per-tick cap makes ticks shorter; total throughput unchanged (same batches, spread across ticks).
- Check points are atomic loads.

### Security
- No new data on the public ntfy topic. The suppression line goes to the journal only.

### Testing Strategy
- dotfiles: fixture matrix with a `systemctl` stub; a mutated copy proves the `stopping` case bites.
- second-brain: the `harness = false` shutdown test (process-level, signals sent with `kill`, not simulated) for the handle; unit tests with a counting embedder and a test-double scanner for check points; rendering tests for units. Each new test is shown to fail against a broken implementation before its phase commits.
- Live: Acceptance Criteria 1-3 on both hosts.

### Rollout Plan
- Phase 1 deploys with dotfiles `manifest` apply plus one cortex restart (operator steps).
- second-brain ships as one `sb` release after Phases 2-5; Phase 6 runs after the installers.

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| A stopped classify or naming loop skips its relink, leaving broken wikilinks | Med | High | relink-on-stop is a Phase 4 criterion with a fixture-vault test |
| A stop path writes `needs-review` or a sentinel | Med | Med | `Stopped` is a distinct outcome; Phase 3/4 tests assert 0 writes |
| desk embed slows past 11 s/chunk (16 x 11 = 176s, near 180s); worst seen 3.90 | Low | Med | lower `max-chunks-per-call` further (config only); Acceptance 1 on desk re-proves it |
| Shutdown suppression hides a genuine last-second failure | Low | Low | accepted; class 3 guarded by tests, not alerts |
| `RestartMode=direct` also skips OnFailure at the start limit | Low | Med | Phase 0 Spike A proves it before Phase 1 ships; cut path defined in Phase 0 |
| A single non-embed action runs longer than 180s on desk (desk cycle time not measured; ripr full cycle ~45-50s) | Low | Med | Acceptance 1's 7-day window on desk; per-note check points in classify, naming, fact, graph, entities cover the loops that scale with the vault |
| SIGTERM from outside systemd: cortex exits 0 and `Restart=on-failure` does not restart it | Low | Med | unchanged from today (cortex already exits 0 between ticks); not widened by this doc |

## Open Questions

None.

## References

- `docs/design/2026-10-05-user-unit-failure-visibility.md` (dotfiles): the alerter.
- second-brain `docs/design/2026-10-05-quality-review-fixes-implementation-notes.md:1186-1219`: the lost-signal fix and the named open half.
- `systemd.service(5)` `RestartMode=`; `systemd.unit(5)` `OnFailure=`.
