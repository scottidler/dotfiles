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

## Phase 3: Embed check points and per-tick cap
Repo: second-brain. Phase 3 `3c8db7a` (on Phase 2 `139b894`).

### Design decisions
- `StopHandle` is threaded from the daemon (`daemon.rs`, the handle Phase 2 creates) into `daemon_tick_with_model(.., stop)` -> `embed_tick` -> `process_batch(.., stop)` -> each `process_*_batch` -> `embed_in_sub_batches(.., stop)`. The CLI `embed::run` passes `StopHandle::never()`; there are no other callers. Tests pass `never()` or a handle they stop.
- The tick loop moved out of `daemon_tick_with_model` into `embed.rs:embed_tick(index, model, vault_root, config, stop)`. `daemon_tick_with_model` opens the index at the fixed `oracle_db_path` and takes the file lock, so no test can drive it. `embed_tick` is the hermetic seam on `SearchIndex::open_memory()`. Index open, lock and RSS logging stay in `daemon_tick_with_model`.
- Check points, each one `is_stopped()`: (1) top of the `embed_tick` batch loop, before the allowance check and before `process_batch`; (2) `embed_in_sub_batches`, before EVERY sub-batch, including the first, so a stop that lands during the read phase also skips inference.
- `Stopped` outcome: `pub enum BatchOutcome { Complete, AllowanceSpent, Stopped }`, each carrying `EmbedStats` (`embed.rs`). `process_batch` returns it. Internally `embed_in_sub_batches` returns `Inference::{Vectors, Stopped}`. A stopped batch returns before the write phase with `failed` untouched. Its `scanned` / `skipped_empty` and the examined sentinels from its read phase stay, as the stop write contract says.
- Tick allowance: `pub enum ChunkAllowance { Unlimited, Limited { remaining, fresh } }`. `per_tick(0)` is `Unlimited`, which keeps `max-chunks-per-tick: 0` meaning "no cap" with no clash against a spent allowance of 0. `embed_tick` builds one per tick. After each batch it draws `embedded + failed` (`EmbedStats::chunks_inferred`: both cost inference time), and it ends the tick when the allowance is spent, when a batch returns `AllowanceSpent`, or on `Stopped`.
- Summary draws 1 per note by selecting `min(batch_size, remaining)` targets (`ChunkAllowance::note_limit`), so `scanned` stays honest. Transcript and claim pass the allowance to `cap_work_by_chunks`. If the cap dropped any note, the batch returns `AllowanceSpent`, which includes the case where the cap kept nothing.
- The oversized-note exception (`cap_work_by_chunks`) applies only to a `fresh` allowance, meaning nothing was drawn yet this tick. On a partly drawn allowance an oversized note defers to the next tick, and so does every note behind it (order preserved). That keeps a tick at or under max(cap, largest single note), and makes "a single 600-chunk note is embedded alone in its tick" true.
- CLI `embed::run` (`sb cortex embed` / backfill) gives each batch `ChunkAllowance::per_tick(cap)`, a fresh one, and keeps looping. Behavior is unchanged: a CLI pass drains, and the cap bounds one batch's inference there.
- `StopHandle::stop` went from private to `pub(crate)`, so crate tests can set the flag at a chosen point. The listener task is still the only production caller.
- `embed.rs:70-84` doc comment: not changed. With the tick-wide allowance the code now does what it says ("Cap on total chunks embedded in a single tick, across all notes", "bounds the tick's WALL CLOCK", unfit notes "picked up next tick"). The same goes for `config.rs` `max_chunks_per_tick` ("Hard ceiling on chunks embedded in a single tick, across all notes").
- `cortex/AGENTS.md`: the per-tick-cap invariant line now describes the shared allowance and the fresh-only exception, and there is a new bullet for the embed check points and `Stopped`.

### Evidence
- `otto ci` green on 3c8db7a: all tasks `finished successfully`, 3093 passed (3084 at Phase 2 + 9 new), 0 failed. The Phase 2 harness lines are still present (`SIGTERM during 30s work ok (exited 120.419467ms after the signal)`).
- New tests (`cortex/src/embed/tests.rs`). `CountingEmbedder` wraps `MockEmbedder`, counts `embed_batch` calls and chunks, and can call `stop()` right after its Nth call:
  - `stop_between_sub_batches_drops_the_batch_and_writes_no_embedding_rows` (criterion 1): a 3-chunk transcript note, `max_chunks_per_call: 1`, stop after call 1, driven through `embed_tick`. It asserts 1 call, 0 rows in `note_embeddings`, `failed == 0`, and that the read-phase sentinel for a skip note is still present.
  - `stopped_batch_is_its_own_outcome`: `process_batch` returns `BatchOutcome::Stopped`, not `Complete` with failures.
  - `preset_stop_returns_before_any_batch` (criterion 2): it asserts 0 calls, `scanned == 0`, and no sentinel for a skip note, which shows no read phase ran.
  - `one_tick_embeds_at_most_the_cap_across_all_kinds` (criterion 3a): cap 512 against a 1300-chunk backlog of summary 200x1, transcript 6x150 and claim 1x200, with all three kinds on. It runs ticks until one is idle and asserts every tick embedded and inferred <= 512, more than one tick, and 1300 total.
  - `an_oversized_note_embeds_alone_in_its_tick` (criterion 3b): 5 summaries, a 600-chunk note and a 100-chunk note, cap 512. Tick 1 = 5 (the big note defers). Tick 2 = 600, all from the big note, with the small note still at 0. Tick 3 = 100.
  - `summary_draws_one_per_note_from_the_tick_allowance`: 600 summary notes against cap 500. Tick 1 = exactly 500 and tick 2 = 100. Cap 500 is chosen because 512 is a multiple of the 64-note batch and would hide a summary path that ignores the allowance.
  - Unit tests: `partly_drawn_allowance_defers_an_oversized_note`, `allowance_draws_down_and_reports_spent`, `sub_batches_stop_at_the_check_point`.
- Existing tests: call sites were updated mechanically (`ChunkAllowance::per_tick(DEFAULT_MAX_CHUNKS_PER_TICK)`, `&StopHandle::never()`, `*process_batch(..).stats()`, `cap_work_by_chunks(work, ChunkAllowance::per_tick(n))`). No test that pinned per-batch-cap behavior existed, so none needed inverting.
- Mutations. Each was applied to a saved copy of `embed.rs` by a scratch script and run with `cargo test -p cortex --lib embed::tests`. Afterwards the file was restored, `cmp` against the saved copy matched, and 0 mutation markers remained. Line numbers are from before the final `use crate::config::EmbedConfig` / `tick_config` edit, which shifted the file by a few lines.
  - M1, sub-batch check point removed (`if false && stop.is_stopped()` in `embed_in_sub_batches`):
    ```
    test embed::tests::sub_batches_stop_at_the_check_point ... FAILED
    test embed::tests::stopped_batch_is_its_own_outcome ... FAILED
    test embed::tests::stop_between_sub_batches_drops_the_batch_and_writes_no_embedding_rows ... FAILED
    assertion failed: matches!(out, Inference::Stopped)
    expected Stopped, got Complete(EmbedStats { scanned: 2, embedded: 2, skipped_empty: 0, failed: 0 })
    assertion `left == right` failed: the check point before sub-batch 2 must stop the batch
      left: 3
     right: 1
    test result: FAILED. 38 passed; 3 failed
    ```
  - M2, batch-loop check point removed (`if false && stop.is_stopped()` in `embed_tick`):
    ```
    thread 'embed::tests::preset_stop_returns_before_any_batch' panicked at cortex/src/embed/tests.rs:1242:5:
    assertion `left == right` failed: no batch was selected
      left: 1
     right: 0
    test result: FAILED. 40 passed; 1 failed
    ```
  - M3, cap applied per batch (`process_batch` gets `ChunkAllowance::per_tick(cap)` instead of the remaining allowance):
    ```
    summary_draws_one_per_note_from_the_tick_allowance: left: 512 right: 500
    an_oversized_note_embeds_alone_in_its_tick: tick 1: the summaries draw first; the big note defers  left: 605 right: 5
    one_tick_embeds_at_most_the_cap_across_all_kinds: tick 0 embedded 650 chunks, over the 512 cap: [(650, 650), (650, 650)]
    test result: FAILED. 38 passed; 3 failed
    ```
  - M4, summary ignores the allowance (selects `batch_size`; written as `black_box((batch_size, allowance)).0` so `allowance` stays used under `-D unused-variables`):
    ```
    thread 'embed::tests::summary_draws_one_per_note_from_the_tick_allowance' panicked at cortex/src/embed/tests.rs:1415:5:
      left: 512
     right: 500
    test result: FAILED. 40 passed; 1 failed
    ```
  - M5, oversized exception on any allowance (the `fresh` condition dropped):
    ```
    partly_drawn_allowance_defers_an_oversized_note: assertion failed: cap_work_by_chunks(work, allowance).is_empty()
    an_oversized_note_embeds_alone_in_its_tick: tick 1: the summaries draw first; the big note defers  left: 605 right: 5
    test result: FAILED. 39 passed; 2 failed
    ```
- Success criteria:
  - Flag set after sub-batch 1 of 3: 1 `embed_batch` call, 0 embedding rows, sentinel present. PASS (fails under M1).
  - Flag preset: the tick returns before any `process_batch`. PASS (fails under M2).
  - Cap 512 with a 1300-chunk cross-kind backlog: every tick <= 512. A 600-chunk note embeds alone in its tick. PASS (fails under M3; 3b also fails under M5).

### Deviations
- The doc names the parameter chain `daemon_tick_with_model`, `process_batch`, `embed_in_sub_batches`. The handle goes through all three, plus a new private `embed_tick` holding the loop that used to live in `daemon_tick_with_model`, because that function cannot run against an in-memory index. Same effect, correct seam.
- `process_batch`'s `max_chunks_per_tick: usize` parameter became `allowance: ChunkAllowance`, and its return type `EmbedStats` became `BatchOutcome`. The doc left the enum shape to the implementer. The allowance is a type rather than a bare `usize` because a spent allowance (0) and "no cap" (0) would otherwise collide.
- The doc's tick-end rule is "allowance hits 0 or the backlog is empty". The tick also ends when the allowance is above 0 but too small for the next note (`AllowanceSpent`). It does not move on to smaller notes of a later kind, which keeps note order and matches the per-batch truncation that was already there.
- The doc comment for `embed_in_sub_batches` ("Call `embed_batch` repeatedly ...") sat above `cap_work_by_chunks`, so `cap_work_by_chunks` carried two stacked doc comments. While rewriting both functions I moved it back onto `embed_in_sub_batches`. Not in the doc, and comment-only.
- `cortex/AGENTS.md` invariant line updated; the doc does not list it, but the line described the old per-batch behavior.

### Tradeoffs
- Fresh-only oversized exception vs. allowing an oversized note on any allowance: allowing it on any allowance would break the max(cap, largest note) bound (tick = summary draw + 600). The cost of fresh-only is that an oversized transcript or claim note waits for a tick where no earlier kind drew anything. If a stale summary showed up every 600s tick indefinitely, it would never get a fresh allowance. Summaries arrive with ingests (~20/day per the cadence comment in `embed.rs`), so most ticks start fresh, but it is a starvation path in principle (see Open questions).
- Drawing `embedded + failed` vs. `embedded` only: a failed inference still spent the wall clock the cap exists to bound.
- Summary limits its SELECT vs. truncating the selected work: limiting keeps `scanned` equal to the notes actually considered, and leaves unselected notes untouched.
- A check point before the FIRST sub-batch too, not only between sub-batches: it costs one atomic load, and it skips inference when the stop landed during the read phase.

### Open questions
- Oversized-note starvation (Tradeoffs above): acceptable as is, or should an oversized note that defers some number of times in a row take the next tick regardless of what summary drew? The doc does not cover it; it is left as implemented.
