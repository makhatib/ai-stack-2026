#!/usr/bin/env bash
# NOM-353 — proves scripts/security-check.sh actually RUNS ci/scan-gate.py and
# that a failing gate fails the audit.
#
# WHY THIS TEST IS SHAPED LIKE THIS.  The thing being tested is a WIRE: the
# gate already worked and the audit already worked, and the defect was that
# the audit never called the gate.  A test that runs the gate directly would
# have passed on the broken version, so this one runs the AUDIT and asserts on
# what the audit says and on the audit's exit code.
#
# It therefore needs a root the audit will call clean, which the repo itself
# is -- so part 1 builds a FIXTURE COPY of the repo and establishes that
# baseline first.  Every later part changes exactly ONE thing in that fixture
# and attributes the difference to it.  If the baseline is not clean the test
# REFUSES (exit 2) instead of reporting results it cannot attribute.
#
# Part 3 is the before/after: HEAD-before-NOM-353's security-check.sh, run on
# the SAME broken register, reports "audit clean".  Without that line part 2
# only shows a red light, not that the red light is new.
#
# Requirements: the real repo's audit must currently be clean (it is run
# unprivileged and --audit-only, ~6s), docker must be reachable for the
# container half, and at least one security-report-*/ directory must hold BOTH
# trivy/ and grype/ evidence.
#
# Usage:  tests/test-scan-gate.sh
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# The commit this ticket's change landed on top of.  Pinned, not "HEAD~1":
# the point of part 3 is a comparison against the version with NO gate call,
# and that is this exact tree, however many commits land later.
BASE_COMMIT="ae9fceb"

FAIL=0
SKIPPED=0
CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); printf '  [ ok ] %s\n' "$*"; }
fail() { CHECKS=$((CHECKS + 1)); FAIL=1; printf '  [FAIL] %s\n' "$*"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  [skip] %s\n' "$*"; }
refuse() { printf '\n  [REFUSE] %s\n\n' "$*"; exit 2; }

printf '\nNOM-353 scan-gate wiring\n'

# --------------------------------------------------------------------------
# Fixture.  A copy of the repo on the REPO'S OWN FILESYSTEM, because the
# evidence directory is ~230 MB and is brought in with hardlinks; /tmp here is
# a tmpfs on a different device, where `cp -al` fails with EXDEV.
#
# Evidence files written by a `sudo security-check` run are root-owned, and
# fs.protected_hardlinks forbids linking to a file you do not own, so those
# fall back to a real copy.  `cp -an` fills in only what the link pass missed.
# Deleting hardlinks never touches the originals; the fixture dir is also
# LABELLED (not the security-report-<UTC> shape) so prune-reports.sh inside
# the audit will not consider it prunable.
# --------------------------------------------------------------------------
EV=""
for d in "$REPO"/security-report-*/; do
  [ -d "$d/trivy" ] && [ -d "$d/grype" ] && EV="${d%/}"
done
[ -n "$EV" ] || refuse "no security-report-*/ directory holds BOTH trivy/ and grype/.
            The gate needs a grype second opinion per pin, so without one
            every part of this test would fail for the wrong reason.
            Produce evidence first: scripts/scan-evidence.sh"

R="$(mktemp -d "$REPO/../gate-test.XXXXXX")" || refuse "could not create a fixture root"
case "$R" in
  */gate-test.*) ;;
  *) refuse "refusing to clean up an unexpected fixture path: $R" ;;
esac
cleanup() { case "$R" in */gate-test.*) rm -rf "$R" ;; esac; }
trap cleanup EXIT

printf '  fixture: %s\n  evidence: %s\n' "$R" "$(basename "$EV")"
# The producing tar's EXIT CODE is not the check here: secrets/ holds
# root-owned files it cannot read, so it exits nonzero on a healthy repo and
# under pipefail that would abort the whole test.  What matters is whether the
# files the audit needs arrived, so that is what is asserted -- and secrets/ is
# excluded outright, because it is replaced by a symlink to the real one so
# `docker compose config` behaves in the fixture exactly as in the repo.
( cd "$REPO" && tar -cf - \
    --exclude='./security-report-*' --exclude='./backups' --exclude='./secrets' \
    --exclude='./support-bundle-*' . 2>/dev/null ) | tar -xf - -C "$R" 2>/dev/null
for need in .git scripts/security-check.sh ci/scan-gate.py ci/invariants.py \
            versions.env security-findings.yaml security-approvers.yaml compose.yaml; do
  [ -e "$R/$need" ] || refuse "the fixture copy is missing $need, so the audit could not run in it"
done
ln -s "$REPO/secrets" "$R/secrets"
# The repo root may already carry an untracked gate.json from someone running
# the gate by hand -- the very file the GATE_JSON redirect exists to stop the
# audit from rewriting.  Remove it from the FIXTURE, or part 1's "did not write
# gate.json into the repo root" assertion passes on a file that was copied in
# and can never fail.
rm -f "$R/gate.json"
FIXEV="$R/security-report-fixture-20260101T000000Z"
cp -al "$EV" "$FIXEV" 2>/dev/null
cp -an "$EV/." "$FIXEV/" 2>/dev/null
[ -d "$FIXEV/trivy" ] && [ -d "$FIXEV/grype" ] || refuse "evidence did not copy into the fixture"

run_audit() {  # run_audit <script-relative-path> <logfile> -> exit code in RC_LAST
  ( cd "$R" && bash "$1" --audit-only ) > "$2" 2>&1
  RC_LAST=$?
}

# --- 1. baseline: the fixture is clean, and the gate ran -------------------
printf '\n1. baseline\n'
run_audit scripts/security-check.sh "$R/log1"
[ "$RC_LAST" -eq 0 ] || { sed -n 's/^  \[FAIL\]/    /p' "$R/log1";
  refuse "the fixture baseline audit is NOT clean (exit $RC_LAST), so nothing
            below could be attributed to the one thing each part changes.
            Fix the repo's audit first: scripts/security-check.sh --audit-only"; }
pass "fixture audit is clean (exit 0) — later parts are attributable"
grep -q 'Audit: release gate' "$R/log1" \
  && pass "the audit has a release-gate step at all" \
  || fail "no release-gate step in the audit output — the gate is still unwired"
grep -q '\[ ok \] release gate passes' "$R/log1" \
  && pass "gate reported a PASS on good inputs" \
  || fail "gate did not report a pass on good inputs: $(grep -i 'release gate' "$R/log1")"
# A pass line that cannot say what it read is the defect this repo keeps
# finding.  Assert the evidence count and the approval state are in the output.
grep -qE '\[ ok \] release gate passes \([1-9][0-9]* evidence dir' "$R/log1" \
  && pass "the pass line states how many evidence dirs it read" \
  || fail "pass line does not state an evidence-dir count"
grep -qE '^ +approvals: [0-9]+/[0-9]+ entries carry a named human approval' "$R/log1" \
  && pass "the pass line carries the gate's approval state" \
  || fail "approval state missing from the audit output"
# gate.json belongs to the run, not to the repo root: a root copy is rewritten
# by every audit, and the evidence_dir names in it would make a generated
# report dir CITED and therefore immune to retention (the NOM-350 leak).
GOUT="$(sed -n 's/.*verdict in \(.*\)\/scan-gate.txt.*/\1/p' "$R/log1" | tail -1)"
[ -n "$GOUT" ] && [ -s "$GOUT/gate.json" ] \
  && pass "machine-readable verdict written inside the run's report dir" \
  || fail "no gate.json in the run's report dir (looked in '${GOUT:-unset}')"
[ -e "$R/gate.json" ] \
  && fail "the audit wrote gate.json into the repo ROOT — that is the retention hazard" \
  || pass "the audit did not write gate.json into the repo root"

# --- 2. fail path: one declared figure no longer matches the scan ----------
# The smallest possible register defect: a single digit. The gate's
# per-entry unit arithmetic is one of the three controls that fired for
# nobody before this wiring existed.
printf '\n2. fail path — a declared figure the scan contradicts\n'
cp "$R/security-findings.yaml" "$R/.reg.good"
LINE="$(grep -nE '^    units: [0-9]+' "$R/security-findings.yaml" | awk -F: '$3+0>1{print $1; exit}')"
[ -n "$LINE" ] || refuse "found no per-entry 'units:' figure above 1 to perturb"
OLDV="$(sed -n "${LINE}s/^    units: //p" "$R/security-findings.yaml")"
sed -i "${LINE}s/^    units: .*/    units: $((OLDV - 1))/" "$R/security-findings.yaml"
printf '  perturbed security-findings.yaml:%s  units: %s -> %s\n' "$LINE" "$OLDV" "$((OLDV - 1))"
run_audit scripts/security-check.sh "$R/log2"
[ "$RC_LAST" -eq 1 ] \
  && pass "a failing gate FAILS the audit (exit 1)" \
  || fail "audit exited $RC_LAST with a broken register; expected 1"
grep -q '\[FAIL\] RELEASE GATE FAILED' "$R/log2" \
  && pass "the audit names the gate as the failure" \
  || fail "no RELEASE GATE FAILED line: $(grep -i 'release gate' "$R/log2")"
grep -q 'unit-arithmetic error' "$R/log2" \
  && pass "the audit surfaces the gate's reason, not just a red light" \
  || fail "the gate's reason was not surfaced into the audit output"
grep -q 'security-check: PROBLEMS' "$R/log2" \
  && pass "the final summary line says PROBLEMS, not clean" \
  || fail "final summary line still reads clean with a broken register"

# --- 3. before/after: the same defect was INVISIBLE before this change ----
printf '\n3. before/after against %s (pre-NOM-353)\n' "$BASE_COMMIT"
if ( cd "$REPO" && git cat-file -e "$BASE_COMMIT:scripts/security-check.sh" ) 2>/dev/null; then
  ( cd "$REPO" && git show "$BASE_COMMIT:scripts/security-check.sh" ) > "$R/scripts/security-check-OLD.sh"
  if grep -q 'scan-gate' "$R/scripts/security-check-OLD.sh"; then
    fail "$BASE_COMMIT already calls scan-gate — BASE_COMMIT is wrong, so part 3 proves nothing"
  else
    run_audit scripts/security-check-OLD.sh "$R/log3"
    [ "$RC_LAST" -eq 0 ] && grep -q 'security-check: audit clean' "$R/log3" \
      && pass "pre-change audit called the SAME broken register clean (exit 0) — the defect was real and silent" \
      || fail "pre-change audit exited $RC_LAST on the broken register; part 2's red light is not attributable to the wiring"
  fi
else
  skip "commit $BASE_COMMIT is not in this clone, so the before/after was NOT run"
fi
cp "$R/.reg.good" "$R/security-findings.yaml"

# --- 4. could-not-run is neither a failure nor a pass ---------------------
printf '\n4. the gate cannot run at all\n'
mv "$R/security-findings.yaml" "$R/.reg.hidden"
run_audit scripts/security-check.sh "$R/log4"
[ "$RC_LAST" -eq 1 ] \
  && pass "a gate that could not run fails the audit (exit 1)" \
  || fail "audit exited $RC_LAST with no register; expected 1"
grep -q 'RELEASE GATE COULD NOT RUN' "$R/log4" \
  && pass "it is reported as COULD NOT RUN, distinct from a verdict of no" \
  || fail "a missing register was not distinguished from a gate failure"
grep -q 'NOT a gate failure and NOT a pass' "$R/log4" \
  && pass "the output refuses to be read as either" \
  || fail "could-not-run output does not say what it is not"
mv "$R/.reg.hidden" "$R/security-findings.yaml"

# --- 5. no evidence at all is NOT RUN, not clean --------------------------
printf '\n5. no scan evidence\n'
mv "$FIXEV" "$R/.ev.hidden"
run_audit scripts/security-check.sh "$R/log5"
[ "$RC_LAST" -eq 1 ] \
  && pass "an evidence-less gate fails the audit (exit 1)" \
  || fail "audit exited $RC_LAST with no evidence; expected 1"
grep -q 'NOT RUN — no security-report' "$R/log5" \
  && pass "reported as NOT RUN with the fix named" \
  || fail "missing evidence was not reported as NOT RUN"
grep -q 'NOT a clean result' "$R/log5" \
  && pass "explicitly not a clean result" \
  || fail "missing-evidence branch did not disclaim cleanliness"
mv "$R/.ev.hidden" "$FIXEV"

# --- 6. the call site hands over EVERY report dir, so ranking must hold ---
# security-check.sh passes the whole pool of report directories, because the
# grype half of the evidence only ever exists in a hand-labelled
# scan-evidence dir.  That is only safe while index_reports prefers the more
# COMPLETE scan of a digest over the last one listed [NOM-341]: before that
# fix, glob order could let a trivy-only recheck shadow a full scan (docling
# measured 3 units instead of 75).  This part rebuilds that collision from
# the fixture's own evidence -- a second dir with the same trivy reports and
# NO grype/, named so it sorts LAST -- and asserts the complete one still
# wins, in both argument orders.
printf '\n6. a trivy-only dir must not shadow a complete scan of the same digest\n'
SHADOW="$R/security-report-zzshadow-20260101T000000Z"
mkdir -p "$SHADOW/trivy" && cp "$FIXEV"/trivy/*.json "$SHADOW/trivy/" 2>/dev/null
NSH=$(ls -1 "$SHADOW/trivy"/*.json 2>/dev/null | wc -l)
[ "$NSH" -gt 0 ] || refuse "could not build the shadow fixture (no trivy JSON copied)"
gate_units() {  # gate_units <json> <image-key>
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    e = json.load(open(sys.argv[1]))[sys.argv[2]]
except Exception:
    print("MISSING 0 -"); raise SystemExit
print(e.get("status"), len(e.get("units") or {}), e.get("evidence_dir") or "-")
PY
}
# First establish that the shadow dir ALONE reads differently -- an assertion
# that cannot tell the two apart would pass either way.
( cd "$R" && GATE_JSON=.g-shadow.json python3 ci/scan-gate.py --coverage-only \
    versions.env security-report-zzshadow-20260101T000000Z ) >/dev/null 2>&1
read -r _ SH_UNITS _ < <(gate_units "$R/.g-shadow.json" DOCLING)
( cd "$R" && GATE_JSON=.g-full.json python3 ci/scan-gate.py --coverage-only \
    versions.env security-report-fixture-20260101T000000Z ) >/dev/null 2>&1
read -r _ FULL_UNITS _ < <(gate_units "$R/.g-full.json" DOCLING)
if [ "$SH_UNITS" -lt "$FULL_UNITS" ] && [ "$FULL_UNITS" -gt 0 ]; then
  pass "the shadow is genuinely worse evidence (DOCLING $SH_UNITS units vs $FULL_UNITS) — the assertion can discriminate"
else
  fail "shadow ($SH_UNITS) is not worse than the complete scan ($FULL_UNITS); part 6 cannot prove anything"
fi
for order in "security-report-fixture-20260101T000000Z security-report-zzshadow-20260101T000000Z" \
             "security-report-zzshadow-20260101T000000Z security-report-fixture-20260101T000000Z"; do
  # shellcheck disable=SC2086
  ( cd "$R" && GATE_JSON=.g-both.json python3 ci/scan-gate.py \
      --dispositions security-findings.yaml versions.env $order ) > "$R/log6" 2>&1
  rc6=$?
  read -r _ u dir < <(gate_units "$R/.g-both.json" DOCLING)
  if [ "$u" = "$FULL_UNITS" ] && [ "$dir" != "security-report-zzshadow-20260101T000000Z" ]; then
    pass "complete scan wins (DOCLING $u units from $dir) with ${order%% *} listed first"
  else
    fail "WORSE evidence won: DOCLING $u units from $dir with ${order%% *} first"
  fi
  [ "$rc6" -eq 0 ] \
    && pass "  and the gate still passes over the mixed pool (exit 0)" \
    || fail "  gate exited $rc6 over the mixed pool: $(sed -n '/GATE FAILURES/,$p' "$R/log6" | head -3 | tr '\n' ' ')"
done
# DOCLING is also the Trivy unsupported-OS case: its OS layer is closed by
# grype alone, and the gate must accept that rather than read trivy's missing
# os-pkgs result as clean.
read -r _ _ _ < <(gate_units "$R/.g-full.json" DOCLING)
python3 - "$R/.g-full.json" <<'PY' && pass "DOCLING's OS layer is covered by grype alone and the gate accepts it" \
  || fail "DOCLING OS coverage is not what the unsupported-OS case requires"
import json, sys
e = json.load(open(sys.argv[1]))["DOCLING"]
raise SystemExit(0 if e.get("os_covered") and e.get("os_covered_by") == ["grype"] else 1)
PY

# --------------------------------------------------------------------------
printf '\n'
if [ "$FAIL" -eq 0 ] && [ "$SKIPPED" -eq 0 ]; then
  printf 'NOM-353 scan-gate wiring: PASS (%s checks)\n' "$CHECKS"
elif [ "$FAIL" -eq 0 ]; then
  printf 'NOM-353 scan-gate wiring: PASS with %s SKIPPED (%s checks ran) — read the skips above.\n' \
    "$SKIPPED" "$CHECKS"
else
  printf 'NOM-353 scan-gate wiring: FAIL (%s checks, %s skipped)\n' "$CHECKS" "$SKIPPED"
fi
exit "$FAIL"
