## Phase 0: Prove the systemd behavior

### Design decisions
- Guard form is a regular file (zero bytes or a one-line comment) at `notify-failure@.service.d/10-onfailure.conf` | design doc Phase 0 results (d) | both the regular file and a `/dev/null` symlink suppress the top-level `service.d` drop-in; the file tracks cleanly and `manifest`'s recursive `link` handles it without a symlink-to-symlink.
- `NOTIFY_FAILURE_WINDOW` stays at the doc's default 3600 | Phase 0 results (c) | collapses a 12-crashes-in-60s `Restart=always` loop to one alert plus a suppressed count, and the 100ms-RestartSec loop (capped by StartLimit at 5 runs) to one.
- Counted inheritance from the unit-file list, not `show '*'` | Phase 0 results (e) | `show '*'` only returns units currently in memory (59 services) and under-counts the 127 that inherit.
- Probe cleanup used `rkvr rmrf` | the probes were throwaway, but the safety rule routes non-build deletes through it.

### Deviations
- Added measurements beyond (a)-(f): a recursion test with a failing notifier, a `RestartSec=5` crash-loop variant, a comment-only guard file, and `env -i` / in-sandbox variants of (f). Same effect: they size the risk the doc names. Recorded in Phase 0 results.
- The doc's risk table assumes the guard is what prevents notifier recursion. Measured: systemd 259 drops a self-template `OnFailure=` with no guard at all (mechanism observed, not read from source). The guard stays as belt and braces; no design change.
- Probe `ExecStart` needed `$$VAR` and `%%` escapes (systemd expands both before the shell runs). Phase 1's unit or script must account for it.
- Step H ran after the measurements as instructed. A leftover failed `notify-failure@probe-loop.service.service` from the default-RestartSec loop was cleared with `reset-failed`.

### Tradeoffs
- Two crash-loop variants (default 100ms vs `RestartSec=5`) vs one: the default variant ends in about a second at StartLimit, so it says nothing about a 60s window; the `RestartSec=5` variant gives the realistic per-crash rate.
- The probe notifier was instant, so the retry-backoff interaction (a repeat `OnFailure=` while a notifier instance is still retrying) was not exercised. A sleeping probe would test Phase 1's design, not Phase 0's question; left for Phase 1's test.

### Open questions
- None.

## Phase 1: Failure alert (dotfiles)

### Design decisions
- `notify-failure` holds an exclusive `flock` on a per-unit lock file for the whole run (check, POST, retries, stamp) | `HOME/.local/bin/notify-failure` | Phase 0 left the repeat-`OnFailure=` start during retry backoff untested. With the lock, a second instance waits, then reads the stamp the first wrote and is suppressed (one POST, count 1); if the first failed all retries, the second gets its own attempts. Covered by the "concurrent start" test; removing the flock makes it fail.
- Backoff delays and the clock are env-overridable (`NOTIFY_FAILURE_BACKOFFS`, default `5 30 120`; `NOTIFY_FAILURE_NOW`) | `notify-failure` | tests run in seconds without sleeping or faking `date`.
- `ntfy-send` honors `NTFY_URL` as an override, default the shipped topic URL | `HOME/.local/bin/ntfy-send` | one place holds the topic; the override exists for ad-hoc local testing, tests themselves stub `curl` and never POST.
- The unit sets `Environment=NOTIFY_FAILURE_WINDOW=3600` and `TimeoutStartSec=400` | `notify-failure@.service` | the window is per the doc/Phase 0; the timeout covers a flock wait behind a retrying instance plus 4 curls (10s each) and 155s of backoff, so systemd does not kill a legitimate retry.
- `swap-watch.sh` locates `ntfy-send` through `readlink -f "$0"`, and a failed send logs to stderr instead of being swallowed | `swap-watch.sh:send_alert` | the script is run through a symlink; its comma-joined tag strings are split into repeated `--tag` flags. Under `set -e` a failed alert must not abort the swap check, hence the `||` log.
- Guard drop-in is a one-line comment regular file (Phase 0 binding finding). `manifest` links it as a symlink to that file; live `show notify-failure@x.service -p OnFailure` prints `OnFailure=`, so a symlinked regular file masks as well as a direct one.
- New test `bin/notify-failure-test.sh`, wired into `.otto.yml` `test` after the sweep-repos matrix | 15 assertions: first POST + stamp, inside-window suppression with count 1, post-window alert naming the suppressed count and stamp reset, per-unit dedup, HTTP 500 x4 attempts leaves no stamp and exits 0, body content, concurrent start.
- Tests bite, shown by mutation (`NOTIFY_FAILURE=` points at a mutated copy): window check forced false -> 7 failures; `flock` removed -> the 2 concurrent-start assertions fail; stamp written after total failure -> "http500: no stamp" fails.

### Deviations
- Doc says four attempts total as "retried 3 times (5s, 30s, 120s)"; implemented exactly that (1 try + 3 retries), and the test asserts 4 curl calls. No deviation in effect; noted because "HTTP 500 three times" in the criterion is read as the three retries after the first failure.
- The doc says a repeat is "dropped and counted" and the stamp holds the count; a suppressed repeat inside the window does not move the window start (stamp keeps the original epoch), so the window is fixed from the last alert, not sliding. Same effect as the doc's wording, chosen so a perpetual crash-loop still alerts once per hour.
- Manifest `script:` entry `notify-failure` is only `daemon-reload` (links come from `link:`); the entry `swap-watch` does `daemon-reload` plus `enable --now swap-watch.timer`. `enable --now` is idempotent for the already-enabled timer.

### Tradeoffs
- Lock held across retries (a waiter can block up to ~3 minutes) vs lock only around the stamp read/write: the narrow lock would let a second instance run its own POST while the first retries, defeating dedup in exactly the untested case. The long hold is bounded by `TimeoutStartSec`.
- A failed total send leaves the old stamp untouched (suppressed count not carried forward) vs persisting the count: simpler, and the doc specifies "no stamp is written".

### Open questions
- None. Live observation: no non-scope user service is in `failed` right now (`systemctl --user --failed` lists only `.scope` units), so eratosthenes.service, named in the doc as failing, had already recovered; nothing will alert until a unit next fails.

## Phase 2: SessionStart check (claude)
### Design decisions
- Key off stdout only, stderr discarded, always exit 0 - claude `HOME/.claude/hooks/user-units-check.sh` - Phase 0 (f): a bus failure and a `degraded` manager both exit 1; only stdout distinguishes them.
- No in-script `.service` re-filter; `--type=service` is the single mechanism - same file - a redundant filter masked the removed-filter mutation, so the scope test could not bite. With it gone, deleting `--type=service` fails the scope test (verified).
- ExecMainStatus fetched per unit via `systemctl --user show <unit> -p ExecMainStatus --value`, `unknown` if empty.
- Test uses a fake `systemctl` on PATH (modes none/service/scope/buserr); `USER_UNITS_CHECK_HOOK` overrides the hook under test (used for the mutation check).
- claude commit 332643d.
### Deviations
- No `manifest.yml` entry: it links `HOME` recursively, and hooks-preflight.sh has no per-file entry either. The `~/.claude/hooks/user-units-check.sh` symlink does not exist yet (operator step below).
- No `.otto.yml` test-task edit: the task globs `HOME/.claude/hooks/*-test.sh`; only the lint list needed the two files.
### Tradeoffs
- One additionalContext string naming all units vs one entry per unit: matches hooks-preflight's shape.
### Open questions
- OPERATOR: register in `HOME/.claude/settings.json` (write-denied; other session's uncommitted edits) under `hooks.SessionStart`, in an existing matcher group's `hooks` array: `{ "type": "command", "command": "~/.claude/hooks/user-units-check.sh" }`. Then `cd ~/repos/scottidler/claude && manifest -l HOME/.claude/hooks/*.sh HOME/.claude/hooks/*.py | bash` to create the symlink (hooks-preflight will otherwise flag the new hook as unresolved).
- Live run on desk printed nothing (no failed user services at that moment), rc=0.

## Phase 3: DELETE-REF guard (claude)
### Design decisions
- Rule lives in the existing per-statement walk of claude `HOME/.claude/hooks/intent-guard.sh` (`delref_check`), after LN, behind a substring gate (`*rm*|*mv*|*uninstall*`) so a non-delete call pays no `cmdword_is` spawn; heads are confirmed with `cmdword_is` on the heredoc/comment-masked statement, same as every other rule, so all 18 `wrap_shapes` spellings deny.
- References load lazily, once per command (`delref_load`), only when a delete head has at least one resolvable operand. Measured with hyperfine on desk: non-delete `ls -la ~/repos` 114.7 ms (HEAD) vs 114.4 ms (new), 150 runs, no measurable change; `rm -v ~/tmp/<unreferenced>` 115.5 ms -> 184.8 ms (+69 ms, the reference read).
- One awk extractor over all files of a source (`delref_extract unit|desktop|cron`) emits `<path>\t<file>:<line>`; tokens are paths when they start with `/` after stripping systemd exec prefixes `-@:+!|` and a `--flag=`; `%h` expanded in units, `$HOME`/`~/` in cron, `~/` everywhere.
- Cron redirect targets (`>> ~/.cache/x.log`) are not references: a log the job recreates is not something it runs. Crontab `VAR=value` lines are skipped.
- `.crates2.json` resolves `cargo uninstall <pkg>` to `<root>/bin/<bin>` (`-p`, `--package[=]`, `name@ver`, `--bin`, `--root` handled); a package the file does not list maps to its own name; an unparseable file denies.
- Operand resolution (`delref_resolve`): `~`, `~/`, `$HOME`, `${HOME}` expanded, lexical `norm_path`, relative resolved against the hook's accumulated `cur_cwd`. Unknown cwd -> the relative path matches as a path suffix of a reference (over-matches rather than misses). A glob operand matches as a bash pattern.
- Env overrides for every source root, exported for every row of `intent-guard-test.sh` so no row reads the live system: `DELREF_UNIT_DIRS` (bypasses systemd-analyze), `DELREF_SYSTEMD_ANALYZE`, `DELREF_DESKTOP_DIRS`, `DELREF_CRONTAB` (binary, run as `-l`), `DELREF_BIN_DIR`, `DELREF_CARGO_ROOT`, `DELREF_CRATES2`. Fixtures under `mktemp -d ${TMPDIR:-/tmp}/intent-guard-delref.XXXXXX`, removed on EXIT (trap now runs both `pr_cleanup` and `delref_cleanup`).
- Matrix: 476 pass / 0 fail (58 new DELETE-REF assertions incl. the 18-shape sweep). Bite: rule call disabled -> 58 failures (every deny/says row); `*.bak|*.orig|*~` skip removed -> the bak-only allow row fails; `.crates2.json` ignored (name mapping) -> the 5 cargo rows fail.
- Live (desk, no DELREF_* set, unsandboxed): `rm -v ~/.cargo/bin/slack` -> deny "referenced by /home/saidler/.config/systemd/user/slack-deliver.service:6"; `rm -v ~/tmp/definitely-unreferenced-file` -> `{}`.
- claude commit 27179fc.
### Deviations
- Condition/Assert key pattern widened from the doc's `Condition*Path*=`/`Assert*Path*=` to `(Condition|Assert)*(Path|File|Directory)*=`, so `ConditionFileIsExecutable=`, `ConditionFileNotEmpty=` and `ConditionDirectoryNotEmpty=` (which name a path but not the word Path) are references too. Strict superset of the doc.
- A missing `systemd-analyze` or `crontab` binary is an empty source (no user manager / no cron means nothing to break), not a deny; a present binary that errors denies (crontab: unless the output says "no crontab for"). The doc only specified the crontab error case.
- Added `DELREF_CRATES2` beyond the four override kinds named in the phase prompt: the criterion's fixture needs the cargo root to be `~/.local` (so `bin/slack` lands on `%h/.local/bin/slack`) while the live `~/.local/.crates2.json` exists (`slack-cli 0.8.0`, the stale install behind the original 203), so the mapping file must be overridable separately.
### Tradeoffs
- An operand not knowable from the command text (`"$x"`, `$(...)`, `~user`, `..`-relative with unknown cwd) is skipped, not denied: denying every `rm "$tmp"` would make the rule unusable. Same disposition as the LN rule's `$` pairs. Blind spot, alongside the doc's accepted non-shell-delete blind spot.
- Lexical path comparison vs `realpath`: lexical, matching `norm_path`'s contract (never dereference). Deleting a referenced file through a symlinked alias path is not seen; a delete of a `~/bin` symlink's target is.
- `mv` destination is not checked: moving a new binary onto the referenced path is the reinstall shape, asserted as allow.
- Wants/requires dirs are walked like any other (`find -L`), so a hit may be reported at the `*.wants/` link path instead of the unit file; same unit content, still a real file and line.
### Open questions
- None.

## Phase 4: `slack doctor` (slack-cli)
### Design decisions
- `diagnose<S: Systemd>(&Inputs)` is the core, with `Inputs { systemd: Option<&S>, invoked, path_var, follow_ups_path, now, okta: Result<(), String> }` | slack-cli `src/command/doctor.rs:diagnose` | generic DI per the house Rust rule (no `dyn`). The queue and PATH checks touch the filesystem only through injected paths; the Okta probe and clock are injected values.
- `SystemctlUser` runs `systemctl --user show <unit> -p ...` one unit per call; `parse_show` splits on the first `=` only (ExecStart values are full of `=`); `exec_start_path` reads the `path=` field. Linux selection is `cfg!(target_os = "linux").then_some(&SystemctlUser)` in `dispatch`, so the same code compiles on every platform and macOS gets `None` -> one Info.
- Okta check reuses okta-auth's `get_token_noninteractive()` via `auth::authenticator(config)`: valid cached token or a silent refresh is Info; anything else (no cache, expired with no refresh token, refresh rejected) is Error with fix `slack login --device`.
- Queue check reuses `slack::follow_ups::load` (so a malformed queue is an Error, same fail-loud contract as `deliver`); "owes follow-ups" is any follow-up with no `delivered_ts` or `partial`, matching `follow_ups::state`'s Delivering rule.
- `invoked_path()` in `src/command/watch/suggest.rs` widened to `pub(crate)` and reused; both sides of every binary comparison are `canonicalize`d.
- PATH check stops at the invoked binary; every earlier executable `slack` is reported once by canonical path (desk is usrmerge: `/usr/bin/slack` and `/bin/slack` are one file).
- Healthy checks emit Info findings, so the report shows every check that ran, not only problems.
- Exit: findings print first, then `verdict()` returns `Err` on any Error; `lib::exit_code` maps that to 1 (no `SlackErr` in the chain). Same print-then-fail shape as `scheduled deliver`.
- Surface lockstep: `doctor` leaf and `doctor --format` arg added to `src/surface.rs` as `NotAgentFacing`/`CliOnly` (new `DOCTOR_PLUMBING` rationale); `plugin/README.md` surface map regenerated with `BLESS_SURFACE=1`; plugin README's CLI-only sentence names `doctor`. README gets a "Checking it: `slack doctor`" subsection under "Running `deliver` unattended".
- Tests: 28 in `src/command/doctor/tests.rs` (fake `Systemd` recording queries, temp queue files, temp PATH dirs, symlink and usrmerge cases, clap case-insensitive `--format JSON`). Bite, each mutation run then restored: 203 constant changed -> `exec_main_status_203_is_an_error_and_exits_one` fails; PATH `earlier.push` removed -> 3 path tests fail; `verdict` threshold `> 0` -> `> 1` -> 3 exit-code tests fail.
- slack-cli commit 5ef3b4a on branch `add-slack-doctor-and-install-timer`.
### Deviations
- "Stranded" means past `post_at + STRANDED_GRACE_SECS` (120s, two ticks of the minutely timer), not strictly past `post_at`: a set due 10 seconds ago is the timer's next job, and flagging it would make a healthy doctor exit 1.
- Timer check also Warns when enabled but not active (doc: "present and enabled"). Phase 6's gate refuses on "timer not active", so doctor reports the same condition.
- Exit 1 message says "ran and exited 1: reported a queued set that needs a human" AND that exit 1 is also any non-Slack error (`lib::exit_code` returns 1 for any error without a `SlackErr`, e.g. a config load failure), pointing at the journal. The doc's distinction holds; the message does not overclaim.
- `--format` is doctor-local and separate from the global `--output text|json`; `--output` is ignored by doctor.
### Tradeoffs
- `fix` strings name `slack scheduled install-timer`, which lands in Phase 5 on the same branch, vs naming the `contrib/systemd` copy steps that Phase 5 deletes: naming the command that will exist at release keeps the shipped text true.
- `SystemctlUser` unconditional (not `#[cfg]`-gated) vs gated: one code path compiles everywhere and macOS cannot drift into a different build; the struct is never selected off Linux.
### Open questions
- macOS build UNVERIFIED locally: `cargo check --target aarch64-apple-darwin` fails in `ring`'s C build (no Apple toolchain on desk), before reaching slack-cli. The new code has no `#[cfg(target_os)]` items; the only cfg is `#[cfg(unix)]` on `is_executable`, which macOS satisfies. GitHub CI's macOS build job is the proof.
- Should doctor honor the global `--output json` (e.g. map it to `--format json`)? Today it ignores it; `--format` is the single override per the doc's API.
- Live run on desk (debug binary, unsandboxed), rc=0: timer info (installed, enabled, active); service-binary info (`/home/saidler/.cargo/bin/slack` exists) + warn (differs from `target/debug/slack`, expected); last-run info (succeeded 07:04); queue info (0 sets); path warn (bare `slack` runs `~/.cargo/bin/slack`, then `/usr/bin/slack`, ahead of the debug binary, expected since target/debug is not on PATH); okta info.

## Phase 5: `install-timer` + path cleanup (slack-cli)
### Design decisions
- `install-timer` is dispatched at the top of `scheduled::dispatch`, before the Slack transport is built — `src/command/scheduled.rs:dispatch` — it needs no token/login, and a host with a broken install is exactly where it must run. The match arm for it errors rather than `unreachable!`.
- Core is `timer::install(&Plan{unit_dir, exec, dry_run, manager})` with a `UserManager` port (`SystemctlUser` real, `FakeManager` in tests) — `src/command/scheduled/timer.rs` — tests never touch the live user manager or `~/.config`.
- `--dry-run` and the real write share `render_service`/`render_timer`; the target/ refusal runs first, so a refused install writes nothing and makes no systemctl call.
- `ExecStart` word is escaped for systemd (`%`->`%%`, `$`->`$$`, quoted when it holds whitespace/quotes); newline or non-UTF-8 paths are an error — `timer.rs:exec_start_word`.
- Target refusal is "any path component named `target`" on the canonicalized path.
- `config::xdg_config_dir` made `pub` to locate `$XDG_CONFIG_HOME/systemd/user`.
- Surface map: `scheduled install-timer` is `NotAgentFacing` + `CliOnly` (machine-mutating operator action); the skill tells the user to run it. plugin/README.md surface map blessed with `BLESS_SURFACE=1`. Doctor's fix text needed no change (it already says `slack scheduled install-timer`).
- Old `ExecStart` is read from the existing unit file (through a symlink) before replacement and printed as `replaced ExecStart=...`.

### Deviations
- None from the doc's intent. The doc says "canonicalized" invoked_path; done in `dispatch` (the pure `install` takes the already-canonical path so tests can use fake paths).

### Tradeoffs
- Verify test is a normal (not `#[ignore]`d) test vs the doc's fallback. Measured: `systemd-analyze --user verify` fails with "Failed to initialize manager: No such device or address" when `$XDG_RUNTIME_DIR` is unset (a runner has no user session), but passes (exit 0) when the child is given a scratch `XDG_RUNTIME_DIR`, with `env -i` and `HOME=/nonexistent`; verify is offline and never contacts a user manager. A bad ExecStart (nonexistent binary) exits 1, so it bites. Only host requirement: `systemd-analyze` on PATH.
- The GitHub ubuntu-latest runner could not be exercised from here (no push). `.github/workflows/ci.yml` runs plain `cargo test` on `ubuntu-latest` (a full VM image, systemd-based) with no setup that would remove systemd-analyze. UNVERIFIED on a real runner; if the first PR run shows it missing, fall back to `#[ignore]` + `cargo test -- --ignored rendered_units_pass_systemd_analyze_verify` in `.otto.yml`. I chose fail-loud over skip-if-absent.
- Refuse-on-`target/` is a hard error, stricter than eratosthenes' warning, per the doc.

### Open questions
- Confirm the first PR CI run passes the verify test on the ubuntu runner (see Tradeoffs).
- The ExecStart is the invoked path (e.g. a `~/.local/bin/slack` symlink is canonicalized to its real target, per the doc). A later `slack update` that replaces the target file in place keeps working; one that changes the symlink target would not. Phase 7 on desk should run it from the installed release binary.

## Phase 6: Queue-time refusal (code part; release steps left to the orchestrator)
### Design decisions
- The predicate reuses doctor's `check_systemd` findings and filters them (`timer` non-Info, `service-binary` Error, `systemd` Error); `last-run` and the "different build" Warn are ignored — `src/command/write/deliverer.rs:blocks_delivery` — one source of truth for "timer/binary is broken", and exit-1 last runs cannot refuse.
- A host whose user manager cannot be queried refuses (doctor reports the same as Error) — `deliverer::check` — fail closed; `SLACK_SKIP_TIMER_CHECK=1` is the way out and is named in the refusal.
- Typed `NoDeliverer` error, relayed by `SlackMcpServer::map_query_err` as a tool error — `src/mcp.rs` — same Display text on both surfaces; CLI exits 1 via the generic error path.
- Injection is through `Config` (`systemd: SystemdPort`, `skip_timer_check: bool`) — `src/config.rs`, `doctor.rs:SystemdPort` — MCP and CLI both reach `schedule_signed` with only `Config`, so this is the one seam both entries share. `skip_timer_check` is env-only (`SLACK_SKIP_TIMER_CHECK`, parsed with the existing bool-word rule).
- Non-Linux note rides `ScheduledSend.deliverer_note` and is rendered by `schedule::render`, so `schedule_signed` stays free of printing.
- README, `plugin/skills/scheduled/SKILL.md`, `plugin/skills/write/SKILL.md` document the refusal and kill switch (the plugin carries no version lines).
### Deviations
- Doc says "placed before `:122`"; the gate sits after the 120-day span check and before `chat_schedule_message` — same effect (zero Slack calls, queue untouched), and a too-far `--at` still gets its own typed error first.
- Added `#[ignore]`d `live_gate_against_the_host_user_manager` test for the live sanity check. Live run on desk: verdict `Proceed` (timer loaded/enabled/active, ExecStart `~/.cargo/bin/slack` exists, last run success).
### Tradeoffs
- Config-carried port vs adding a parameter to `schedule_signed` and every MCP helper — Config is already threaded through both; a param would have touched every signature on the MCP path.
- Existing test config builders (`write/tests.rs`, `mcp/tests.rs`) now default to a healthy fake rather than the host's systemd, so the suite is hermetic.
### Open questions
- Release must touch: `Cargo.toml`/`Cargo.lock` version (bump), then tatari-skills `marketplace.json` pin for slack-cli `plugin/` (Phase 6 cross-repo step). No version strings in `plugin/` or README to edit.
- Should `chat_schedule_message`'s MCP tool description mention the refusal? Left alone (tool schema text; the error is self-explanatory).

### Phase 6 addendum (supersedes the "unqueryable manager refuses" decision above)
- Deviation: when `systemctl --user show` fails (bus unreachable), the gate no longer refuses. Phase 0 measured that the Claude Code Bash sandbox, or a missing XDG_RUNTIME_DIR, gives "Failed to connect to user scope bus" while the timer is healthy; refusing there would block every sandboxed agent, and an unreachable bus is not evidence that nothing can deliver. `deliverer::check` now falls back to unit files via an injected `Config.unit_dirs` (`UnitDirs { roots, home }`): both units present in `~/.config/systemd/user` or `~/.local/share/systemd/user` (symlinks followed), a `timers.target.wants/slack-deliver.timer` link, and the `ExecStart` binary (first token, `%h` expanded) existing and executable. Refuses only if one fails; "active" is unknowable without the bus and is skipped. Doctor still reports an unreachable bus as an Error, unchanged.
- Live: the ignored live test returns Proceed both sandboxed and unsandboxed on desk, and the unit-file fallback alone reports no blockers on desk's real dirs. The bus is reachable from both on desk (XDG_RUNTIME_DIR is set and systemctl runs outside the sandbox), so the fallback branch is exercised by the hermetic tests plus the direct fallback call, not by a genuinely failed bus.

## Phase 7: Ownership cleanup (dotfiles)
### Design decisions
- `primary-host` reads the marker path from `PRIMARY_HOST_MARKER` (default `${XDG_CONFIG_HOME:-$HOME/.config}/primary-host`), compares its first line, whitespace-stripped, to `hostname -s` by exact equality — `HOME/bin/primary-host` — prefix matches (`desk-extra`) and empty files must not pass; the reason on stderr names the marker path and both hostnames.
- `bin/primary-host-test.sh` takes `PRIMARY_HOST=path` to run a mutated copy, same convention as `notify-failure-test.sh`. Mutation-checked: replacing `exit 1` with `exit 0`, and inverting the comparison, each fail 4 of 8 cases.
- `firefox-volume-keeper.service` and its script moved into `HOME/.config/systemd/user/` and `HOME/.local/bin/` by copying then running `manifest -l <exact paths> | bash` (byte-identical to the live originals, cmp-verified). The linker backed up the live files as `.orig`; after cmp I `rkvr rmrf`'d the two `.orig` files. Left disabled, as it was before (the doc says track it, not enable it).
- Tool-owned installer entries in `manifest.yml` (`aka-daemon`, `git-maintenance`, `slack-deliver-timer`, `clyde-bootstrap`, `eratosthenes-service`, `sb-borg-daemon`, `sb-cortex-daemon`, `sb-borg-harvest`). Each removes a dotfiles symlink for its tool-owned unit (`[ ! -L unit ] || rm -f unit`, a no-op when nothing is linked) before calling the installer. `sb-cortex-daemon` and `sb-borg-harvest` add `daemon-reload` and `enable --now` because those installers only write.
- `primary-host` linked into `~/bin` via scoped manifest run so the `script:` entries resolve it on PATH.
### Deviations
- Entry `sb-cortex-daemon` adds daemon-reload + enable --now. The doc's parenthetical "these two write only" is ambiguous about which two; the orchestrator's instruction named cortex and harvest, so borg daemon (which enables itself) does not get it.
- The `mv` of the firefox files into the repo was blocked by the DELETE-REF guard (the unit references the script), working as designed; used copy + linker (which itself leaves a symlink and a `.orig`) instead.
- Success criterion 1 as written (`systemd-analyze --user verify ~/.config/systemd/user/*.service ~/.config/systemd/user/*.timer`) still exits 1 on desk, but not from anything in this work: the glob includes `org.gnome.SettingsDaemon.Smartcard.service -> /dev/null` (a GNOME mask from 15 Apr), and verify reports `Unit ... is masked` and exits 1. Verified with that one file excluded: exit 0. slack-deliver is clean. Not contorted; the criterion's glob should exclude masked units.
- Acceptance criteria 4 and 5 (`slack doctor --help`, `install-timer --help`, slack-cli rg/contrib) are not met on slack-cli main / installed v0.14.7 (release not merged yet). On branch `add-slack-doctor-and-install-timer` the rg finds nothing and `contrib/systemd` is gone.
### Tradeoffs
- Symlink removal inline in each entry vs a shared helper — the manifest `script:` entries are standalone bash blobs with no common prelude; four lines of duplication beat inventing one.
- Stray-symlink removal vs fail-loud refusal — the doc says remove, and a dotfiles symlink to a tool unit is exactly the state this phase exists to undo.
### Open questions
- Orchestrator to run `slack scheduled install-timer` on desk after the slack-cli release (excluded from this phase), then re-check acceptance criteria 4 and 5 against main.
- Should acceptance criterion 2's glob be amended to skip masked units (or should the GNOME Smartcard mask be removed)? As written it can never pass on this desktop.
- `ydotoold.service` retired via `rkvr rmrf` after confirming `ydotoold` disabled/inactive and `ydotool.service` enabled/active.
