# Design Document: Cargo Target SSD Leak (relocate-targets hardening + orphan sweep)

**Author:** Scott Idler (drafted with Claude)
**Date:** 2026-09-27
**Status:** Implemented
**Review Passes Completed:** 5/5 (+ review-panel rounds 1 and 2)

## Summary

- `/media/saidler/intel-480gb-ssd` hit 0 bytes free at 02:03 on 2026-09-27.
- Cause: `relocate-targets`' nightly cron tar-copied a 53G `target/` onto a disk with 46GiB free, then left the partial copy on the SSD when tar failed.
- The first draft of this doc blamed orphan dirs and a stray `CARGO_TARGET_DIR`. The second is fabricated and the first is 173M today. The manual cleanup built on that diagnosis deleted live targets.
- Fix the generator first (`relocate-targets`: free-space precheck, clean up its own partial copy, repair dangling links, shared lock). Then add a fail-closed orphan sweep to `sweep-repos` as the backstop for whatever the generator still leaks (SIGKILL, power loss, a hand-made dir).

## Problem Statement

### Background

- `relocate-targets` (`claude/HOME/.claude/skills/relocate-targets/scripts/relocate-targets`, 259 lines)
  - cron `0 2 * * * /home/saidler/bin/relocate-targets >> ~/.cache/relocate-targets.log` (`claude/manifest.yml:89-99`), no args -> `ROOT=~/repos`, `DEST=/media/saidler/intel-480gb-ssd/cargo-target` (:35-36)
  - per repo: `<repo>/target` -> `DEST/<rel>/target`, `rel` = repo path under ROOT (:176-177)
  - `target/` is a plain dir (not a link) -> `migrate()` tar-pipes it to DEST, verifies entry counts, removes source, symlinks (:124-170, :209-210)
  - never hardened since 2026-07-05 (`f3d6a03`)
- `sweep-repos` (`dotfiles/HOME/bin/sweep-repos`, 347 lines), run as `sweep-repos-watchdog.service`: `ExecStart=%h/bin/sweep-repos --ensure-free 40 --watch 30`
  - every 30s: `df` on `TARGET_DISK` (:79, :178-180); below 40GiB -> `cargo sweep --time` 14d/7d/3d/1d, then a 20GB per-repo cap (:282-325)
  - only touches repos whose `target` symlink resolves onto `TARGET_DISK` (`ONLY_RELOCATED`, :108, :235, :251, :329)
  - worked correctly all day (journal); PID 2308 active since 2026-09-25 20:38
- Both scripts enumerate forward only: `~/repos` -> `Cargo.toml` / `.bare` worktrees -> that repo's `target`. Neither ever lists DEST.

### What happened on 2026-09-27 (evidence)

| Time | Source | Event |
|------|--------|-------|
| 01:59:47 | watchdog journal | `46GiB free`, nothing to do |
| 02:00 | `~/.cache/relocate-targets.log` | `[scottidler/second-brain/described-tag-classification] migrating 53G -> drive` |
| 02:00:17 | watchdog | `37GiB < 40GiB floor`, ladder starts |
| 02:02:51 -> 02:03:23 | watchdog | 3GiB -> 0GiB |
| ~02:03 | relocate log | 3,045 `No space left on device` lines (`tail -n +188698 ~/.cache/relocate-targets.log \| rg -c 'No space left'`), then `ERROR tar pipe failed (read=0 write=2); leaving source in place` |
| 02:04:26 | watchdog | `floor restored: 43GiB >= 40GiB after 20GB cap` |
| 09:20-09:35 | watchdog | held 37-42GiB; `second-brain/main/target` swept live at 09:20:56, 09:24:29, 09:34:38 |
| ~10:30 | watchdog | free 40 -> 401GiB: ~361G deleted by hand, on the orphan diagnosis |
| 12:27-12:32 | watchdog | ~55GiB consumed: described-tag-classification linked into DEST and rebuilt |

- The 10:30 manual delete removed `DEST/otto-rs/otto` and `DEST/scottidler/second-brain/main`, the parent dirs of live targets. Both symlinks went dangling (`cargo check` -> `Not a directory (os error 20)`, exit 101). Repaired by hand the same day, together with 54 other dangling links (56 total). The 56 count is from that session and can no longer be re-measured.
- Run 73 of the cron (~2026-09-01, counted back from today; the log has no timestamps) failed the same way on `second-brain/main` (266G) plus mcp-io-rs, pagerduty-cli, renew. Someone cleaned up by hand before run 74. **This is the second occurrence.**

### Problem

Defects in `relocate-targets`, each verified by reading the code:

- **P1: no free-space check.** The `du` at :207 only feeds a log line. It started a 53G copy into 46GiB.
- **P2: a failed copy leaks.** `migrate()` does `mkdir -p "${dst}"` (:152). On tar failure (:153-156) or an entry-count mismatch (:162-165) it returns 1 and leaves `${dst}` behind. Nothing links to it, and nothing ever deletes it.
- **P3: a leak blocks that repo forever.** Next run: `dest already exists, leaving ... on OS disk` (:203-205). The repo builds on `/` (93% full, 67G free) until a human intervenes.
- **P4: dangling links are never repaired.**
  - Link with a missing middle component: `readlink -f` -> empty -> `WARN ... not into DEST; leaving alone` (:183).
  - Link with only the final component missing: resolves into DEST -> `return 0` "already done" (:182). Cargo then fails with os error 20.
  - 46-47 of these WARNs were logged every night from run 80 to run 99, to a log file nobody reads.
- **P5: `--dry-run` mutates.** `mkdir -p "${dstparent}"` (:139) runs before any `DRY_RUN` check.
- **P6: no lock.** Nothing stops a second run, or a future DEST sweeper, from racing a copy that is still in flight.

Defects in `sweep-repos`:

- **S1: DEST is invisible.** A dir under DEST that no symlink points to is never swept, whatever produced it (P2, SIGKILL mid-copy, a hand-made dir). The same state blocks the repo per P3. Today that is `DEST/tatari-tv/catalog-api/target`: 173M, next to a root-owned local `target/` created 2026-09-18.
- **S2: comment drift.** `dotfiles/manifest.yml:494-499` says `--ensure-free 100` and "5GB per-repo cap". The unit runs 40, and `FALLBACK_CAP="20GB"` (:93).

The first draft's root causes, rechecked:

- **"stray `CARGO_TARGET_DIR` override": not true.**
  - `rg CARGO_TARGET_DIR` over dotfiles, claude/HOME and `~/.cargo/config.toml` finds only prose rejecting the idea. `env | grep CARGO` is empty.
  - The only `target-dir` settings are repo-relative: `awslabs/aws-sdk-rust/.cargo/config.toml:3` and `tatari-tv/slack-cli/.otto.yml:61,65,78`.
- **"orphans filled the disk": not true.** Only 173M of orphans exist today (124 DEST target dirs, 123 live). The 361G deleted at 10:30 included live content.

### Goals

- A relocate that would breach the floor never starts. (P1)
- A relocate that fails leaves nothing on DEST. (P2, P3)
- A dangling `target` link into DEST is repaired on the next nightly run, and the WARN count reaches the desktop. (P4)
- `relocate-targets --dry-run` creates nothing. (P5)
- `sweep-repos` reclaims DEST dirs with no live link, and **structurally cannot** delete a live target or any ancestor of one. (S1)
- The orphan pass fails closed: if live-set discovery errors, comes back empty, or flags more candidates than the breaker allows, it deletes nothing and alerts.

### Non-Goals

- Excluded: `git-tools`' `worktree` CLI owning link create/cleanup (rejected 2026-09-27: covers one creation path, duplicates `relocate-targets`).
- Excluded: a shared `CARGO_TARGET_DIR` (`relocate-targets` header :13-22: per-target build lock contention).
- Excluded: a new timer or daemon. The watchdog is the reactive loop.
- Excluded: remote DEST (`--remote`). The new checks are local-only, same as the existing `dest already exists` check (:203).
- Excluded: finding out what created the 84 dangling links at cron run 35 (late July), and the root-owned `catalog-api/target` (2026-09-18). P4 repair and the S1 sweep close the class whatever the origin.
- Excluded: global `incremental = false` in `~/.cargo/config.toml` (first draft's Phase 3). Dropped by Scott 2026-09-27, see Resolved Decisions and the Addendum measurements.

## Proposed Solution

### Overview

Two scripts in two repos. They share one lock file, one owner-marker contract, and one invariant: nothing under DEST is removed unless it is a leaf `target` dir that no live symlink resolves to, whose owning repo is gone or provably points elsewhere, that no cargo build holds, and that relocate-targets is not mid-copy into.

```
cron 02:00  relocate-targets ──flock DEST/.relocate.lock (exclusive, whole run)──┐
                 precheck free - need >= floor ? migrate : WARN skip             │
                 migrate fails -> rm -rf the dst THIS run created                │
                 dangling link into DEST -> mkdir -p its path                    │
                                                                                 │
watchdog    sweep-repos --ensure-free 40 --watch 30                              │
   below floor, or 24h since last -> orphan pass (flock -n; held -> skip) ──────┘
   below floor -> age ladder 14/7/3/1d -> 20GB cap   (unchanged)
```

### relocate-targets changes (claude repo)

- `--min-free GIB`, default 40 (matches the watchdog floor). Before `migrate()`: `need=$(du -sB1 src)` (allocated bytes, the same measure `df` reports), `avail=$(df -B1 --output=avail DEST)`. If `avail - need < min-free`: `WARN insufficient space for <rel>: need=<n> avail=<a> floor=<f>`, skip. `du` counts each hardlinked inode once and tar keeps hardlinks, so `need` matches what lands on DEST.
- Leak cleanup: the tar and count-mismatch failure paths `rm -rf -- "${dst}"`. This is safe because :203 already guarantees `${dst}` did not exist before this run. Also a `trap` on `INT TERM` that removes the in-flight dst and exits. **Commit point = tar succeeded and the entry-count verify passed.** The trap is armed just before the tar and disarmed at the commit point. The post-commit sequence is reordered so no interruption can leave a complete dst next to a plain local `target/`:
  1. `mv "${src}" "${src}.relocated-$$"` (same dir, same filesystem: an atomic rename)
  2. `ln -s "${ssd}" "${tgt}"`, then append the marker (below). A failed marker write logs WARN; the link is already live.
  3. `rm -rf "${src}.relocated-$$"`
  - Interrupted before 2: `target` is absent, so the repo-mapping rule (sweep step 6) keeps dst and the pre-link branch (:189-195) re-adopts it next run.
  - Interrupted after 2: the link is live.
  - A leftover `target.relocated-*` is removed at the start of that repo's next `relocate_one` (regenerable build output).
  - Result: a plain local `target/` next to a DEST copy only ever means the copy never committed (the `catalog-api` shape), so the DEST copy is a partial and safe to delete.
  - SIGKILL and power loss cannot be trapped; the S1 sweep is the backstop for a pre-commit leak.
- Ownership precheck: skip with `WARN <tgt> not owned by uid $(id -u) (owner=<uid>)` if `stat -c %u` of the local `target/` is not `id -u`. Without it, a root-owned source fails the final `rm -rf "${src}"` (:169) after a full copy. `catalog-api` would hit this.
- Dangling repair: for a `-L` target where `[[ ! -e ]]` and `realpath -m` of the raw `readlink` (no `-f`; a relative link is resolved against the link's parent dir, not the CWD) is under `${DEST}/` (`realpath -m` so `DEST/../..` cannot pass a string-prefix match): `mkdir -p` that path, log `repaired dangling link <tgt>`, `REPAIRED++`. A dangling link pointing outside DEST keeps the existing WARN.
- Owner marker: `.relocate-link` sits beside the link's **referent**, `$(dirname "$(realpath -m <link text>)")/.relocate-link`, not beside `ssd`: `clyde.sav/target` resolves to `DEST/tatari-tv/clyde/main/target`, while its `ssd` would be `.../clyde.sav/target`. One absolute link path per line, append-if-absent, written whenever relocate-targets creates a link (pre-link :193, post-migrate, dangling repair) and on every already-done visit (:182), so every link it enumerates gets recorded. Two links sharing a target both stay recorded. It is the positive ownership record the orphan pass checks (step 6), and it covers links created with `--root <other>` or `--repo`, which no scan of `~/repos` can see. No link into DEST exists outside `~/repos` today (review-panel round 3: `find /home/saidler -xdev`, unlimited depth, excluding repos, `.cache` and Trash -> 0; `/tmp`, `/opt`, `/var/tmp` -> none into DEST).
- Dry-run: move `mkdir -p "${dstparent}"` (:139) after the `DRY_RUN` return.
- Lock: `exec 9>"${DEST}/.relocate.lock"; flock -w 600 9 || { log "ERROR lock held >600s"; toast critical ...; exit 1; }`, taken after `require_dest_mounted` (:217) and a `mkdir -p "${DEST}"` (a missing DEST is a case `dev_of` handles, :82-86). Held until the process exits. It waits rather than failing with `-n`, because the orphan pass holds the lock for seconds and a `-n` would skip that night's run. Skipped under `--dry-run`, so a dry run creates no lock file (P5).
- End of run: if `WARN > 0`, `toast normal` with the count and the log path.
- `claude/.otto.yml:135`: `whitespace -r` -> `whitespace --check -r .`. `-r` rewrites files and exits 0, so it never fails lint. `--check` exits 1 on a dirty tree (dotfiles, 2026-09-27: rc=1). Fixed here so the dotfiles `.otto.yml` in Phase 2 matches its sibling.

### sweep-repos changes (dotfiles repo)

New `sweep_orphans()`, called at the top of `run_watermark()` once free is below floor, before the tier loop. Re-measure `free` after it, and return 0 if the floor is restored. In watch mode it also runs when `now - LAST_ORPHAN_RUN >= ORPHAN_INTERVAL` (env, default 86400s) regardless of free space, including the first tick after start. Without that cadence a leak never clears at today's ~347GiB free, and `catalog-api`'s stray keeps blocking that repo's relocation (P3). The tier loop's early `return 0` (:299-303) is why the first draft's after-the-ladder placement would never run. Also called in `--maxsize` mode before `sweep_maxsize_pass`. Manual `--time` mode keeps its current scope.

Steps, each failure logged `ERROR orphan pass aborted: <why>` plus `toast critical`, with the pass returning without deleting:

1. **Kill switch + scope.** `SWEEP_ORPHANS` env, default `0`. `0` -> log `orphan pass disabled` and return. Also skip with `WARN orphan pass needs the default root` when `ROOT` is not `${HOME}/repos`: candidates come from all of DEST, so a narrowed `--root` would shrink the live set without shrinking the candidates. Set in the unit file (`Environment=SWEEP_ORPHANS=1`) only after the rollout dry-run.
2. **Mount guard.** `--dest DIR` (default `${TARGET_DISK}/cargo-target`). Abort unless `dev_of DEST` differs from `dev_of ROOT`. Copy `dev_of` and `require_dest_mounted` from relocate-targets :83-106.
3. **Lock.** `exec 9>>"${DEST}/.relocate.lock"; flock -n 9`, and `exec 9>&-` on every return path, so watch mode never holds the lock between ticks. If it is held, log `relocate-targets running, skipping orphan pass` and return. This is a skip, not an abort: the next tick retries.
4. **Live set**, the union of:
   - (a) `readlink -f <repo>/target` for every manifest from `list_manifests` (:208-226), hardened in place, not forked: git stderr goes to the journal instead of `/dev/null`, a failed `git worktree list` sets the function's exit status to 1, and paths are parsed with `sed 's/^worktree //'` (the current `awk '{print $2}'` at :214 truncates paths with spaces). The orphan pass reads it with `mapfile -d '' manifests < <(list_manifests)` then `wait $!` for the status (bash >= 4.4); non-zero -> abort. The ladder's callers (:242, :258) keep ignoring the status, so their behavior is unchanged apart from the space fix. relocate-targets' own copy (:235-251) is left alone; it only feeds relocation.
   - (b) `fd -HI -t l '^target$' --max-depth 6 ROOT`, each `readlink -f`'d. Catches links the enumeration misses (`--repo` mode, nested layouts). Measured 0.14s and 124 links on 2026-09-27.
   - Drop empty resolutions (`readlink -f` fails on a link with a missing middle component) and log them as `dangling=<n>`. An empty string in the set would match every candidate as "under live".
   - Abort if the union is empty.
5. **Candidates.** `find DEST -mindepth 2 -type d -name target -prune`. Leaf `target` dirs only; `-prune` stops at the first `target` on every path, so a `target` nested inside another is never listed. `-mindepth 2` (not 3) matters: at 3, find would still descend into a depth-2 `target` and list dirs nested inside it. A depth-2 hit, `DEST/<name>/target`, is the `--repo` outside-ROOT shape (:176). Those are kept with `WARN unknown layout <path>`; none exist today.
6. **Classify** each candidate `c` (`realpath`). Keep it if any of these hold:
   - `c` is in the live set
   - some live path starts with `c/` (live is under `c`)
   - `c` starts with some live path followed by `/` (`c` is under live)
   - `c` is a symlink
   - `c` is not under `DEST/`
   - **owner marker:** any line of `$(dirname c)/.relocate-link` names a symlink whose `readlink -f` equals `c`
   - **repo mapping** (relocate-targets' own `ssd = DEST/<rel>/target`, :177, with `rel` = `c` minus `DEST/` minus `/target`): `ROOT/<rel>` exists AND (`ROOT/<rel>/target` does not exist, OR `readlink -f ROOT/<rel>/target` equals `c` or is under `c/`). An absent `target` is owned because relocate-targets' pre-link branch (:189-195) re-adopts that dir on its next run.
   - What is left is a candidate whose repo path is gone, or whose `ROOT/<rel>/target` is a plain dir (the P3 block: `catalog-api`) or a link resolving elsewhere. Those are the only orphans. Ownership comes from the DEST path itself, so a live link that the scans in step 4 miss (depth > 6, a symlinked parent) is still kept.
   - any `.cargo-lock` found by `find c -maxdepth 3 -name .cargo-lock` (covers `debug/`, `release/`, `<triple>/debug/`) cannot be locked. Each is opened read-only on its own fd (`exec {fd}<"$f"`: no create, no truncate) and `flock -n`'d, and **every such fd stays open and locked through that candidate's `rm -rf`**, then closed. Every fd is closed on every path: reject, breaker abort, dry-run, `rm` failure. A lock that cannot be opened or taken -> keep, and a failed `find` of the lock files -> keep. A cargo that starts after the lock is taken blocks on it, then fails once the dir is gone, which is acceptable for a hand-run build into an unlinked dir. A build into a dir that has no `.cargo-lock` yet is not covered, and the doc claims no more than that.
7. **Breaker.** Abort if more than `ORPHAN_MAX` (env, default 5) candidates survive. That many at once means discovery broke, not that leaks piled up. Today: 1. A legit mass event (several worktrees removed at once) trips it too; the toast names the count and the one-off override `SWEEP_ORPHANS=1 ORPHAN_MAX=<n> ~/bin/sweep-repos --maxsize 1000GB` (a shell run does not inherit the unit's `Environment=`). Orphan-abort toasts use their own `LAST_ORPHAN_NOTIFY` against `NOTIFY_INTERVAL` (:276), so they fire at most every 15m. They cannot share `LAST_LOW_NOTIFY`, which every floor-restored path resets to 0 (:288, :301, :314).
8. **Remove.** For each survivor, log `orphan <c> <du -sh>`. Dry-run stops there. Otherwise `rm -rf -- "$c"` (regenerable, see Security), and only if the `rm` succeeded, remove that candidate's own stale `$(dirname c)/.relocate-link` if present, then `rmdir` each now-empty parent up to, not including, DEST. `rmdir` fails on a non-empty dir, so a parent holding a live target cannot be removed even if the classification is wrong.
9. Log `orphan pass: kept=<k> removed=<r> freed=<bytes>`.

Other `sweep-repos` changes:

- Log the script revision once at startup: `git -C "$(dirname "$(readlink -f "$0")")" rev-parse --short HEAD`, plus a `-dirty` flag.
- `usage()` and header cover `--dest`, `SWEEP_ORPHANS`, `ORPHAN_MAX`, `ORPHAN_INTERVAL`.
- A guard that prunes, not just filters: the candidate `find` excludes `DEST/target` (depth 1) with `-path "${DEST}/target" -prune -o ...`, so a depth-1 `target` is never descended into. It does not exist today.
- `LAST_ORPHAN_RUN`, `LAST_ORPHAN_NOTIFY` and `NOTIFY_INTERVAL` are initialized before the `--maxsize` dispatch (:261-265 exits before :276-277 today; under `set -u` an unset read crashes).
- `LAST_ORPHAN_RUN` advances only on a completed pass (a lock-held skip does not advance it). A tick that is both overdue and below the floor runs one pass. It lives in memory, so each watchdog restart makes the pass due again: one extra `fd` + `find`.
- Fix the `manifest.yml:494-499` comment to 40 / 20GB.

### Evidence gathered during design (zero-code spikes, 2026-09-27)

| Assumption | Command | Observed |
|------------|---------|----------|
| ENOSPC reproducible rootless for fixtures | `unshare -rm bash -c 'mount -t tmpfs -o size=1m tmpfs m; ... tar -C s -cf - . \| tar -C m -xpf -; echo ${PIPESTATUS[*]}'` with a 3MB source | `pipestatus=0 2`, `tar: ./src.bin: Wrote only 5120 of 10240 bytes`: same `read=0 write=2` shape as the 02:03 log line. Works inside the Bash sandbox. |
| cargo holds a lock during a build | build of a crate whose `build.rs` sleeps 20s, then `flock -n target/debug/.cargo-lock true` | `HELD` while building, `FREE after build` |
| live-link scan is cheap | `time fd -HI -t l '^target$' --max-depth 6 ~/repos \| wc -l` | `124`, 0.143s total |
| orphan volume today | DEST scan vs live set | 124 target dirs, 123 live, 1 orphan: `tatari-tv/catalog-api/target` 173M |

### Implementation Plan

Ship order: Phase 1 (claude) -> Phase 2 -> Phase 3 (dotfiles). Phase 1 removes the generator and starts writing owner markers. Phase 3's tests need Phase 2's `.otto.yml` and harness. The lock file is created by whichever script takes it first, so the order between the repos does not break the lock.

#### Phase 1: Harden relocate-targets
**Model:** opus
**Repo:** `scottidler/claude`
- Every change under "relocate-targets changes" above.
- New `claude/bin/relocate-targets-test.sh`. It sits in `bin/`, not in the skill's `scripts/`, so it is never linked into `~/bin`. It follows `HOME/.claude/hooks/lib-test.sh`'s `eq()` PASS/FAIL style. Fixtures run under `unshare -rm` with a tmpfs DEST, so DEST's `st_dev` differs from ROOT's and ENOSPC comes from the kernel, not a stub. Cases:
  - insufficient space -> `WARN insufficient space`, source untouched, no dst created
  - forced ENOSPC mid-tar: `--min-free 0`, DEST tmpfs mounted with `nr_inodes` below the source's entry count, so the byte precheck passes and tar still hits ENOSPC -> exit 0, source intact, `${dst}` absent
  - dangling link (final component missing, and middle component missing) -> link resolves afterwards, `repaired` logged
  - `--dry-run` -> `find DEST -newer <stamp>` empty
  - lock held by a background `flock` released after 2s -> run waits, then migrates; held past a test-shortened `-w` -> exit 1, `ERROR lock held`, nothing migrated
  - ownership: inside `unshare -r` fixture files are uid 0 and `id -u` is 0, so the normal cases pass the check unmodified. A rootless user namespace cannot create a file owned by another uid, so the ownership case puts a `stat` shim first on PATH that reports uid 65534, and expects `WARN ... not owned by`, source untouched.
  - SIGTERM at the commit point: an `ln` shim first on PATH writes `ready` to a fifo and blocks; the test waits for `ready`, sends SIGTERM, then releases the shim -> dst present and complete, `target` absent (not a plain dir), and a second run re-adopts dst via the pre-link branch. No test hook in the production script.
  - a leftover `target.relocated-*` is removed on the next run
  - owner marker written beside the referent on pre-link, migrate, dangling repair and already-done visits; two links sharing one target (the `clyde.sav` shape) both appear, one per line
  - `notify-send` stubbed on PATH, so test runs raise no desktop toasts. Background lock holders signal readiness over a fifo, not a `sleep`.
- Wire into `claude/.otto.yml` `test:` (after the hooks loop, :139-151).
- The skill dir is write-denied in the Bash sandbox. The implementer edits `relocate-targets` with the Edit tool or unsandboxed.
- **Success criteria:**
  - `bash bin/relocate-targets-test.sh` exits 0 with every case PASS
  - removing the new `rm -rf -- "${dst}"` line makes the ENOSPC case FAIL, and reverting the rename-then-link order makes the SIGTERM case FAIL (the tests bite)
  - `otto ci` green in `scottidler/claude`

#### Phase 2: dotfiles test scaffold
**Model:** sonnet
**Repo:** `scottidler/dotfiles`
- Add `.otto.yml` copied from claude's shape. `lint`: the `docs/` markdown-only check (claude `.otto.yml:125-134`) + `whitespace --check -r .`. `test`: `bash bin/sweep-repos-test.sh`. `ci`: both.
- Fix the one file `whitespace --check -r .` flags today (rc=1 on 2026-09-27).
- `bin/sweep-repos-test.sh` with one smoke case: `sweep-repos --help` exits 0. That proves the harness before Phase 3 adds cases.
- **Success criteria:**
  - `otto ci` exits 0 in dotfiles
  - adding a `.txt` under `docs/` makes `otto lint` exit non-zero

#### Phase 3: Orphan sweep in sweep-repos
**Model:** opus
**Repo:** `scottidler/dotfiles`
- Every change under "sweep-repos changes" above.
- Test cases in `bin/sweep-repos-test.sh`. Fixture: ROOT and DEST in separate tmpfs mounts under `unshare -rm`, with ROOT mounted at `${HOME}/repos` under the isolated `HOME`, so the default-root scope check passes. The harness sets an isolated `HOME` (`sweep-repos:75` prepends `${HOME}/.cargo/bin` to PATH, so a PATH shim alone loses to the installed binary) holding a `cargo-sweep` shim that logs its args, so the ladder runs without cargo. `notify-send` is stubbed. Background lock holders signal readiness over a fifo.
  - live `DEST/o/r/target` + its parent `DEST/o/r` + unrelated `DEST/o/gone/target`: dry-run lists only `gone`; a non-dry run removes only `gone` and `rmdir`s `DEST/o/gone`; `DEST/o/r/target` and `DEST/o/r` survive (the 10:30 incident case)
  - worktree layout `DEST/o/wt/main/target` live, `DEST/o/wt/old/target` unlinked -> only `old` removed
  - candidate that contains a live referent: a ROOT link resolving to `DEST/o/c/target/nested`, candidate `DEST/o/c/target` -> kept by the "live under `c`" check
  - live link deeper than `--max-depth 6` (missed by `fd`, no marker), where `ROOT/<rel>/target` exists as a link resolving to `c` -> kept by the repo-mapping check
  - link created outside ROOT, recorded only in `.relocate-link` -> kept by the marker check
  - `ROOT/<rel>` exists with no `target` -> kept; `ROOT/<rel>/target` a plain dir -> removed (the `catalog-api` case)
  - `--root <non-default>` -> `WARN orphan pass needs the default root`, zero removals
  - a candidate's `.cargo-lock` is held by the pass through the `rm`: a background `flock -w 5` on it, started after the pass took it, acquires only after the dir is gone (it records `[ -d c ]` at acquire time: false)
  - watch mode above the floor with `ORPHAN_INTERVAL=0` -> the orphan pass runs; with the default, only once
  - `git worktree list` failure (a corrupt `.bare`) -> `ERROR orphan pass aborted`, zero removals
  - empty live set -> abort, zero removals
  - 6 candidates with `ORPHAN_MAX=5` -> abort, zero removals
  - `c/debug/.cargo-lock` held by a background `flock` -> kept
  - `DEST/.relocate.lock` held -> skip message, zero removals
  - `SWEEP_ORPHANS=0` -> `orphan pass disabled`, zero removals
  - a dangling link with a missing middle component in ROOT -> `dangling=1` logged, the unrelated orphan still removed, nothing else touched
  - same-device DEST (DEST inside ROOT's tmpfs) -> abort
  - ordering: free space below floor, orphan removal alone restores it -> the log shows the orphan pass and no `sweeping artifacts older than 14d` line
  - `--maxsize` mode runs the orphan pass before the cap
- **Success criteria:**
  - `otto ci` exits 0 in dotfiles
  - deleting the "live under `c`" check makes the contains-a-live-referent case FAIL; deleting the repo-mapping check makes the depth > 6 case FAIL
  - deleting the breaker makes the 6-candidate case FAIL

## Acceptance Criteria

- [ ] `bash bin/relocate-targets-test.sh` (claude) exits 0, including a case where tar hits ENOSPC and `${dst}` does not exist afterwards.
  - Observed on main: `No such file or directory` (file does not exist; Phase 1 deliverable). `rg -c 'flock|min-free|avail' relocate-targets` -> no matches, rc=1.
- [ ] `bash bin/sweep-repos-test.sh` (dotfiles) exits 0, including the live-target-plus-parent incident case with both surviving.
  - Observed on main: `No such file or directory`; `rg -c orphan HOME/bin/sweep-repos` -> no matches, rc=1 (Phase 3 deliverable).
- [ ] `otto ci` exits 0 in both `scottidler/claude` and `scottidler/dotfiles`.
  - Observed on main: dotfiles has no `.otto.yml` (`No such file or directory`); claude `.otto.yml` has no `relocate-targets` reference (rg rc=1).
- [ ] After rollout, `SWEEP_ORPHANS=1 ~/bin/sweep-repos --maxsize 1000GB --dry-run` on the live tree lists exactly the DEST target dirs that the independent inventory command below lists, and no others.
  - Inventory (DEST = `/media/saidler/intel-480gb-ssd/cargo-target`): `LC_ALL=C; comm -23 <(find DEST -mindepth 2 -type d -name target -prune | sort) <(fd -HI -t l '^target$' --max-depth 6 ~/repos -x readlink -f | sort -u)`
  - Observed on main (2026-09-27): `/media/saidler/intel-480gb-ssd/cargo-target/tatari-tv/catalog-api/target`, one line, 124 candidates total. Without `LC_ALL=C`, `comm` errors `file 1 is not in sorted order`. `sweep-repos` has no orphan pass yet.

## Resolved Decisions

- **2026-09-27, Scott (recorded by the first draft's session; not re-verified here because the clyde MCP was down):** the DEST cleanup lives in `sweep-repos` (Option A), not in the `worktree` CLI (Option B). Kept: Phase 3 is Option A.
- **2026-09-27, Scott (same provenance):** scope is "most comprehensive fix". That is the reason this doc also changes `relocate-targets`: fixing the generator is the comprehensive fix, and the sweep alone would treat a 173M symptom.
- **2026-09-27, this revision:** the root cause is re-derived from `~/.cache/relocate-targets.log` + the watchdog journal (table above). It replaces the first draft's orphan / `CARGO_TARGET_DIR` diagnosis.
- **2026-09-27, this revision:** no mtime grace period.
  - A dir's mtime does not track writes deeper in its tree.
  - Only two things write into an unlinked DEST target: relocate-targets mid-copy (covered by the lock) and a cargo build pointed there by hand (covered by the `.cargo-lock` probe, verified above).
  - Round 1's C4 asked for a flat grace period. This supersedes it with two direct activity signals plus a breaker. **Round 2, both seats: agree C4 is superseded, conditional on the held `.cargo-lock` (M2) and positive ownership (M1). Both are now in the design.**
- **2026-09-27, this revision:** `rm -rf`, not `rkvr rmrf`, for orphan units. See Security.
- **2026-09-27, Scott: drop global `incremental = false` (option A).** It costs ~13s on every `clyde` edit-rebuild (4.0s -> 16.8s), saves ~13s only on an in-place clean rebuild (35.5s -> 22.6s), gives new worktrees nothing (sccache keys on absolute paths), and did not cause the incident. Both panel seats agreed in round 2. Measurements in the Addendum.
- **2026-09-27, review-panel round 3 (Round 3 section of the same synthesis):** all 3 must-fix folded in: N1 repo mapping also keeps a link resolving to or under `c`; N2 rename-then-link commit sequence; N3 marker beside the referent, one path per line, removed only after a successful `rm`, backfilled on already-done visits. All 8 cheap-wins folded in. Q3 settled on the PATH `ln` shim (staff) over an env test hook, so the production script carries no test hook. Deferred with reasons: `--root <other>` links made before Phase 1 (none exist, checked at unlimited depth); ENOSPC on the marker write (the link is already live; WARN only).
- **2026-09-27, review-panel round 2 (synthesis `/tmp/review-panel/YyescmNv/synthesis.md`, Round 2 section):**
  - 5 must-fix folded in: M1 positive ownership + default-root scope, M2 held `.cargo-lock`, M3 trap commit point, M4 a mutation case that bites, M5 daily cadence
  - 12 cheap-wins folded in: override needs `SWEEP_ORPHANS=1`, own toast limiter, isolated `HOME`, `notify-send` stub, `mkdir -p DEST` before the lock, 3,045 ENOSPC lines, Phase 2 -> 3 order, `realpath -m` containment, `du -sB1`, uid compare, `whitespace --check`, fifo sync
  - 4 deferred/demoted, with reasons: non-`target` symlinks into DEST (nothing creates one: relocate-targets and `git-tools` `worktree migrate` only handle `target`), depth-1 `DEST/target` (does not exist; a one-line guard added anyway), a rollback section (one sentence added), and the docs-lint provenance objection (dropped: it is a house rule)

## Alternatives Considered

### Orphan sweep only (the first draft)
- **Why not chosen:** it leaves the generator in place. Every failed nightly migration would still leak a dir, and the repo would build on `/` until the next below-floor tick deleted the leak. The 02:03 zero-bytes event would still happen, because it came from the copy itself.

### Fix relocate-targets only, no sweep
- **Pros:** smaller. It removes every observed leak path.
- **Cons:** SIGKILL, power loss or OOM mid-copy still leaks, and so does any hand-made dir under DEST. `catalog-api`'s 173M exists today and blocks that repo's relocation. Nothing would ever notice these.
- **Why not chosen:** Scott chose the DEST sweep (Option A). The backstop keeps DEST self-healing.

### Mtime grace period as the activity signal
- **Why not chosen:** it does not track activity. See Resolved Decisions.

### Classify every path under DEST (first draft's step 2)
- **Why not chosen:** it has no defined deletion unit, and a parent dir is exactly what the 10:30 delete got wrong. Leaf `target` dirs + `rmdir` for parents make the parent case structurally impossible.

## Technical Considerations

### Dependencies
- bash, `find`, `fd`, `flock` (util-linux), `stat`, `df`, `du`, `git`; `unshare` + tmpfs for tests only. All present on desk (`command -v` checked 2026-09-27).

### Performance
- Orphan pass: one pruned `find` over DEST (stops at each `target`), one `fd` (0.14s), O(candidates x live) string compares at 124 x 124. It runs below the floor and once per `ORPHAN_INTERVAL` (24h).

### Security / safety
- rm vs rkvr: `rules/safety.md` anchors the regenerable exception on `target` next to `Cargo.toml`. DEST targets have no `Cargo.toml` sibling (the manifest lives in the repo, the target on the SSD), so the rule does not match them by position. They are still cargo build output.
- `rkvr rmrf` would archive them into `/var/tmp/rmrf` on `/`, which is 93% full with 67G free: a 50G orphan would move the incident onto the OS disk.
- Decision: `rm -rf --` with a `# regenerable: cargo build output relocated from <repo>/target` comment at the call site. `safety.md` provides for this case: "A path outside the set that is still regenerable build output gets a trailing `# regenerable` comment on the `rm` stage." Same reasoning as relocate-targets' own `rm -rf "${src}"` (:166-169).
- Blast radius of the orphan pass is bounded five ways: leaf-`target` unit, live-set classification, positive ownership (marker + repo mapping), the breaker, and `rmdir`-only parents.

### Rollout Plan
1. Phase 1 merges -> `manifest` redeploys claude. The next 02:00 cron runs the hardened script. Next morning, check `~/.cache/relocate-targets.log`: `repaired=`/`WARN` counts, and no `ERROR tar pipe` with a leftover dst.
2. Phases 2-3 merge -> `systemctl --user restart sweep-repos-watchdog.service`. The journal shows the revision line and `orphan pass disabled`.
3. `SWEEP_ORPHANS=1 ~/bin/sweep-repos --maxsize 1000GB --dry-run` by hand. Compare its orphan list against the inventory command (Acceptance Criteria). Stop if they differ.
4. Set `Environment=SWEEP_ORPHANS=1` in `dotfiles/HOME/.config/systemd/user/sweep-repos-watchdog.service`, `systemctl --user daemon-reload`, restart.
5. Rollback: `SWEEP_ORPHANS=0` (or remove the `Environment=` line) + restart; relocate-targets reverts by `git revert` + `manifest`. Everything the orphan pass removes is regenerable build output.
6. Operator, one time: `catalog-api`'s root-owned local `target/` needs `sudo rm -rf` (regenerable build output) before relocate-targets can link it. `tatari-tv/clyde.sav/target` and `tatari-tv/clyde/target` share one DEST target and one build lock. Harmless to both scripts; noted only.

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Orphan pass deletes a live target or its parent (the 10:30 incident) | Low | High | leaf-`target` unit, union live set, `rmdir`-only parents, positive ownership, the contains-a-live-referent and depth > 6 fixture cases that fail when their check is removed |
| Live-set discovery silently undercounts | Low | High | git errors fatal, empty set fatal, `fd` union, `ORPHAN_MAX` breaker |
| Orphan pass races an in-flight relocate copy | Med without lock | High | shared `DEST/.relocate.lock`, orphan pass skips while held |
| Hand-run cargo build into an unlinked DEST dir | Low | Low (regenerable) | `.cargo-lock` probe |
| Unmounted SSD reads as empty DEST | Low | High | `dev_of` guard in both scripts |
| Free-space precheck races a concurrent build filling DEST | Med | Med | 40GiB floor margin; the watchdog still reacts every 30s |

## Open Questions

None.

## References
- `claude/HOME/.claude/skills/relocate-targets/scripts/relocate-targets` (full read)
- `dotfiles/HOME/bin/sweep-repos` (full read)
- `~/.cache/relocate-targets.log` (runs 73, 99)
- `journalctl --user -u sweep-repos-watchdog.service` (2026-09-27)
- Review panel round 1 on the first draft: `/tmp/review-panel/YyescmNv/synthesis.md`
- Cargo config `[profile]` precedence: https://doc.rust-lang.org/cargo/reference/config.html#profile
- sccache caveats (incremental, bin/proc-macro not cacheable): https://github.com/mozilla/sccache/blob/main/README.md
- `~/repos/.claude/rules/safety.md` (regenerable set)

## Addendum: first draft (rejected 2026-09-27)
- Diagnosis: orphans + a stray `CARGO_TARGET_DIR`. Both disproved (Problem).
- Mechanism: classify every DEST path by relationship; no deletion unit; Phase 0 spikes. Replaced by the leaf-`target` unit. The spikes already ran (Evidence table).
- Kept from it: the fail-closed live set, `--maxsize` wiring, the before-ladder ordering, the kill switch, and the revision log line.
- Round-1 C3's `--root` shrink was claimed addressed in the first version of this rewrite and was not (round 2, M1). It is closed now by the default-root scope check plus positive ownership.
- Its "all 8 must-fix + 3 cheap-win folded in" claim did not hold. P0 (re-derive the root cause), C1 (skip unknown layouts), C3 (`--root` shrink, awk spaces), D4 (relocate-targets needs a change) and D5 (independent inventory) were missing. All five are addressed in this revision. D5 is covered by the ownership rules, not by the `comm` inventory: that inventory is only an equality check for rollout step 3.

## Addendum: incremental = false measurements (dropped 2026-09-27)

- **Global `incremental = false`** (first draft's Phase 3). Measured 2026-09-27, scratch copies, sccache on:
  - `sdv` (1.4k lines): edit-rebuild 1.20s incremental vs 2.03-2.25s not
  - `clyde` (80k lines, edit in `session` crate): **4.03s vs 16.75s**
  - Disk: a fresh `clyde` build is 2.0G incremental vs 1.3G not. The live `clyde/main` target holds 3.3G of `incremental/` across 114 session dirs (a fresh build has 14), so the bloat is accumulation.
  - What `incremental = false` buys in cache hits (2026-09-27, `clyde` copies, one sccache server on :4227, stats deltas read around each build, cache warmed by one build per mode first):

    | Scenario | incremental on | incremental off |
    |----------|----------------|-----------------|
    | fresh checkout at a new path (a new worktree) | 49.8s | 50.8s, +25 misses (workspace crates miss) |
    | same source path, new target dir | n/a | 51.1s, +25 misses |
    | same source path + same target dir (`cargo clean`, or the target wiped) | 35.5s, +8 refused as incremental | **22.6s, 0 misses** |

  - sccache keys include absolute paths (source and target dir), so workspace crates hit only when both paths match. A new worktree gains nothing. The only gain is rebuilding a wiped target in place, 35.5s -> 22.6s.
  - The first draft's escape hatch is broken: `CARGO_INCREMENTAL=1` with the global `RUSTC_WRAPPER=sccache` fails every build (`sccache: increment compilation is  prohibited.`, rustc `-vV` exit 1).

## Addendum: the tier ladder swept live builds (fixed 2026-09-27)

- **Problem.** The orphan pass holds each candidate's `.cargo-lock` through its `rm`, but the tier ladder (`sweep_pass` `--time`, `sweep_maxsize_pass` `--maxsize`) never checked any lock. With the SSD at its 40GiB floor on 2026-09-27, the watchdog ran `cargo sweep --maxsize 20GB` on `second-brain/main` at 09:00, 09:02, 09:04, 09:06, 09:08, 09:10, 09:13, 09:17, 09:21 and 09:24 (journal). Every `second-brain` release build between 09:08 and 09:25 failed with a missing `.rlib` (`failed to build archive from rlib ... libsb-*.rlib`) or fingerprint (`failed to write .../invoked.timestamp`). This broke the S1 goal ("structurally cannot delete a live target") by another route.
- **Which lock.** cargo 1.98 creates three per profile: `.cargo-lock`, `.cargo-build-lock`, `.cargo-artifact-lock`. All three are held for a whole build. A build with work to do blocks on an externally held `.cargo-lock` ("Blocking waiting for file lock on artifact directory"; measured on a scratch crate, 25s hold -> 50.4s build). A no-op build does not wait, and has nothing to lose. So `.cargo-lock` alone is the right signal, the same file the orphan pass uses.
- **Fix.** `hold_build_locks <repo>/target` takes every `.cargo-lock` under the target (`find -H`, depth 3, covering `<profile>/` and `<triple>/<profile>/`) with `flock -n` and keeps them held through that repo's `cargo sweep`, then releases them. A build that starts mid-sweep waits for the sweep instead of racing it. If any lock is held, or a lock file cannot be listed or opened, the repo is skipped for this pass and logged `skipping <repo>: <reason>`. Every mode goes through this, not just watch mode.
- **Decision: skip, don't sweep, even below the floor.** Sweeping a live build turns a disk-pressure problem into a corrupted build either way, and a skipped repo is retried on the next 30s check. If the ladder still ends below the floor, the existing still-low WARN and critical toast (every 15m) now list the skipped repos: `Skipped (cargo build in progress, retried next check): <repos>.` The operator sees that the space is going into a running build. A build that fills the disk then fails with ENOSPC, a clear error, instead of a missing artifact.
- **Tests.** `bin/sweep-repos-test.sh` adds three cases: a held lock skips that repo and still sweeps the others; the lock stays held through `cargo sweep`, so a waiting build acquires it only after the sweep finishes; a still-low run names the skipped repo in the toast. All 93 assertions pass. Against the pre-fix script, 6 of the new assertions fail.
