#!/bin/bash
# sweep-repos-test.sh: fixture matrix for HOME/bin/sweep-repos.
#
# Phase 2 lands the harness with one smoke case, proving the scaffold before
# Phase 3 adds the orphan-pass matrix. eq() PASS/FAIL style matches
# claude/HOME/.claude/hooks/lib-test.sh.
set -u

SWEEP_REPOS="$(cd "$(dirname "$0")/.." && pwd)/HOME/bin/sweep-repos"

pass=0
fail=0

eq() { # eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$1"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      want [%s]\n      got  [%s]\n' "$1" "$2" "$3"
  fi
}

echo "=== --help ==="
bash "$SWEEP_REPOS" --help >/dev/null 2>&1
eq '--help exits 0' 0 "$?"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
