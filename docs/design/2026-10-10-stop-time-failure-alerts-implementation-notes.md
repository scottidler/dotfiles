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

## Phase 4: Action-cycle check points
Repo: second-brain. Phase 4 `cdedea4` (on Phase 3 `3c8db7a`).

### Design decisions
- Action cycle: `daemon.rs:configured_actions_with_scanner` checks `stopped_before(stop, action)` at the top of every action, before the rescan, and again right after a rescan. A stop that lands during an action skips the rescan for the next one, and a stop that lands during the rescan still stops before dispatch. A stopped cycle returns the fingerprint it has so far. `configured_actions` and every daemon caller (startup sweep, watcher arm, periodic sweep) pass the daemon's handle. `classify_only`, the latched-oscillation path, passes it too.
- classify: the check points sit in `classify.rs:Classifiers::classify`, which runs once per note. It checks before the primary call and before the fallback. A primary or fallback failure seen once the flag is set returns `Classification::Stopped`, so there is no fallback call and no `Low` result, and so no `mark_needs_review`. A primary that succeeds after the flag lands is applied: the call finished, and a stop does not throw away a real answer. `apply_classify` breaks out of the loop on `Stopped` and falls through to the post-loop `update_wikilinks_batch`, so moves already made are relinked. `lint_classify` (dry run) breaks the same way.
- `Classification<T> { Done(T), Stopped }` is private to classify. `classify_note` returns `Classification<ClassifyResult>`.
- naming: `naming.rs:apply_naming(.., stop)` delegates to a private `apply_naming_with(.., stop, rename)`, which takes the filesystem rename as a closure. The tests stop or fail the loop at a chosen rename through it. The loop moved into `execute_renames`, which returns `Result<RenameLoop { Complete, Stopped }>`. `apply_naming_with` runs `update_wikilinks_batch` over the completed renames whatever ended the loop, then returns the loop's error if there was one. A relink that also fails on that path is logged at error level and the rename error is returned. `NamingApplied.stopped` reports a stop.
- lint: `lib.rs:lint_with_notes(.., stop)` hands the handle to `apply_naming` only. The other appliers have no check point (the doc's "checked around the action only" list), so after a stopped naming pass lint finishes frontmatter, tags and scope, and the cycle's next check point ends the cycle. `lint()` (CLI) passes `StopHandle::never()`.
- fact: `memgraph.rs:extract_facts(.., stop)` checks before each note's extraction. `FactStats.stopped`. `graph.rs:extract_fact_layer` skips consolidation when extraction stopped, because noise deletes and bridges are writes. `FactLayerStats.stopped`.
- graph: `graph.rs:build(.., stop)` checks before each note. A stopped pass keeps the notes it finished (edges and watermarks) and returns before the `last_run_at` write. So a stopped first build is rebuilt in full by the next pass, which is the doc's "partial graph until the next 900s graph tick rebuilds it". `GraphStats.stopped`. `run --backfill` skips the fact layer when the build stopped.
- entities: `entities.rs:discover(.., stop)` checks before each note and returns `Discovery { proposals, scanned, stopped }`. The old tuple became a struct so the stop could be reported. A stopped pass drops its proposals and `run` writes nothing (`EntityReport.stopped`).
- intel: a new `intel.rs:IntelFabric` port (`is_available`, `run_pattern`) with a `ShellFabric(&FabricConfig)` adapter, the same shape as `IntelLlm`. `generate` takes `fabric: &F` in place of `&FabricConfig`, plus `stop`. In `generate_weekly_review` a failed LLM call checks the flag (`Err(e) if stop.is_stopped()`) before the Fabric fallback. When it is set, the review is not written and `IntelReport.stopped` is set. The daily digest has no fallback, so it gets no check point. In the action cycle, a stopped intel does not mark the note cache dirty.
- `Stopped` per stage: every stopped stage logs one info line naming where it stopped, is never counted as failed, and writes nothing past the check point. Daemon tick logs for graph, fact and entities print `stopped=`, and graph and entities log a stopped tick even when it processed 0 notes.
- One-shot `run` entry points that the daemon calls with its handle (`classify::run`, `intel::run`), and the ones whose daemon ticks wrap them (`graph::run`, `entities::run`), take a `&StopHandle`. The four `sb` CLI call sites in `sb/src/cli/cortex.rs` pass `StopHandle::never()`, as the doc's API section says.
- `cortex/AGENTS.md`: a new invariant bullet for the action-cycle and per-note check points.

### Evidence
- `otto ci` green on `cdedea4`: every task `finished successfully`, `All CI checks passed!`, 3108 passed (3093 at Phase 3 + 15 new), 0 failed. The Phase 2 harness lines are still present (`SIGTERM during 30s work ok (exited 100.368578ms after the signal)`).
- New tests (15), each with a fixture vault or an in-memory index and test doubles:
  - `daemon::tests::no_action_runs_after_a_stop_between_actions` (criterion 5): actions classify then lint, both applying. A scanner double records its calls and sets the flag during call 2, which is the rescan after classify's promotion. Asserts classify's move stands, lint did not run (a frontmatter-less root note keeps its bytes), exactly 2 scanner calls, and a fingerprint of `["classify"]`.
  - `daemon::tests::no_action_runs_after_a_stop_during_the_top_scan` (criterion 5): the flag is set during scanner call 1. 0 actions, 1 call, inbox note and root note untouched.
  - `daemon::tests::both_actions_write_without_a_stop`: the control. The same fixture with no stop writes through both actions, so the two tests above observe the check point and not a fixture that never writes.
  - `classify::tests::stop_after_note_one_keeps_its_move_relinks_it_and_leaves_the_rest` (criterion 1): 3 inbox notes and a referrer `[[alpha]] [[beta]] [[gamma]]`. The primary double sets the flag after call 1. Asserts 1 classifier call, 0 fallback calls, `written == [inbox/alpha.md]`, `notes/alpha.md` classified, beta and gamma byte-identical in `inbox/`, the referrer's `alpha` resolving to `notes/alpha.md`, and 0 broken wikilinks (`links::lint_broken_links`).
  - `classify::tests::classifier_failure_after_the_stop_runs_no_fallback_and_writes_nothing` (criterion 3): the primary sets the flag, then fails. 0 fallback calls, nothing written, note bytes unchanged.
  - `classify::tests::fallback_failure_after_the_stop_writes_no_needs_review` (criterion 3, fallback leg): the primary fails with no stop, then the fallback sets the flag and fails. No `cortex-needs-review`.
  - `classify::tests::total_failure_without_a_stop_still_holds_the_note_for_review`: the control. With no stop, the old hold-for-review behavior stands.
  - `naming::tests::stop_after_rename_one_relinks_it_and_leaves_the_rest` (criterion 2): `Alpha Note`, `Beta Note`, `Gamma Note` and a referrer. The rename closure sets the flag after rename 1. Asserts `alpha-note.md` exists, Beta and Gamma keep their names, the referrer has `[[alpha-note]]`, and 0 broken wikilinks.
  - `naming::tests::rename_error_on_note_two_relinks_note_one_before_returning_the_error` (criterion 2): the rename closure fails on call 2. Asserts `Err` carrying the injected failure, `alpha-note.md` landed, the referrer has `[[alpha-note]]`, and 0 broken wikilinks.
  - `naming::tests::preset_stop_renames_nothing`.
  - `intel::tests::weekly_llm_failure_after_the_stop_skips_the_fabric_fallback_and_writes_nothing` (criterion 4): the LLM double sets the flag and fails, and the Fabric double is available with `batch_weekly` configured. 0 Fabric calls, `report.stopped`, no file at `output_path`.
  - `intel::tests::weekly_llm_failure_without_a_stop_falls_back_to_fabric`: the control. 1 Fabric call and the review is written with its output.
  - `graph::tests::stopped_build_processes_no_note_and_leaves_last_run_at_unset`: preset flag gives 0 notes, 0 edges and `last_run_at` unset. The next unstopped pass is a full rebuild of both notes.
  - `memgraph::tests::extract_facts_stops_before_the_next_note`: the extractor sets the flag on note 1. 1 extraction, note 1's edge written, `stopped`.
  - `entities::tests::discover_stops_before_the_next_note_and_drops_its_proposals`: the extractor sets the flag on note 1. 1 extraction, proposals empty, `stopped`.
- Existing tests: call sites updated mechanically (`&StopHandle::never()` added, `discover` destructured as `Discovery { .. }`, `generate` given `&ShellFabric(&fabric)`). No existing test pinned behavior this phase changes, so none needed inverting.
- Mutations. Each was applied by a scratch script to the real source file, then `cargo test -p cortex --lib -- <filter>` ran. The script restored the file from a saved copy and checked it with `filecmp` (`restored ... (cmp ok)` for all 11):
  - M1, action-cycle check disabled (`let stopped = false && stop.is_stopped();` in `stopped_before`):
    ```
    test daemon::tests::no_action_runs_after_a_stop_between_actions ... FAILED
    test daemon::tests::no_action_runs_after_a_stop_during_the_top_scan ... FAILED
    assertion `left == right` failed: lint ran after the stop and inserted frontmatter
    test result: FAILED. 0 passed; 2 failed
    ```
  - M2, classify per-note check removed (`if false && stop.is_stopped()` before the primary call):
    ```
    test classify::tests::stop_after_note_one_keeps_its_move_relinks_it_and_leaves_the_rest ... FAILED
    assertion `left == right` failed: no classifier call after the stop
      left: 3
     right: 1
    ```
  - M3, discard-after-flag removed (both the primary-failure and fallback-failure guards):
    ```
    test classify::tests::fallback_failure_after_the_stop_writes_no_needs_review ... FAILED
    test classify::tests::classifier_failure_after_the_stop_runs_no_fallback_and_writes_nothing ... FAILED
    assertion `left == right` failed: no fallback call after the stop
      left: 1
     right: 0
    nothing written: ["inbox/alpha.md"]
    test result: FAILED. 24 passed; 2 failed
    ```
  - M4, classify relink skipped on stop (`return Ok((report, written))` in place of `break`): the test PASSES (`test result: ok. 1 passed`). This is not a gap in the test. The classify relink is a no-op for every move classify records (see Open questions), so skipping it changes no byte.
  - M5, naming relink skipped on stop (early `return` before `update_wikilinks_batch` when the loop stopped):
    ```
    test naming::tests::stop_after_rename_one_relinks_it_and_leaves_the_rest ... FAILED
    referrer relinked to note 1's new name:
    test result: FAILED. 23 passed; 1 failed
    ```
  - M6, the old `?` early return restored (`executed?` before the relink):
    ```
    test naming::tests::rename_error_on_note_two_relinks_note_one_before_returning_the_error ... FAILED
    note 1 relinked before the error returned:
    test result: FAILED. 23 passed; 1 failed
    ```
  - M7, naming per-rename check removed:
    ```
    test naming::tests::preset_stop_renames_nothing ... FAILED
    test naming::tests::stop_after_rename_one_relinks_it_and_leaves_the_rest ... FAILED
    assertion failed: applied.stopped
    ```
  - M8, intel check removed (`Err(e) if false && stop.is_stopped()`):
    ```
    test intel::tests::weekly_llm_failure_after_the_stop_skips_the_fabric_fallback_and_writes_nothing ... FAILED
    assertion `left == right` failed: no Fabric call after the stop
      left: 1
     right: 0
    ```
  - M9 graph, M10 fact, M11 entities, per-note check removed in each:
    ```
    test graph::tests::stopped_build_processes_no_note_and_leaves_last_run_at_unset ... FAILED   (assertion failed: stats.stopped)
    test memgraph::tests::extract_facts_stops_before_the_next_note ... FAILED                    (assertion failed: stats.stopped)
    test entities::tests::discover_stops_before_the_next_note_and_drops_its_proposals ... FAILED (assertion failed: found.stopped)
    ```
- Success criteria:
  - Classify, flag set after note 1 of 3: notes 2 and 3 untouched, note 1 classified and moved, its referrers resolve, 0 broken wikilinks. PASS (fails under M2). "Referrers of note 1 are relinked" passes only in the sense that they resolve: the relink rewrites nothing for a classify move (M4, Open questions).
  - Naming, same shape, plus a rename forced to fail on note 2 still relinks note 1 before returning the error. PASS (fails under M5, M6, M7).
  - A classifier failure returned after the flag is set produces no `needs-review` write and no fallback call. PASS (fails under M3).
  - intel: LLM stub fails after the flag is set, Fabric stub never called. PASS (fails under M8).
  - No action after the stop point runs (test-double scanner records calls). PASS (fails under M1).

### Deviations
- `IntelFabric` port added and `generate`'s `fabric: &FabricConfig` parameter replaced by `fabric: &impl IntelFabric`. The doc has no Fabric seam in intel, and criterion 4 needs a Fabric stub. Same effect in production (`ShellFabric` wraps the same two `crate::fabric` calls).
- naming's rename is injected through a private `apply_naming_with`. The public `apply_naming` keeps its shape plus `stop`. The doc has no seam for "a rename forced to fail on note 2".
- `classify::run`, `intel::run`, `graph::run` and `entities::run` gained a `stop` parameter, and the four `sb` call sites pass `never()`. Phase 3 kept `embed::run`'s signature and passed `never()` inside it. Here the daemon calls `classify::run` and `intel::run` directly with its handle, so they must take one, and `graph::run` / `entities::run` follow for one consistent shape. `lint()` keeps its signature because the daemon calls `lint_with_notes`.
- The action-cycle check runs twice per action when the cache is dirty (before and after the rescan). The doc says "between actions". The second check catches a stop that lands during the rescan, and the first skips a rescan nobody will read.
- A stopped weekly review writes nothing. The doc places only a check point there. Writing the review without its insights would persist `intel-input-hash` and pin the degraded review until the week's notes change, which breaks the stop write contract's "never writes".
- A stopped fact extraction skips consolidation, and a stopped `graph run --backfill` build skips the fact layer. The doc does not mention either. Both are writes after the check point.
- The classify check points live in `Classifiers::classify` rather than in the `apply_classify` loop body. It runs once per note, so the per-note check is the same, and it also covers the fallback check and the dry-run path.

### Tradeoffs
- `stopped: bool` on the existing stats structs (`GraphStats`, `FactStats`, `FactLayerStats`, `EntityReport`, `NamingApplied`, `IntelReport`) vs. a new enum per stage: those structs are already the return values, and a field keeps every caller's shape. The classify loop, which has no stats struct, uses the private `Classification` enum.
- A classifier success after the flag is applied, not discarded: the call finished and its answer is real. Only failures are suspect, because a stop can cause them (a killed Fabric child).
- lint's other appliers run after a stopped naming pass vs. returning early: the doc lists them as checked around only, they are short and per-file atomic, and the cycle check point right after lint ends the cycle.
- `IntelFabric` local to intel vs. reusing `distillers::tags::FabricRunner`: `FabricRunner` has no timeout parameter and no availability check, and is built from the tags config. A local port matches `IntelLlm`.

### Open questions
- classify's post-loop relink rewrites nothing for any move classify records. It records only same-stem moves (`inbox/x.md` -> `notes/x.md`), and `update_wikilinks_batch` replaces only the stem inside a link target. A bare `[[x]]` resolves by suffix before and after the move, so it never needed a rewrite. A path-qualified `[[inbox/x]]` is left pointing at the old path and breaks on every promotion, stopped or not. Measured with a temporary test (removed): an unstopped promotion of `inbox/alpha.md` with a referrer `See [[inbox/alpha]].` left the referrer byte-identical and `broken=1`. This predates Phase 4 and is out of its scope. It is why M4 survives. Fix it here, or file it as its own issue?
- classify still has `?` early returns inside the loop (`mark_needs_review`'s read and `write_atomic`) and on the post-loop rescan. Like naming's before this phase, an error there skips the relink of moves already made. Given the item above, that relink rewrites nothing today, so the effect is nil. The doc names only naming's `?` returns. Left as is.
- Phase 3's oversized-note starvation question is still open.

## Phase 5: Unit rendering: TimeoutStopSec and SuccessExitStatus
Repo: second-brain. Phase 5 `d3aae90` (on Phase 4 `cdedea4`). Nothing was installed, restarted or deployed.

### Design decisions
- `vault::systemd::ServiceUnit` gains `timeout_stop_sec: Option<u64>`, `kill_mode: Option<KillMode>` and `success_exit_status: Vec<i32>` (`vault/src/systemd.rs`). New `KillMode { Mixed, ControlGroup }`. Each renders only when set, in the order TimeoutStopSec, KillMode, SuccessExitStatus, between `RestartSec` and `WorkingDirectory`. borg's unit sets all three to unset, and its golden files are untouched and green, which is the byte-for-byte proof.
- `cortex/src/daemon.rs:render_systemd_unit`: `timeout_stop_sec: Some(config.daemon.stop_timeout_secs)`, `kill_mode: Some(KillMode::Mixed)`. `DaemonConfig.stop_timeout_secs` (`stop-timeout-secs`, default 180) in `cortex/src/config.rs`.
- The guard logic lives on `Config` (`cortex/src/config.rs`): `per_call_timeouts()` lists the six keys by config path, `stop_budget_shortfall()` returns a `StopBudgetShortfall` (stop value, offending key, its timeout; `Display` names `daemon.stop-timeout-secs` and the key). Margin is `STOP_TIMEOUT_MARGIN_SECS = 30`. On a tie the first listed key is named, so the all-120s default names `fabric.timeout-secs`. `Config::load_service_config(path)` loads the file at a path, defaults when it is missing, errors when it does not parse.
- Install guard: `cortex/src/daemon/stop_budget.rs:ensure_stop_budget(config_path)`, called first in `install_systemd_service` with `vault::paths::cortex_config()`, before any file is written. It validates the service's config, not the run's `--config`.
- Doctor: `sb/src/cli/checks/stop_timeout.rs` (a child module; `checks.rs` was exactly at the 1500-line bloat limit). `stop_budget_finding(cfg)` is an Error naming both keys, or Ok. `user_manager_stop_finding(cfg, read)` takes the `TimeoutStopUSec` read as a closure, so tests inject 5s, an error, and 210s. The real read is `systemctl show -p TimeoutStopUSec --value user@<uid>.service` (system manager), parsed with `humantime` (already an sb dependency), `infinity` mapped to `Duration::MAX`. uid comes from `/proc/self` ownership (no new dependency). Hooked into `systemd_findings` through `stop_timeout::findings()`.
- The user@ check runs only when `cortex.service` is installed on the host (a host with no cortex daemon has no reboot budget to protect). The stop-budget check runs whenever the cortex config loads.
- harvest: `borg/src/harvest/timer.rs:render_units` sets `success_exit_status: vec![130]`.
- `config/templates/cortex.yml.example` documents `daemon.stop-timeout-secs` (commented out at the default, with the six keys and the user@ coupling). `cortex/AGENTS.md` gets one invariant bullet.
- Four golden files regenerated by hand (cortex minimal/full gain the two lines, harvest minimal/full gain one).

### Evidence
- `otto ci` green on `d3aae90`: all tasks finished successfully, `All CI checks passed!`, 3131 passed (3108 at Phase 4), 0 failed.
- Live CLI run of the guard, with `HOME`, `XDG_CONFIG_HOME` and `XDG_DATA_HOME` all pointed at a scratch dir holding a `cortex.yml` with `daemon.stop-timeout-secs: 100` (so an install that wrongly passed could only write into the scratch dir):
```
Error: refusing to install cortex.service: daemon.stop-timeout-secs (100) is below fabric.timeout-secs (120) + 30s margin = 150s; raise daemon.stop-timeout-secs to at least 150
install exit 1          (no ~/.config/systemd created in the scratch home)
```
  `sb doctor` on that same config: `❌ [systemd] cortex stop budget: daemon.stop-timeout-secs (100) is below fabric.timeout-secs (120) + 30s margin = 150s; ...`. With 180: `✅ [systemd] cortex stop budget: daemon.stop-timeout-secs (180) covers the longest per-call timeout + 30s`.
- Real read, this host (ripr): `systemctl show -p TimeoutStopUSec --value user@1000.service` prints `5s`, which the parser reads as 5s, so doctor on this host reports the user@ Error until the operator applies the Phase 1 drop-in.
- New tests: vault `unset_stop_fields_render_no_lines`, `stop_fields_render_between_restart_and_working_directory`, `kill_mode_control_group_renders_its_systemd_name`. cortex `rendered_unit_has_default_timeout_stop_and_mixed_kill_mode`, `rendered_unit_takes_timeout_stop_from_the_config_key`, `stop_timeout_secs_defaults_to_180_and_parses_from_daemon_block`, `default_stop_budget_holds`, `stop_budget_names_fabric_timeout_first_on_a_tie_of_120s_defaults`, `stop_budget_boundary_is_largest_timeout_plus_30`, `stop_budget_covers_each_of_the_six_timeouts`, `load_service_config_defaults_when_the_file_is_missing_and_errors_when_unparseable`, and four `install_guard_*` in `daemon/stop_budget/tests.rs`. borg `harvest_service_treats_exit_130_as_success`. sb (`checks/stop_timeout/tests.rs`) `stop_budget_finding_errors_naming_both_keys`, `stop_budget_finding_is_ok_at_the_default`, `user_manager_stop_finding_errors_on_five_seconds`, `..._errors_when_unreadable`, `..._passes_at_210_with_180`, `..._tracks_the_configured_budget`, `parse_timeout_stop_usec_reads_systemd_timespans`.
- Mutations. Each applied by a scratch script to the real source, `cargo test` on the affected filter, file restored from a saved copy (no mutation markers remain in the tree):
  - M1, vault ignores `timeout_stop_sec`: `stop_fields_render_between_restart_and_working_directory ... FAILED` (15 passed; 1 failed).
  - M1b, cortex render caps the key at 90: `golden_cortex_service_minimal`, `golden_cortex_service_full`, `rendered_unit_has_default_timeout_stop_and_mixed_kill_mode`, `rendered_unit_takes_timeout_stop_from_the_config_key` all FAILED (44 passed; 4 failed).
  - M2, cortex drops `KillMode=mixed`: the default-render test and both goldens FAILED (45 passed; 3 failed).
  - M3, harvest drops `SuccessExitStatus=130`: `harvest_service_treats_exit_130_as_success`, `golden_harvest_service_full`, `golden_harvest_service_minimal` FAILED (10 passed; 3 failed).
  - M4, install guard never refuses (`stop_budget_shortfall().filter(|_| false)`): `install_guard_refuses_100s_...naming_both_keys` and `install_guard_reads_the_file_it_is_given` FAILED (2 passed; 2 failed).
  - M5, margin 0: `stop_budget_boundary_is_largest_timeout_plus_30` and `stop_budget_covers_each_of_the_six_timeouts` FAILED.
  - M6, guard ignores `graph.fact-timeout-secs`: `stop_budget_covers_each_of_the_six_timeouts` FAILED.
  - M7, doctor stop-budget finding always Ok: `stop_budget_finding_errors_naming_both_keys` FAILED.
  - M8, doctor user@ threshold collapses to 1s: `user_manager_stop_finding_errors_on_five_seconds` and `..._tracks_the_configured_budget` FAILED.
  - M9, doctor user@ unreadable downgraded to a warning: `user_manager_stop_finding_errors_when_unreadable` FAILED.
- Success criteria:
  - Cortex unit has `TimeoutStopSec=180` and `KillMode=mixed` by default, harvest has `SuccessExitStatus=130`, borg unchanged byte for byte: PASS (M1b, M2, M3; borg goldens green and unedited).
  - `--install` with `stop-timeout-secs: 100` exits non-zero naming `stop-timeout-secs` and `fabric.timeout-secs`, doctor reports an Error naming both: PASS (live CLI output above, M4, M7).
  - Doctor user@ check Errors for an injected 5s and for an unreadable value, passes at 210s with 180: PASS (M8, M9).

### Deviations
- Guard logic is in `Config` (`per_call_timeouts`, `stop_budget_shortfall`, `load_service_config`) with the install wrapper in a new `daemon/stop_budget.rs`, and the doctor checks are in a new `checks/stop_timeout.rs`. The doc names neither. Same effect; the split is forced by the 1500-line bloat limit (`checks.rs` sat at exactly 1500, `daemon/tests.rs` would have gone to 1513) and keeps one source for both callers.
- The doctor user@ check is gated on `cortex.service` being installed; the doc says only "an Error when below or unreadable".
- The rendered unit takes `TimeoutStopSec` from the config passed to the install, while the guard validates the service's own config file. They are the same file in every normal run (the unit pins `--config` to `cortex_config()` and `Config::load(None)` reads it). They differ only for an install run with a different `--config`; the guard still protects the service's real file, which was the doc's ask.
- Added `KillMode::ControlGroup` beyond what is rendered today, so the enum names systemd's default and a test covers a second variant.

### Tradeoffs
- `humantime` parse of systemd's `3min 30s` text vs asking `systemd-analyze timespan` or a numeric property: `humantime` is already an sb dependency, no extra process, and the real `5s` output parses. Cost: an unparseable string becomes the "cannot read" Error, which is the intended fail-closed outcome.
- uid from `/proc/self` ownership vs adding `libc`/`nix`: no new dependency; Linux-only, and the whole check is systemd-only.
- Stop-budget check ungated vs gated on the unit being installed: the check is pure config, and a too-tight value is wrong whether or not this host has installed yet.

### Open questions
- Operator-side, not run here: both hosts need `sb` released, `sb cortex daemon --install`, `daemon-reload`, a cortex restart, and the Phase 1 `user@` drop-in applied. Until then `sb doctor` on ripr reports the user@ Error (`5s`) and cortex.service drift, which is correct.
- None otherwise.
