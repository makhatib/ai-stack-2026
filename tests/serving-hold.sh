#!/usr/bin/env bash
# tests/serving-hold.sh — the serving lifetime hold (NOM-300).
#
# WHAT WENT WRONG AND WHY IT NEEDED A TEST.
#
# final-design §2.1 requires the lifecycle lock's SHARED mode to be held "for
# as long as that project is up", so that a restore drill is excluded by the
# kernel rather than by a check.  `cmd_up` took the shared mode, started the
# project inside it and then RETURNED, which released it.  With nine services
# healthy, `aistack status` said `free` and `flock -n -x` on the lock exited 0.
# Every service was fine, every other check was green, and the one property
# the drill's safety rests on was absent.  Nothing in the repository measured
# it, which is the whole reason this file exists.
#
# IT NEEDS NO DOCKER, NO ROOT, NO STACK AND NO WINDOW.  It gives bin/aistack
# its own lock directory, its own project name and a stub `docker` it can tell
# to report N containers or to fail outright, and it drives the CLI's own
# arm/release functions.  It never runs `up`, `down` or `compose`, so a live
# stack is neither needed nor touched.
#
# IT REFUSES (exit 2) rather than reporting half a result: if the functions it
# drives are no longer there, if it cannot make a lock directory, or if fewer
# assertions than expected were evaluated.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
AISTACK="$ROOT/bin/aistack"
[ -x "$AISTACK" ] || { echo "  [refuse] no executable $AISTACK"; exit 2; }
command -v flock >/dev/null || { echo "  [refuse] flock is not installed"; exit 2; }

RTDIR="${XDG_RUNTIME_DIR:-/tmp}"
[ -w "$RTDIR" ] || RTDIR=/tmp
WORK="$(mktemp -d "$RTDIR/aistack-hold-test.XXXXXX")" || {
  echo "  [refuse] cannot create a work directory under $RTDIR"; exit 2; }

export AISTACK_RUNDIR="$WORK/rundir"
export COMPOSE_PROJECT_NAME=aistackholdtest
CTL="$WORK/ctl"
LOCK="$AISTACK_RUNDIR/lifecycle.lock"
PIDF="$AISTACK_RUNDIR/serving.holder.pid"
STOPF="$AISTACK_RUNDIR/serving.holder.stop"
ARMF="$AISTACK_RUNDIR/serving.holder.arm"
HLOG="$AISTACK_RUNDIR/serving.holder.log"

# --- the stub docker --------------------------------------------------------
# It answers only the one question the hold asks -- how many containers of the
# project are running -- and it can refuse to answer, which is the state the
# hold must not read as "none".
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'STUB'
#!/bin/sh
mode="$(head -1 "$STUB_CTL" 2>/dev/null)"
if [ "$mode" = err ]; then
  echo "Cannot connect to the Docker daemon (stub)" >&2; exit 1
fi
# `docker ps -a` is a DIFFERENT QUESTION from the one the hold asks.  The hold
# asks how many containers of the project are RUNNING; `_up` asks whether any
# restore-drill container exists at all.  They answer from separate control
# files so that a case can leave a drill container behind without changing how
# many project containers are running -- which is exactly the combination case
# 11 needs.  Cases 1-9 never pass -a, so their answers are unchanged.
for a in "$@"; do
  [ "$a" = "-a" ] || continue
  if [ -n "${STUB_DRILLS:-}" ] && [ -s "$STUB_DRILLS" ]; then cat "$STUB_DRILLS"; fi
  exit 0
done
case "$mode" in
  n:*) c="${mode#n:}"; i=0
       while [ "$i" -lt "$c" ]; do echo "stubcid$i"; i=$((i+1)); done
       exit 0 ;;
esac
echo "stub docker: unknown control '$mode'" >&2; exit 1
STUB
chmod +x "$WORK/bin/docker"
DRILLCTL="$WORK/ctl-drills"
: > "$DRILLCTL"
export STUB_CTL="$CTL"
export STUB_DRILLS="$DRILLCTL"
export PATH="$WORK/bin:$PATH"

say()        { printf 'n:%s\n' "$1" > "$CTL"; }
err_mode()   { printf 'err\n' > "$CTL"; }
drills()     { printf '%s\n' "$@" > "$DRILLCTL"; }   # what `ps -a` reports
no_drills()  { : > "$DRILLCTL"; }

# `. bin/aistack --help` loads the definitions and leaves the dispatch through
# `usage`.  Passing an argument is required: with none, the dispatch would see
# this script's own positional parameters.
load() { . "$AISTACK" --help >/dev/null 2>&1; }
arm()     { ( load; _with_arm_lock _holder_arm ); }
release() { ( load; _with_arm_lock _holder_let_go ); }
# CASE 11 DRIVES THE REAL `cmd_up`, not its pieces.  It can, without a stack,
# because the refusal it is about happens in `_up`'s FIRST check -- before
# `compose up` and before the health gate -- so nothing compose-shaped runs.
# What is under test is the wiring between the two: whether a failure that
# early still reaches `cmd_up`'s release step.
up_cmd()  { ( load; cmd_up ); }

# REFUSE if the thing under test is not there any more, instead of passing on
# a stack of no-ops.
MISSING=""
for fn in _hold_run _holder_arm _holder_let_go _with_arm_lock _holder_pid \
          _serving_count _serving_running cmd_up _up _holder_release_if_idle; do
  ( load; declare -F "$fn" >/dev/null ) || MISSING="$MISSING $fn"
done
if [ -n "$MISSING" ]; then
  printf '  [refuse] bin/aistack no longer defines:%s\n' "$MISSING"
  printf '           The serving lifetime hold was renamed or removed.  If it\n'
  printf '           was replaced (a systemd serving supervisor, say), this\n'
  printf '           test has to be rewritten against the replacement -- not\n'
  printf '           deleted, because the property is in final-design 2.1.\n'
  rm -rf "$WORK"; exit 2
fi

CHECKED=0; FAILED=0
pass() { CHECKED=$((CHECKED+1)); printf '  [ ok ] %s\n' "$*"; }
fail() { CHECKED=$((CHECKED+1)); FAILED=$((FAILED+1)); printf '  [FAIL] %s\n' "$*"; }
chk()  { if [ "$1" = 0 ]; then pass "$2"; else fail "$2"; fi; }

ex_free() {
  # 0 = nothing holds it.
  #
  # A MISSING LOCK FILE IS NOT A HELD ONE, and the distinction only shows up
  # after a reboot.  MEASURED while writing case 10: `flock -n -x` cannot OPEN
  # a file that is not there, so it fails, and the one-line version of this
  # function read that failure as "something holds the lock" — a false green
  # for exactly the state the case is about.  Cases 1-9 always run with the
  # file present, so their verdicts are unchanged.
  [ -e "$LOCK" ] || return 0
  flock -n -x "$LOCK" true 2>/dev/null
}
holder_alive() {
  local p
  [ -f "$PIDF" ] || return 1
  p="$(head -1 "$PIDF" | tr -dc '0-9')"; [ -n "$p" ] || return 1
  [ -r "/proc/$p/cmdline" ] || return 1
  tr '\0' ' ' < "/proc/$p/cmdline" | grep -q 'serving.hold.run'
}
holder_procs() {
  # ONLY THIS FIXTURE'S HOLDERS.  MEASURED: `pgrep -c -f` counted the real
  # stack's hold as well, so the test passed with the stack down and failed
  # with it up — a test whose verdict depends on the machine's unrelated state
  # is worse than no test.  A holder is this fixture's when it has a
  # descriptor on this fixture's lock file, which no other one can have.
  local n=0 p
  for p in $(pgrep -f 'serving.hold.run' 2>/dev/null || true); do
    if ls -l "/proc/$p/fd" 2>/dev/null | grep -q "$LOCK"; then n=$((n+1)); fi
  done
  printf '%s\n' "$n"
}
gone() { [ ! -f "$PIDF" ]; }
wait_until() {   # $1 = seconds, rest = predicate
  local d=$(( SECONDS + $1 )); shift
  while [ "$SECONDS" -lt "$d" ]; do if "$@"; then return 0; fi; sleep 0.3; done
  return 1
}
cleanup() {
  if [ -d "$AISTACK_RUNDIR" ]; then
    : > "$STOPF" 2>/dev/null
    wait_until 10 gone >/dev/null 2>&1
    if holder_alive; then kill -9 "$(head -1 "$PIDF" | tr -dc '0-9')" 2>/dev/null; fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

printf '  fixture: %s, project %s, stubbed docker\n' "$AISTACK_RUNDIR" "$COMPOSE_PROJECT_NAME"

# --- 1: the hold is taken, and the proof is the contract itself -------------
say 1
arm >"$WORK/t1.out" 2>&1; chk $? "arm returns 0 with a container running"
grep -q 'SHARED, pid' "$WORK/t1.out"; chk $? "it reports taking the SHARED mode"
holder_alive; chk $? "a validated holder process exists"
if ex_free; then fail "AN EXCLUSIVE PROBE SUCCEEDED while the hold is held — this is the NOM-300 defect"
else pass "an exclusive probe FAILS — the hold is real, not just a pid file"; fi
flock -n -s "$LOCK" true 2>/dev/null; chk $? "a shared probe still succeeds, so a backup can still run"

# FD HYGIENE.  flock lives on the open file DESCRIPTION and fork shares it, so
# a descriptor the holder inherited keeps that lock alive for the holder's
# whole life.  MEASURED: the first version of the hold inherited the arm
# lock's descriptor and the next up/down blocked 120s and then died.
HP="$(head -1 "$PIDF" | tr -dc '0-9')"
FDS="$(ls -l "/proc/$HP/fd" 2>/dev/null)"
[ -n "$FDS" ]; chk $? "the holder's descriptor table is readable"
if printf '%s\n' "$FDS" | grep -q 'serving.holder.arm'; then
  fail "the holder keeps the ARM lock's descriptor open — the next up/down will block"
else pass "the holder holds no descriptor on the arm lock"; fi
NL="$(printf '%s\n' "$FDS" | grep -c 'lifecycle.lock' || true)"
[ "$NL" = 1 ]; chk $? "it holds exactly one descriptor on the lifecycle lock (got $NL)"
flock -n -x "$ARMF" true 2>/dev/null; chk $? "the arm lock is free once arming has returned"

# --- 2: arming twice does not make a second holder -------------------------
arm >"$WORK/t2.out" 2>&1; chk $? "a second arm returns 0"
grep -q 'already held' "$WORK/t2.out"; chk $? "and says it was already held"
N="$(holder_procs)"; [ "$N" = 1 ]; chk $? "still exactly one holder process (got $N)"

# --- 3: an unanswered docker is not an empty stack -------------------------
err_mode
sleep 12
holder_alive; chk $? "the hold survives a docker that does not answer"
if ex_free; then fail "THE LOCK WENT FREE while docker was unreachable — a lost answer was read as an empty stack"
else pass "the lock is still held while docker is unreachable"; fi
grep -q 'did not answer' "$HLOG"; chk $? "and the holder logged that it could not tell"
say 1; sleep 6
holder_alive; chk $? "the hold is still there once docker answers again"

# --- 4: it releases when the project stops ---------------------------------
say 0
if wait_until 20 gone; then pass "the hold releases within 20s of the last container stopping"
else fail "the hold was still there 20s after the last container stopped"; fi
if wait_until 5 ex_free; then pass "and the lock is exclusively takeable again, so a drill can run"
else fail "the lock is still held with nothing running"; fi
grep -q 'is running; releasing' "$HLOG"; chk $? "and the holder logged why it let go"

# --- 5: the startup window is not read as "stop" ---------------------------
# `up` arms the hold BEFORE `compose up`, so "no container yet" must not mean
# "nothing to hold the lock for".
say 0
arm >"$WORK/t5.out" 2>&1; chk $? "arm returns 0 with zero containers running"
sleep 8
holder_alive; chk $? "the hold is still there 8s later — waiting, not giving up"
if ex_free; then fail "the lock is free during the startup window, when a drill must not start"
else pass "the lock is held through the startup window"; fi
say 2; sleep 6
holder_alive; chk $? "and once the containers appear"
say 0
if wait_until 20 gone; then pass "and it still releases when they go away"
else fail "it did not release after the containers went away"; fi

# --- 6: release while containers run, which is what `down` does first ------
say 3
arm >/dev/null 2>&1
holder_alive; chk $? "armed with three containers running"
release >"$WORK/t6.out" 2>&1; chk $? "release returns 0"
if holder_alive; then fail "the holder is still alive after release, so down would block on it"
else pass "the holder is gone after release"; fi
if ex_free; then pass "the lock is exclusively takeable, so down can proceed"
else fail "the lock is still held after release"; fi
[ ! -e "$STOPF" ]; chk $? "the stop file is cleaned up, so the next arm is not pre-stopped"

# --- 7: arming is refused while something holds the exclusive mode ---------
say 1
flock -x "$LOCK" sleep 25 &
DRILLPID=$!
sleep 1
arm >"$WORK/t7.out" 2>&1
if [ $? = 0 ]; then fail "arm claimed success while the exclusive mode was held"
else pass "arm refuses while a drill holds the exclusive mode"; fi
grep -q 'EXCLUSIVE' "$WORK/t7.out"; chk $? "and names the reason"
if holder_alive; then fail "the refused arm left a holder behind"
else pass "the refused arm left no holder behind"; fi
wait "$DRILLPID" 2>/dev/null

# --- 8: concurrent arms produce one holder ---------------------------------
say 1
rm -f "$PIDF" "$STOPF"
for i in 1 2 3; do arm >"$WORK/t8.$i" 2>&1 & done
wait
sleep 1
N="$(holder_procs)"; [ "$N" = 1 ]; chk $? "three concurrent arms leave exactly one holder (got $N)"
holder_alive; chk $? "and the pid file names a live one"

# --- 9: a forced holder exit is visible, never silent ----------------------
P="$(head -1 "$PIDF" | tr -dc '0-9')"
kill -9 "$P" 2>/dev/null; sleep 1
if holder_alive; then fail "a SIGKILLed holder still reads as live — the pid file is being believed"
else pass "a SIGKILLed holder reads as absent"; fi
[ -f "$PIDF" ]; chk $? "its stale pid file survives, which is the state status and doctor must catch"
# Not "free immediately": a child the holder had already forked shares the
# description and holds the lock until it exits.  The longest-lived child is a
# one-second sleep, and the direction is the safe one -- too long, never too
# short.
if wait_until 5 ex_free; then pass "the lock becomes free within 5s of the forced exit"
else fail "the lock was still held 5s after the holder was killed"; fi
release >/dev/null 2>&1; chk $? "release over a stale pid file returns 0"
gone; chk $? "and removes it"
arm >"$WORK/t9.out" 2>&1; chk $? "re-arming after a forced exit works"
if ex_free; then fail "the re-arm did not take the lock"
else pass "and the lock is held again"; fi

# --- 10: the state a reboot leaves, and the repair for it (NOM-395) --------
# A reboot is the one route into the NOM-300 symptom that is not a failure of
# anything.  The hold lives in a tmpfs, so a boot clears it; every serving
# service is `restart: unless-stopped`, so the containers come back without it.
# The stack then serves with the lifecycle lock free.
#
# WHAT IS NOT MEASURED HERE, AND WHY THAT IS NOT A GAP IN THE CASE: the reboot
# itself.  This fixture has no stack and no containers, and the host that does
# carries other squads' work.  Neither half is in doubt — a restart policy is
# what restarts containers after a boot, and a process in a user session does
# not survive one.  What IS measured is the state those two halves produce,
# constructed exactly: the rundir gone, the containers back, no holder.
release >/dev/null 2>&1
rm -rf "$AISTACK_RUNDIR"          # what a tmpfs does to it across a boot
say 2                             # ...while the containers came back without it
[ ! -e "$LOCK" ]; chk $? "a reboot leaves no lock file at all (the tmpfs is cleared)"
if ex_free; then pass "nothing holds the lifecycle lock after a reboot"
else fail "the lock reads as HELD with no lock file — a missing file is not a hold"; fi
gone; chk $? "and no holder exists: this is the NOM-395 state, constructed"
# The repair `docs/troubleshooting.md` and `doctor` both name is `bin/aistack
# up`, whose arming step is this.  It has to work from an EMPTY rundir, not
# just from one some earlier command left behind.
arm >"$WORK/t10.out" 2>&1; chk $? "the documented repair re-arms from an empty rundir"
holder_alive; chk $? "a validated holder exists again"
if ex_free; then fail "the repair returned 0 without taking the lock"
else pass "and the lock is held again — the kernel enforces the interlock once more"; fi

# --- 11: a refusal inside `up` must not leave the hold armed ---------------
# THE MIRROR IMAGE OF THIS TICKET'S DEFECT, and it was shipped by the fix for
# it.  MEASURED (NOM-300 review, 2026-10-24): `cmd_up` arms the hold, then runs
# `_up "$@" || rc=$?` so that a failure routes to `_holder_release_if_idle` --
# but `_up`'s first check called `die`, and `die` is `exit 1`.  The process left
# before `|| rc=$?` could run, so the release never happened: nothing serving,
# zero containers, and the lock held for up to the 1200s startup grace.  The
# lock had stopped describing the serving state again, in the other direction.
#
# Cases 1-10 drive `_holder_arm`/`_holder_let_go` directly and all stayed green
# through that, which is why this case exists: the defect was in `cmd_up`'s
# failure path, and nothing drove `cmd_up`.
release >/dev/null 2>&1
say 0
drills restore-drill-20260101000000-postgres
rc=0; up_cmd >"$WORK/t11.out" 2>&1 || rc=$?
[ "$rc" != 0 ]; chk $? "cmd_up fails when a drill container was left behind (rc=$rc)"
grep -q 'restore-drill-20260101000000-postgres' "$WORK/t11.out"; chk $? "and names the container it refused over"
if grep -q 'Starting (profiles' "$WORK/t11.out"; then
  fail "it reached the start step; the refusal has to come before anything starts"
else pass "it refused before starting anything"; fi
if holder_alive; then
  fail "THE HOLD IS STILL ARMED after a refusal with nothing serving -- an exit skipped the release"
else pass "the refusal released the hold it had armed"; fi
if ex_free; then pass "and the lock is free, so the next drill or restore is not refused for 1200s"
else fail "the lock is still held with nothing serving"; fi
flock -n -x "$ARMF" true 2>/dev/null; chk $? "and the arm lock is free, so the next up or down does not block"

# THE OTHER BRANCH IS DELIBERATE and must not regress into "always release":
# when containers ARE running, the same refusal keeps the hold, because a drill
# alongside half a started stack is precisely what it exists to prevent.
say 2
rc=0; up_cmd >"$WORK/t11b.out" 2>&1 || rc=$?
[ "$rc" != 0 ]; chk $? "cmd_up still fails over the same leftover drill with containers up (rc=$rc)"
holder_alive; chk $? "and this time the hold STAYS, because something is running"
if ex_free; then fail "the lock went free with containers running -- that is the NOM-300 defect"
else pass "the lock is still held, so no drill can start against them"; fi
grep -q 'hold stays: containers are still running' "$WORK/t11b.out"; chk $? "and it says which of the two keep-reasons applied"
no_drills
release >/dev/null 2>&1; chk $? "release cleans up after the case"

printf '\n  %s assertions, %s failed\n' "$CHECKED" "$FAILED"
if [ "$CHECKED" -lt 57 ]; then
  printf '  [refuse] only %s assertions were evaluated, expected at least 57.\n' "$CHECKED"
  printf '           Something stopped early; this is not a pass.\n'
  exit 2
fi
[ "$FAILED" = 0 ] || exit 1
