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
