#!/usr/bin/env bash
# Push an ntfy alert naming the victim of every kernel or systemd-oomd OOM kill.
# Streams the journal, so the alert fires within seconds of the kill instead of
# on swap-watch's 5-minute poll.
set -euo pipefail

NTFY_SEND="$(dirname "$(readlink -f "$0")")/ntfy-send"
host="$(hostname -s)"

notify() {
  "${NTFY_SEND}" --title "$1" --priority high --tag rotating_light "$2" \
    || echo "oom-kill-alert: ntfy-send failed for: $1" >&2
}

kernel_kill() {
  local line="$1" name rss_kb
  name=$(sed -n 's/.*Killed process [0-9]* (\(.*\)) total-vm.*/\1/p' <<< "${line}")
  rss_kb=$(sed -n 's/.*anon-rss:\([0-9]*\)kB.*/\1/p' <<< "${line}")
  notify "OOM kill on ${host}: ${name:-unknown}" \
    "Kernel OOM-killed ${name:-unknown}, anon-rss $(( ${rss_kb:-0} / 1048576 ))G"
}

oomd_kill() {
  notify "oomd kill on ${host}" "$1"
}

LOW_AVAIL_MB=40960
LOW_AVAIL_REPEAT_SEC=600

# Polls every 2s so a runaway that eats 20G/min warns while the box still responds.
low_avail_watch() {
  local last=0 avail_mb now top
  while sleep 2; do
    avail_mb=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)
    now=$(date +%s)
    if [ "${avail_mb}" -lt "${LOW_AVAIL_MB}" ] && [ $(( now - last )) -ge "${LOW_AVAIL_REPEAT_SEC}" ]; then
      top=$(ps -eo rss=,comm= --sort=-rss | head -n 1 | awk '{printf "%s %dG", $2, $1/1048576}')
      echo "w ${avail_mb}MB available, largest process ${top}"
      last=${now}
    fi
  done
}

while read -r source line; do
  case "${source}" in
    k) kernel_kill "${line}" ;;
    o) oomd_kill "${line}" ;;
    w) notify "Memory draining on ${host}" "${line}" ;;
  esac
done < <(
  journalctl -k -f -n0 -o cat | sed -u -n 's/^\(.*Out of memory: Killed process.*\)$/k \1/p' &
  journalctl -f -n0 -o cat _COMM=systemd-oomd | sed -u -n 's/^\(.*[Kk]illed.*\)$/o \1/p' &
  low_avail_watch &
  wait
)
