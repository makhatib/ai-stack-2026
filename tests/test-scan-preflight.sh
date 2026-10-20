#!/usr/bin/env bash
# NOM-352 — proves the scan's pre-flight disk assertion.
#
# TWO LEVELS, BECAUSE ONE WOULD NOT BE ENOUGH:
#
#   A  scripts/preflight-disk.sh on its own — the arithmetic, the refusals,
#      and the rule that "could not measure" never reports as "enough".
#      Driven against a FIXTURE path and an explicit requirement, so the
#      result does not depend on how full the host happens to be today.
#   B  scripts/security-check.sh actually running — that a low-disk answer
#      really does stop the scan half, that it is reported as NOT RUN rather
#      than as clean, and that --allow-low-disk really does override it.
#      Driven by AISTACK_SCAN_MIN_FREE_MB, which makes any host look full.
#
# WHY B DOES NOT SCAN ANYTHING.  A real scan is 45 minutes and several GB, so
# B points COMPOSE_FILE at an empty file: the image list is then empty and the
# scan half reports that instead of pulling. What B proves is which BRANCH the
# script took and what it told the operator, which is the whole change. It
# does not re-prove that trivy works.
#
# B runs the real audit half against the real repo. It is given
# SECURITY_REPORT_RETAIN=99 so a test can never prune a real report
# directory, and it removes the report directory it created — by the exact
# path the run printed, matched against the generated shape, never a glob.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PRE="$ROOT/scripts/preflight-disk.sh"
SC="$ROOT/scripts/security-check.sh"
FAIL=0
pass() { printf '  [ ok ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

printf '\nNOM-352 scan pre-flight disk assertion\n'
printf '\nA. scripts/preflight-disk.sh\n'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. enough free disk ---------------------------------------------------
out="$(bash "$PRE" --path "$TMP" --need-mb 1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0 when there is more free than the requirement" \
               || fail "exit $rc with a 1 MB requirement; output: $out"
printf '%s\n' "$out" | grep -q '  OK: .* free, the scan needs about 1 MB' \
  && pass "reports both numbers, not just a verdict" || fail "output missing both numbers: $out"

# --- 2. low free disk ------------------------------------------------------
out="$(bash "$PRE" --path "$TMP" --need-mb 999999999 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "exit 1 when free disk is below the requirement" \
               || fail "exit $rc with an unreachable requirement; output: $out"
printf '%s\n' "$out" | grep -q '  LOW: ' \
  && pass "says LOW, with the measurement beside it" || fail "no LOW line: $out"
printf '%s\n' "$out" | grep -q '  OK: ' \
  && fail "printed an OK line in the same run as a LOW one" \
  || pass "does not also print OK"

# --- 3. COULD NOT MEASURE is not a pass -----------------------------------
# The whole point of the exit-code contract: a caller must be able to tell
# "there is room" from "nothing answered". If an unmeasurable path exited 0,
# a scan would start on the strength of a check that never looked.
out="$(bash "$PRE" --path "$TMP/does-not-exist" --need-mb 1 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "exit 2 when df cannot answer for the path" \
               || fail "an unmeasurable path exited $rc, want 2; output: $out"
printf '%s\n' "$out" | grep -q 'NOT MEASURED' \
  && pass "says NOT MEASURED in those words" || fail "no NOT MEASURED line: $out"
printf '%s\n' "$out" | grep -q '  OK: ' \
  && fail "an unmeasurable path still printed OK" || pass "an unmeasurable path prints no OK"

# --- 4. an empty image list produces a FLOOR, never a 0 MB requirement ----
# `docker compose config --images` returns an EMPTY list for an operator who
# cannot read secrets/*.env. A requirement derived from it would be 0 MB,
# which no host can ever be below -- a check that always passes.
: > "$TMP/no-images.txt"
out="$(bash "$PRE" --path "$TMP" --images-from "$TMP/no-images.txt" 2>&1)"; rc=$?
printf '%s\n' "$out" | grep -q 'requirement: 8192 MB (FLOOR' \
  && pass "falls back to the 8192 MB floor when the image list is empty" \
  || fail "empty image list did not produce the floor: $out"
printf '%s\n' "$out" | grep -q 'requirement: 0 MB' \
  && fail "derived a 0 MB requirement from an empty list" \
  || pass "never reports a 0 MB requirement"
out="$(bash "$PRE" --path "$TMP" --images-from "$TMP/no-images.txt" --floor-mb 999999999 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "the floor is what gets compared (an unreachable floor reads LOW)" \
               || fail "an unreachable floor exited $rc, want 1"

# --- 5. a real image list derives from the LARGEST image ------------------
# One image at a time is read, and each is freed before the next, so the
# largest is what has to fit. Driven with a list of real local images so the
# sizes are real.
if command -v docker >/dev/null 2>&1 && docker image inspect busybox:stable >/dev/null 2>&1; then
  docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | head -3 > "$TMP/imgs.txt"
  out="$(bash "$PRE" --path "$TMP" --images-from "$TMP/imgs.txt" --margin-mb 2048 2>&1)"
  printf '%s\n' "$out" | grep -qE 'requirement: [0-9]+ MB = largest image [0-9]+ MB \(.*\) \+ 2048 MB margin' \
    && pass "derived requirement names the largest image and the margin" \
    || fail "derivation line missing or malformed: $out"
else
  printf '  [note] skipped the derived-requirement case: no local image to measure\n'
fi

# --- 6. bad arguments are refused, not ignored ---------------------------
for bad in "--need-mb abc" "--margin-mb -5" "--floor-mb x" "--not-a-flag"; do
  # shellcheck disable=SC2086
  out="$(bash "$PRE" --path "$TMP" $bad 2>&1)"; rc=$?
  [ "$rc" -eq 2 ] && pass "refused '$bad' (exit 2)" \
                  || fail "'$bad' exited $rc, want 2; output: $out"
done
out="$(bash "$PRE" --path "$TMP" --images-from "$TMP/missing.txt" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "refused an unreadable --images-from (exit 2)" \
               || fail "unreadable --images-from exited $rc, want 2"

printf '\nB. scripts/security-check.sh, with the host made to look full\n'

run_sc() {
  # Returns the combined output; the caller greps it.
  AISTACK_SCAN_MIN_FREE_MB=999999999 \
  SECURITY_REPORT_RETAIN=99 \
  COMPOSE_FILE=/dev/null \
  bash "$SC" "$@" 2>&1
}

cleanup_report() {
  # Remove ONLY the directory this run printed, and only if its name is the
  # generated shape. No glob, no `rm -rf security-report-*`.
  local out="$1" d
  d="$(printf '%s\n' "$out" | sed -n 's/^Report directory: //p' | head -1)"
  [ -n "$d" ] || return 0
  case "$(basename "$d")" in
    security-report-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
    *) printf '  [note] not removing %s — not the generated shape\n' "$d"; return 0 ;;
  esac
  [ -d "$d" ] || return 0
  rm -rf -- "$d" 2>/dev/null
  [ -d "$d" ] && printf '  [note] left behind %s (not writable here)\n' "$d"
  return 0
}

# --- 7. low disk, no flag: the scan does not run and says so -------------
out="$(run_sc)"
printf '%s\n' "$out" | grep -q 'The SCAN half will NOT RUN: too little free disk' \
  && pass "low disk stops the scan half" || fail "no low-disk refusal line in the output"
printf '%s\n' "$out" | grep -q -- '--allow-low-disk' \
  && pass "the message names the override flag" || fail "the override flag is not named"
printf '%s\n' "$out" | grep -q 'NOT RUN — too little free disk' \
  && pass "the scan half reports NOT RUN, not clean" || fail "scan half did not report NOT RUN"
printf '%s\n' "$out" | grep -q 'audit clean' \
  && fail "a run with an unrun scan still printed 'audit clean'" \
  || pass "an unrun scan is not summarised as clean"
printf '%s\n' "$out" | grep -q 'Audit: running containers' \
  && pass "the audit half still ran in full" || fail "low disk also skipped the audit half"
printf '%s\n' "$out" | grep -q '^  scanning ' \
  && fail "it scanned an image after reporting low disk" || pass "no image was scanned"
cleanup_report "$out"

# --- 8. --allow-low-disk overrides it ------------------------------------
out="$(run_sc --allow-low-disk)"
printf '%s\n' "$out" | grep -q 'running the scan anyway because --allow-low-disk' \
  && pass "--allow-low-disk proceeds, and says it is proceeding" \
  || fail "--allow-low-disk did not take effect"
printf '%s\n' "$out" | grep -q 'The SCAN half will NOT RUN: too little free disk' \
  && fail "--allow-low-disk still refused the scan" || pass "no refusal line with the flag"
# COMPOSE_FILE is empty here, so the scan half is REACHED and stops on the
# image list -- which is the proof it was reached rather than skipped.
printf '%s\n' "$out" | grep -q 'NOT RUN — the image list could not be resolved' \
  && pass "the scan half was reached (it stopped on the empty image list, not on disk)" \
  || fail "the scan half was not reached with --allow-low-disk"
cleanup_report "$out"

# --- 9. --audit-only needs no disk and is still distinguishable ----------
out="$(run_sc --audit-only)"
printf '%s\n' "$out" | grep -q 'SKIPPED (--audit-only)' \
  && pass "--audit-only still reports its own reason, not the disk one" \
  || fail "--audit-only lost its skip reason"
printf '%s\n' "$out" | grep -q 'too little free disk' \
  && fail "--audit-only ran the disk pre-flight it does not need" \
  || pass "--audit-only does not pre-flight disk it will not use"
cleanup_report "$out"

# --- 10. the argument loop reads every argument --------------------------
# The old form read only "$1", so `--allow-low-disk --audit-only` would have
# run the full scan: the override would have silently cancelled --audit-only.
out="$(run_sc --allow-low-disk --audit-only)"
printf '%s\n' "$out" | grep -q 'SKIPPED (--audit-only)' \
  && pass "--allow-low-disk --audit-only still skips the scan (both args read)" \
  || fail "a second argument was ignored"
cleanup_report "$out"
out="$(run_sc --no-such-flag)"; rc=$?
printf '%s\n' "$out" | grep -q 'unknown argument --no-such-flag' \
  && pass "an unknown argument is refused, not ignored" \
  || fail "unknown argument was accepted: $out"

printf '\n'
[ "$FAIL" -eq 0 ] && { echo "scan pre-flight: all assertions pass"; exit 0; }
echo "scan pre-flight: FAILURES above"; exit 1
