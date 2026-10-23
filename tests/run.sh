#!/usr/bin/env bash
# tests/run.sh — the one command that runs this repository's tests.
#
# WHY THIS FILE EXISTS (NOM-357).
#
# tests/ held eleven test scripts and NOTHING invoked any of them -- not
# bin/aistack, not scripts/security-check.sh, not ci/invariants.py, not a doc.
# Each was written against a specific defect and then only ever ran on the day
# it was written.  That is the shape NOM-353 fixed one level up, where
# ci/scan-gate.py worked and no standing command called it: a control that
# fires only when somebody remembers to type it is a document.
#
# WHAT THIS RUNNER REFUSES TO DO, AND WHY EACH REFUSAL IS LOAD-BEARING.
#
# 1. IT DOES NOT DECIDE PASS/FAIL BY GREPPING OUTPUT.  register-controls.sh
#    drives ci/scan-gate.py and quotes the gate's own output back at the
#    reader, and that output contains the word FAIL.  Measured 2026-10-20:
#    five such lines on a run that ends "cases passed: 26   failed: 0" and
#    exits 0.  A grep-for-FAIL runner calls that green run red.  Only the exit
#    code decides.
#
# 2. IT DOES NOT READ EXIT 2 AS A PASS -- OR AS A PLAIN FAILURE.  Several
#    tests here deliberately REFUSE when they cannot establish their own
#    preconditions: installer-idempotent.sh when it cannot read secrets/,
#    test-scan-gate.sh when its fixture baseline is not clean,
#    port-preflight.sh when install.sh's matcher no longer extracts.  A
#    refusal means the property WAS NOT MEASURED, which is neither "fine" nor
#    "broken".  It gets its own column, its own count, and its own runner exit
#    code, because collapsing it into either one is how a suite reports on a
#    property nobody checked.
#
# 3. IT DOES NOT SWALLOW A TEST'S INTERNAL [skip].  A test can exit 0 having
#    skipped a check inside itself -- secret-modes.sh skips its 0640
#    root:<gid> assertion when it is not root.  Those lines are counted per
#    test and repeated in the summary.  The pattern is ANCHORED to the start
#    of the line: these tests indent quoted tool output behind "> ", so the
#    anchor cannot match a [skip] a test is merely reporting about something
#    else.
#
# 4. IT DOES NOT PRINT A GREEN BANNER OVER AN EMPTY RUN.  If a selection
#    executes nothing, that is exit 2 and says so.  "0 failed" out of 0 tests
#    is the cheapest false green there is.
#
# AND ONE THING IT INSISTS ON.  Every executable in tests/ must appear in the
# REGISTRY below, and every REGISTRY entry must exist on disk.  A test dropped
# into this directory and wired to nothing is precisely the defect NOM-357 is
# about, so a disagreement between the two FAILS the run instead of being
# ignored.  That check is the part of this file that stops NOM-357 recurring;
# the rest only stops it being invisible today.
#
# TIERS.  The split is "what the test needs", not "how long it takes", because
# the prerequisite is what decides whether you can run it at all right now:
#
#   fast     no docker, no live stack, no root, no arguments.  ~35s total.
#            This is the set to run routinely.
#   stack    needs a working docker daemon.  ~85s total.  None of these
#            touch the live stack's data; app-list-coupling.sh uses a
#            throwaway container and the two scan tests read evidence.
#   root     needs to read root-owned secrets/.  Refuses (exit 2) as an
#            ordinary user, which is the test working, not the suite breaking.
#   archive  needs an encrypted backup archive passed with --archive.  Not
#            run otherwise, and reported as NOT RUN rather than skipped.
#
# EXIT CODES (highest precedence first):
#   1   a test FAILED, or the registry and tests/ disagree
#   2   no failures, but a test REFUSED, or nothing ran at all
#   3   --strict only: no failures or refusals, but a check inside a test was
#       skipped
#   0   every selected test ran and passed
#   64  bad usage
#
# Note that `run.sh all` as an ordinary user ends at exit 2 BY DESIGN: the
# root tier cannot measure anything without privilege and says so.  Use
# `sudo tests/run.sh root` to actually measure that tier.
#
# Rollback: delete tests/run.sh and the `test` entries in bin/aistack (the
# cmd_test function, the dispatch case and the usage line).  Nothing here
# writes to the repository, so there is nothing else to undo.

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

# tier | script | what it needs, and what it costs
REGISTRY=(
"fast|approval-authority.sh|python3. Drives ci/approvers.py with synthetic values; reads no evidence, starts no container, writes nothing. <1s"
"fast|port-preflight.sh|python3. Extracts install.sh's listener matcher and feeds it synthetic listener tables. Refuses if step 8 was restructured so the matcher no longer extracts. <1s"
"fast|test-backup-retention.sh|coreutils only. Runs scripts/prune-backups.sh against a fixture directory, never against backups/. <1s"
"fast|test-report-retention.sh|coreutils only. Runs scripts/prune-reports.sh against a fixture root, never against the repo. ~2s"
"fast|secret-modes.sh|bash, awk, sed, openssl -- deliberately NOT python3, so it passes on the documented-minimum machine. Skips its 0640 root:<gid> assertion unless run as root. <1s"
"fast|register-controls.sh|python3 and a scan evidence directory (security-findings.yaml's evidence_dir, or \$EVIDENCE). Refuses if that directory is gone -- report retention prunes to 3, so it can go. No docker. ~30s"
"fast|backup-db-set.sh|bash and python3. Extracts THREE shipped blocks between markers and runs THEM, never a retyped copy: the dump-set derivation from scripts/backup.sh (against a stubbed cluster and a synthetic password file), the restored-db classification from scripts/restore.sh (which decides both what the drill expects a role for and whether CREATE DATABASE names an owner, and which the drill itself can only exercise during planned downtime), and restore.sh's verify-only resolution. Then drives verify-archive.py's database_statement() and its recorded-set refusal against fixture manifests, and asserts the read-only \`aistack verify\` path docs/backup-restore.md promises exists, asks for it out of band rather than by an appendable flag, and stops above the write phase. No docker, no postgres, no secrets, and nothing under backups/ is read. Refuses (exit 2) if any marker pair is gone, because an empty extraction measures nothing. <2s"
"stack|app-list-coupling.sh|A working docker daemon. Starts a THROWAWAY container against a synthetic password file; the live stack is never touched. ~13s"
"stack|collation-migration.sh|A working docker daemon. Starts a THROWAWAY postgres from the rendered pin and fakes collation staleness in it -- needs allow_system_table_mods, which is postmaster-level and so is passed as a server argument rather than SET, which is also why this cannot run against the live cluster. The live stack is never named. ~40s"
"stack|test-scan-preflight.sh|docker, plus scripts/security-check.sh's audit half against the real repo. Drives the disk pre-flight in all three places it is used: scripts/preflight-disk.sh alone, security-check.sh's one-shot check, and scan-evidence.sh's per-image re-check. Points COMPOSE_FILE at an empty file and scan-evidence.sh at a fixture image list with every output pre-seeded, so it never pulls and never scans. Section D additionally runs a COPY of scan-evidence.sh beside a stubbed preflight-disk.sh, in a throwaway tree under the test's own TMPDIR, to reach the stops real free space cannot stage. ~30s"
"stack|test-scan-gate.sh|docker, a security-report-*/ holding BOTH trivy/ and grype/, and a baseline audit that is clean. Hardlinks ~230 MB of evidence into a fixture BESIDE the repo -- not /tmp, which is a tmpfs on another device here, where cp -al fails with EXDEV. Prints [skip] if its pinned BASE_COMMIT is absent. ~41s"
"root|installer-idempotent.sh|ROOT. secrets/*.env is root-owned and the docker CLI reads env_file as the invoking user, so unprivileged every probe compares empty output with empty output and four checks report green without running. Refuses instead. Re-runs the installer: slow."
"archive|b2-archive-refusal.sh|An encrypted archive passed as --archive <path>, plus secrets/backup.key and secrets/backup.hmac. backups/*.enc is 0600 root, so this normally needs sudo as well. Decrypts ~240 MB once. ~10s"
)

usage() {
  cat <<'EOF'
tests/run.sh — run this repository's tests

  tests/run.sh [fast|stack|root|archive|all|list] [options]

  fast      no docker, no live stack, no root, no arguments  (~35s)  [default]
  stack     needs a working docker daemon                    (~85s)
  root      needs to read root-owned secrets/; use sudo
  archive   needs --archive <path>
  all       every tier; archive only when --archive is given
  list      print the registry and each test's prerequisites, run nothing

  --archive <path>   an encrypted backup archive for the archive tier
  --strict           also exit non-zero (3) when a check inside a test skipped
  -v, --verbose      stream each test's output instead of logging it
  -h, --help         this text

Exit: 1 failure, 2 refusal or nothing ran, 3 skip under --strict, 0 clean.
A test that cannot establish its preconditions exits 2 and is reported as
REFUSED — not measured — and never as a pass.
EOF
}

TIER=fast
ARCHIVE=""
STRICT=0
VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    fast|stack|root|archive|all|list) TIER="$1" ;;
    --archive) ARCHIVE="${2:-}"; [ -n "$ARCHIVE" ] || { echo "--archive needs a path" >&2; exit 64; }; shift ;;
    --strict)  STRICT=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    # An unknown argument is refused, not ignored: silently dropping one is how
    # a run ends up measuring something other than what was asked for.
    *) printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

if [ "$TIER" = list ]; then
  printf '\nRegistered tests by tier. `tests/run.sh <tier>` runs one tier.\n'
  for want in fast stack root archive; do
    printf '\n%s:\n' "$want"
    for e in "${REGISTRY[@]}"; do
      tier=${e%%|*}; rest=${e#*|}; script=${rest%%|*}; needs=${rest#*|}
      [ "$tier" = "$want" ] || continue
      printf '  tests/%s\n' "$script"
      printf '%s\n' "$needs" | fold -s -w 68 | sed 's/^[[:space:]]*/      /'
    done
  done
  printf '\n'
  exit 0
fi

# --- the registry and tests/ must agree -----------------------------------
# This is the check that stops NOM-357 happening again: a new test file that no
# tier claims, or a registry line whose file was deleted, fails the run.
DISAGREE=0
registered() {
  local want="$1" e
  for e in "${REGISTRY[@]}"; do
    local rest=${e#*|}
    [ "${rest%%|*}" = "$want" ] && return 0
  done
  return 1
}
for f in "$ROOT"/tests/*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  b="$(basename "$f")"
  [ "$b" = "run.sh" ] && continue
  if ! registered "$b"; then
    printf '  [FAIL] tests/%s exists but no tier in tests/run.sh claims it.\n' "$b"
    printf '         Add it to REGISTRY with its prerequisites, or delete it.\n'
    DISAGREE=$((DISAGREE + 1))
  fi
done
for e in "${REGISTRY[@]}"; do
  rest=${e#*|}; script=${rest%%|*}
  if [ ! -f "$ROOT/tests/$script" ]; then
    printf '  [FAIL] tests/run.sh registers tests/%s, which does not exist.\n' "$script"
    DISAGREE=$((DISAGREE + 1))
  fi
done

LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/aistack-tests.XXXXXX")"
PASSED=0; FAILED=0; REFUSED=0; NOTRUN=0; SKIPS=0; RAN=0
declare -a SUMMARY=()

run_one() {
  local script="$1" tier="$2"; shift 2
  local log="$LOGDIR/${script%.sh}.log" start end rc skips dur
  printf '\n=== %s  (%s) ===\n' "$script" "$tier"
  start=$(date +%s)
  if [ "$VERBOSE" -eq 1 ]; then
    bash "$ROOT/tests/$script" "$@" 2>&1 | tee "$log"
    # PIPESTATUS, not $?: with a pipe, $? is tee's.  This is also why this
    # runner is bash and never invokes a test through `sh -c`.
    rc=${PIPESTATUS[0]}
  else
    bash "$ROOT/tests/$script" "$@" >"$log" 2>&1
    rc=$?
  fi
  end=$(date +%s); dur=$((end - start))
  RAN=$((RAN + 1))
  skips=$(grep -c '^[[:space:]]*\[skip\]' "$log" 2>/dev/null) || true
  skips=${skips:-0}
  SKIPS=$((SKIPS + skips))

  local verdict note=""
  case "$rc" in
    0) verdict=PASS;    PASSED=$((PASSED + 1)) ;;
    2) verdict=REFUSED; REFUSED=$((REFUSED + 1)); note="not measured" ;;
    *) verdict=FAIL;    FAILED=$((FAILED + 1)); note="exit $rc" ;;
  esac
  [ "$skips" -gt 0 ] && note="${note:+$note, }$skips check(s) skipped"

  if [ "$VERBOSE" -eq 0 ]; then
    # Always show the tail of anything that is not a clean pass, and show the
    # skip lines even on a pass -- those are the ones that would otherwise
    # disappear behind a green word.
    if [ "$verdict" != PASS ]; then
      sed 's/^/    /' "$log" | tail -15
    elif [ "$skips" -gt 0 ]; then
      grep '^[[:space:]]*\[skip\]' "$log" | sed 's/^/    /'
    fi
  fi
  printf '  -> %s (%ss)%s\n' "$verdict" "$dur" "${note:+ — $note}"
  SUMMARY+=("$(printf '  %-8s %-26s %4ss  %s' "$verdict" "$script" "$dur" "$note")")
}

# `all` selects every tier INCLUDING archive even with no --archive, so that
# the archive tier is reported as NOT RUN rather than vanishing from the
# summary. A tier that silently disappears is indistinguishable from one that
# passed.
want_tier() {
  case "$TIER" in
    all) return 0 ;;
    *)   [ "$1" = "$TIER" ] ;;
  esac
}

for e in "${REGISTRY[@]}"; do
  tier=${e%%|*}; rest=${e#*|}; script=${rest%%|*}
  want_tier "$tier" || continue
  [ -f "$ROOT/tests/$script" ] || continue   # already counted as a disagreement
  if [ "$tier" = archive ]; then
    if [ -z "$ARCHIVE" ]; then
      printf '\n=== %s  (%s) ===\n  -> NOT RUN — needs --archive <path>\n' "$script" "$tier"
      NOTRUN=$((NOTRUN + 1))
      SUMMARY+=("$(printf '  %-8s %-26s %4s   %s' "NOT RUN" "$script" "-" "needs --archive <path>")")
      continue
    fi
    run_one "$script" "$tier" "$ARCHIVE"
  else
    run_one "$script" "$tier"
  fi
done

printf '\n%s\n' "======================================================================"
printf 'tests/run.sh — tier: %s\n\n' "$TIER"
for line in ${SUMMARY[@]+"${SUMMARY[@]}"}; do printf '%s\n' "$line"; done
printf '\n  ran %d   passed %d   failed %d   refused %d   not run %d   checks skipped %d\n' \
  "$RAN" "$PASSED" "$FAILED" "$REFUSED" "$NOTRUN" "$SKIPS"
[ "$VERBOSE" -eq 0 ] && printf '  logs: %s\n' "$LOGDIR"

if [ "$DISAGREE" -gt 0 ]; then
  printf '\n  SUITE BROKEN: %d test file(s) and the registry in tests/run.sh disagree.\n' "$DISAGREE"
  printf '  Nothing below is a verdict on those files — they were never run.\n\n'
  exit 1
fi
if [ "$RAN" -eq 0 ]; then
  printf '\n  NOTHING RAN. Not a pass: no property in this tier was measured.\n\n'
  exit 2
fi
if [ "$FAILED" -gt 0 ]; then
  printf '\n  FAIL — %d test(s) failed.\n\n' "$FAILED"
  exit 1
fi
if [ "$REFUSED" -gt 0 ]; then
  printf '\n  INCOMPLETE — %d test(s) refused: their properties were NOT measured.\n' "$REFUSED"
  printf '  This is not a failure and it is not a pass. See the logs for what each\n'
  printf '  one needs; the root tier needs sudo and the archive tier needs --archive.\n\n'
  exit 2
fi
if [ "$SKIPS" -gt 0 ]; then
  printf '\n  PASS WITH GAPS — %d test(s) passed, but %d check(s) inside them were\n' "$PASSED" "$SKIPS"
  printf '  skipped and therefore not measured (listed above).\n\n'
  [ "$STRICT" -eq 1 ] && exit 3
  exit 0
fi
printf '\n  PASS — %d test(s), every check measured.\n\n' "$PASSED"
exit 0
