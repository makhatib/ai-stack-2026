#!/usr/bin/env bash
# NOM-341 — the three register controls, DRIVEN TO FAILURE.
#
# A check that has only ever passed is a note, not a control.  NOM-341 added
# three checks that the two registers' headers had CLAIMED for days while no
# code implemented them:
#
#   1. exception digest binding      ci/invariants.py I9
#   2. the review_by <= 180-day cap  ci/approvers.py, called by I9 and the gate
#   3. per-entry unit arithmetic     ci/scan-gate.py
#
# CONTROL 0 is the one that carries the other three: the gate's register half
# used to be reachable only through a DISPOSITIONS environment variable, so the
# invocation the register itself documents ran the coverage half, skipped
# controls 1-3 and exited 0.  A control you can skip by accident is a note too.
#
# Each case below makes ONE wrong edit on a SCRATCH COPY of the register and
# asserts the check names it.  Every case also asserts the check is QUIET on
# the unmutated file, because a check that fires on everything is as useless as
# one that fires on nothing.  Nothing here writes to the repo.
#
# Run:  tests/register-controls.sh
# Exit: 0 all cases behaved, 1 otherwise.
#
# Rollback: none needed — it only creates and removes its own mktemp -d.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

EVIDENCE="${EVIDENCE:-$(sed -n 's/^  evidence_dir:[[:space:]]*\(.*\)$/\1/p' security-findings.yaml | head -1)}"
if [ ! -d "$EVIDENCE" ]; then
  echo "FATAL: evidence dir '$EVIDENCE' not found. Set EVIDENCE=<scan dir>." >&2
  exit 2
fi
echo "evidence: $EVIDENCE"

PASS=0; FAIL=0
SCRATCH="$(mktemp -d /tmp/nom341-regctl.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

# ok <name> <expect-hit: yes|no> <needle> -- <command...>
# Runs the command, captures output, and checks whether $needle appears.
ok() {
  local name="$1" expect="$2" needle="$3"; shift 4
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$expect" = yes ]; then
    if printf '%s' "$out" | grep -qF -- "$needle"; then
      printf '  PASS  %s\n' "$name"; PASS=$((PASS+1))
      printf '%s\n' "$out" | grep -F -- "$needle" | head -2 | sed 's/^/          > /'
    else
      printf '  FAIL  %s — expected a failure mentioning %s, got none\n' "$name" "$needle"
      printf '%s\n' "$out" | tail -5 | sed 's/^/          | /'; FAIL=$((FAIL+1))
    fi
  else
    if printf '%s' "$out" | grep -qF -- "$needle"; then
      printf '  FAIL  %s — the check fired on CORRECT input\n' "$name"
      printf '%s\n' "$out" | grep -F -- "$needle" | head -3 | sed 's/^/          | /'; FAIL=$((FAIL+1))
    else
      printf '  PASS  %s (quiet on correct input)\n' "$name"; PASS=$((PASS+1))
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Controls 1 and 2 live in I9 and are driven through the real check functions
# against a scratch root holding only the three files they read.
# ---------------------------------------------------------------------------
i9probe() {   # i9probe <scratch-root>
  python3 - "$1" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "ci"))
import importlib.util, datetime, yaml
import approvers
spec = importlib.util.spec_from_file_location("inv", "ci/invariants.py")
inv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inv)

root = sys.argv[1]
class Stub:  # I9's digest binding reads ctx.root and nothing else
    pass
ctx = Stub(); ctx.root = root
reg = yaml.safe_load(open(os.path.join(root, "security-exceptions.yaml"))) or {}
for e in reg.get("exceptions") or []:
    if e.get("scope") == "deferred":
        continue
    for p in inv._exception_digest_binding(ctx, e):
        print("DIGEST-BINDING:", p)
    for p in approvers.check_review_window(
            f"exception {e.get('id')}", e.get("approved_at"), e.get("review_by")):
        print("REVIEW-WINDOW:", p)
PY
}

mkroot() {   # mkroot <name> -> prints a scratch root seeded with the real files
  local d="$SCRATCH/$1"
  mkdir -p "$d"
  cp versions.env security-exceptions.yaml security-approvers.yaml \
     security-findings.yaml "$d/"
  printf '%s' "$d"
}

echo
echo "CONTROL 1 — an exception's recorded digest must still be the pin (I9)"
CLEAN="$(mkroot clean)"
ok "clean register, digest binding silent" no "DIGEST-BINDING:" -- i9probe "$CLEAN"

BAD="$(mkroot baddigest)"
sed -i 's/^    digest: sha256:7a7e9f22015b67edb4bef5c59daeebcd7e74bfa570df6ce60ae01237c8648a84$/    digest: sha256:0000000000000000000000000000000000000000000000000000000000000000/' \
  "$BAD/security-exceptions.yaml"
grep -q "sha256:00000000" "$BAD/security-exceptions.yaml" || { echo "  FAIL  mutation did not apply"; FAIL=$((FAIL+1)); }
ok "E7 digest no longer matches POSTGRES_DIGEST" yes "is NOT the pinned digest" -- i9probe "$BAD"

MOVED="$(mkroot movedpin)"
sed -i 's/^POSTGRES_DIGEST=.*$/POSTGRES_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111/' \
  "$MOVED/versions.env"
ok "the PIN moves instead (same defect, other side)" yes "the pin moved" -- i9probe "$MOVED"

NOSVC="$(mkroot nopin)"
sed -i '0,/^  - id: E7$/{s/^  - id: E7$/  - id: E7/}' "$NOSVC/security-exceptions.yaml"
python3 - "$NOSVC/security-exceptions.yaml" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
# E7 keeps its digest but names a service that no pin covers
s = s.replace("  - id: E7\n    service: postgres\n",
              "  - id: E7\n    service: not-a-pinned-service\n", 1)
open(p, "w").write(s)
PY
ok "a digest whose service resolves to no pin FAILS, not skips" yes "resolve to no pin" -- i9probe "$NOSVC"

echo
echo "CONTROL 2 — review_by must be within 180 days of approved_at (I9 + gate)"
ok "clean register, review window silent" no "REVIEW-WINDOW:" -- i9probe "$CLEAN"

W200="$(mkroot window200)"
python3 - "$W200/security-exceptions.yaml" <<'PY'
import datetime, re, sys
p = sys.argv[1]; s = open(p).read()
# Put E7's review_by 200 days past ITS OWN approved_at — NOT past due, which is
# exactly the case the old past-due-only check waved through.
#
# Read that date from the register; do NOT hard-code it.  It was 2026-10-18
# when this case was written, the NOM-310 signature pass moved it to
# 2026-10-20, and the assertion below ("200 days after approved_at") then
# missed a message that correctly said 198.  The control was right and the test
# was stale.  `approved_at` moves at every signature, including the next
# re-signing, so the arithmetic has to follow the file.
lines = s.split("\n"); approved_at = None; inE7 = False
for ln in lines:
    if ln.startswith("  - id: "):
        inE7 = ln.strip() == "- id: E7"
    if inE7 and ln.startswith("    approved_at:"):
        approved_at = ln.split(":", 1)[1].strip().strip('"').strip("'")
if not approved_at:
    sys.exit("E7 carries no approved_at, so there is no window to make too long")
far = (datetime.date.fromisoformat(approved_at)
       + datetime.timedelta(days=200)).isoformat()
out = []; inE7 = False
for ln in lines:
    if ln.startswith("  - id: "):
        inE7 = ln.strip() == "- id: E7"
    if inE7 and ln.startswith("    review_by:"):
        ln = "    review_by: " + far
    out.append(ln)
open(p, "w").write("\n".join(out))
print("E7 approved_at is", approved_at, "- review_by set to", far,
      "(200 days out, still in the future)")
PY
ok "a 200-day window fails even though it is not past due" yes "200 days after approved_at" -- i9probe "$W200"

BACKWARD="$(mkroot windowback)"
python3 - "$BACKWARD/security-exceptions.yaml" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n"); out = []; inE7 = False
for ln in lines:
    if ln.startswith("  - id: "):
        inE7 = ln.strip() == "- id: E7"
    if inE7 and ln.startswith("    review_by:"):
        ln = "    review_by: 2026-10-01"
    out.append(ln)
open(p, "w").write("\n".join(out))
PY
ok "a review_by BEFORE approved_at fails" yes "is BEFORE approved_at" -- i9probe "$BACKWARD"

# ---------------------------------------------------------------------------
# Control 3 runs the real gate end to end against a scratch dispositions file.
# ---------------------------------------------------------------------------
echo
echo "CONTROL 3 — a declared unit count must equal what the scan measures (gate)"
gate() {   # gate <scratch-root>
  DISPOSITIONS="$1/security-findings.yaml" GATE_JSON="$1/gate.json" \
    python3 ci/scan-gate.py versions.env "$EVIDENCE"
}
ok "clean register, arithmetic silent" no "unit-arithmetic error" -- gate "$CLEAN"

UNITS="$(mkroot wrongunits)"
python3 - "$UNITS/security-findings.yaml" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n"); out = []; cur = None
for ln in lines:
    if ln.startswith("  - id: "):
        cur = ln.split("- id:")[1].strip()
    if cur == "V6" and ln.startswith("    units:"):
        ln = "    units: 62"          # the exact figure NOM-309 found wrong
    out.append(ln)
open(p, "w").write("\n".join(out))
PY
ok "V6 declaring 62 against 79 measured" yes "declares units: 62 but the scan measures 79" -- gate "$UNITS"

CRIT="$(mkroot wrongcrit)"
python3 - "$CRIT/security-findings.yaml" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n"); out = []; cur = None
for ln in lines:
    if ln.startswith("  - id: "):
        cur = ln.split("- id:")[1].strip()
    if cur == "V6" and ln.startswith("    critical_units:"):
        ln = "    critical_units: 9"
    out.append(ln)
open(p, "w").write("\n".join(out))
PY
ok "V6 declaring 9 CRITICAL against 8 measured" yes "declares critical_units: 9 but the scan measures 8" -- gate "$CRIT"

MISSING="$(mkroot missingdecl)"
python3 - "$MISSING/security-findings.yaml" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n"); out = []; cur = None
for ln in lines:
    if ln.startswith("  - id: "):
        cur = ln.split("- id:")[1].strip()
    # the dodge: say nothing rather than say something wrong
    if cur == "V10" and ln.startswith("    critical_units:"):
        continue
    out.append(ln)
open(p, "w").write("\n".join(out))
PY
ok "an UNDECLARED figure is not a passing figure" yes "V10: declares no critical_units" -- gate "$MISSING"

HEADER="$(mkroot wrongheader)"
python3 - "$HEADER/security-findings.yaml" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n"); out = []; inblk = False
for ln in lines:
    if ln.startswith("  totals_after_V0_bump:"):
        inblk = True
    elif inblk and ln[:4].strip():
        inblk = False
    if inblk and ln.startswith("    blocking_units:"):
        ln = "    blocking_units: 203"   # the stale header NOM-309 flagged
    out.append(ln)
open(p, "w").write("\n".join(out))
PY
ok "entries right, HEADER stale — still fails" yes "header totals_after_V0_bump.blocking_units says 203" -- gate "$HEADER"

# ---------------------------------------------------------------------------
# Control 0 — the register half cannot be skipped without saying so.
# ---------------------------------------------------------------------------
echo
echo "CONTROL 0 — the gate cannot run its coverage half alone in silence"
gateflag() {   # gateflag <scratch-root>  — the invocation the register documents
  GATE_JSON="$1/gate.json" env -u DISPOSITIONS \
    python3 ci/scan-gate.py --dispositions "$1/security-findings.yaml" \
      versions.env "$EVIDENCE"
}
gatebare() {   # no register named at all
  GATE_JSON="$SCRATCH/bare.json" env -u DISPOSITIONS \
    python3 ci/scan-gate.py versions.env "$EVIDENCE"
}
gatecov() {    # the narrower run, asked for out loud
  GATE_JSON="$SCRATCH/cov.json" env -u DISPOSITIONS \
    python3 ci/scan-gate.py --coverage-only versions.env "$EVIDENCE"
}
ok "no register named at all FAILS, it does not pass quietly" yes \
   "REGISTER CHECKS DID NOT RUN" -- gatebare
ok "...and does not print a clean verdict while skipping them" no \
   "COVERAGE COMPLETE" -- gatebare
ok "--coverage-only runs, and says what it did not check" yes \
   "REGISTER NOT CHECKED" -- gatecov
ok "the DOCUMENTED --dispositions form reaches the arithmetic check" yes \
   "unit arithmetic: per-entry declarations vs this scan" -- gateflag "$UNITS"
ok "...and that form still catches the wrong figure" yes \
   "declares units: 62 but the scan measures 79" -- gateflag "$UNITS"

# ---------------------------------------------------------------------------
# Control 4 — the gate must not call a regression on a SIGNED register
# "EXPECTED".  Before NOM-310 every approved_by was PENDING, so the one
# summary line the gate had ("EXPECTED until the named human approver
# approves; this is the control working") was true.  The signature made it a
# lie for every later failure: a tampered name, a PENDING value put back, or
# a widened review_by window would all be reported as expected and
# self-congratulatory.  It also asserted a cause that may not be the one the
# per-entry lines gave -- re-approving does not fix a bad date.
# ---------------------------------------------------------------------------
echo
echo "CONTROL 4 — on a signed register, a failure reads as a REGRESSION not as EXPECTED"

SIGNEDREG="$(mkroot signedreg)"
ok "clean signed register says nothing about regressions" no \
   "REGRESSION on a signed register" -- gateflag "$SIGNEDREG"
ok "...and does not call itself unsigned" no \
   "EXPECTED while the register is unsigned" -- gateflag "$SIGNEDREG"

TAMPER="$(mkroot tampered)"
python3 - "$TAMPER/security-findings.yaml" <<'PY'
import sys
# Put ONE agent name back on an otherwise fully signed register.
p = sys.argv[1]; s = open(p).read()
needle = 'approved_by: "Mahmoud Alkhatib"'
if needle not in s:
    sys.exit("no signed entry to tamper with -- is the register still signed?")
open(p, "w").write(s.replace(needle, 'approved_by: "Tech Lead"', 1))
PY
ok "one agent name on a signed register is a REGRESSION" yes \
   "REGRESSION on a signed register" -- gateflag "$TAMPER"
ok "...and is NOT reported as the expected pre-signature state" no \
   "EXPECTED while the register is unsigned" -- gateflag "$TAMPER"
ok "...and still names the real cause per entry" yes \
   "names an agent of this company" -- gateflag "$TAMPER"

WIDENED="$(mkroot widened)"
python3 - "$WIDENED/security-findings.yaml" <<'PY'
import sys
# A widened window is NOT a missing approval, and must not be reported as one.
p = sys.argv[1]; lines = open(p).read().split("\n"); out = []; done = False
for ln in lines:
    if not done and ln.startswith("    review_by:"):
        ln = "    review_by: 2099-01-01"; done = True
    out.append(ln)
if not done:
    sys.exit("no review_by found to widen")
open(p, "w").write("\n".join(out))
PY
ok "a widened review_by on a signed register is a REGRESSION" yes \
   "REGRESSION on a signed register" -- gateflag "$WIDENED"
ok "...and the summary does not blame a missing approval for it" yes \
   "may be the approver name, a PENDING value, or an expired review_by window" \
   -- gateflag "$WIDENED"

UNSIGNED="$(mkroot unsignedreg)"
python3 - "$UNSIGNED/security-findings.yaml" <<'PY'
import sys
# The pre-signature state must STILL read as expected -- the fix must not
# invert into crying regression at a register nobody has signed yet.
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace('approved_by: "Mahmoud Alkhatib"', "approved_by: PENDING"))
PY
ok "a wholly unsigned register is still EXPECTED, not a regression" yes \
   "EXPECTED while the register is unsigned" -- gateflag "$UNSIGNED"
ok "...and is not called a regression" no \
   "REGRESSION on a signed register" -- gateflag "$UNSIGNED"

echo
echo "cases passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
