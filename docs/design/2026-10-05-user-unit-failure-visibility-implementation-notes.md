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
