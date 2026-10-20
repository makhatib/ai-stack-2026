#!/usr/bin/env bash
# tests/approval-authority.sh — the approval-authority rule, exercised.
#
# The gap this test exists for: before NOM-310, both gates rejected `PENDING`
# and the string "DevOps Engineer", and NEITHER rejected "Tech Lead" — an agent
# of this company, and the very one the registers named as reviewer.  Case 3 is
# that regression and it must stay failing-to-approve forever.
#
# Runs against ci/approvers.py directly with synthetic values.  It reads no
# scan evidence, starts no container and changes nothing, so it is safe to run
# at any time on any machine with python3.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import os, sys, tempfile, textwrap
sys.path.insert(0, os.path.join(os.getcwd(), "ci"))
import approvers as A

fails = []
def ok(cond, label):
    print(("  pass  " if cond else "  FAIL  ") + label)
    if not cond:
        fails.append(label)

real, probs = A.load_approvers(os.getcwd())
print("security-approvers.yaml:")
ok(not probs, f"the shipped approvers list parses with no problems ({probs})")
ok(len(real) >= 1, "at least one authorised approver is listed")
names = A.authorised_names(real)
print(f"  authorised: {names}")

print("\nvalues that must NOT be accepted as an approval:")
REJECT = [
    "PENDING",
    "null",   # distinct from n/a: 'null' as an approver name is not a decision
    "TBD",
    "DevOps Engineer (NOM-258), pending Tech Lead review",
    "Tech Lead",                      # THE GAP — case 3
    "tech lead",
    "Tech Lead (NOM-310)",
    "Tech Lead / Senior Engineer",
    "the Tech Lead, after review",
    "Modeer",                         # the CEO of this company is an agent
    "CTO Advisor",
    "the agent that measured it",
    "claude",
    "the team",
    "approved",
    "ok",
    "",
]
for v in REJECT:
    if v.lower() in ("", "null"):
        # `n/a`/`null` means "nothing to approve" to the callers, so the rule
        # returns no problems; what must hold is that it is NOT on the
        # authorised list, i.e. it can never be read as a named human.
        ok(not any(v.lower() == n.lower() for n in names),
           f"{v!r} is not an authorised approver")
        continue
    p = A.check_approved_by("TEST", v, real)
    ok(bool(p), f"{v!r} rejected  -> {p[0].split(': ',1)[1][:62] if p else 'ACCEPTED'}")

print("\nevery agent of this company, by name and by title:")
for n in A.AGENT_NAMES:
    ok(bool(A.check_approved_by("TEST", n, real)), f"{n!r} rejected")
    ok(bool(A.check_approved_by("TEST", f"{n} (2026-10-20)", real)),
       f"{n!r} rejected when dressed up with a date")

print("\nthe authorised human:")
for v in names:
    ok(not A.check_approved_by("TEST", v, real), f"{v!r} accepted")
    ok(not A.check_approved_by("TEST", v.lower(), real), f"{v.lower()!r} accepted (case)")
    ok(not A.check_approved_by("TEST", f"  {v}  ", real), f"{v!r} accepted (padded)")
    ok(bool(A.check_approved_by("TEST", f"{v}, Tech Lead", real)),
       f"{v!r} + an agent name is still rejected (both halves must pass)")
    ok(bool(A.check_approved_by("TEST", v.replace(" ", ""), real)),
       "a name that is not EXACTLY on the list is rejected")
print("  pass   n/a is the 'nothing to approve' value and raises nothing"
      if not A.check_approved_by("TEST", "n/a", real) else "  FAIL  n/a")
if A.check_approved_by("TEST", "n/a", real):
    fails.append("n/a")

print("\nthe approvers list itself:")
with tempfile.TemporaryDirectory() as d:
    _, p = A.load_approvers(d)
    ok(bool(p), "a MISSING approvers list is a failure, not an empty allowlist")
    ok(not A.authorised_names([]), "and authorises nobody")
    bad = textwrap.dedent("""\
        schema: aistack.security-approvers.v1
        approvers:
          - name: "Tech Lead"
            human: true
            authority_record: NOM-310
          - name: "A Person"
            authority_record: NOM-310
          - name: "B Person"
            human: true
        """)
    open(os.path.join(d, "security-approvers.yaml"), "w").write(bad)
    got, p = A.load_approvers(d)
    joined = " | ".join(p)
    ok(len(got) == 3, "all three entries parsed (none silently dropped)")
    ok("Tech Lead" in joined and "agent identity" in joined,
       "an agent that adds ITSELF to the list fails the list's own check")
    ok("human: true" in joined, "an entry not declaring human: true is a problem")
    ok("authority_record" in joined, "an entry citing no authority_record is a problem")

print()
if fails:
    print(f"FAIL — {len(fails)} assertion(s): {fails[:5]}")
    sys.exit(1)
print("OK — the approval-authority rule holds, including the 'Tech Lead' gap.")
PY
