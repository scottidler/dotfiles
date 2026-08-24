#!/usr/bin/env bash
set -euo pipefail

NTFY_TOPIC="escote-alerts-b6810699"
NTFY_URL="https://ntfy.sh/${NTFY_TOPIC}"
STATE_DIR="${HOME}/.cache/swap-watch"
STATE_FILE="${STATE_DIR}/state"
mkdir -p "${STATE_DIR}"

WARN_PCT=25
CRIT_PCT=50
GROWTH_MB_ALERT=2048

read -r total free < <(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print t, f}' /proc/meminfo)
used_kb=$(( total - free ))
used_mb=$(( used_kb / 1024 ))
pct=0
if [ "${total}" -gt 0 ]; then
  pct=$(( used_kb * 100 / total ))
fi

prev_used_mb=0
prev_state="ok"
if [ -f "${STATE_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
fi

growth_mb=$(( used_mb - prev_used_mb ))

new_state="ok"
if [ "${pct}" -ge "${CRIT_PCT}" ]; then
  new_state="crit"
elif [ "${pct}" -ge "${WARN_PCT}" ]; then
  new_state="warn"
fi

send_alert() {
  local title="$1" msg="$2" priority="$3" tags="$4"
  curl -s -H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: ${tags}" -d "${msg}" "${NTFY_URL}" >/dev/null || true
}

if [ "${new_state}" != "${prev_state}" ]; then
  case "${new_state}" in
    warn) send_alert "Swap climbing on desk" "Swap at ${pct}% (${used_mb}MB used)" "default" "warning" ;;
    crit) send_alert "Swap critical on desk" "Swap at ${pct}% (${used_mb}MB used), risk of OOM" "high" "rotating_light" ;;
    ok)   send_alert "Swap back to normal on desk" "Swap at ${pct}% (${used_mb}MB used)" "low" "white_check_mark" ;;
  esac
fi

if [ "${growth_mb}" -ge "${GROWTH_MB_ALERT}" ]; then
  send_alert "Swap growing fast on desk" "Swap grew ${growth_mb}MB in the last check, now ${used_mb}MB (${pct}%)" "high" "chart_with_upwards_trend"
fi

cat > "${STATE_FILE}" <<EOF
prev_used_mb=${used_mb}
prev_state=${new_state}
EOF
