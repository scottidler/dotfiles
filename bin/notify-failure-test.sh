#!/usr/bin/env bash
# notify-failure-test.sh: fixture matrix for HOME/.local/bin/notify-failure.
#
# curl is a stub on PATH that appends its args to a log and exits per a mode
# file (ok | http500 | slow-ok), so no test ever POSTs to ntfy. systemctl is a
# stub too, its output per a sysmode file (running | stopping | error | hang). Retry backoff
# and the clock are overridden by env so the matrix runs in seconds.
# NOTIFY_FAILURE=path overrides the script under test, so a mutated copy can
# prove a case bites (it must sit beside ntfy-send, or copy that too).
set -u
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
NF="$(realpath "${NOTIFY_FAILURE:-${HERE}/../HOME/.local/bin/notify-failure}")"

pass=0
fail=0
eq() {
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "PASS: $1"
  else fail=$((fail + 1)); echo "FAIL: $1 (want '$3', got '$2')"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT   # regenerable: this test's own scratch dir

# New isolated case: fresh state dir, curl stub log, mode.
newcase() {
  CASE="${TMP}/$1"
  mkdir -p "${CASE}/bin" "${CASE}/state"
  : > "${CASE}/curl.log"
  echo ok > "${CASE}/mode"
  cat > "${CASE}/bin/curl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${CASE}/curl.log"
case "\$(cat "${CASE}/mode")" in
  ok) exit 0 ;;
  slow-ok) sleep 1; exit 0 ;;
  http500) echo "curl: (22) The requested URL returned error: 500" >&2; exit 22 ;;
esac
STUB
  chmod +x "${CASE}/bin/curl"
  echo running > "${CASE}/sysmode"
  cat > "${CASE}/bin/systemctl" <<STUB
#!/usr/bin/env bash
case "\$(cat "${CASE}/sysmode")" in
  running) echo running; exit 0 ;;
  stopping) echo stopping; exit 1 ;;
  error) exit 1 ;;
  hang) sleep 30; exit 0 ;;
esac
STUB
  chmod +x "${CASE}/bin/systemctl"
}

# run_nf <unit> [extra env assignments...]
run_nf() {
  local unit="$1"; shift
  env PATH="${CASE}/bin:${PATH}" XDG_STATE_HOME="${CASE}/state" \
    NOTIFY_FAILURE_BACKOFFS="0 0 0" MONITOR_SERVICE_RESULT=exit-code \
    MONITOR_EXIT_STATUS=203 MONITOR_EXIT_CODE=exited "$@" \
    bash "${NF}" "${unit}" 2>>"${CASE}/stderr"
}
posts() { wc -l < "${CASE}/curl.log" | tr -d ' '; }
stamp() { cat "${CASE}/state/notify-failure/$1.stamp" 2>/dev/null || echo none; }

# 1: first failure sends exactly one POST and stamps "<now> 0".
newcase first
run_nf a.service NOTIFY_FAILURE_NOW=1000
eq "first failure: one POST" "$(posts)" "1"
eq "first failure: stamp written" "$(stamp a.service)" "1000 0"

# 2: second failure inside the window sends none; stamp count reads 1.
run_nf a.service NOTIFY_FAILURE_NOW=1100
eq "inside window: still one POST" "$(posts)" "1"
eq "inside window: suppressed count 1" "$(stamp a.service)" "1000 1"

# 3: after the window one more POST that reports the suppressed count.
run_nf a.service NOTIFY_FAILURE_NOW=5000
eq "after window: second POST" "$(posts)" "2"
eq "after window: POST names suppressed count" \
  "$(tail -1 "${CASE}/curl.log" | grep -c '1 further failures suppressed')" "1"
eq "after window: stamp reset" "$(stamp a.service)" "5000 0"

# 4: dedup is per unit.
run_nf b.service NOTIFY_FAILURE_NOW=5001
eq "other unit not suppressed" "$(posts)" "3"

# 5: HTTP 500 three retries (four attempts) leaves no stamp and exits 0.
newcase http500
echo http500 > "${CASE}/mode"
run_nf a.service NOTIFY_FAILURE_NOW=1000; rc=$?
eq "http500: exit 0" "${rc}" "0"
eq "http500: four attempts" "$(posts)" "4"
eq "http500: no stamp" "$(stamp a.service)" "none"

# 6: the POST carries the facts, not journal content.
newcase body
run_nf a.service NOTIFY_FAILURE_NOW=1000
eq "body names result and status" \
  "$(grep -c 'result=exit-code status=203' "${CASE}/curl.log")" "1"
eq "body names the log command" \
  "$(grep -c 'journalctl --user -u a.service -n 20' "${CASE}/curl.log")" "1"

# 6b: with MONITOR_INVOCATION_ID the log command targets that exact run; without
# it, the unit fallback applies.
newcase invocation
run_nf a.service NOTIFY_FAILURE_NOW=1000 MONITOR_INVOCATION_ID=abc123
eq "invocation id: log command names the run" \
  "$(grep -c 'journalctl --user _SYSTEMD_INVOCATION_ID=abc123' "${CASE}/curl.log")" "1"
eq "invocation id: no unit fallback" \
  "$(grep -c -- '-u a.service' "${CASE}/curl.log")" "0"

# 7: a second start while the first is mid-send waits on the lock, then is
# suppressed: one POST, stamp count 1 (not two POSTs).
newcase race
echo slow-ok > "${CASE}/mode"
run_nf a.service NOTIFY_FAILURE_NOW=1000 &
sleep 0.3
run_nf a.service NOTIFY_FAILURE_NOW=1001 &
wait
eq "concurrent start: one POST" "$(posts)" "1"
eq "concurrent start: suppressed count 1" "$(stamp a.service)" "1000 1"

# 8: system stopping: no POST, stamp untouched, journal line on stderr.
newcase stopping
run_nf a.service NOTIFY_FAILURE_NOW=1000
echo stopping > "${CASE}/sysmode"
run_nf a.service NOTIFY_FAILURE_NOW=9000; rc=$?
eq "stopping: exit 0" "${rc}" "0"
eq "stopping: no further POST" "$(posts)" "1"
eq "stopping: stamp unchanged" "$(stamp a.service)" "1000 0"
eq "stopping: journal line" \
  "$(grep -c 'a.service: suppressed (system stopping)' "${CASE}/stderr")" "1"

# 9: probe error (no output, exit 1): fails open, alert sent.
newcase probe-error
echo error > "${CASE}/sysmode"
run_nf a.service NOTIFY_FAILURE_NOW=1000
eq "probe error: alert sent" "$(posts)" "1"
eq "probe error: stamp written" "$(stamp a.service)" "1000 0"

# 10: probe hang: the 5s timeout fires, alert sent, script returns in ~6s.
newcase probe-hang
echo hang > "${CASE}/sysmode"
t0=$(date +%s)
run_nf a.service NOTIFY_FAILURE_NOW=1000
elapsed=$(( $(date +%s) - t0 ))
eq "probe hang: alert sent" "$(posts)" "1"
eq "probe hang: returned within 7s" "$([ "${elapsed}" -le 7 ] && echo yes || echo "no (${elapsed}s)")" "yes"

echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
