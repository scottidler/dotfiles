#!/usr/bin/env bash
# primary-host-test.sh: matrix for HOME/bin/primary-host.
# PRIMARY_HOST=path overrides the script under test, so a mutated copy can
# prove a case bites.
set -u
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
PH="$(realpath "${PRIMARY_HOST:-${HERE}/../HOME/bin/primary-host}")"

pass=0
fail=0
eq() {
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "PASS: $1"
  else fail=$((fail + 1)); echo "FAIL: $1 (want '$3', got '$2')"; fi
}
has() {
  case "$2" in *"$3"*) pass=$((pass + 1)); echo "PASS: $1" ;;
    *) fail=$((fail + 1)); echo "FAIL: $1 (want substring '$3', got '$2')" ;; esac
}

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT   # regenerable: this test's own scratch dir

me="$(hostname -s)"
run() { PRIMARY_HOST_MARKER="$1" "${PH}" 2>"${TMP}/err"; echo $?; }

printf '%s\n' "${me}" > "${TMP}/match"
eq "marker matching this host -> 0" "$(run "${TMP}/match")" 0

printf '%s' "${me}" > "${TMP}/nonl"
eq "marker without trailing newline -> 0" "$(run "${TMP}/nonl")" 0

printf 'not-%s\n' "${me}" > "${TMP}/other"
eq "marker naming another host -> 1" "$(run "${TMP}/other")" 1
has "other-host reason names both hosts" "$(cat "${TMP}/err")" "not-${me}"

eq "absent marker -> 1" "$(run "${TMP}/absent")" 1
has "absent-marker reason names the path" "$(cat "${TMP}/err")" "${TMP}/absent"

: > "${TMP}/empty"
eq "empty marker -> 1" "$(run "${TMP}/empty")" 1

printf '%s-extra\n' "${me}" > "${TMP}/prefix"
eq "marker that merely starts with this host -> 1" "$(run "${TMP}/prefix")" 1

echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
