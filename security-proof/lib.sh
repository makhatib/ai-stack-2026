# Shared by the three proof scripts.  Source it; do not run it.
#
# Exit codes, the same in all three scripts:
#   0  PASS  every check ran and held
#   1  FAIL  at least one check ran and did not hold
#   2  NOT MEASURED  something needed to measure was missing; neither PASS nor FAIL
PASS=0; FAIL=0; SKIP=0
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'; else B=; G=; R=; Y=; N=; fi
title() { printf "\n%s%s%s\n" "$B" "$1" "$N"; [ -z "${2:-}" ] || printf "%s\n" "$2"; }
ok()    { PASS=$((PASS+1)); printf '  %s[ ok ]%s %s\n' "$G" "$N" "$*"; }
bad()   { FAIL=$((FAIL+1)); printf '  %s[FAIL]%s %s\n' "$R" "$N" "$*"; }
skip()  { SKIP=$((SKIP+1)); printf '  %s[skip]%s %s (NOT MEASURED)\n' "$Y" "$N" "$*"; }
info()  { printf '        %s\n' "$*"; }
# verdict "<PASS line>" "<FAIL line>" -> prints the one line for the camera and exits.
verdict() {
  local yes="$1" no="${2:-$1}"
  printf '\n  checks: %d passed, %d failed, %d not measured\n' "$PASS" "$FAIL" "$SKIP"
  if [ "$FAIL" -gt 0 ]; then printf '\n%s%s FAIL: %s%s\n' "$B$R" "$NAME" "$no" "$N"; exit 1; fi
  if [ "$SKIP" -gt 0 ] || [ "$PASS" -eq 0 ]; then printf '\n%s%s NOT MEASURED: %s%s\n' "$B$Y" "$NAME" "$yes" "$N"; exit 2; fi
  printf '\n%s%s PASS: %s%s\n' "$B$G" "$NAME" "$yes" "$N"; exit 0
}
