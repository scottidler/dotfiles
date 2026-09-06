#!/usr/bin/env bash
set -euo pipefail

NTFY_TOPIC="escote-alerts-b6810699"
NTFY_URL="https://ntfy.sh/${NTFY_TOPIC}"
STATE_DIR="${HOME}/.cache/swap-watch"
STATE_FILE="${STATE_DIR}/state"
mkdir -p "${STATE_DIR}"

# Disk-backed swap is the overflow tier only. zram-generator (see dotfiles
# manifest.yml) caps zram at 8G physical / 16G logical, swap-priority=100,
# vm.swappiness=100 -- so filling zram is cheap and by design. /swap.img
# sits at priority -1 and only takes pages once zram is full; PSI is the
# ground truth for whether anything is actually stalling on memory. Alerting
# on raw total-swap% (old behavior) false-positived every time zram filled
# as intended. Track disk-swap bytes and PSI instead.
DISK_SWAP_DEV="/swap.img"
WARN_MB=512
CRIT_MB=4096
GROWTH_MB_ALERT=512
PSI_FULL_CRIT=5.0 # % of the last 60s with ALL tasks stalled on memory

disk_used_mb=$(swapon --show=NAME,USED --bytes --noheadings 2>/dev/null \
  | awk -v dev="${DISK_SWAP_DEV}" '$1==dev{printf "%d", $2/1024/1024}')
disk_used_mb=${disk_used_mb:-0}

psi_full_avg60=$(awk '/^full/{for(i=1;i<=NF;i++) if ($i ~ /^avg60=/){split($i,a,"="); print a[2]}}' /proc/pressure/memory 2>/dev/null)
psi_full_avg60=${psi_full_avg60:-0}

prev_used_mb=0
prev_state="ok"
if [ -f "${STATE_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
fi

growth_mb=$(( disk_used_mb - prev_used_mb ))

new_state="ok"
if [ "${disk_used_mb}" -ge "${CRIT_MB}" ]; then
  new_state="crit"
elif [ "${disk_used_mb}" -ge "${WARN_MB}" ]; then
  new_state="warn"
fi

psi_crit=0
if awk -v v="${psi_full_avg60}" -v t="${PSI_FULL_CRIT}" 'BEGIN{exit !(v>=t)}'; then
  psi_crit=1
  new_state="crit"
fi

send_alert() {
  local title="$1" msg="$2" priority="$3" tags="$4"
  curl -s -H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: ${tags}" -d "${msg}" "${NTFY_URL}" >/dev/null || true
}

if [ "${new_state}" != "${prev_state}" ]; then
  case "${new_state}" in
    warn) send_alert "Disk swap climbing on desk" "Disk swap (/swap.img) at ${disk_used_mb}MB -- zram overflow tier filling" "default" "warning" ;;
    crit)
      if [ "${psi_crit}" -eq 1 ]; then
        send_alert "Memory pressure critical on desk" "PSI full avg60=${psi_full_avg60}% (tasks stalled on memory), disk swap ${disk_used_mb}MB" "high" "rotating_light"
      else
        send_alert "Disk swap critical on desk" "Disk swap (/swap.img) at ${disk_used_mb}MB, risk of OOM" "high" "rotating_light"
      fi
      ;;
    ok)   send_alert "Swap back to normal on desk" "Disk swap (/swap.img) at ${disk_used_mb}MB, PSI full avg60=${psi_full_avg60}%" "low" "white_check_mark" ;;
  esac
fi

if [ "${growth_mb}" -ge "${GROWTH_MB_ALERT}" ]; then
  send_alert "Disk swap growing fast on desk" "Disk swap grew ${growth_mb}MB in the last check, now ${disk_used_mb}MB" "high" "chart_with_upwards_trend"
fi

cat > "${STATE_FILE}" <<EOF
prev_used_mb=${disk_used_mb}
prev_state=${new_state}
EOF
