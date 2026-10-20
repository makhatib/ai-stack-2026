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
# E7's approved_at is 2026-10-18; put review_by 200 days out — NOT past due,
# which is exactly the case the old past-due-only check waved through.
far = (datetime.date(2026, 10, 18) + datetime.timedelta(days=200)).isoformat()
lines = s.split("\n"); out = []; inE7 = False
for ln in lines:
    if ln.startswith("  - id: "):
        inE7 = ln.strip() == "- id: E7"
    if inE7 and ln.startswith("    review_by:"):
        ln = "    review_by: " + far
    out.append(ln)
open(p, "w").write("\n".join(out))
print("E7 review_by set to", far, "(200 days, still in the future)")
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

echo
echo "cases passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
