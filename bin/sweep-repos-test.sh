#!/bin/bash
# sweep-repos-test.sh: fixture matrix for HOME/bin/sweep-repos.
#
# Every case gets an isolated HOME whose repos/ (ROOT) is its own tmpfs, and a
# target disk (TD, holding DEST=TD/cargo-target) on a second tmpfs, inside a
# rootless user+mount namespace. DEST's st_dev differs from ROOT's, so the
# mount guard passes, and ROOT is ${HOME}/repos, so the default-root scope
# check passes. sweep-repos prepends ${HOME}/.cargo/bin to PATH, so the cargo
# and cargo-sweep shims live there (a PATH shim alone would lose to the
# installed binary); they log their args, so the ladder runs without cargo.
# PATH shims stand in for notify-send (no desktop toasts) and rm (a pause
# before an orphan's removal). Processes that must reach a state before the
# test acts signal it over a fifo, or, for a blocked flock waiter, show up in
# /proc/locks.
#
# SWEEP_REPOS overrides the script under test, so a mutated copy can prove a
# case bites. eq() PASS/FAIL style matches claude/HOME/.claude/hooks/lib-test.sh.
set -u
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
SR="$(realpath "${SWEEP_REPOS:-${HERE}/../HOME/bin/sweep-repos}")"

if [ -z "${SR_TEST_IN_NS:-}" ]; then
  exec unshare -rm env SR_TEST_IN_NS=1 SWEEP_REPOS="${SR}" bash "$0" "$@"
fi
unset SWEEP_ORPHANS ORPHAN_MAX ORPHAN_INTERVAL

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
bash "$SR" --help >/dev/null 2>&1
eq '--help exits 0' 0 "$?"

command -v fd >/dev/null || { echo "sweep-repos-test: fd not on PATH" >&2; exit 1; }

W="$(realpath "$(mktemp -d "${TMPDIR:-/tmp}/sweep-repos-test.XXXXXX")")"
cleanup() {
  local m
  for m in "$W"/case*/home/repos "$W"/case*/ssd; do umount -l "$m" 2>/dev/null; done
  rm -rf -- "$W"   # regenerable: this run's own mktemp fixtures
}
trap cleanup EXIT

REAL_RM="$(command -v rm)"
SHIMS="$W/shims"
mkdir -p "$SHIMS" "$W/rm-shim"
cat > "$SHIMS/notify-send" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SR_TOASTS"
EOF
cat > "$W/rm-shim/rm" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = "\${SR_PAUSE_ON:-}" ]; then echo ready > "\$SR_READY"; read -r _ < "\$SR_GO"; fi
done
exec "$REAL_RM" "\$@"
EOF
chmod +x "$SHIMS"/* "$W"/rm-shim/*

n=0
fresh() { # fresh [ssd tmpfs options]: sets C H ROOT TD DEST LOG for a new case
  n=$((n + 1))
  C="$W/case$n"
  H="$C/home"
  ROOT="$H/repos"
  TD="$C/ssd"
  DEST="$TD/cargo-target"
  LOG="$C/log"
  mkdir -p "$ROOT" "$TD" "$H/.cargo/bin"
  mount -t tmpfs -o size=64m tmpfs "$ROOT"
  mount -t tmpfs -o "${1:-size=64m}" tmpfs "$TD"
  mkdir -p "$DEST"
  cat > "$H/.cargo/bin/cargo" <<'EOF'
#!/bin/bash
echo "cargo-shim: $*" >> "$SR_LOG"
EOF
  cp "$H/.cargo/bin/cargo" "$H/.cargo/bin/cargo-sweep"
  chmod +x "$H/.cargo/bin/"*
  mkfifo "$C/ready" "$C/go"
  : > "$LOG"
}

# live <rel>: a repo at ROOT/<rel> whose target links to its DEST dir.
live() {
  mkdir -p "$ROOT/$1" "$DEST/$1/target/debug"
  touch "$ROOT/$1/Cargo.toml"
  ln -s "$DEST/$1/target" "$ROOT/$1/target"
}
# orphan <rel>: a DEST target dir nothing links to.
orphan() { mkdir -p "$DEST/$1/target/debug"; echo artifact > "$DEST/$1/target/debug/out"; }

there() { if [ -e "$1" ]; then echo yes; else echo no; fi; }
logged() { grep -c -- "$1" "$LOG"; }
# DEST target dirs, relative, sorted, one line.
targets() { (cd "$DEST" && find . -type d -name target -prune | sed 's|^\./||' | sort | tr '\n' ' '); }
# Orphans the pass reported, relative to DEST.
reported() { grep -o "sweep-repos: orphan $DEST/[^ ]*" "$LOG" | sed "s|.*$DEST/||" | sort | tr '\n' ' '; }

# sr <shim dir> [VAR=VAL ...] -- <args>: exec the script with this case's HOME
# and target disk. It execs so that `sr ... & pid=$!` is the script's own pid.
sr() {
  local extra="$1"; shift
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  exec ${SR_TIMEOUT:+timeout "$SR_TIMEOUT"} env HOME="$H" SR_LOG="$LOG" SR_TOASTS="$C/toasts" \
    SR_READY="$C/ready" SR_GO="$C/go" PATH="${extra:+$extra:}$SHIMS:$PATH" "${envs[@]}" \
    bash "$SR" --target-disk "$TD" "$@" 2>>"$LOG"
}
run() { (sr "$@"); }
# orphans [VAR=VAL ...] [-- extra args]: one-shot orphan pass, the rollout
# vehicle (--maxsize runs the pass, then a cap the cargo shim absorbs).
orphans() {
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  run "" SWEEP_ORPHANS=1 "${envs[@]}" -- --maxsize 1000GB "$@"
}

# waiter_blocked <pid>: wait until pid sleeps in the kernel's flock wait.
# (/proc/locks cannot show it: it hides a lock whose taker has exited, and the
# pass takes its locks through a short-lived flock(1).)
waiter_blocked() {
  local i
  for i in $(seq 250); do
    [ "$(cat "/proc/$1/wchan" 2>/dev/null)" = locks_lock_inode_wait ] && return 0
    sleep 0.02
  done
  return 1
}

cd /

echo "=== the 10:30 incident: live target and its parent survive ==="
fresh
live o/r
orphan o/gone
orphans -- --dry-run; rc=$?
eq 'incident dry-run: exit 0' 0 "$rc"
eq 'incident dry-run: lists only gone' 'o/gone/target ' "$(reported)"
eq 'incident dry-run: removes nothing' 'o/gone/target o/r/target ' "$(targets)"
eq 'incident dry-run: creates no lock file' no "$(there "$DEST/.relocate.lock")"
eq 'incident: revision logged once' 1 "$(logged 'sweep-repos: revision ')"
: > "$LOG"
orphans; rc=$?
eq 'incident: exit 0' 0 "$rc"
eq 'incident: removes only gone' 'o/r/target ' "$(targets)"
eq 'incident: gone parent rmdir-ed' no "$(there "$DEST/o/gone")"
eq 'incident: live target survives' yes "$(there "$DEST/o/r/target/debug")"
eq 'incident: live parent survives' yes "$(there "$DEST/o/r")"
eq 'incident: summary line' 1 "$(logged 'orphan pass: kept=1 removed=1 freed=')"

echo "=== worktree layout ==="
fresh
git init -q --bare "$ROOT/o/wt/.bare"
tree=$(git --git-dir="$ROOT/o/wt/.bare" mktree </dev/null)
commit=$(git --git-dir="$ROOT/o/wt/.bare" -c user.name=t -c user.email=t@t commit-tree -m init "$tree")
git --git-dir="$ROOT/o/wt/.bare" update-ref refs/heads/main "$commit"
git --git-dir="$ROOT/o/wt/.bare" worktree add -q "$ROOT/o/wt/main" main
# Deeper than fd's --max-depth 6 and with a space in its path, linked to a DEST
# dir the repo mapping cannot see: only the git enumeration keeps it.
git --git-dir="$ROOT/o/wt/.bare" worktree add -q -b deep "$ROOT/o/wt/a/b/c/d x" main
for wt in main 'a/b/c/d x'; do touch "$ROOT/o/wt/$wt/Cargo.toml"; done
mkdir -p "$DEST/o/wt/main/target" "$DEST/o/spaced/target"
ln -s "$DEST/o/wt/main/target" "$ROOT/o/wt/main/target"
ln -s "$DEST/o/spaced/target" "$ROOT/o/wt/a/b/c/d x/target"
orphan o/wt/old
orphans; rc=$?
eq 'worktree: exit 0' 0 "$rc"
eq 'worktree: only old removed' 'o/spaced/target o/wt/main/target ' "$(targets)"
eq 'worktree: repo container survives' yes "$(there "$DEST/o/wt")"

echo "=== a candidate that contains a live referent ==="
fresh
live o/r
mkdir -p "$ROOT/x/y" "$DEST/o/c/target/nested"
touch "$ROOT/x/y/Cargo.toml"
ln -s "$DEST/o/c/target/nested" "$ROOT/x/y/target"
orphan o/gone
orphans; rc=$?
eq 'contains live: exit 0' 0 "$rc"
eq 'contains live: kept by the live-under-c check' yes "$(there "$DEST/o/c/target/nested")"
eq 'contains live: the unrelated orphan still removed' no "$(there "$DEST/o/gone")"

echo "=== a live link deeper than --max-depth 6 ==="
fresh
live o/r
deep=d/1/2/3/4/5/6
mkdir -p "$ROOT/$deep" "$DEST/$deep/target/debug"
ln -s "$DEST/$deep/target" "$ROOT/$deep/target"
orphans; rc=$?
eq 'depth > 6: exit 0' 0 "$rc"
eq 'depth > 6: fd does not see the link' '' "$(fd -HI -t l '^target$' --max-depth 6 "$ROOT/d")"
eq 'depth > 6: no marker' no "$(there "$DEST/$deep/.relocate-link")"
eq 'depth > 6: kept by the repo-mapping check' yes "$(there "$DEST/$deep/target/debug")"

echo "=== a link outside ROOT, recorded only in .relocate-link ==="
fresh
live o/r
mkdir -p "$C/elsewhere/proj" "$DEST/ext/proj/target"
ln -s "$DEST/ext/proj/target" "$C/elsewhere/proj/target"
printf '%s\n' "$C/elsewhere/proj/target" > "$DEST/ext/proj/.relocate-link"
orphan ext/stale
printf '%s\n' "$C/elsewhere/stale/target" > "$DEST/ext/stale/.relocate-link"
orphans; rc=$?
eq 'marker: exit 0' 0 "$rc"
eq 'marker: kept by the marker check' yes "$(there "$DEST/ext/proj/target")"
eq 'marker: a stale marker keeps nothing' no "$(there "$DEST/ext/stale/target")"
eq 'marker: the stale marker goes with its target' no "$(there "$DEST/ext/stale")"

echo "=== repo mapping: absent target kept, plain dir or elsewhere removed ==="
fresh
live o/r
mkdir -p "$ROOT/o/nt"
touch "$ROOT/o/nt/Cargo.toml"
orphan o/nt
mkdir -p "$ROOT/tt/cat/target"
touch "$ROOT/tt/cat/Cargo.toml"
orphan tt/cat
mkdir -p "$ROOT/o/else" "$DEST/o/other/target"
touch "$ROOT/o/else/Cargo.toml"
ln -s "$DEST/o/other/target" "$ROOT/o/else/target"
orphan o/else
orphans; rc=$?
eq 'mapping: exit 0' 0 "$rc"
eq 'mapping: repo with no target keeps its DEST dir' yes "$(there "$DEST/o/nt/target")"
eq 'mapping: plain local target/ (catalog-api) removed' no "$(there "$DEST/tt/cat/target")"
eq 'mapping: a repo link resolving elsewhere removed' no "$(there "$DEST/o/else/target")"
eq 'mapping: what remains' 'o/nt/target o/other/target o/r/target ' "$(targets)"

echo "=== --root other than the default ==="
fresh
live o/r
orphan o/gone
mkdir -p "$C/other"
orphans -- --root "$C/other"; rc=$?
eq 'non-default root: exit 0' 0 "$rc"
eq 'non-default root: WARN' 1 "$(logged 'WARN orphan pass needs the default root')"
eq 'non-default root: zero removals' 'o/gone/target o/r/target ' "$(targets)"

echo "=== a .cargo-lock stays held through the rm ==="
fresh
live o/r
orphan o/gone
touch "$DEST/o/gone/target/debug/.cargo-lock"
sr "$W/rm-shim" SWEEP_ORPHANS=1 SR_PAUSE_ON="$DEST/o/gone/target" -- --maxsize 1000GB & pid=$!
read -r _ < "$C/ready"
flock -w 5 "$DEST/o/gone/target/debug/.cargo-lock" \
  -c "if [ -d '$DEST/o/gone/target' ]; then echo present; else echo gone; fi > '$C/at-acquire'" & waiter=$!
waiter_blocked "$waiter"
eq 'lock through rm: the waiter blocks while the pass holds the lock' 0 "$?"
echo go > "$C/go"
wait "$pid"; rc=$?
wait "$waiter"
eq 'lock through rm: exit 0' 0 "$rc"
eq 'lock through rm: waiter acquired only after the dir was gone' gone "$(cat "$C/at-acquire" 2>/dev/null)"

echo "=== watch mode above the floor ==="
fresh
live o/r
SR_TIMEOUT=2.5 run "" SWEEP_ORPHANS=1 ORPHAN_INTERVAL=0 -- --ensure-free 0 --watch 1
ticks=$(logged 'orphan pass: links=')
eq 'watch, ORPHAN_INTERVAL=0: the pass runs every tick' yes "$([ "$ticks" -ge 2 ] && echo yes || echo "no ($ticks)")"
: > "$LOG"
SR_TIMEOUT=2.5 run "" SWEEP_ORPHANS=1 -- --ensure-free 0 --watch 1
eq 'watch, default interval: the pass runs once' 1 "$(logged 'orphan pass: links=')"
eq 'watch, default interval: every tick checked' yes "$([ "$(logged 'nothing to do')" -ge 2 ] && echo yes || echo no)"

echo "=== git worktree list failure ==="
fresh
live o/r
orphan o/gone
mkdir -p "$ROOT/o/bad/.bare"
orphans; rc=$?
eq 'git failure: exit 1' 1 "$rc"
eq 'git failure: WARN names the .bare (orphan pass, then the cap)' 2 "$(logged "WARN git worktree list failed for $ROOT/o/bad/.bare")"
eq 'git failure: aborted' 1 "$(logged 'ERROR orphan pass aborted')"
eq 'git failure: zero removals' 'o/gone/target o/r/target ' "$(targets)"
eq 'git failure: critical toast' 1 "$(grep -c 'orphan pass aborted' "$C/toasts" 2>/dev/null)"

echo "=== empty live set ==="
fresh
orphan o/gone
orphans; rc=$?
eq 'empty live set: aborted' 1 "$(logged 'ERROR orphan pass aborted: live set is empty')"
eq 'empty live set: zero removals' 'o/gone/target ' "$(targets)"

echo "=== breaker ==="
fresh
live o/r
for i in 1 2 3 4 5 6; do orphan "o/g$i"; done
orphans ORPHAN_MAX=5; rc=$?
eq 'breaker: 6 > ORPHAN_MAX=5 aborts' 1 "$(logged 'ERROR orphan pass aborted: 6 orphans > ORPHAN_MAX=5')"
eq 'breaker: zero removals' 7 "$(targets | wc -w)"
eq 'breaker: toast names the override' 1 "$(grep -c 'ORPHAN_MAX=6 ~/bin/sweep-repos --maxsize 1000GB' "$C/toasts" 2>/dev/null)"
orphans ORPHAN_MAX=08; rc=$?
eq 'breaker: ORPHAN_MAX=08 exits 2' 2 "$rc"
eq 'breaker: ORPHAN_MAX=08 zero removals' 7 "$(targets | wc -w)"
orphans ORPHAN_MAX=010; rc=$?
eq 'breaker: ORPHAN_MAX=010 exits 2' 2 "$rc"
eq 'breaker: ORPHAN_MAX=010 zero removals' 7 "$(targets | wc -w)"
orphans ORPHAN_INTERVAL=010; rc=$?
eq 'a leading-zero ORPHAN_INTERVAL exits 2' 2 "$rc"
eq 'leading-zero ORPHAN_INTERVAL: zero removals' 7 "$(targets | wc -w)"
orphans ORPHAN_MAX=6
eq 'breaker: ORPHAN_MAX=6 removes all six' 'o/r/target ' "$(targets)"

echo "=== a .cargo-lock held by a build ==="
fresh
live o/r
orphan o/busy
orphan o/gone
touch "$DEST/o/busy/target/debug/.cargo-lock"
flock "$DEST/o/busy/target/debug/.cargo-lock" -c "echo ready > '$C/ready'; read -r _ < '$C/go'" & holder=$!
read -r _ < "$C/ready"
orphans; rc=$?
echo go > "$C/go"; wait "$holder"
eq 'held cargo lock: exit 0' 0 "$rc"
eq 'held cargo lock: kept' yes "$(there "$DEST/o/busy/target/debug/.cargo-lock")"
eq 'held cargo lock: logged' 1 "$(logged 'held by a cargo build')"
eq 'held cargo lock: an unheld orphan still removed' no "$(there "$DEST/o/gone")"

echo "=== DEST/.relocate.lock held ==="
fresh
live o/r
orphan o/gone
touch "$DEST/.relocate.lock"
flock "$DEST/.relocate.lock" -c "echo ready > '$C/ready'; read -r _ < '$C/go'" & holder=$!
read -r _ < "$C/ready"
orphans; rc=$?
echo go > "$C/go"; wait "$holder"
eq 'relocate lock held: exit 0' 0 "$rc"
eq 'relocate lock held: skip logged' 1 "$(logged 'relocate-targets running, skipping orphan pass')"
eq 'relocate lock held: zero removals' 'o/gone/target o/r/target ' "$(targets)"

echo "=== SWEEP_ORPHANS=0 ==="
fresh
live o/r
orphan o/gone
run "" SWEEP_ORPHANS=0 -- --maxsize 1000GB; rc=$?
eq 'SWEEP_ORPHANS=0: exit 0' 0 "$rc"
eq 'SWEEP_ORPHANS=0: disabled logged' 1 "$(logged 'orphan pass disabled')"
: > "$LOG"
run "" -- --maxsize 1000GB
eq 'SWEEP_ORPHANS unset: disabled by default' 1 "$(logged 'orphan pass disabled')"
eq 'SWEEP_ORPHANS=0: zero removals' 'o/gone/target o/r/target ' "$(targets)"
run "" SWEEP_ORPHANS=yes -- --maxsize 1000GB; rc=$?
eq 'SWEEP_ORPHANS=yes: rejected, exit 2' 2 "$rc"

echo "=== a dangling link with a missing middle component ==="
fresh
live o/r
orphan o/gone
mkdir -p "$ROOT/o/dang"
touch "$ROOT/o/dang/Cargo.toml"
ln -s "$DEST/missing/mid/target" "$ROOT/o/dang/target"
before=$(cd "$DEST" && find . ! -name .relocate.lock | grep -v '^./o/gone' | sort)
orphans; rc=$?
eq 'dangling: exit 0' 0 "$rc"
eq 'dangling: dangling=1 logged' 1 "$(logged 'dangling=1$')"
eq 'dangling: the unrelated orphan removed' no "$(there "$DEST/o/gone")"
eq 'dangling: nothing else touched' "$before" "$(cd "$DEST" && find . ! -name .relocate.lock | sort)"

echo "=== same-device DEST ==="
fresh
live o/r
mkdir -p "$ROOT/dest/o/gone/target"
orphans -- --dest "$ROOT/dest"; rc=$?
eq 'same device: aborted' 1 "$(logged 'ERROR orphan pass aborted: .* same filesystem')"
eq 'same device: zero removals' yes "$(there "$ROOT/dest/o/gone/target")"

echo "=== below the floor: the orphan pass runs before the ladder ==="
fresh size=1100m
live o/r
orphan o/big
head -c 200M /dev/zero > "$DEST/o/big/target/debug/blob"
run "" SWEEP_ORPHANS=1 -- --ensure-free 1; rc=$?
eq 'ordering: exit 0' 0 "$rc"
eq 'ordering: started below the floor' 1 "$(logged 'watermark: 0GiB free')"
eq 'ordering: orphan removed' no "$(there "$DEST/o/big")"
eq 'ordering: floor restored by the orphan pass' 1 "$(logged 'floor restored: .* after the orphan pass')"
eq 'ordering: no age tier ran' 0 "$(logged 'sweeping artifacts older than 14d')"

echo "=== --maxsize runs the orphan pass before the cap ==="
fresh
live o/r
orphan o/gone
orphans; rc=$?
pass_at=$(grep -n 'orphan pass: kept=' "$LOG" | head -1 | cut -d: -f1)
cap_at=$(grep -n 'cargo-shim: sweep --maxsize 1000GB' "$LOG" | head -1 | cut -d: -f1)
eq 'maxsize: exit 0' 0 "$rc"
eq 'maxsize: orphan pass, then the cap' yes "$([ -n "$pass_at" ] && [ -n "$cap_at" ] && [ "$pass_at" -lt "$cap_at" ] && echo yes || echo "no (pass=$pass_at cap=$cap_at)")"

echo "=== the ladder skips a repo whose .cargo-lock a build holds ==="
fresh
live o/busy
live o/idle
touch "$DEST/o/busy/target/debug/.cargo-lock" "$DEST/o/idle/target/debug/.cargo-lock"
flock "$DEST/o/busy/target/debug/.cargo-lock" -c "echo ready > '$C/ready'; read -r _ < '$C/go'" & holder=$!
read -r _ < "$C/ready"
run "" -- --maxsize 1GB; rc=$?
echo go > "$C/go"; wait "$holder"
eq 'live build: exit 0' 0 "$rc"
eq 'live build: busy repo not swept' 0 "$(logged "cargo-shim: sweep --maxsize 1GB $ROOT/o/busy")"
eq 'live build: skip logged with the reason' 1 "$(logged "skipping $ROOT/o/busy: .*held by a cargo build")"
eq 'live build: idle repo still swept' 1 "$(logged "cargo-shim: sweep --maxsize 1GB $ROOT/o/idle")"

echo "=== a .cargo-lock stays held through cargo sweep ==="
fresh
live o/r
touch "$DEST/o/r/target/debug/.cargo-lock"
cat > "$H/.cargo/bin/cargo" <<'EOF'
#!/bin/bash
echo "cargo-shim: $*" >> "$SR_LOG"
echo ready > "$SR_READY"; read -r _ < "$SR_GO"
echo "cargo-shim: done" >> "$SR_LOG"
EOF
run "" -- --maxsize 1GB & pid=$!
read -r _ < "$C/ready"
flock -w 5 "$DEST/o/r/target/debug/.cargo-lock" \
  -c "grep -c 'cargo-shim: done' '$LOG' > '$C/at-acquire'" & waiter=$!
waiter_blocked "$waiter"
eq 'lock through sweep: a build blocks while cargo sweep runs' 0 "$?"
echo go > "$C/go"
wait "$pid"; rc=$?
wait "$waiter"
eq 'lock through sweep: exit 0' 0 "$rc"
eq 'lock through sweep: the build got the lock only after the sweep finished' 1 "$(cat "$C/at-acquire" 2>/dev/null)"

echo "=== still below the floor: the toast names the skipped live build ==="
fresh size=1100m
live o/busy
touch "$DEST/o/busy/target/debug/.cargo-lock"
head -c 200M /dev/zero > "$DEST/o/busy/target/debug/blob"
flock "$DEST/o/busy/target/debug/.cargo-lock" -c "echo ready > '$C/ready'; read -r _ < '$C/go'" & holder=$!
read -r _ < "$C/ready"
run "" -- --ensure-free 1; rc=$?
echo go > "$C/go"; wait "$holder"
eq 'still low: exit 1' 1 "$rc"
eq 'still low: busy repo never swept' 0 "$(logged "cargo-shim: sweep .* $ROOT/o/busy")"
eq 'still low: blob survives' yes "$(there "$DEST/o/busy/target/debug/blob")"
eq 'still low: toast names the skipped repo' 1 "$(grep -c "Skipped (cargo build in progress, retried next check): $ROOT/o/busy\." "$C/toasts" 2>/dev/null)"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
