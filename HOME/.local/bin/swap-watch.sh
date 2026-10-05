#!/usr/bin/env bash
set -euo pipefail

NTFY_SEND="$(dirname "$(readlink -f "$0")")/ntfy-send"
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
DISK_SWAP_CAP_MB=16384
WARN_MB=8192
CRIT_MB=14746
FULL_MB=16000             # >99% of disk swap — system is about to seize
GROWTH_MB_ALERT=512
PSI_FULL_CRIT=5.0         # % of the last 60s with ALL tasks stalled on memory
# Disk swap bytes alone are not pressure: pages parked after a past spike sit
# there until faulted back. Ignore the byte tiers while RAM is plentiful and
# PSI is quiet; PSI_FULL_CRIT above still escalates on its own.
AVAIL_OK_MB=20480
PSI_QUIET=${PSI_FULL_CRIT}   # no cliff below the PSI escalation point

# Re-alert cadence: fire 🚨 every CRIT_REPEAT_INTERVAL checks while in crit/full
# Timer runs every 5min, so 3 checks = every 15 minutes
CRIT_REPEAT_INTERVAL=3

disk_used_mb=$(swapon --show=NAME,USED --bytes --noheadings 2>/dev/null \
  | awk -v dev="${DISK_SWAP_DEV}" '$1==dev{printf "%d", $2/1024/1024}')
disk_used_mb=${disk_used_mb:-0}

psi_full_avg60=$(awk '/^full/{for(i=1;i<=NF;i++) if ($i ~ /^avg60=/){split($i,a,"="); print a[2]}}' /proc/pressure/memory 2>/dev/null)
psi_full_avg60=${psi_full_avg60:-0}

# Load previous state
prev_used_mb=0
prev_state="ok"
crit_checks=0
if [ -f "${STATE_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
fi

growth_mb=$(( disk_used_mb - prev_used_mb ))

# Determine new state (three tiers: ok / warn / crit / full)
new_state="ok"
if [ "${disk_used_mb}" -ge "${FULL_MB}" ]; then
  new_state="full"
elif [ "${disk_used_mb}" -ge "${CRIT_MB}" ]; then
  new_state="crit"
elif [ "${disk_used_mb}" -ge "${WARN_MB}" ]; then
  new_state="warn"
fi

avail_mb=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)
avail_mb=${avail_mb:-0}
ram_quiet=0
if [ "${avail_mb}" -ge "${AVAIL_OK_MB}" ] && awk -v v="${psi_full_avg60}" -v t="${PSI_QUIET}" 'BEGIN{exit !(v<t)}'; then
  ram_quiet=1
  new_state="ok"
fi

psi_crit=0
if awk -v v="${psi_full_avg60}" -v t="${PSI_FULL_CRIT}" 'BEGIN{exit !(v>=t)}'; then
  psi_crit=1
  # PSI critical escalates to at least crit
  if [ "${new_state}" = "ok" ] || [ "${new_state}" = "warn" ]; then
    new_state="crit"
  fi
fi

send_alert() {
  local title="$1" msg="$2" priority="$3" tags="$4"
  local tag_args=() t
  IFS=, read -ra tag_list <<< "${tags}"
  for t in "${tag_list[@]}"; do tag_args+=(--tag "${t}"); done
  "${NTFY_SEND}" --title "${title}" --priority "${priority}" "${tag_args[@]}" "${msg}" \
    || echo "swap-watch: ntfy-send failed for: ${title}" >&2
}

# --- State transition alerts ---
if [ "${new_state}" != "${prev_state}" ]; then
  crit_checks=0  # reset repeat counter on any transition
  case "${new_state}" in
    warn)
      send_alert "Disk swap climbing on desk" \
        "Disk swap (/swap.img) at ${disk_used_mb}MB -- zram overflow tier filling" \
        "default" "warning"
      ;;
    crit)
      if [ "${psi_crit}" -eq 1 ]; then
        send_alert "Memory pressure critical on desk" \
          "PSI full avg60=${psi_full_avg60}% (tasks stalled on memory), disk swap ${disk_used_mb}MB" \
          "high" "rotating_light"
      else
        send_alert "Disk swap critical on desk" \
          "Disk swap (/swap.img) at ${disk_used_mb}MB, risk of OOM" \
          "high" "rotating_light"
      fi
      ;;
    full)
      send_alert "🚨 DISK SWAP FULL on desk — INTERVENE NOW" \
        "Disk swap at ${disk_used_mb}/${DISK_SWAP_CAP_MB}MB (>99%), PSI full=${psi_full_avg60}%. System will seize without intervention. Kill Firefox/Zoom or reboot." \
        "urgent" "rotating_light,skull"
      ;;
    ok)
      send_alert "Swap back to normal on desk" \
        "Disk swap (/swap.img) at ${disk_used_mb}MB, PSI full avg60=${psi_full_avg60}%" \
        "low" "white_check_mark"
      ;;
  esac
fi

# --- Still-critical / still-full repeating alarm ---
if [ "${new_state}" = "${prev_state}" ]; then
  if [ "${new_state}" = "crit" ] || [ "${new_state}" = "full" ]; then
    crit_checks=$(( crit_checks + 1 ))
    if [ $(( crit_checks % CRIT_REPEAT_INTERVAL )) -eq 0 ]; then
      if [ "${new_state}" = "full" ]; then
        send_alert "🚨 STILL FULL — desk swap ${disk_used_mb}MB (check #${crit_checks})" \
          "Disk swap STILL at ${disk_used_mb}/${DISK_SWAP_CAP_MB}MB, PSI full=${psi_full_avg60}%. Unresolved for $((crit_checks * 5))min. INTERVENE." \
          "urgent" "rotating_light,skull"
      else
        send_alert "🚨 Still critical — desk swap ${disk_used_mb}MB (check #${crit_checks})" \
          "Disk swap still at ${disk_used_mb}MB (crit >${CRIT_MB}MB), PSI full=${psi_full_avg60}%. Unresolved for $((crit_checks * 5))min." \
          "high" "rotating_light"
      fi
    fi
  fi
fi

# --- Growth alert (escalated if already in crit/full) ---
if [ "${growth_mb}" -ge "${GROWTH_MB_ALERT}" ] && [ "${ram_quiet}" -eq 0 ]; then
  if [ "${new_state}" = "crit" ] || [ "${new_state}" = "full" ]; then
    send_alert "🚨 Swap surging while critical on desk" \
      "Disk swap grew ${growth_mb}MB in the last check, now ${disk_used_mb}MB. Already in ${new_state} state." \
      "high" "rotating_light,chart_with_upwards_trend"
  else
    send_alert "Disk swap growing fast on desk" \
      "Disk swap grew ${growth_mb}MB in the last check, now ${disk_used_mb}MB" \
      "high" "chart_with_upwards_trend"
  fi
fi

cat > "${STATE_FILE}" <<EOF
prev_used_mb=${disk_used_mb}
prev_state=${new_state}
crit_checks=${crit_checks}
EOF
