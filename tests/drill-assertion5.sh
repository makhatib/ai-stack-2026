#!/usr/bin/env bash
# AI Stack 2026 — the drill's assertion 5 (cluster-kind databases), driven
# without docker, without a stack and without a maintenance window (NOM-393).
#
# WHY THIS TEST EXISTS.
#
# Assertion 5 in scripts/drill.sh is the one that turns "the control database
# came back empty" from a pg_restore warning into a FAILURE (NOM-392).  Its
# only exercise was a LIVE drill, which needs the serving stack stopped — so
# every change to it cost a maintenance window, and the branches a live drill
# cannot reach (a missing database, a cluster that does not answer, a
# non-numeric count) were never measured at all.
#
# It also shipped with a defect that a live drill could not have found,
# because no archive the stack produces today can trigger it.  restore.sh
# writes the kinds channel as `<kind> <name>` per line; assertion 5 read the
# name back as awk's `$2` and looped with an unquoted `for`.  Both split on
# whitespace, so a database name CONTAINING a space arrived truncated:
#
#     kinds line `cluster my db`  ->  [ ok ] cluster-kind database 'my'
#                                     restored and is not empty (6 tables, 31 rows)
#
# A green assertion about a database that is not in the archive, while the one
# that is went unchecked — and the [A-Za-z0-9_] refusal that was supposed to
# stop exactly this never saw a space to refuse.  Case 14 below is that line.
#
# IT RUNS THE SHIPPED BLOCK, NOT A COPY OF IT.  The block is extracted from
# scripts/drill.sh between its own anchor and the end of the assertion, then
# eval'd with a STUB `q()` that answers the two queries with whatever the case
# wants.  A retyped copy would pass forever while drill.sh drifted.  If the
# anchor is gone, or matches more than once, the test REFUSES (exit 2) rather
# than reporting on a block it could not find.
#
# AND IT PROVES ITS OWN TEETH.  The last section rebuilds the pre-NOM-393
# field-wise reader out of the shipped block and requires the space case to
# PRODUCE the defect there.  A test whose key case cannot fail on the broken
# code is not evidence; if the substitution no longer applies, that is a
# [skip] with the reason, never a silent pass.
#
# No docker, no postgres, no secrets, no live stack: psql is a shell function.
#
# Run:  tests/drill-assertion5.sh        (<1s)
#
# Rollback: delete this file and its line from the REGISTRY in tests/run.sh.
# It writes nothing outside its own mktemp.

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

SRC="${1:-$ROOT/scripts/drill.sh}"

PASS=0
FAIL=0
SKIP=0

t_ok()   { printf '  ok    %s\n' "$*"; PASS=$((PASS + 1)); }
t_bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
t_skip() { printf '  [skip] %s\n' "$*"; SKIP=$((SKIP + 1)); }
note()   { printf '        %s\n' "$*"; }
refuse() { printf '\n  REFUSED: %s\n\n' "$*" >&2; exit 2; }

printf '\n== drill assertion 5: cluster-kind databases, present and not empty ==\n\n'

# --- extract the shipped block ---------------------------------------------
[ -r "$SRC" ] || refuse "cannot read $SRC"

ANCHOR='^  # 5\. CLUSTER-KIND DATABASES'
N="$(grep -c "$ANCHOR" "$SRC")"
[ "$N" = "1" ] || refuse "the assertion-5 anchor matched $N times in $SRC, not once"

BLOCK="$(awk '/^  # 5\. CLUSTER-KIND DATABASES/{f=1} f && /^fi$/{exit} f{print}' "$SRC")"
case "$BLOCK" in
  *CLUSTER_DBS*LEGACY_DBS*) ;;
  *) refuse "the extracted block does not mention both CLUSTER_DBS and LEGACY_DBS" ;;
esac
BLOCK_LINES="$(printf '%s\n' "$BLOCK" | wc -l | tr -d ' ')"
[ "$BLOCK_LINES" -ge 40 ] \
  || refuse "the extracted block is only $BLOCK_LINES lines; that is not assertion 5"
note "extracted $BLOCK_LINES lines of shipped assertion-5 code from ${SRC#$ROOT/}"
printf '\n'

# --- the driver ------------------------------------------------------------
# run_case <name> <kinds-file content> <want_rc> <want_re> [<want_not_re>] [<want_re2>]
# Q_PRESENT / Q_COUNT in the environment are what the stubbed cluster answers.
# LAST_OUT keeps the output so a case can make a further assertion about it.
LAST_OUT=""
run_case() {
  local name="$1" kinds="$2" want_rc="$3" want_re="$4" want_not_re="${5:-}" want_re2="${6:-}"
  local body="$7" out rc got_rc why=""
  out="$(
    set -uo pipefail
    DRILL_RC=0
    ok()  { printf '  [ ok ] %s\n' "$*"; }
    bad() { printf '  [FAIL] %s\n' "$*"; DRILL_RC=1; }
    RESTORED_KINDS="$(mktemp)"
    printf '%s' "$kinds" > "$RESTORED_KINDS"
    # The stubbed cluster.  $1 is the database, $2 the SQL; which query it is
    # is decided by the SQL's own text, so a reworded query still routes.
    q() {
      case "$2" in
        *pg_database*)  printf '%s' "${Q_PRESENT-checked:present}" ;;
        *query_to_xml*) printf '%s' "${Q_COUNT-checked:6:31}" ;;
        *)              printf '' ;;
      esac
    }
    eval "$body"
    rm -f "$RESTORED_KINDS"
    printf 'RC=%s\n' "$DRILL_RC"
  )"; rc=$?
  LAST_OUT="$out"
  if [ "$rc" -ne 0 ]; then
    t_bad "$name — the driver itself errored (rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/          | /'
    return 1
  fi
  got_rc="$(printf '%s\n' "$out" | sed -n 's/^RC=//p')"
  [ "$got_rc" = "$want_rc" ] || why="rc=$got_rc, wanted $want_rc"
  printf '%s\n' "$out" | grep -Eq "$want_re" || why="${why:+$why; }output does not match /$want_re/"
  if [ -n "$want_re2" ]; then
    printf '%s\n' "$out" | grep -Eq "$want_re2" || why="${why:+$why; }output does not match /$want_re2/"
  fi
  if [ -n "$want_not_re" ] && printf '%s\n' "$out" | grep -Eq "$want_not_re"; then
    why="${why:+$why; }output DOES match /$want_not_re/, which it must not"
  fi
  if [ -z "$why" ]; then
    t_ok "$name"
    return 0
  fi
  t_bad "$name — $why"
  printf '%s\n' "$out" | sed 's/^/          | /'
  return 1
}

# shipped() runs a case against the block as it ships.
shipped() { run_case "$1" "$2" "$3" "$4" "${5:-}" "${6:-}" "$BLOCK"; }

printf -- '-- the shipped block, driven by the kinds file and the cluster'"'"'s answers --\n'

Q_PRESENT=checked:present Q_COUNT=checked:6:31 \
shipped "1  a full cluster-kind database passes" \
  $'cluster aistack\napp n8n\n' 0 \
  'ok \] cluster-kind database .aistack. restored and is not empty \(6 tables, 31 rows\)'

Q_PRESENT=checked:present Q_COUNT=checked:0:0 \
shipped "2  NO TABLE reds it (the defect NOM-392 was about)" \
  $'cluster aistack\napp n8n\n' 1 'FAIL\].*NO TABLE'

Q_PRESENT=checked:present Q_COUNT=checked:6:0 \
shipped "3  tables but ZERO ROWS reds it (schema-only restore)" \
  $'cluster aistack\n' 1 'FAIL\].*0 rows — schema only'

Q_PRESENT=checked:missing Q_COUNT=checked:6:31 \
shipped "4  a database absent after the restore reds it" \
  $'cluster aistack\n' 1 'FAIL\].*is not in the cluster after the restore'

Q_PRESENT= Q_COUNT=checked:6:31 \
shipped "5  a cluster that does not answer reds it, rather than passing" \
  $'cluster aistack\n' 1 'FAIL\].*did not answer whether it exists'

Q_PRESENT=checked:present Q_COUNT= \
shipped "6  a count that does not answer reds it" \
  $'cluster aistack\n' 1 'FAIL\].*did not answer how much is in it'

Q_PRESENT=checked:present Q_COUNT=checked:six:31 \
shipped "7  a non-numeric count reds it" \
  $'cluster aistack\n' 1 'FAIL\].*which is not two counts'

Q_PRESENT=checked:present Q_COUNT=checked:6:31 \
shipped "8  a non-bare identifier is refused, not spliced into SQL" \
  $'cluster ai;DROP\n' 1 'FAIL\].*is not a bare identifier'

Q_PRESENT=checked:present Q_COUNT=checked:6:31 \
shipped "9  a legacy (pre-NOM-378) archive is a NOTE, not a failure" \
  $'legacy n8n\nlegacy openwebui\n' 0 '\[note\] this archive records no database kinds'

Q_PRESENT=checked:present Q_COUNT=checked:6:31 \
shipped "10 an EMPTY kinds file reds it (it checked nothing)" \
  '' 1 'FAIL\].*checked nothing'

Q_PRESENT=checked:present Q_COUNT=checked:6:31 \
shipped "11 app-only kinds, no cluster line, reds it" \
  $'app n8n\napp openwebui\n' 1 'FAIL\].*checked nothing'

Q_PRESENT=checked:present Q_COUNT=checked:6:31 \
shipped "12 two cluster-kind databases are both asserted" \
  $'cluster aistack\ncluster metrics\n' 0 'metrics. restored and is not empty' \
  '' '.aistack. restored and is not empty'

Q_PRESENT=checked:present Q_COUNT=checked:6:31 \
shipped "13 cluster + legacy together: the cluster wins, no note" \
  $'cluster aistack\nlegacy n8n\n' 0 'ok \] cluster-kind database .aistack.' \
  '\[note\]'

printf -- '\n-- NOM-393: a name that is not one whitespace-free word --\n'

# THE TICKET'S CASE.  `cluster my db` must reach the bare-identifier refusal
# with the WHOLE name, and must not produce a green line about `my`.
Q_PRESENT=checked:present Q_COUNT=checked:6:31 \
shipped "14 a name with a SPACE is refused whole, not truncated to its first word" \
  $'cluster my db\n' 1 "FAIL\\].*'my db'.*is not a bare identifier" \
  '\[ ok \]'

Q_PRESENT=checked:present Q_COUNT=checked:6:31 \
shipped "15 a name with a TAB is refused the same way" \
  $'cluster ai\tstack\n' 1 'FAIL\].*is not a bare identifier' \
  '\[ ok \]'

# A spaced name must not take the good one down with it, and must not be
# silently dropped either: one refusal, one assertion, rc 1.
Q_PRESENT=checked:present Q_COUNT=checked:6:31 \
shipped "16 a spaced name beside a good one: the good one is still asserted, the run still reds" \
  $'cluster my db\ncluster aistack\n' 1 'ok \] cluster-kind database .aistack.' \
  '' "FAIL\\].*'my db'"

# The dedup `sort -u` used to provide must survive the rewrite.
Q_PRESENT=checked:present Q_COUNT=checked:6:31 \
shipped "17 a duplicated cluster line is asserted once, not twice" \
  $'cluster aistack\ncluster aistack\n' 0 'ok \] cluster-kind database .aistack.'
DUPES="$(printf '%s\n' "$LAST_OUT" | grep -c 'cluster-kind database')"
[ "$DUPES" = "1" ] \
  && t_ok "18 ...and that is exactly one assertion line (sort -u still dedups)" \
  || t_bad "18 the duplicated line produced $DUPES assertions, expected 1"

printf -- '\n-- the regression tripwire: the reader must not be field-wise again --\n'

# Comments are stripped first: the block DESCRIBES the field-wise reader it
# replaced, and a scan of raw text would match that prose and fail the fix
# that removed the defect.
CODE="$(printf '%s\n' "$BLOCK" | grep -v '^[[:space:]]*#')"
BAD_SHAPES=0
case "$CODE" in
  *'for db in $CLUSTER_DBS'*)
    t_bad "the loop splits the cluster set on whitespace again (unquoted \$CLUSTER_DBS)"
    BAD_SHAPES=1 ;;
esac
case "$CODE" in
  *'print $2'*)
    t_bad "the name is read as a whitespace field again (awk print \$2)"
    BAD_SHAPES=1 ;;
esac
[ "$BAD_SHAPES" -eq 0 ] \
  && t_ok "19 neither field-wise shape is back in the shipped reader"

printf -- '\n-- teeth: case 14 must FAIL against the pre-NOM-393 reader --\n'

# Rebuild the old field-wise reader out of the shipped block.  If these
# substitutions no longer apply, the control was not built -- say so and
# count it as a skip.  A missing negative control must never read as a pass.
OLD="$BLOCK"
APPLIED=0
subst() {
  local before="$OLD"
  OLD="$(printf '%s\n' "$OLD" | sed "$1")"
  [ "$OLD" != "$before" ] && APPLIED=$((APPLIED + 1))
}
subst 's|^  mapfile -t CLUSTER_DBS.*|  CLUSTER_DBS="$(awk '"'"'$1 == "cluster" { print $2 }'"'"' "$RESTORED_KINDS" 2>/dev/null \| sort -u)"|'
subst 's|^  mapfile -t LEGACY_DBS.*|  LEGACY_DBS="$(awk '"'"'$1 == "legacy" { print $2 }'"'"' "$RESTORED_KINDS" 2>/dev/null \| sort -u)"|'
subst 's|^  if \[ "${#CLUSTER_DBS\[@\]}" -gt 0 \]; then|  if [ -n "$CLUSTER_DBS" ]; then|'
subst 's|^    for db in "${CLUSTER_DBS\[@\]}"; do|    for db in $CLUSTER_DBS; do|'
subst 's|^  elif \[ "${#LEGACY_DBS\[@\]}" -gt 0 \]; then|  elif [ -n "$LEGACY_DBS" ]; then|'

if [ "$APPLIED" -ne 5 ]; then
  t_skip "the pre-NOM-393 reader could not be reconstructed ($APPLIED/5 substitutions"
  note "applied), so case 14's teeth were NOT measured on this revision."
  note "Not a failure and not a pass: update the substitutions in this test."
else
  # Against the OLD reader the ticket's line must produce the truncated green
  # assertion about 'my' and rc 0.  If it does not, case 14 proves nothing.
  if Q_PRESENT=checked:present Q_COUNT=checked:6:31 \
     run_case "20 the old reader truncates 'my db' to 'my' and passes — so case 14 has teeth" \
       $'cluster my db\n' 0 "ok \\].*database 'my' restored and is not empty" \
       'is not a bare identifier' '' "$OLD"
  then :; fi
fi

printf '\n== %d passed, %d failed, %d skipped ==\n\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
