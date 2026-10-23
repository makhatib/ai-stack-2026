#!/usr/bin/env bash
# NOM-352, NOM-372 — proves the scan's pre-flight disk assertion.
#
# FOUR LEVELS, BECAUSE ONE WOULD NOT BE ENOUGH:
#
#   A  scripts/preflight-disk.sh on its own — the arithmetic, the refusals,
#      and the rule that "could not measure" never reports as "enough".
#      Driven against a FIXTURE path and an explicit requirement, so the
#      result does not depend on how full the host happens to be today.
#   B  scripts/security-check.sh actually running — that a low-disk answer
#      really does stop the scan half, that it is reported as NOT RUN rather
#      than as clean, and that --allow-low-disk really does override it.
#      Driven by AISTACK_SCAN_MIN_FREE_MB, which makes any host look full.
#   C  scripts/scan-evidence.sh actually running (NOM-372) — the script that
#      pulls the whole versions.env set, where the old guard was a hard
#      `free < 4096 MB` abort with no override, below the size of one image.
#      Proves the derived requirement, the override, and the re-check inside
#      the loop.  C's own header below says what it does and does not measure.
#   D  scripts/scan-evidence.sh again, with preflight-disk.sh STUBBED so a
#      chosen call goes low (NOM-372 review).  That reaches the three things
#      the real pre-flight cannot make happen on a host with room: the in-loop
#      stop BELOW THE REQUIREMENT, a stop at the repo config+secret pass, and
#      a successful resume clearing the stopped run's marker.
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

printf '\nC. scripts/scan-evidence.sh, with the host made to look full\n'

# WHY C EXISTS (NOM-372).  scan-evidence.sh is the script that pulls the whole
# versions.env set and owns the two cache volumes — the one that actually
# burned the disk on NOM-350.  It used to abort in its loop at a flat
# `free < 4096 MB` with NO override: a hard refusal (the shape the Tech Lead
# rejected) at a number BELOW ONE IMAGE (the largest pin is 4769 MB).  C
# proves the replacement: the requirement is derived, low disk warns and names
# --allow-low-disk, the flag works, and the re-check INSIDE the loop can still
# stop a run that started with room.
#
# WHY C NEVER SCANS.  A real scan is 45 minutes and several GB.  C drives the
# script against a FIXTURE image list whose name cannot resolve, with every
# output file pre-seeded, so every step reports SKIP (present) and no docker
# run happens at all.  If the seeding ever stopped matching the script's name
# mangling, the fixture image would fail to pull in seconds rather than start
# a real scan — the failure mode is a fast red, not a 45-minute one.
#
# WHAT C DOES NOT MEASURE, AND WHERE IT IS MEASURED INSTEAD.  The in-loop
# re-check has two stop branches sharing one function and one exit path: below
# the requirement, and below the mid-run floor.  With the REAL pre-flight only
# the FLOOR branch is reachable, because the other needs free disk to actually
# fall between the pre-flight and the loop.  That is a limit of driving the
# real pre-flight, not a limit of the script — SECTION D stubs the pre-flight
# and drives the requirement branch, the stop at the repo config+secret pass,
# and a resume.  C and D together cover both branches.

SE="$ROOT/scripts/scan-evidence.sh"
# 64 zeros: a syntactically valid digest for a registry that cannot resolve.
FAKE_IMG="nom372.invalid/fixture:0@sha256:$(printf '0%.0s' $(seq 64))"

# Seeds every output the script checks for, for every image in the list, so a
# full pass does no work.  Mirrors the script's own name mangling.
seed_outputs() {
  local o="$1" img name
  while read -r img; do
    [ -n "$img" ] || continue
    name="$(printf '%s' "$img" | sed 's#[/:@]#_#g' | cut -c1-80)"
    printf '{}\n' > "$o/trivy/${name}.json"
    printf '{}\n' > "$o/syft/${name}.syft.json"
    printf '{}\n' > "$o/grype/${name}.grype.json"
  done < "$o/images.txt"
  printf '{}\n' > "$o/trivy-repo-config-secret.json"
}

new_out() {   # $1 = dir name under $TMP; echoes the path
  local o="$TMP/$1"
  mkdir -p "$o/trivy" "$o/syft" "$o/grype"
  printf '%s\n' "$o"
}

# --- 11. low disk, no flag: nothing is scanned, and the override is named ---
# No images.txt is seeded here, so the script derives the real list from
# versions.env before it gets to the disk answer — which is what the last
# assertion in this case checks.
O11="$(new_out c11)"
out="$(OUT="$O11" AISTACK_SCAN_MIN_FREE_MB=999999999 bash "$SE" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "low disk with no flag exits 2 (refused, nothing measured)" \
               || fail "low-disk refusal exited $rc, want 2; output: $out"
printf '%s\n' "$out" | grep -q 'SCAN NOT RUN' \
  && pass "says SCAN NOT RUN" || fail "no SCAN NOT RUN line: $out"
printf '%s\n' "$out" | grep -q 'NO IMAGE WAS SCANNED' \
  && pass "says NO IMAGE WAS SCANNED, not a clean result" || fail "no NO IMAGE WAS SCANNED line"
printf '%s\n' "$out" | grep -q -- '--allow-low-disk' \
  && pass "the refusal names the override flag" || fail "the override flag is not named"
printf '%s\n' "$out" | grep -qE 'trivy  (START|SKIP)' \
  && fail "it reached the scan loop after refusing on disk" || pass "the scan loop was not reached"
grep -q 'NOT RUN (low disk' "$O11/NOT-RUN.txt" 2>/dev/null \
  && pass "leaves a NOT-RUN marker in the report directory" \
  || fail "no NOT-RUN.txt marker written"
printf '%s\n' "$out" | grep -q 'DONE —' \
  && fail "a refused run still printed DONE" || pass "a refused run does not print DONE"
printf '%s\n' "$out" | grep -qE 'candidate set: [1-9][0-9]* images' \
  && pass "the real image list was derived before the disk answer" \
  || fail "no candidate set line: $out"

# --- 12. SCAN-EVIDENCE.SH's OWN requirement is derived, not a flat number ---
# WHAT THIS CASE EXISTS TO CATCH, and why its earlier form did not.  It used to
# run preflight-disk.sh directly and check ITS arithmetic — which this change
# never touched.  Nothing asserted that scan-evidence.sh USES it, so putting
# the old flat 4096 back into scan-evidence.sh left all 31 of section C green:
# exactly the regression the ticket exists to stop.  So the number is now read
# out of SCAN-EVIDENCE.SH's own output.
#
# It still does not scan.  No images.txt is seeded, so the real pin list is
# derived and the real pre-flight runs; the mid-run floor is set unreachably
# high so the FIRST in-loop check stops the run before any docker run.
O12="$(new_out c12)"
out="$(OUT="$O12" AISTACK_SCAN_HARD_FLOOR_MB=999999999 bash "$SE" 2>&1)"; rc=$?
printf '%s\n' "$out" | grep -qE 'trivy  (START|SKIP)' \
  && fail "case 12 reached the scan loop; it must stop before any image" \
  || pass "case 12 scanned nothing (it stops at the first in-loop check)"

# THE DERIVED SHAPE IS THE ASSERTION, not just the value: a flat number cannot
# produce this line, and neither can --need-mb (that prints "(override)").
printf '%s\n' "$out" \
  | grep -qE '^  requirement: [0-9]+ MB = largest image [0-9]+ MB \(.+\) \+ [0-9]+ MB margin' \
  && pass "scan-evidence.sh's own run reports a DERIVED requirement, naming the largest image" \
  || fail "scan-evidence.sh did not report a derived requirement: $out"

req="$(printf '%s\n' "$out" | sed -n 's/^  requirement: \([0-9][0-9]*\) MB.*/\1/p' | head -1)"
LARGEST_MB=0; LARGEST_NAME=""; MISSING=0
while read -r img; do
  [ -n "$img" ] || continue
  bytes="$(docker image inspect -f '{{.Size}}' "$img" 2>/dev/null)"
  case "$bytes" in ''|*[!0-9]*) MISSING=$((MISSING + 1)); continue ;; esac
  mb=$((bytes / 1048576))
  [ "$mb" -gt "$LARGEST_MB" ] && { LARGEST_MB="$mb"; LARGEST_NAME="${img%%@*}"; }
done < "$O12/images.txt"
case "$req" in
  ''|*[!0-9]*) fail "could not read a requirement out of scan-evidence.sh: $out" ;;
  *)
    [ "$req" -gt 4096 ] \
      && pass "scan-evidence.sh requires ${req} MB — above the old flat 4096 MB guard" \
      || fail "scan-evidence.sh requires ${req} MB, no better than the old flat 4096 MB guard"
    if [ "$LARGEST_MB" -eq 0 ]; then
      printf '  [skip] requirement-vs-largest-image: no pinned image is present locally to measure\n'
    else
      [ "$req" -ge "$LARGEST_MB" ] \
        && pass "requirement ${req} MB >= largest pinned image ${LARGEST_MB} MB ($LARGEST_NAME)" \
        || fail "requirement ${req} MB is BELOW the largest pinned image ${LARGEST_MB} MB ($LARGEST_NAME)"
    fi
    # AND THAT THE LOOP RE-CHECKS AGAINST THE SAME NUMBER.  Printing a derived
    # requirement and then guarding the loop with something else would still
    # pass everything above; disk.log records the number each re-check used.
    if printf '%s\n' "$out" | grep -q 'pre-flight OK'; then
      grep -q "need=${req}MB" "$O12/disk.log" 2>/dev/null \
        && pass "the in-loop re-check used the same ${req} MB requirement (disk.log)" \
        || fail "no in-loop re-check against ${req} MB in $O12/disk.log"
      [ "$rc" -eq 3 ] && pass "a green pre-flight plus the unreachable floor exits 3" \
                     || fail "green pre-flight + in-loop stop exited $rc, want 3"
    else
      printf '  [skip] in-loop-uses-same-requirement: this host reported no green\n'
      printf '         pre-flight, so the run never reached the loop\n'
    fi
    ;;
esac
[ "$MISSING" -gt 0 ] && printf '  [note] %d pinned image(s) not present locally; the requirement is a floor there\n' "$MISSING"

# --- 13. an EMPTY image list is refused, not scanned ----------------------
# Plenty of disk here on purpose: this refusal is about the list, and it must
# not depend on the disk answer.  A loop over zero images that then prints
# DONE is a scan of nothing reported as a scan.
O13="$(new_out c13)"
: > "$O13/images.txt"
out="$(OUT="$O13" bash "$SE" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "an empty image list exits 2" \
               || fail "empty image list exited $rc, want 2; output: $out"
printf '%s\n' "$out" | grep -q 'image list is EMPTY' \
  && pass "says the list is empty, in those words" || fail "no empty-list line: $out"
printf '%s\n' "$out" | grep -q 'DONE —' \
  && fail "an empty image list still printed DONE" || pass "an empty list does not print DONE"
grep -q 'NOT RUN (image list empty)' "$O13/NOT-RUN.txt" 2>/dev/null \
  && pass "an empty list leaves a NOT-RUN marker" || fail "no NOT-RUN.txt for an empty list"

# --- 14. --allow-low-disk overrides the pre-flight ------------------------
O14="$(new_out c14)"
printf '%s\n' "$FAKE_IMG" > "$O14/images.txt"
seed_outputs "$O14"
out="$(OUT="$O14" AISTACK_SCAN_MIN_FREE_MB=999999999 bash "$SE" --allow-low-disk 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "--allow-low-disk runs to completion (exit 0)" \
               || fail "--allow-low-disk exited $rc, want 0; output: $out"
printf '%s\n' "$out" | grep -q 'running anyway because --allow-low-disk was given' \
  && pass "it says it is proceeding, and why" || fail "no proceeding line: $out"
printf '%s\n' "$out" | grep -q 'SCAN NOT RUN' \
  && fail "--allow-low-disk still refused the scan" || pass "no refusal line with the flag"
printf '%s\n' "$out" | grep -q 'trivy  SKIP (present)' \
  && pass "the scan loop was reached (every output already present)" \
  || fail "the scan loop was not reached with --allow-low-disk: $out"
printf '%s\n' "$out" | grep -q 'DONE —' \
  && pass "a complete pass prints DONE" || fail "a complete pass did not print DONE"

# --- 15. the re-check INSIDE the loop stops the run, flag or no flag ------
# This is the half security-check.sh does not need: it scans once, this script
# scans image after image and can run out half way.  Driven with the mid-run
# floor set unreachably high, which is the one way a test can make the disk
# look like it fell AFTER the run started.
O15="$(new_out c15)"
printf '%s\n' "$FAKE_IMG" > "$O15/images.txt"
seed_outputs "$O15"
out="$(OUT="$O15" AISTACK_SCAN_MIN_FREE_MB=999999999 AISTACK_SCAN_HARD_FLOOR_MB=999999999 \
       bash "$SE" --allow-low-disk 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && pass "an in-loop stop exits 3 (part way), not 0 and not 2" \
               || fail "in-loop stop exited $rc, want 3; output: $out"
printf '%s\n' "$out" | grep -q 'mid-run floor' \
  && pass "says it stopped on the mid-run floor" || fail "no mid-run floor line: $out"
printf '%s\n' "$out" | grep -qE 'STOPPED at .* \(before trivy\) — 0 of 1 images scanned' \
  && pass "says what stopped it and how far it got, in images" \
  || fail "no 'STOPPED at <step> — n of m images scanned' line: $out"
printf '%s\n' "$out" | grep -q 'DONE —' \
  && fail "a run that stopped part way still printed DONE" || pass "a part-way run does not print DONE"
printf '%s\n' "$out" | grep -q -- 'AISTACK_SCAN_HARD_FLOOR_MB=0' \
  && pass "the floor message names how to remove the floor" \
  || fail "the floor is a refusal with no override named"
grep -q 'STOPPED at .* (before trivy) after 0 of 1 images' "$O15/NOT-RUN.txt" 2>/dev/null \
  && pass "a part-way run leaves a marker naming the step and the count" \
  || fail "no STOPPED marker, or it does not name the step: $(cat "$O15/NOT-RUN.txt" 2>/dev/null)"

# --- 16. the in-loop re-check runs even when the pre-flight was GREEN -----
# The regression this guards: deleting the re-check from the loop and keeping
# only the pre-flight. No disk override here, so the pre-flight passes on this
# host and the only thing that can stop the run is the check inside the loop.
O16="$(new_out c16)"
printf '%s\n' "$FAKE_IMG" > "$O16/images.txt"
seed_outputs "$O16"
out="$(OUT="$O16" AISTACK_SCAN_HARD_FLOOR_MB=999999999 bash "$SE" 2>&1)"; rc=$?
if printf '%s\n' "$out" | grep -q 'pre-flight OK'; then
  pass "the pre-flight passed on this host"
  [ "$rc" -eq 3 ] && pass "a green pre-flight followed by an in-loop stop exits 3" \
                 || fail "green pre-flight + in-loop stop exited $rc, want 3; output: $out"
  printf '%s\n' "$out" | grep -q 'STOP at .* (before trivy)' \
    && pass "the stop happened inside the loop, at an image" \
    || fail "the in-loop stop does not name where it stopped: $out"
else
  printf '  [skip] case 16: the run reported no green pre-flight (too little free disk\n'
  printf '         here, or no pre-flight at all), so an in-loop-only stop cannot be\n'
  printf '         isolated from one the pre-flight would have caught anyway\n'
fi

# --- 17. bad arguments are refused, not ignored --------------------------
out="$(OUT="$(new_out c17)" bash "$SE" --no-such-flag 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "an unknown argument exits 2" || fail "unknown argument exited $rc, want 2"
printf '%s\n' "$out" | grep -q 'unknown argument --no-such-flag' \
  && pass "it names the argument it refused" || fail "unknown argument was accepted: $out"
out="$(OUT="$(new_out c17b)" AISTACK_SCAN_HARD_FLOOR_MB=abc bash "$SE" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a non-numeric AISTACK_SCAN_HARD_FLOOR_MB exits 2" \
               || fail "a non-numeric floor exited $rc, want 2; output: $out"

printf '\nD. scripts/scan-evidence.sh with a STUBBED pre-flight\n'

# WHY A STUB, AND WHAT IT BUYS.  Section C drives the real pre-flight, so the
# only way it can make free space look like it fell AFTER the run started is
# the mid-run floor.  Three things stayed unmeasured because of that, and C's
# header used to call the first of them unreachable:
#
#   * the in-loop stop BELOW THE REQUIREMENT — the other branch of guard_disk,
#     which needs free disk to fall between the pre-flight and the loop;
#   * the stop at the REPO CONFIG+SECRET pass, which needs it to fall after
#     the last image — the case whose message used to read "STOPPED AFTER 1 of
#     1 images. The 0 image(s) ... were NOT SCANNED" and never name the step;
#   * a successful RESUME, which needs the first run to stop deterministically.
#
# A copy of scan-evidence.sh in a throwaway ROOT, beside a preflight-disk.sh
# that answers OK for the first N calls and LOW after that, reaches all three
# without filling the host.  The script UNDER TEST is the real one, byte for
# byte; only the thing it asks about free space is replaced.  Nothing here
# scans either: every output is pre-seeded and the stop lands before docker.

make_stub_tree() {   # $1 = dir name under $TMP; echoes the throwaway ROOT
  local t="$TMP/$1"
  mkdir -p "$t/scripts"
  cp "$SE" "$t/scripts/scan-evidence.sh"
  cat > "$t/scripts/preflight-disk.sh" <<'STUB'
#!/usr/bin/env bash
# TEST STUB for scripts/preflight-disk.sh.  Emits the same three line shapes
# the real one does -- the per-filesystem free count scan-evidence.sh parses
# its number out of, the requirement line, and an OK/LOW verdict -- and counts
# its calls so a test can choose WHICH call goes low.
n=$(( $(cat "$STUB_CALLS" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$STUB_CALLS"
printf 'call %s: %s\n' "$n" "$*" >> "$STUB_CALLS.args"
if [ "$n" -le "$STUB_OK_CALLS" ]; then
  printf '  / (/dev/stub): %s MB free\n' "$STUB_OK_FREE"
  printf '  requirement: %s MB = largest image 4769 MB (stub/largest:1) + 2048 MB margin\n' "$STUB_NEED"
  printf '  OK: %s MB free, the scan needs about %s MB\n' "$STUB_OK_FREE" "$STUB_NEED"
  exit 0
fi
printf '  / (/dev/stub): %s MB free\n' "$STUB_LOW_FREE"
printf '  requirement: %s MB (override)\n' "$STUB_NEED"
printf '  LOW: %s MB free, the scan needs about %s MB\n' "$STUB_LOW_FREE" "$STUB_NEED"
exit 1
STUB
  printf '%s\n' "$t"
}

# $1 = tree, $2 = OUT, $3 = how many calls answer OK, then extra argv.
# STUB_LOW_FREE is 3000: BELOW the 6817 MB requirement but ABOVE the 2048 MB
# mid-run floor, so these stops are the REQUIREMENT branch, not the floor.
STUB_FLOOR=2048   # a case sets this to move the mid-run floor; see case 21
run_stub() {
  local t="$1" o="$2" ok="$3"; shift 3
  OUT="$o" STUB_CALLS="$t/calls" STUB_OK_CALLS="$ok" \
  STUB_OK_FREE=50000 STUB_LOW_FREE=3000 STUB_NEED=6817 \
  AISTACK_SCAN_HARD_FLOOR_MB="$STUB_FLOOR" \
  bash "$t/scripts/scan-evidence.sh" "$@" 2>&1
}

stub_out() {   # $1 = tree; seeds a one-image OUT with every output present
  local t="$1" o="$1/out"
  mkdir -p "$o/trivy" "$o/syft" "$o/grype"
  printf '%s\n' "$FAKE_IMG" > "$o/images.txt"
  seed_outputs "$o"
  printf '%s\n' "$o"
}

# --- 18. the in-loop stop BELOW THE REQUIREMENT (not the floor) -----------
# The branch C's header used to call unmeasurable.  OK for the pre-flight,
# LOW at 3000 MB on the first in-loop check.
T18="$(make_stub_tree t18)"; O18="$(stub_out "$T18")"
out="$(run_stub "$T18" "$O18" 1)"; rc=$?
[ "$rc" -eq 3 ] && pass "a below-the-requirement in-loop stop exits 3" \
               || fail "below-requirement in-loop stop exited $rc, want 3; output: $out"
printf '%s\n' "$out" | grep -q 'pre-flight OK' \
  && pass "it started with room (the pre-flight passed), then ran out" \
  || fail "the stub pre-flight did not report OK on call 1: $out"
printf '%s\n' "$out" | grep -q 'STOP at .* (before trivy) — 3000MB free, the scan needs about 6817MB' \
  && pass "the stop names the step, the free count and the requirement" \
  || fail "no requirement-branch STOP line: $out"
printf '%s\n' "$out" | grep -q 'mid-run floor' \
  && fail "3000MB free took the FLOOR branch; the requirement branch is untested" \
  || pass "it is the requirement branch, not the floor (3000 > 2048)"
printf '%s\n' "$out" | grep -q -- '--allow-low-disk' \
  && pass "the in-loop refusal names the override too" \
  || fail "the in-loop requirement stop is a refusal with no override named"
printf '%s\n' "$out" | grep -qE 'trivy  (START|SKIP)' \
  && fail "it reached trivy after the in-loop stop" || pass "no tool ran after the stop"
grep -q 'STOPPED at .* (before trivy) after 0 of 1 images' "$O18/NOT-RUN.txt" 2>/dev/null \
  && pass "the marker names the step that stopped it" \
  || fail "marker does not name the step: $(cat "$O18/NOT-RUN.txt" 2>/dev/null)"

# --- 19. a stop at the REPO CONFIG+SECRET pass reports that pass ----------
# Every image is scanned and the stop lands on the last step.  The old message
# reported this as "STOPPED AFTER 1 of 1 images. The 0 image(s) ... were NOT
# SCANNED" — self-contradictory, and silent about the step that did not run.
# It matters because that pass is the only SECRET scan in the evidence set and
# ci/scan-gate.py does not read its report: the marker is the only signal.
T19="$(make_stub_tree t19)"; O19="$(stub_out "$T19")"
rm -f "$O19/trivy-repo-config-secret.json"
out="$(run_stub "$T19" "$O19" 4)"; rc=$?
[ "$rc" -eq 3 ] && pass "a stop at the repo pass exits 3" \
               || fail "repo-pass stop exited $rc, want 3; output: $out"
printf '%s\n' "$out" | grep -q 'STOPPED at repo config+secret scan' \
  && pass "it names the repo config+secret pass as what stopped" \
  || fail "the stop does not name the repo pass: $out"
printf '%s\n' "$out" | grep -q 'all 1 images were scanned, but THIS STEP DID NOT RUN' \
  && pass "it says the images are done and the STEP is what is missing" \
  || fail "no 'all n images scanned, this step did not run' line: $out"
printf '%s\n' "$out" | grep -qE 'The 0 image\(s\)|other 0 image' \
  && fail "still claims 0 images were not scanned" \
  || pass "no self-contradictory 'the 0 image(s) were NOT SCANNED'"
printf '%s\n' "$out" | grep -q 'trivy  START repo' \
  && fail "it ran the repo scan it had just refused" || pass "the repo scan did not run"
grep -q 'STOPPED at repo config+secret scan after 1 of 1 images' "$O19/NOT-RUN.txt" 2>/dev/null \
  && pass "the marker names the repo pass, so the gate's only signal is right" \
  || fail "marker wrong for a repo-pass stop: $(cat "$O19/NOT-RUN.txt" 2>/dev/null)"
printf '%s\n' "$out" | grep -q 'DONE —' \
  && fail "a run that skipped the secret pass still printed DONE" \
  || pass "it does not print DONE"

# --- 20. --allow-low-disk overrides the IN-LOOP requirement stop too ------
# The pre-flight override is case 14; this is the same flag on the other check.
T20="$(make_stub_tree t20)"; O20="$(stub_out "$T20")"
out="$(run_stub "$T20" "$O20" 1 --allow-low-disk)"; rc=$?
[ "$rc" -eq 0 ] && pass "--allow-low-disk carries the run past an in-loop LOW (exit 0)" \
               || fail "--allow-low-disk in-loop exited $rc, want 0; output: $out"
printf '%s\n' "$out" | grep -q 'LOW DISK at .* continuing because --allow-low-disk was given' \
  && pass "it says it is continuing, where, and why" || fail "no in-loop continuing line: $out"
printf '%s\n' "$out" | grep -q 'DONE —' \
  && pass "it reaches DONE" || fail "it did not reach DONE: $out"
[ -e "$O20/NOT-RUN.txt" ] \
  && fail "a complete run left a NOT-RUN marker: $(cat "$O20/NOT-RUN.txt")" \
  || pass "a complete run leaves no NOT-RUN marker"

# --- 21. a successful RESUME clears the stopped run's marker --------------
# Resuming is the path the script's own header advertises: stop on disk, free
# some space, re-run, present outputs are skipped.  The marker written by the
# stopped run used to survive that, so a COMPLETE evidence set carried a note
# saying it was incomplete — and the gate's only signal for the repo pass is
# that same file.
T21="$(make_stub_tree t21)"; O21="$(stub_out "$T21")"
STUB_FLOOR=999999999
out="$(run_stub "$T21" "$O21" 999)"; rc=$?
STUB_FLOOR=2048
[ "$rc" -eq 3 ] && pass "resume step 1: the run stops part way (exit 3)" \
               || fail "resume step 1 exited $rc, want 3; output: $out"
# Existence, not wording: this case is about fix 3 (the marker surviving a
# resume), so it must not also fail when the marker's TEXT changes — case 18
# owns the wording.
[ -s "$O21/NOT-RUN.txt" ] \
  && pass "resume step 1: a marker is on disk" || fail "resume step 1 wrote no marker"
rm -f "$T21/calls"
out="$(run_stub "$T21" "$O21" 999)"; rc=$?
[ "$rc" -eq 0 ] && pass "resume step 2: the re-run completes (exit 0)" \
               || fail "resume step 2 exited $rc, want 0; output: $out"
printf '%s\n' "$out" | grep -q 'DONE —' \
  && pass "resume step 2: prints DONE" || fail "resume step 2 did not print DONE: $out"
[ -e "$O21/NOT-RUN.txt" ] \
  && fail "the resumed run kept the old marker: $(cat "$O21/NOT-RUN.txt")" \
  || pass "the resumed run cleared the stopped run's marker"

printf '\n'
[ "$FAIL" -eq 0 ] && { echo "scan pre-flight: all assertions pass"; exit 0; }
echo "scan pre-flight: FAILURES above"; exit 1
