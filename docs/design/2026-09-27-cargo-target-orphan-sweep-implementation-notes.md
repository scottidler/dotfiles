# Implementation Notes: Cargo Target SSD Leak

Design doc: `docs/design/2026-09-27-cargo-target-orphan-sweep.md`

## Phase 1: Harden relocate-targets

Repo: `scottidler/claude`. Files: `HOME/.claude/skills/relocate-targets/scripts/relocate-targets`, `HOME/.claude/skills/relocate-targets/SKILL.md`, `bin/relocate-targets-test.sh`, `.otto.yml`.

### Design decisions
- Commit sequence split across two functions: `migrate()` owns the trap window and the rename-aside (`mv src src.relocated-$$`), and `relocate_one()` owns `ln -s`, the marker and `rm -rf src.relocated-$$`. That way every transport returns with the same contract ("SRC is gone from its path") and the link step stays where it was for the rename and rsync transports. `relocate-targets:migrate`, `relocate-targets:relocate_one`.
- Signals are ignored (`trap '' INT TERM`) across the rename alone, between the commit point and `mv`. With the trap simply disarmed at the commit point, a signal landing between disarm and `mv` would kill the run with a complete dst next to a plain local `target/`, the shape the design rules out. Keeping the removal trap armed through the `mv` would instead delete dst after the source had moved. `relocate-targets:migrate`.
- The trap handler removes `INFLIGHT_DST`, a global, not a `migrate()` local. The handler can then run in any scope, and the trap fires only while that global is set. `relocate-targets:abort_inflight`.
- New checks are local-only. Under `--remote` there is no free-space precheck, dangling repair, marker write or lock. A remote DEST's paths do not exist locally, so dangling repair would `mkdir` stray local dirs, and the lock would create a local `DEST`. This matches the design's Non-Goals (remote excluded, local-only like `dest already exists`). `relocate-targets:relocate_one`, main.
- Check order for a plain `target/`: ownership, then `dest already exists`, then free space. Ownership comes first because `catalog-api` has both a root-owned local `target/` and a DEST copy. The ownership WARN names the action the operator must take (Rollout step 6), and `dest already exists` would hide it.
- A failed `du`/`df` measurement is a per-repo WARN and skip, not a run abort. Under `set -e`, an unguarded `du` error on one unreadable tree would kill the whole nightly run. `relocate-targets:relocate_one`.
- The WARN toast names the log by reading `/proc/$$/fd/2`, so it reports wherever cron actually sends stderr, not a hardcoded `~/.cache/relocate-targets.log`. main tail.
- `record_link` stores the link path with `realpath -ms` (absolute, symlinks not resolved), so the marker names the link as it sits in the tree. `relocate-targets:record_link`.
- Test harness: `rt()` `exec`s the script, and `run()` is `(rt ...)`. With a plain function, `run ... & pid=$!` gives the pid of a subshell, and `kill -TERM` hit the subshell, not the script. The first draft of the commit-point case passed for the wrong reason that way: the script died on the shim's failed `ln` under `set -e`, not on the signal. The mid-copy trap case exposed it. `bin/relocate-targets-test.sh:rt`.
- Test coverage beyond the listed cases: argument validation, a mid-copy SIGTERM (a `tar` shim pauses the extract side and the trap removes dst, exit 143), a relative dangling link resolved against its own dir (the test runs from `/`), dangling links outside DEST and via `DEST/..` (both still WARN, nothing created), the WARN toast reaching the `notify-send` stub, and no toast on a clean run.
- Dry-run check: fixture DEST contents are backdated to epoch 1e9 before the stamp is touched. `find DEST -newer stamp` then cannot miss a creation that lands in the same timestamp tick as the stamp. It also checks that ROOT's listing is unchanged and that no lock file exists.
- `SKILL.md`: three rows added to the situation table (dangling repair, floor skip, failed/interrupted copy), plus one paragraph on the marker, lock and toast. Without them the table would no longer describe what the script does.

### Deviations
- `--lock-wait SECS` flag (default 600) added. The design says "a test-shortened `-w`" but names no mechanism. A flag keeps it config, not a test hook, and it is documented in `usage()`.
- `claude/.otto.yml` lint does not run `whitespace --check -r .` literally. It runs `whitespace --check -r` over a scratch copy of `git ls-files --cached --others --exclude-standard`. Reason: the literal command exits 1 on 19 files, all under `HOME/.claude/skills/synced/`. That dir is gitignored (`.gitignore:50`), and the harness replaces it on every resync (Anthropic's pptx/docx skill bundles), so fixing them in place would not survive and is not repo content. `whitespace` has no `.gitignore` support and rejects file arguments (`Not a directory`), so a copy of the tracked tree was the only way to scope it. Verified both ways: an untracked `ws-probe.txt` holding `x ` made `otto lint` exit 1 naming the file, and after it was removed lint exited 0. Phase 2's dotfiles `.otto.yml` should copy this shape if dotfiles has ignored content; otherwise the literal form works there.
- A separate `fix(test)` commit precedes the Phase 1 commit (orchestrator's call). `otto ci` in claude was already red at HEAD 4edea75 because of the release-driver retirement. 94458c9 deleted `HOME/.claude/bin/release` and its `release *` excludedCommands entry, but `pr-open-test.sh` still required the file and the rails `index.test.ts` EXCLUDED list still named it. 333f6e3 reworded Gate D's deny to `no package version line changes`, which broke one pr-open-test substring; the MISSING exit had hidden that break. The commit removes only what those commits made dead, the `RELEASE=` requirement and the release-script section, and syncs that one substring. Every other pr-open case is unchanged.
- No files were fixed for whitespace: the scoped check is clean on the tracked tree.
- `SKILL.md` edit is not listed under "relocate-targets changes". It is a docs-truthfulness follow-on, recorded above.
- Bite test for the commit order: the "revert" used is the pre-Phase-1 order. That is `rm -rf "${src}"` at the commit point in place of the rename-aside, then link. With that order the process is still killed at `ln` with `target` absent, so the case's "target absent" assertion alone cannot tell the orders apart. The case therefore also asserts that the source was set aside (`target.relocated-*` exists at kill time), and that assertion is what fails. A link-before-rename order would fail "target absent" instead, but it was not run as a mutation.
- Bite-test output observed (mutated copies under `$TMPDIR`; every other case PASS):
  - `rm -rf -- "${dst}"` removed from the tar-failure path: `FAIL  ENOSPC: partial dst removed / want [absent] / got [dir]`, `pass=61 fail=1`
  - rename-aside reverted to `rm -rf "${src}"` at commit: `FAIL  commit-point SIGTERM: source set aside, not deleted / want [1] / got [0]`, `pass=61 fail=1`
  - unmutated: `pass=62 fail=0`

### Tradeoffs
- Rename-aside then later `rm` vs deleting the source at the commit point: this costs a `target.relocated-*` leftover sweep at the start of each `relocate_one`. In return, the slow `rm -rf` of a large source (53G in the incident) is never the step that an interruption can cut in half next to a complete dst.
- Mutated copies via `RELOCATE_TARGETS=<copy>` vs editing the production script for bite tests: copies leave the write-denied skill dir untouched and cannot be forgotten in a mutated state. The test honours the override and has no other hook.
- Fixture sync over fifos, with one deliberate `sleep 2` inside the background lock holder for the "released after 2s" case. That sleep is the scenario, not the sync: the test reads a fifo to know the lock is held before it starts the run.

### Open questions
- `otto ci` in `scottidler/claude` is red at HEAD 4edea75 for two reasons that predate this phase, both from the release-driver deletion (94458c9, 2026-09-26): `HOME/.claude/bin/pr-open-test.sh:31` requires the deleted `HOME/.claude/bin/release`, and rails `index.test.ts:365-387` still lists `'release'` in EXCLUDED while `settings.json` no longer excludes it. Escalated to the orchestrator; resolution recorded in the phase report.

## Phase 2: dotfiles test scaffold

Repo: `scottidler/dotfiles`. Files: `.otto.yml` (new), `bin/sweep-repos-test.sh` (new), `HOME/.gitconfig`.

### Design decisions
- `.otto.yml` copies claude's `lint`/`test`/`ci` shape at 9614613: `lint` runs the `docs/` markdown-only `find` plus a whitespace check over a scratch copy of `git ls-files --cached --others --exclude-standard`; `test` runs `bin/sweep-repos-test.sh`; `ci` is `before: [lint, test]`. `.otto.yml`.
- Dotfiles has exactly one gitignored path today, `.claude/settings.local.json`, and it is already whitespace-clean, so the literal `whitespace --check -r .` and the scratch-copy form agree right now. Used the scratch-copy form anyway, to match the claude sibling and because it costs nothing today and covers a future gitignored bucket (a new `.claude/` cache dir, a local override file) the way claude's does. `.otto.yml:lint`.
- `bin/sweep-repos-test.sh` follows `claude/HOME/.claude/hooks/lib-test.sh`'s `eq()` PASS/FAIL style: one case, `sweep-repos --help` exits 0, proving the harness before Phase 3 adds the orphan-pass matrix. `bin/sweep-repos-test.sh`.
- `HOME/.gitconfig:60,63`: dropped the trailing space after `helper = ` (an empty-string credential helper entry) on both `[credential]` blocks. That was the only file `whitespace --check -r .` flagged on the tracked tree today (`(60,63)`).

### Deviations
- None. This phase is scaffold-only, per the design doc's Phase 2 section; no `relocate-targets`-style hardening logic applies here.

### Tradeoffs
- Scratch-copy whitespace check vs the literal `whitespace --check -r .`: the literal form is simpler and passes today, but the scratch-copy form keeps the two sibling `.otto.yml` lint steps textually and behaviorally identical, which is easier to reason about when both repos are touched together (as this design doc does). Cost is one `mktemp -d` + two `tar` pipes per lint run, same as claude pays.

### Open questions
- None.

## Phase 3: Orphan sweep in sweep-repos

Repo: `scottidler/dotfiles`. Files: `HOME/bin/sweep-repos`, `bin/sweep-repos-test.sh`, `manifest.yml` (comment only).

### Design decisions
- The pass is split in two: `sweep_orphans()` owns the kill switch, the default-root scope check, the mount guard and `DEST/.relocate.lock` (opened, taken, and closed on every return), and `orphan_pass()` does steps 4-9 with the lock held. A single close after `orphan_pass` returns covers every abort path. `sweep-repos:sweep_orphans`, `sweep-repos:orphan_pass`.
- Classification is its own function, `orphan_keep_reason()`, which prints why a candidate is owned and fails when nothing owns it. It runs in a subshell, so the `.cargo-lock` fds are opened afterwards in the pass's own shell, where they stay open through the `rm`. `sweep-repos:orphan_keep_reason`.
- Every orphan-pass caller wraps it in `||`, which turns `set -e` off inside it (bash ignores errexit in an `||` context, function bodies included). Every status in the pass is therefore checked explicitly, and no step relies on errexit.
- The live set is built from link paths first, deduplicated with `realpath -ms`, then resolved once. The git enumeration and the `fd` scan both report the same link, so resolving per source would count one dangling link twice. `dangling=1` in the missing-middle case depends on this.
- The enumeration adds every `<repo>/target` that exists or is a link, plain dirs included, not links only. A plain dir's `readlink -f` is its own local path, which cannot match a DEST candidate. Resolving it anyway covers the "symlinked parent" case the design names.
- `LAST_ORPHAN_RUN` also advances on `orphan pass disabled` and on the non-default-root skip, not only on a completed pass. Both outcomes are fixed for the life of the process (env and args are read once at startup). Without the advance, a watchdog running with the default `SWEEP_ORPHANS=0` would log `orphan pass disabled` every 30s. An abort does not advance it, so a broken discovery retries each tick, with its toast limited by `LAST_ORPHAN_NOTIFY`. `sweep-repos:sweep_orphans`.
- `list_manifests` now finishes enumerating after one `.bare` fails, then returns 1. Before, errexit killed the loop at the first failing `.bare`, so the ladder silently skipped every worktree repo after it. The ladder's callers still ignore the status, and they now see more repos. `sweep-repos:list_manifests`.
- In `--maxsize` mode an aborted orphan pass still runs the cap, then the script exits 1. The rollout dry-run and a hand run both see the failure in the exit code.
- The revision line's `-dirty` checks `sweep-repos` alone (`git diff --quiet HEAD -- <script>`). The dotfiles tree nearly always has unrelated edits, so a whole-repo dirty flag would always be set and tell nothing. A copy outside a git tree logs `revision unknown`.
- `orphan` log lines carry `numfmt --to=iec` of `du -sB1`, not `du -sh`. The same byte count feeds `freed=`, so `du` runs once per orphan.
- Breaker aborts list each would-be orphan in the log before the ERROR, so a tripped breaker can be diagnosed from the journal.
- Test harness: `/proc/locks` cannot show the pass's `.cargo-lock` holder or anyone waiting on it. The kernel hides a lock whose taking pid has exited, and the pass takes its locks through a short-lived `flock(1)`. The lock-through-rm case therefore detects the blocked waiter by `/proc/<pid>/wchan == locks_lock_inode_wait`, polled, and an `rm` shim pauses the pass at the orphan's `rm` over a fifo. `bin/sweep-repos-test.sh:waiter_blocked`.
- Test coverage beyond the listed cases: a worktree deeper than `fd --max-depth 6` with a space in its path, linked to a DEST dir the repo mapping cannot see (only the git enumeration keeps it, which pins the `awk` -> `sed` fix); a stale marker that names a link which no longer resolves keeps nothing and is removed with its target; a repo link that resolves elsewhere is removed; `ORPHAN_MAX=6` clears the six the breaker held; `SWEEP_ORPHANS` unset defaults to disabled; `SWEEP_ORPHANS=yes` exits 2; the revision line appears once; a dry run creates no lock file; the abort raises a critical toast; the breaker toast names the override.

### Deviations
- A dry run opens `DEST/.relocate.lock` read-only, and only if it exists. When the file is absent it takes no lock. The design's `exec 9>>` would create the file, and a dry run creates nothing (same stance as relocate-targets' P5). relocate-targets creates the file before it locks, so an absent file means no run holds it. The remaining race is a relocate starting mid-dry-run, and the worst it can do is add a wrong line to a report that deletes nothing. Non-dry runs use `9>>` as specified.
- Mount guard: `require_dest_mounted` is copied from relocate-targets, but it aborts the pass (`ERROR orphan pass aborted`, toast) and does not exit the script, so the watch loop keeps running. The `--remote` branch is dropped (sweep-repos has no remote mode). A DEST that does not exist on a mounted drive also aborts. Same effect, correct seam.
- Cadence lives in `run_watermark()` (overdue check before the floor check), not in the watch loop. That way "both overdue and below the floor" runs one pass, and the floor is re-measured after it either way. It logs `floor restored: ... after the orphan pass` when the pass alone restored the floor.
- `--dest DIR` is a flag. The `SWEEP_ORPHANS` / `ORPHAN_MAX` / `ORPHAN_INTERVAL` env vars are validated at startup (exit 2 on a bad value), which the design does not spell out.
- `bin/sweep-repos-test.sh` honours a `SWEEP_REPOS` override for mutated copies (same pattern as relocate-targets-test's `RELOCATE_TARGETS`). It is the harness's only hook, and the production script carries none.
- Bite-test output observed (mutated copies under `$TMPDIR`, full matrix, every other case PASS):
  - "live under `c`" line removed: `FAIL  contains live: kept by the live-under-c check / want [yes] / got [no]`, `pass=75 fail=1`
  - repo-mapping block removed: `FAIL  depth > 6: kept by the repo-mapping check / want [yes] / got [no]`, plus `mapping: repo with no target keeps its DEST dir` and `mapping: what remains`, `pass=73 fail=3`
  - breaker block removed: `FAIL  breaker: 6 > ORPHAN_MAX=5 aborts / want [1] / got [0]`, `breaker: zero removals / want [7] / got [1]`, `breaker: toast names the override`, `pass=73 fail=3`
  - extra, cargo-lock fds closed before the `rm`: `FAIL  lock through rm: the waiter blocks ... / want [0] / got [1]`, `waiter acquired only after the dir was gone / want [gone] / got [present]`, `pass=74 fail=2`
  - extra, `sed` reverted to `awk '{print $2}'`: `FAIL  worktree: only old removed / want [o/spaced/target o/wt/main/target ] / got [o/wt/main/target ]`, `pass=75 fail=1`
  - unmutated: `pass=76 fail=0`
- Rollout step 3, run read-only against the live tree on 2026-09-27 (before commit, script at 3edbf98-dirty): `SWEEP_ORPHANS=1 HOME/bin/sweep-repos --maxsize 1000GB --dry-run` -> rc=0, `orphan pass: links=125 live=124 dangling=0`, one `orphan .../tatari-tv/catalog-api/target 173M (dry-run)`, `kept=123 removed=0`. The inventory `comm` listed the same single path (`diff` empty). DEST's 124 target dirs were unchanged afterwards, and no `.relocate.lock` was created. The one `WARN sweep failed for .../Vrtgs/thirtyfour` comes from `cargo sweep` in the cap step (a workspace member's manifest is missing), not from the orphan pass.

### Tradeoffs
- Holding every survivor's `.cargo-lock` from classification through its own `rm` vs re-probing just before each `rm`: holding them costs a few fds per orphan (at most `ORPHAN_MAX` candidates reach the `rm`). In exchange there is no window between check and delete, and the design asks for exactly that.
- Aborts retry every tick vs backing off for `ORPHAN_INTERVAL`: a retry costs one `fd` scan and one pruned `find` (0.14s measured), and the alert stays rate-limited to 15m. Backing off would let a transient failure (git lock contention) hide a leak for a day.
- The watch-mode cadence test uses `timeout 2.5` against `--watch 1` (about three ticks) and asserts `>= 2` passes with `ORPHAN_INTERVAL=0` and exactly 1 with the default. That is a bounded run, not a sync sleep. A slower machine can only lower the tick count, and the assertions leave room for that.

### Open questions
- Rollout steps 2 and 4 (restart `sweep-repos-watchdog.service`, then set `Environment=SWEEP_ORPHANS=1`) are the operator's. The running watchdog is still on the pre-Phase-3 script in memory. Step 3's comparison already matches (above), but it ran on the uncommitted working copy, so it should be re-run after the restart as the doc orders.
- Rollout step 6: `catalog-api`'s root-owned local `target/` still needs `sudo rm -rf` before relocate-targets can link that repo. Once the orphan pass is enabled, it will remove the 173M DEST copy on its first run.
