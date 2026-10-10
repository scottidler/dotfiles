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
