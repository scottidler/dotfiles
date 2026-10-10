# Implementation Notes: Stop-Time Failure Alerts

## Phase 0: Prove RestartMode=direct still alerts at the start limit
### Design decisions
- Spike units were written into the live `~/.config/systemd/user/` (the only place the user manager loads from) and removed afterwards; nothing under the repo changed except this file. Recorder is a templated oneshot `spikea-recorder@.service` appending a timestamp to a scratch file; the unit's own start is logged the same way, so starts and activations are counted from files, not inferred from the journal.
- Guard: `spikea.service.d/10-onfailure.conf` (same name as the fleet `service.d/10-onfailure.conf`) contains `OnFailure=` (reset) then `OnFailure=spikea-recorder@%n.service`. Verified BEFORE starting: `systemctl --user show spikea.service -p OnFailure -p DropInPaths` printed `OnFailure=spikea-recorder@spikea.service.service` and `DropInPaths=` listing only the guard drop-in. The fleet drop-in never applied, so nothing could reach ntfy.
- Unit: `ExecStart=/bin/sh -c '... exit 2'`, `SuccessExitStatus=1`, `Restart=on-failure`, `RestartSec=2s`, `RestartMode=direct`, `StartLimitBurst=5`, `StartLimitIntervalSec=60` (run 1) / `10` (run 2). `systemctl show` confirmed `RestartMode=direct`, the interval, and burst before each run.

### Observed results (ripr, systemd 259, 2026-10-10)
- Run 1, `StartLimitIntervalSec=60`: 5 starts (15:50:09.65, :11.85, :14.10, :16.35, :18.60). Recorder activations: 0 through the 5th failed start's exit, then exactly 1 at 15:50:20.85, when the 6th restart was refused: journal `Scheduled restart job, restart counter is at 5` -> `Start request repeated too quickly` -> `Failed to start` -> `Triggering OnFailure= dependencies`. Unit ended `ActiveState=failed Result=exit-code`. Total recorder activations: **1**. The journal showed no OnFailure activation during the four direct restarts.
- Run 2, `StartLimitIntervalSec=10` (shipped value): unit started, stopped by hand after 60s (28 starts at ~2.25s cadence, 1791672641 to 1791672701 epoch). Recorder activations: **0** (no rec log, no `spikea-recorder` journal lines). Unit never reached `failed`; it would restart silently forever.
- Success criteria: run 1 PASS (exactly 1, after the 5th failed start, 0 before); run 2 PASS (0 in 60s). The snapd drop-in stays in Phase 1, with `StartLimitIntervalSec=60`.

### Commands used
- `systemctl --user daemon-reload`, then `systemctl --user show spikea.service -p OnFailure -p RestartMode -p StartLimitIntervalUSec -p StartLimitBurst -p SuccessExitStatus -p DropInPaths` (guard check, before start).
- `systemctl --user start spikea.service`; counted `starts.log` / `rec.log`; `journalctl --user -u spikea.service -o short-precise`.
- Run 2: `systemctl --user stop spikea.service; systemctl --user reset-failed spikea.service`, `sed -i s/StartLimitIntervalSec=60/StartLimitIntervalSec=10/`, `daemon-reload`, start, wait for 28 starts (~60s), `systemctl --user stop spikea.service`.
- Cleanup: removed `spikea.service`, `spikea.service.d/`, `spikea-recorder@.service` (archived by the rm hook under `/var/tmp/rmrf/`), `daemon-reload`; `systemctl --user cat spikea.service` reports no files; no `spike*` entries in the unit dir.

### Deviations
- Recorder is a template unit (`spikea-recorder@.service`) rather than a plain unit, so `%i` identifies the failed unit; same effect.
- The 5th-failure timing: the recorder fires ~2.25s after the 5th start, when the 6th restart is refused, not at the instant of the 5th failure's exit. Consistent with the doc's "after the 5th failed start".

### Tradeoffs
- Counting via files written by the units vs. journal grep: files are unambiguous; the journal was used only as corroboration.

### Open questions
- None.

## Phase 1: dotfiles alerter changes
### Design decisions
- `is-system-running` probe sits after the flock and before the stamp read, `timeout 5`, only `stopping` suppresses — `HOME/.local/bin/notify-failure` — suppression returns before any stamp write, so dedup state survives; empty/other values fall through and alert (fail open).
- Test stub `systemctl` is driven by a per-case `sysmode` file (running | stopping | error | hang), created in `newcase` so every existing case sees `running` — `bin/notify-failure-test.sh`.
- snapd drop-in carries both `RestartMode=direct` and `[Unit] StartLimitIntervalSec=60`, as Spike A proved — `HOME/.config/systemd/user/snap.snapd-desktop-integration.snapd-desktop-integration.service.d/10-restart-direct.conf`.
- `cortex.yml` `embed.max-chunks-per-call: 16` placed under `embed:` beside `max-chunks-per-tick`.
- Manifest script entry named `user-manager-stop-timeout`, inserted before `passwordless-sudo` — `manifest.yml`; follows the oomd precedent (`sudo mkdir -p`, `sudo tee`, `sudo systemctl daemon-reload`).

### Mutation proof (stopping case bites)
Copy of `notify-failure` with the `system_state` block removed, run as `NOTIFY_FAILURE=<copy> bash bin/notify-failure-test.sh`:
```
PASS: stopping: exit 0
FAIL: stopping: no further POST (want '1', got '2')
FAIL: stopping: stamp unchanged (want '1000 0', got '9000 0')
FAIL: stopping: journal line (want '1', got '0')
22 passed, 3 failed
```
Real script: `25 passed, 0 failed`.

### Live deploy on ripr (no sudo)
- Linked the drop-in into `~/.config/systemd/user/snap.snapd-desktop-integration.snapd-desktop-integration.service.d/` as a file symlink into the repo (the parent `~/.config/systemd/user` is a real directory with per-file links, so the recursive link would do the same), then `systemctl --user daemon-reload`.
- `systemctl --user show snap.snapd-desktop-integration.snapd-desktop-integration.service -p RestartMode -p StartLimitIntervalUSec` -> `RestartMode=direct`, `StartLimitIntervalUSec=1min`.
- NOT done (operator): manifest apply, `sudo` user@ drop-in, cortex restart.

### Deviations
- Existing test cases needed no change; `stopping` case first sends one alert (stamp `1000 0`) so "stamp unchanged" and "no further POST" are meaningful rather than trivially empty — same intent as the spec.
- Manifest script entry also does `sudo mkdir -p` of the drop-in dir (the doc only lists tee and daemon-reload); the dir exists on both hosts via oomd, but the entry should not depend on that.

### Tradeoffs
- Header comment in `notify-failure` documents the new skip in the Env block vs a separate section — kept short, the inline comment carries the why.

### Open questions
- UNVERIFIED pending operator: `systemctl show user@1000.service -p TimeoutStopUSec` = `3min 30s` on desk and ripr (needs manifest apply with sudo, then daemon-reload; note a running user@ may need a re-login/reboot to show new value if read from the live unit).
- UNVERIFIED pending operator: desk `cortex.log` `inference progress` sub-batches <= 16 after `systemctl --user restart cortex.service`.

## Phase 2: Stop handle and listener task
Repo: second-brain. Baseline chore `c7462f8`, Phase 2 `139b894`.

### Baseline fix (before Phase 2)
- `otto ci` was red on second-brain main (939470e) under rustc/clippy 1.99.0, and already red at the 14:38 otto run on the previous commit. There were 3 `clippy::double_must_use` errors in distillers and 3 `semicolon_in_expressions_from_macros` errors in oracle, plus 41 warnings from that same lint.
- Both came from macros in dependencies, so the fix is a precise lockfile bump in its own commit `c7462f8 chore(lint): fix clippy errors under rustc 1.99`. No code edits, no `#[allow]`, no toolchain pin.
  - async-trait 0.1.89 -> 0.1.92. 0.1.89's `expand.rs:69` pushes `#[must_use]` onto every async trait method, whose expansion already returns a must_use type. 0.1.91 still does; 0.1.92 does not. It pulls in syn 3.0.6 as a proc-macro build dep.
  - eyre 0.6.12 -> 0.6.14. 0.6.12's `bail!` expands to `return Err(..);` with a trailing semicolon; 0.6.14 drops it.
- Afterwards both lints are at 0 and otto ci is green (3080 passed).

### Design decisions
- `StopHandle` (`cortex/src/shutdown.rs`) is `Arc<StopState { stopped: AtomicBool, notify: Notify }>`, derives `Clone`. `is_stopped` is one Acquire load. `stopped()` enables its `Notified` before it reads the flag, so a stop that lands between the read and the await still wakes it. The stop path is store(Release), then `notify_waiters`, and the flag never clears. That makes `stopped()` cancel-safe in a looping `select!`.
- `StopHandle::listen()` is the constructor that spawns the listener task: it builds `Shutdown::listen()`, moves it into `tokio::spawn`, awaits `recv()`, logs `stop signal received; stopping at the next check point`, and sets the flag. The name mirrors `Shutdown::listen()`: both install the signal listeners and need a runtime. `StopHandle::never()` is `Default`, a handle with no task.
- `cortex/src/daemon.rs:start_watching`: the handle is the first statement, before `validate_canonical_assets`, the model load and the startup sweep. The post-sweep `Shutdown::listen()` is removed, and the `biased;` stop arm awaits `stop.stopped()`, still logging `received shutdown signal; shutting down daemon` (Acceptance 1 greps this).
- `Shutdown` stays `pub` and unchanged. The existing harness cases still drive it directly, and they stay as they were.
- Harness (`cortex/tests/shutdown.rs`): new `--work-child` mode, with the daemon loop shape around a `StopHandle` and a tick arm that runs 30s of `block_in_place` work polling `is_stopped()` every 100ms. The spawn/signal/wait code is factored into `signal_child_during_work(name, signal, mode, deadline, lost)` and shared with the existing case, whose deadline is unchanged.
- Unit tests in `cortex/src/shutdown/tests.rs` (sibling file, per `source-lint`): `never` is not stopped, `never().stopped()` does not resolve in 50ms, a stop is seen by clones, and a stop wakes a waiter registered before it.
- `cortex/AGENTS.md` module map line for `shutdown.rs` names `StopHandle`.

### Evidence
- `otto ci` green on 139b894 (3084 passed, 0 failed). The harness output inside it:
```
shutdown harness: SIGTERM ok
shutdown harness: SIGINT ok
shutdown harness: SIGTERM during 30s work ok (exited 120.377895ms after the signal)
shutdown harness: SIGINT during 30s work ok (exited 120.387178ms after the signal)
```
- Mutation: in `StopHandle::listen` the listener task's `setter.stop()` was replaced with `if std::hint::black_box(false) { setter.stop(); }`, so the flag is never set (written that way so `stop()` stays used under `deny(dead_code)`). `cargo test --features vault/vec --test shutdown` in `cortex/`:
```
shutdown harness: SIGTERM ok
shutdown harness: SIGINT ok

thread 'main' (1703477) panicked at cortex/tests/shutdown.rs:171:9:
SIGTERM (--work-child): loop still running 2s after the signal: the work never saw the stop flag
error: test failed, to rerun pass `--test shutdown`
```
  The file was then restored from a saved copy (0 `MUTATION` markers), and `pgrep` found no stray `--work-child` processes (the `Cleanup` guard kills the child).
- Success criteria: new case `ok` under SIGTERM and SIGINT, exit 0 within 2s of the signal, PASS (~120ms). The case fails with the listener broken, PASS.

### Deviations
- The doc gives no constructor name for the spawned listener; it is `StopHandle::listen()` (above). Same effect.
- The baseline lint fix landed as a separate chore commit before Phase 2 (the coordinator's instruction), outside the doc's phase list.
- The handle is created before `validate_canonical_assets` too, not just before the sweep. That is the doc's "first thing in the daemon run" taken literally, and a failed validation returns an error either way.

### Tradeoffs
- `notify_waiters` plus a sticky flag, vs `notify_one`'s stored permit: there can be several waiters across clones, and the flag makes a late `stopped()` return at once. `notify_one` would wake only one waiter.
- Lockfile bumps vs editing the 44 `bail!` call sites and allowing `double_must_use`: both defects are upstream macro output, already fixed upstream, so call-site edits would only work around them.

### Open questions
- None.
