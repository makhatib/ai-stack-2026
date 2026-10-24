#!/usr/bin/env bash
# The installer's profile (service-group) selection, unit-tested against
# synthetic answer files and synthetic keystrokes.
#
# WHY THIS TEST EXISTS.  Step 8 chose the group with `[ -z
# "${ANS[COMPOSE_PROFILES]:-}" ]`, which cannot tell "the operator chose
# Starter" from "the operator said nothing" -- and Starter is the one
# selection in this installer whose correct value is the EMPTY STRING.  So an
# answer file containing `COMPOSE_PROFILES=` with --non-interactive installed
# the `knowledge` group and 9 services, exit 0, no warning (NOM-398, measured
# on the isolated QA target at 45a7907).  Interactive option 1 was fine; only
# the answer-file path was wrong, so no amount of installing this stack by
# hand would have found it.  A bug about the difference between absent and
# empty needs cases that are absent and cases that are empty.
#
# IT EXTRACTS THE SHIPPED CODE RATHER THAN RE-IMPLEMENTING IT.  Three blocks
# come out of install.sh -- the valid-key list, `parse_answers` and the
# selection block itself -- because the empty value has to survive the real
# parser before the real branch sees it, and a retyped copy of either would
# keep passing after install.sh drifted away from it.  If any extraction comes
# back empty this test exits 2 (CANNOT VERIFY) instead of reporting a pass
# over nothing.
#
# AND IT DRILLS ITSELF.  Section C rebuilds the pre-NOM-398 `:-` form of the
# shipped block and requires the explicit-empty case to FAIL against it.  A
# test that cannot reproduce the bug it is named after is decoration.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
RC=0
TOTAL=0
MISSING_MARK=__NOT_SET__
MIN_ASSERTIONS=13

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------------------
# Extraction.  Every piece is checked for emptiness AND for a single match;
# an anchor that now matches twice would silently measure half the code.
# ---------------------------------------------------------------------------
refuse() {
  printf 'profile selection: CANNOT VERIFY -- %s\n' "$1" >&2
  printf 'If step 8 or the answer parser was restructured, update this test.\n' >&2
  exit 2
}

KEYS="$TMPD/keys.sh"
FN="$TMPD/parse_answers.sh"
BLOCK="$TMPD/block.sh"

grep -n '^VALID_KEYS=' install.sh > "$TMPD/keys.hits" || true
[ "$(wc -l < "$TMPD/keys.hits")" = 1 ] \
  || refuse "install.sh has $(wc -l < "$TMPD/keys.hits") VALID_KEYS lines, expected 1"
sed -n 's/^\(VALID_KEYS=.*\)$/\1/p' install.sh > "$KEYS"

sed -n '/^parse_answers() {$/,/^}$/p' install.sh > "$FN"
[ -s "$FN" ] || refuse "parse_answers() could not be extracted from install.sh"
grep -q 'ANS\["\$key"\]=' "$FN" || refuse "the extracted parse_answers() never assigns into ANS"

sed -n '/^if \[ -z "${ANS\[COMPOSE_PROFILES\]/,/^fi$/p' install.sh > "$BLOCK"
[ -s "$BLOCK" ] || refuse "the selection block could not be extracted from install.sh"
[ "$(grep -c '^if \[ -z "${ANS\[COMPOSE_PROFILES\]' install.sh)" = 1 ] \
  || refuse "the selection block's opening anchor matches more than once"
grep -q 'NON_INTERACTIVE' "$BLOCK" \
  || refuse "the extracted selection block does not mention NON_INTERACTIVE"

printf 'profile selection (extracted from install.sh: %s-line key list, %s-line parser, %s-line selection block)\n' \
  "$(wc -l < "$KEYS")" "$(wc -l < "$FN")" "$(wc -l < "$BLOCK")"

# ---------------------------------------------------------------------------
# The harness.  install.sh's own `set -euo pipefail` is reproduced, because
# the EOF case below depends on it: a `read` that fails must stop the
# installer, not fall through to a silent default.
# ---------------------------------------------------------------------------
build_runner() {  # $1 = block file, $2 = runner path
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'say()  { printf "%s\n" "$*" >&2; }'
    printf '%s\n' 'warn() { printf "  ! %s\n" "$*" >&2; }'
    printf '%s\n' 'die()  { printf "DIE: %s\n" "$*" >&2; exit 1; }'
    printf '%s\n' 'declare -A ANS=()'
    cat "$KEYS"
    cat "$FN"
    printf '%s\n' 'if [ -n "${ANSWERS:-}" ]; then parse_answers "$ANSWERS"; fi'
    cat "$1"
    printf '%s\n' 'printf "%s\n" "${ANS[COMPOSE_PROFILES]-'"$MISSING_MARK"'}"'
  } > "$2"
}

RUNNER="$TMPD/runner.sh"
build_runner "$BLOCK" "$RUNNER"

# case_ <name> <ni|tty> <answer-file body, or - for none> <stdin, or - for closed> <expected>
# expected: STARTER | knowledge | <marker> | REFUSED
case_() {
  local name="$1" mode="$2" answers="$3" keys="$4" expect="$5"
  local ansfile="" out rc got
  TOTAL=$((TOTAL + 1))
  if [ "$answers" != '-' ]; then
    ansfile="$TMPD/answers.conf"
    printf '%s' "$answers" > "$ansfile"
  fi
  local ni=0
  [ "$mode" = ni ] && ni=1
  if [ "$keys" = '-' ]; then
    out="$(NON_INTERACTIVE="$ni" ANSWERS="$ansfile" bash "$RUNNER" </dev/null 2>/dev/null)"
    rc=$?
  else
    out="$(printf '%s' "$keys" | NON_INTERACTIVE="$ni" ANSWERS="$ansfile" bash "$RUNNER" 2>/dev/null)"
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    got=REFUSED
  elif [ -z "$out" ]; then
    got=STARTER
  else
    got="$out"
  fi
  if [ "$got" = "$expect" ]; then
    printf '  [ ok ] %-58s %s\n' "$name" "$got"
  else
    printf '  [FAIL] %-58s expected %s, got %s (exit %s)\n' "$name" "$expect" "$got" "$rc"
    RC=1
  fi
}

# ---------------------------------------------------------------------------
# A  The answer-file path.  THE REGRESSION IS THE SECOND CASE.
# ---------------------------------------------------------------------------
printf '\n  A. answer file, --non-interactive\n'

case_ "key omitted keeps the documented default" \
      ni "AISTACK_TZ=UTC
" - knowledge
case_ "COMPOSE_PROFILES= selects Starter" \
      ni "COMPOSE_PROFILES=
" - STARTER
case_ 'COMPOSE_PROFILES="" selects Starter too' \
      ni 'COMPOSE_PROFILES=""
' - STARTER
case_ "COMPOSE_PROFILES= among other keys" \
      ni "AISTACK_HOSTNAME=aistack.localhost
COMPOSE_PROFILES=
AISTACK_TZ=UTC
" - STARTER
case_ "COMPOSE_PROFILES=knowledge selects AI Automation" \
      ni "COMPOSE_PROFILES=knowledge
" - knowledge
case_ "no answer file at all keeps the default" \
      ni - - knowledge

# ---------------------------------------------------------------------------
# B  The interactive screen.  Option 1 was always right; it is here so that
#    a fix to the answer-file path cannot quietly break the keyboard path.
# ---------------------------------------------------------------------------
printf '\n  B. interactive screen\n'

case_ "choice 1 selects Starter" \
      tty - "1
" STARTER
case_ "choice 2 selects AI Automation" \
      tty - "2
" knowledge
case_ "bare Enter takes the [2] default" \
      tty - "
" knowledge
case_ "an unrecognised choice takes the [2] default" \
      tty - "9
" knowledge

# An answered key must not be re-asked.  Each of these feeds the keystroke
# for the OTHER group, so a stray prompt shows up as the wrong answer rather
# than having to be detected in the output.
case_ "answer file COMPOSE_PROFILES= is not re-asked" \
      tty "COMPOSE_PROFILES=
" "2
" STARTER
case_ "answer file COMPOSE_PROFILES=knowledge is not re-asked" \
      tty "COMPOSE_PROFILES=knowledge
" "1
" knowledge

# No stdin and no --non-interactive must stop, not pick something.
case_ "interactive with stdin closed refuses" \
      tty - - REFUSED

# ---------------------------------------------------------------------------
# C  The drill.  Rebuild the pre-NOM-398 form of the SHIPPED block and
#    require the explicit-empty case to fail against it.
# ---------------------------------------------------------------------------
printf '\n  C. drill: the pre-NOM-398 form must still fail\n'

PREFIX_OLD='if [ -z "${ANS[COMPOSE_PROFILES]+set}" ]; then'
PREFIX_NEW='if [ -z "${ANS[COMPOSE_PROFILES]:-}" ]; then'
if ! grep -qF "$PREFIX_OLD" "$BLOCK"; then
  printf '  [skip] the `+set` presence test is gone from install.sh, so the\n'
  printf '         pre-NOM-398 form cannot be reconstructed. If step 8 now\n'
  printf '         distinguishes absent from empty some other way, re-point\n'
  printf '         this drill at it -- do not delete it.\n'
else
  OLDBLOCK="$TMPD/block-prefix.sh"
  OLDRUNNER="$TMPD/runner-prefix.sh"
  python3 - "$BLOCK" "$OLDBLOCK" "$PREFIX_OLD" "$PREFIX_NEW" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src).read()
assert text.count(old) == 1, text.count(old)
open(dst, "w").write(text.replace(old, new))
PY
  build_runner "$OLDBLOCK" "$OLDRUNNER"
  printf 'COMPOSE_PROFILES=\n' > "$TMPD/drill-answers.conf"
  DRILL_OUT="$(NON_INTERACTIVE=1 ANSWERS="$TMPD/drill-answers.conf" bash "$OLDRUNNER" 2>/dev/null)"
  TOTAL=$((TOTAL + 1))
  if [ "$DRILL_OUT" = knowledge ]; then
    printf '  [ ok ] %-58s %s\n' "pre-NOM-398 block mis-selects on explicit empty" "knowledge"
  else
    printf '  [FAIL] %-58s %s\n' "pre-NOM-398 block should mis-select, gave" "${DRILL_OUT:-<empty>}"
    printf '         This test is no longer sensitive to the bug it exists for.\n'
    RC=1
  fi
fi

# ---------------------------------------------------------------------------
# Count what was measured.  A harness that silently stopped running cases is
# not a pass.
# ---------------------------------------------------------------------------
printf '\n  %s assertions evaluated\n' "$TOTAL"
if [ "$TOTAL" -lt "$MIN_ASSERTIONS" ]; then
  printf 'profile selection: CANNOT VERIFY -- only %s of at least %s assertions ran.\n' \
    "$TOTAL" "$MIN_ASSERTIONS" >&2
  exit 2
fi

echo
if [ "$RC" -eq 0 ]; then echo "profile selection: PASS"; else echo "profile selection: FAIL"; fi
exit "$RC"
