#!/usr/bin/env bash
# Demo 4 -- business automation with human approval (MVP W3).
#
# The MVP's W3 workflow writes a daily summary, asks a named human to approve
# it, and delivers it only after that approval -- once, and only the exact text
# that was approved.  `aistack samples` already grades every step from the
# database; this check runs the whole story in order, as on camera:
#   1. run W3          -> an approval request appears, nothing is delivered
#   2. a person approves it (here: `samples approve <id> --yes`, the same command)
#   3. run W3 again    -> the approved text is delivered exactly once
#   4. P2              -> six negative cases: no self-approval, no double claim,
#                         no expired claim, no change after approval, ...
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
A="$ROOT/bin/aistack"
fail=0; t0=$(date +%s)
say() { printf '%s\n' "$*"; }

say "  -- 1. W3 asks for approval"
out1="$("$A" samples run W3 2>&1)"; rc1=$?
if printf '%s\n' "$out1" | grep -q "PASS     W3.6"; then
  # W3 is a DAILY summary: for 20 hours after a delivery it correctly asks for
  # nothing (W3.6).  A rehearsal earlier today leaves it there, so start the
  # demo database over -- the same reset the camera script tells you to do.
  say "  [info] today's summary was already delivered (W3.6); resetting the demo data: samples teardown + setup"
  "$A" samples teardown >/dev/null 2>&1 && "$A" samples setup >/dev/null 2>&1 && bash "$HERE/../setup.sh" >/dev/null 2>&1 \
    || { say "  [FAIL] could not reset the demo data"; exit 1; }
  out1="$("$A" samples run W3 2>&1)"; rc1=$?
fi
printf '%s\n' "$out1" | sed -n '/^== W3/,/^== Summary/p' | sed 's/^/     /'
id="$(printf '%s\n' "$out1" | grep -oE 'samples approve [0-9a-f-]{36}' | head -1 | awk '{print $3}')"
if [ "$rc1" -ne 0 ] || [ -z "$id" ]; then
  say "  [FAIL] W3 did not leave an approval request to decide (rc=$rc1)"; fail=1
else
  say "  [ok  ] W3 wrote approval request $id and delivered nothing"
  say "  -- 2. the human decision"
  "$A" samples approve "$id" --yes 2>&1 | grep -E "approver|recipient|scope|recorded" | sed 's/^/     /'
  say "  -- 3. W3 delivers what was approved"
  out3="$("$A" samples run W3 2>&1)"; rc3=$?
  printf '%s\n' "$out3" | sed -n '/^== W3/,/^== Summary/p' | sed 's/^/     /'
  if [ "$rc3" -eq 0 ] && printf '%s\n' "$out3" | grep -q "PASS     W3.5"; then
    say "  [ok  ] after approval the summary was delivered once (W3.5)"
  else
    say "  [FAIL] no W3.5 delivery after the approval (rc=$rc3)"; fail=1
  fi
fi
say "  -- 4. the negative cases"
out4="$("$A" samples run P2 2>&1)"; rc4=$?
printf '%s\n' "$out4" | grep -E "^\s+(PASS|FAIL|BLOCKED)" | sed 's/^/     /'
n="$(printf '%s\n' "$out4" | grep -cE '^\s+PASS +P2\.')"
if [ "$rc4" -eq 0 ] && [ "$n" -ge 6 ]; then say "  [ok  ] P2: $n negative cases refused as they should"; else say "  [FAIL] P2 (rc=$rc4, $n passed)"; fail=1; fi
st=PASS; [ "$fail" = 0 ] || st=FAIL
printf '{"demo": "04-approval-automation", "status": "%s", "times_s": {"total_s": %s}}\n' "$st" "$(( $(date +%s) - t0 ))"
exit "$fail"
