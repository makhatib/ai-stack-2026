#!/usr/bin/env bash
# AI Stack 2026 — a live restore refuses while the stack is up, and a failed
# pg_restore is a refusal.  Driven without docker, without postgres and
# without a maintenance window (NOM-405).
#
# WHY THIS TEST EXISTS.
#
# scripts/restore.sh's live path assumed the stack was down and never checked.
# It brought `postgres` up and nothing else, so n8n, Authelia, LiteLLM and Open
# WebUI stayed attached while `pg_restore --clean --if-exists` dropped their
# tables under them and `rm -rf /dst/*` emptied aistack-n8n-data under a
# running n8n.  The closing "Bring the stack up with: aistack up" was printed
# after the damage, and scripts/rollback.sh's two-line instruction never said
# to stop anything.
#
# And one line below, a pg_restore that FAILED was reduced to
#
#     ... >/dev/null 2>&1 || echo "      (pg_restore reported warnings for $db)"
#
# so a database that is in the archive could come back half-loaded under a
# reassuring word, with stderr discarded so the reason was gone too.  The
# script had already taken the opposite position one line earlier --
# require_database_present() exists because "a dump that cannot be loaded at
# all is not a warning" -- and left the --clean case swallowed.
#
# THE ONLY WAY TO EXERCISE EITHER DECISION FOR REAL is to stop the serving
# stack, start it again, and perform a restore that overwrites live data.  That
# is a maintenance window per assertion, which is how both of these shipped
# unmeasured.  So both decisions live in functions, and this test extracts
# THOSE LINES out of scripts/restore.sh and runs them against a stub `docker`
# and a stub `dc`.  A retyped copy would pass forever while restore.sh drifted;
# if either marker pair is gone, or matches more than once, the test REFUSES
# (exit 2) rather than reporting on a block it could not find.
#
# IT ALSO CHECKS THE CALL SITES, which a stub cannot see: the guard must be
# called on the live path, before the confirmation prompt, NOT behind --yes,
# and never on the drill path.  A guard nothing calls passes every stub test.
#
# AND IT PROVES ITS OWN TEETH.  Section D rebuilds the pre-NOM-405 forms out of
# the shipped blocks -- the live branch with the guard call removed, and the
# `|| echo` pg_restore line -- and requires the two key cases to FAIL there.  A
# test whose cases cannot fail on the broken code is not evidence.  If a
# reconstruction no longer applies, that is a [skip] with the reason, never a
# silent pass.
#
# No docker, no postgres, no secrets, no live stack, and no stack container is
# named to anything but a stub.  It reads nothing under backups/ and writes
# only inside its own mktemp.
#
# Run:  tests/restore-live-stack.sh        (<1s)
#
# Rollback: delete this file and its line from the REGISTRY in tests/run.sh.

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

SRC="${1:-$ROOT/scripts/restore.sh}"

PASS=0
FAIL=0
SKIP=0

t_ok()   { printf '  ok    %s\n' "$*"; PASS=$((PASS + 1)); }
t_bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
t_skip() { printf '  [skip] %s\n' "$*"; SKIP=$((SKIP + 1)); }
note()   { printf '        %s\n' "$*"; }
refuse() { printf '\n  REFUSED: %s\n\n' "$*" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/aistack-restore-live.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

printf '\n== restore.sh: a live restore refuses while the stack is up ==\n\n'

[ -r "$SRC" ] || refuse "cannot read $SRC"

# --- extract the two shipped blocks ----------------------------------------
extract() {
  # $1 = marker name.  Refuses unless the open and close markers appear once.
  local name="$1" open close n block
  open="# >>> $name:"
  close="# <<< $name <<<"
  n="$(grep -cF "$open" "$SRC")"
  [ "$n" = "1" ] || refuse "the '$name' open marker matched $n times in $SRC, not once"
  n="$(grep -cF "$close" "$SRC")"
  [ "$n" = "1" ] || refuse "the '$name' close marker matched $n times in $SRC, not once"
  block="$(awk -v o="$open" -v c="$close" '
    index($0, o) { f = 1; next }
    index($0, c) { f = 0 }
    f { print }' "$SRC")"
  [ -n "$block" ] || refuse "the '$name' block extracted empty; that measures nothing"
  printf '%s\n' "$block"
}

GUARD="$(extract 'live-stack guard')" || exit 2
LOADER="$(extract 'dump load decision')" || exit 2

case "$GUARD" in
  *blocking_live_containers*require_stack_down*) ;;
  *) refuse "the live-stack guard block defines neither blocking_live_containers nor require_stack_down" ;;
esac
case "$LOADER" in
  *load_dump_or_die*) ;;
  *) refuse "the dump-load block does not define load_dump_or_die" ;;
esac
note "extracted $(printf '%s\n' "$GUARD" | wc -l | tr -d ' ') lines of guard and \
$(printf '%s\n' "$LOADER" | wc -l | tr -d ' ') lines of loader from ${SRC#$ROOT/}"

# --- the stub docker -------------------------------------------------------
# Answers `docker ps` with NOM405_PS verbatim (so a missing final newline is
# reproducible) and exits NOM405_RC.  Every docker invocation the block makes
# goes here; the real daemon is never contacted and never needs to exist.
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${NOM405_PS:-}"
exit "${NOM405_RC:-0}"
STUB
chmod 0755 "$TMP/bin/docker"

printf '\n-- A. which containers block a live restore --\n\n'

# run_guard <name> <ps-output> <docker-rc> <want: PROCEED|REFUSE> <want_re> [<want_not_re>]
LAST_OUT=""
run_guard() {
  local name="$1" ps_out="$2" drc="$3" want="$4" want_re="${5:-}" want_not="${6:-}"
  local out rc got why=""
  out="$(
    NOM405_PS="$ps_out" NOM405_RC="$drc" PATH="$TMP/bin:$PATH" \
    ARCHIVE="/backups/aistack-20261024.tar.gz.enc" \
    bash -c '
      set -euo pipefail
      die() { printf "REFUSE\n%s\n" "$*"; exit 1; }
      '"$GUARD_SRC"'
      require_stack_down aistack aistack-postgres
      printf "PROCEED\n"
    ' 2>&1
  )"; rc=$?
  LAST_OUT="$out"
  case "$out" in
    PROCEED*) got=PROCEED ;;
    REFUSE*)  got=REFUSE ;;
    *)        t_bad "$name — the driver itself errored (rc=$rc)"
              printf '%s\n' "$out" | sed 's/^/          | /'
              return 1 ;;
  esac
  [ "$got" = "$want" ] || why="got $got, wanted $want"
  if [ "$want" = REFUSE ] && [ "$rc" -eq 0 ]; then
    why="${why:+$why; }refused but exited 0"
  fi
  if [ -n "$want_re" ] && ! printf '%s\n' "$out" | grep -Eq "$want_re"; then
    why="${why:+$why; }output does not match /$want_re/"
  fi
  if [ -n "$want_not" ] && printf '%s\n' "$out" | grep -Eq "$want_not"; then
    why="${why:+$why; }output matches /$want_not/ and must not"
  fi
  if [ -n "$why" ]; then
    t_bad "$name — $why"
    printf '%s\n' "$out" | sed 's/^/          | /'
    return 1
  fi
  t_ok "$name"
  return 0
}

# The block is sourced into the stub shell through the environment, so the
# quoting below does not have to survive two levels of expansion.
GUARD_SRC="$GUARD"

PS_ONLY_PG='aistack-postgres aistack
traefik traefik
paperless-ar-db-1 paperless-ar
'
run_guard "only aistack-postgres up: a restore proceeds" "$PS_ONLY_PG" 0 PROCEED
run_guard "nothing running at all: a restore proceeds" "" 0 PROCEED
run_guard "an empty line from docker is not a container" "
" 0 PROCEED

run_guard "aistack-n8n up: refused, and n8n is named" \
  "aistack-postgres aistack
aistack-n8n aistack
" 0 REFUSE 'aistack-n8n'
printf '%s\n' "$LAST_OUT" | grep -q 'bin/aistack down' \
  && t_ok "the refusal names the command that fixes it (bin/aistack down)" \
  || t_bad "the refusal does not name 'bin/aistack down'"
printf '%s\n' "$LAST_OUT" | grep -Eq 'Nothing has been changed|nothing was changed' \
  && t_ok "the refusal says nothing was changed" \
  || t_bad "the refusal does not say nothing was changed"
printf '%s\n' "$LAST_OUT" | grep -q 'aistack-postgres' \
  && t_bad "the refusal names aistack-postgres, which restore.sh starts itself" \
  || t_ok "the refusal does not name aistack-postgres"
printf '%s\n' "$LAST_OUT" | grep -q 'drill-project' \
  && t_ok "the refusal points at the drill path as the no-downtime alternative" \
  || t_bad "the refusal does not mention the drill path"

run_guard "all four app containers up: every one of them is named" \
  "aistack-postgres aistack
aistack-n8n aistack
aistack-authelia aistack
aistack-litellm aistack
aistack-open-webui aistack
" 0 REFUSE 'aistack-n8n'
for c in aistack-authelia aistack-litellm aistack-open-webui; do
  printf '%s\n' "$LAST_OUT" | grep -q "$c" \
    && t_ok "named $c" || t_bad "did not name $c"
done

run_guard "a stack container whose container_name was changed still blocks (by label)" \
  "aistack-postgres aistack
renamed-by-hand aistack
" 0 REFUSE 'renamed-by-hand'

run_guard "a container named aistack-* with no compose label still blocks" \
  "aistack-postgres aistack
aistack-leftover
" 0 REFUSE 'aistack-leftover'

run_guard "a running restore drill does NOT block a live restore" \
  "aistack-postgres aistack
restore-drill-20261024010203-postgres-1 restore-drill-20261024010203
restore-drill-20261024010203-n8n-1 restore-drill-20261024010203
" 0 PROCEED

run_guard "unrelated projects on the same daemon do NOT block" \
  "traefik traefik
paperless-ar-webserver-1 paperless-ar
nom-82-hello-web-1 nom-82-hello
" 0 PROCEED

# ANOTHER PROJECT WHOSE NAME STARTS WITH THE LIVE PROJECT'S.  The first version
# of this guard blocked on the name prefix alone, so `aistack-staging-n8n`
# refused a live restore while holding nothing the restore overwrites -- and
# `bin/aistack down`, the only command the refusal names, does not stop it.
# With no override flag, that refusal could not be cleared by its own advice.
# The rows above did NOT cover this: `restore-drill-<ts>` and `paperless-ar`
# have no `aistack-` prefix, so they never reached the prefix rule.
run_guard "a container of project aistack-staging does NOT block" \
  "aistack-staging-n8n aistack-staging
" 0 PROCEED
run_guard "aistack-v2 and aistack-staging alongside a stopped live stack do NOT block" \
  "aistack-staging-postgres aistack-staging
aistack-staging-n8n aistack-staging
aistack-v2-n8n aistack-v2
" 0 PROCEED

# THE ONE THAT CLOSES THE LOOP: the refusal's own last paragraph invites the
# operator to rehearse with --into-drill-project, whose name they choose.
# `--into-drill-project aistack-drill` is the obvious thing to type, and under
# the prefix rule those containers then blocked every later live restore.
run_guard "a drill project the operator named aistack-drill does NOT block" \
  "aistack-drill-postgres-1 aistack-drill
aistack-drill-n8n-1 aistack-drill
" 0 PROCEED

# AND IT IS STILL SELECTIVE.  Same daemon, both up: the live n8n blocks, the
# look-alike does not, and the refusal must not name the look-alike -- naming a
# container the operator cannot stop with the command we give them is the
# expensive half of this defect.
run_guard "the live n8n blocks while aistack-staging-n8n is up" \
  "aistack-postgres aistack
aistack-n8n aistack
aistack-staging-n8n aistack-staging
aistack-drill-n8n-1 aistack-drill
" 0 REFUSE 'aistack-n8n' 'aistack-staging-n8n|aistack-drill-n8n'

# RECORDED, NOT FIXED (reviewer's call to either).  `keep` is matched by name
# only, so a container named aistack-postgres carrying another project's label
# is skipped as ours.  The answer is PROCEED either way -- rule 2 would also
# let it through as somebody else's -- so tightening `keep` to name AND label
# could not change an outcome.  Measured separately: `dc up -d postgres` then
# fails on the unique-name collision before anything is overwritten.
run_guard "aistack-postgres owned by another project: PROCEED, by name or by label" \
  "aistack-postgres aistack-staging
" 0 PROCEED

# A restarting container is listed by plain `docker ps` and holds its
# connections.  --filter status=running lists neither restarting nor paused,
# which is why the block must not use it.
run_guard "a restarting/paused container blocks like any other" \
  "aistack-postgres aistack
aistack-n8n aistack
" 0 REFUSE 'aistack-n8n'
# Asserted over the CODE lines only.  The block's own comment explains why it
# does not use `--filter status=running`, so matching the whole block would
# match the explanation and fail against correct code.
GUARD_CODE="$(printf '%s\n' "$GUARD" | grep -v '^[[:space:]]*#')"
case "$GUARD_CODE" in
  *status=running*) t_bad "the guard filters on status=running, which misses restarting and paused" ;;
  *) t_ok "the guard does not filter on status=running" ;;
esac
case "$GUARD_CODE" in
  *"docker ps "*) t_ok "the guard asks docker ps, not a cached or derived list" ;;
  *) t_bad "the guard does not call docker ps at all" ;;
esac

# docker's last line arrives without a trailing newline when it is piped; a
# `read` loop over a pipe fills the variable and returns 1, dropping it.
run_guard "docker's last line without a trailing newline is still counted" \
  "aistack-postgres aistack
aistack-n8n aistack" 0 REFUSE 'aistack-n8n'

# AN UNANSWERABLE QUESTION IS NOT AN EMPTY STACK.  This is the direction that
# costs data if it is wrong, and it is the branch a live window cannot stage.
run_guard "a docker that fails is refused, not read as 'nothing is running'" \
  "" 1 REFUSE 'UNKNOWN|did not answer'

printf '\n-- B. the guard is called where it has to be --\n\n'

# A stub cannot see the call site, and a guard nothing calls passes section A.
N="$(grep -cF 'require_stack_down "$PROJECT" "$PROJECT-postgres"' "$SRC")"
[ "$N" = "1" ] \
  && t_ok "the live path calls require_stack_down exactly once" \
  || t_bad "require_stack_down is called $N times on the live path, not once"

read -r L_IF L_ELSE L_FI <<EOF
$(awk '
  /^if \[ -n "\$DRILL_PROJECT" \]; then$/ && !i { i = NR }
  i && !e && /^else$/ { e = NR }
  i && e && !f && /^fi$/ { f = NR }
  END { printf "%s %s %s\n", i, e, f }' "$SRC")
EOF
if [ -z "${L_FI:-}" ] || [ "$L_FI" = "0" ] || [ "$L_IF" = "0" ]; then
  refuse "could not locate restore.sh's drill/live branch (if=${L_IF:-} else=${L_ELSE:-} fi=${L_FI:-})"
fi
note "drill/live branch: if=$L_IF else=$L_ELSE fi=$L_FI"

DRILL_BRANCH="$(awk -v a="$L_IF" -v b="$L_ELSE" 'NR > a && NR < b' "$SRC")"
LIVE_BRANCH="$(awk -v a="$L_ELSE" -v b="$L_FI" 'NR > a && NR < b' "$SRC")"

printf '%s\n' "$LIVE_BRANCH" | grep -q 'require_stack_down' \
  && t_ok "the guard is called inside the live branch" \
  || t_bad "the live branch does not call the guard"
printf '%s\n' "$DRILL_BRANCH" | grep -q 'require_stack_down' \
  && t_bad "the drill branch calls the guard; a drill must not care about the live stack" \
  || t_ok "the drill branch does not call the guard"

# Before the prompt: nobody should have to type RESTORE to find out it cannot
# proceed.  And NOT behind --yes, which answers a question about intent, not
# one about whether the machine is quiet.
GUARD_AT="$(printf '%s\n' "$LIVE_BRANCH" | grep -n 'require_stack_down' | head -1 | cut -d: -f1)"
YES_AT="$(printf '%s\n' "$LIVE_BRANCH" | grep -n 'ASSUME_YES' | head -1 | cut -d: -f1)"
PROMPT_AT="$(printf '%s\n' "$LIVE_BRANCH" | grep -n 'read -r reply' | head -1 | cut -d: -f1)"
if [ -n "$GUARD_AT" ] && [ -n "$YES_AT" ] && [ -n "$PROMPT_AT" ]; then
  [ "$GUARD_AT" -lt "$PROMPT_AT" ] \
    && t_ok "the guard runs before the RESTORE confirmation prompt" \
    || t_bad "the guard runs after the prompt (guard=$GUARD_AT prompt=$PROMPT_AT)"
  [ "$GUARD_AT" -lt "$YES_AT" ] \
    && t_ok "the guard is not inside the --yes branch, so --yes cannot skip it" \
    || t_bad "the guard sits inside the --yes branch (guard=$GUARD_AT yes=$YES_AT)"
else
  t_skip "could not locate the guard, --yes and prompt lines inside the live branch"
fi

# The read-only path must be unaffected: it writes nothing, so a running stack
# is none of its business.  The guard is below the read-only exit.
VERIFY_AT="$(grep -n 'if verify_only_requested' "$SRC" | head -1 | cut -d: -f1)"
if [ -n "$VERIFY_AT" ]; then
  [ "$VERIFY_AT" -lt "$L_ELSE" ] \
    && t_ok "the guard is below the read-only exit, so 'aistack verify' is unaffected" \
    || t_bad "the read-only exit is below the guard (verify=$VERIFY_AT else=$L_ELSE)"
else
  t_skip "could not find the read-only exit in $SRC"
fi

printf '\n-- C. a pg_restore that failed is a refusal, not a warning --\n\n'

LOADER_SRC="$LOADER"

# run_load <name> <dc-rc> <dc-stderr> <want: OK|REFUSE> <want_re> [<want_not_re>]
run_load() {
  local name="$1" dcrc="$2" dcerr="$3" want="$4" want_re="${5:-}" want_not="${6:-}"
  local out rc got why=""
  out="$(
    NOM405_DCRC="$dcrc" NOM405_DCERR="$dcerr" \
    bash -c '
      set -euo pipefail
      die() { printf "REFUSE\n%s\n" "$*"; exit 1; }
      # The stubbed cluster.  It consumes the dump on stdin, writes what the
      # case wants to the stderr file restore.sh gave it, and exits as asked.
      dc() {
        wc -c > "$NOM405_STDIN_BYTES"
        printf "%s" "$NOM405_DCERR" >&2
        return "$NOM405_DCRC"
      }
      '"$LOADER_SRC"'
      load_dump_or_die n8n "$NOM405_DUMP" "$NOM405_ERR"
      printf "OK\n"
    ' 2>&1
  )"; rc=$?
  case "$out" in
    REFUSE*) got=REFUSE ;;
    *OK)     got=OK ;;
    *)       t_bad "$name — the driver itself errored (rc=$rc)"
             printf '%s\n' "$out" | sed 's/^/          | /'
             return 1 ;;
  esac
  LAST_OUT="$out"
  [ "$got" = "$want" ] || why="got $got, wanted $want"
  if [ -n "$want_re" ] && ! printf '%s\n' "$out" | grep -Eq "$want_re"; then
    why="${why:+$why; }output does not match /$want_re/"
  fi
  if [ -n "$want_not" ] && printf '%s\n' "$out" | grep -Eq "$want_not"; then
    why="${why:+$why; }output matches /$want_not/ and must not"
  fi
  if [ -n "$why" ]; then
    t_bad "$name — $why"
    printf '%s\n' "$out" | sed 's/^/          | /'
    return 1
  fi
  t_ok "$name"
  return 0
}

printf 'a synthetic dump, not a real one\n' > "$TMP/n8n.dump"
export NOM405_DUMP="$TMP/n8n.dump"
export NOM405_ERR="$TMP/pg.err"
export NOM405_STDIN_BYTES="$TMP/stdin.bytes"

# MEASURED against pg_restore 17.11 from the pinned image: a healthy restore,
# into a fresh database and again over the populated one, is exit 0 with an
# empty stderr.  So the quiet case must stay quiet.
run_load "a clean restore (exit 0, stderr empty) says nothing" 0 "" OK "" 'warning|WARNING|REFUSE'
[ -s "$NOM405_STDIN_BYTES" ] && [ "$(tr -d ' ' < "$NOM405_STDIN_BYTES")" != "0" ] \
  && t_ok "the dump reached pg_restore on stdin ($(tr -d ' ' < "$NOM405_STDIN_BYTES") bytes)" \
  || t_bad "the dump did not reach pg_restore's stdin"

# Real warnings stay warnings, and now say what they were instead of going to
# /dev/null.
run_load "exit 0 with something on stderr is still a warning, not a refusal" \
  0 "WARNING: some ownership could not be set
" OK 'reported warnings for n8n'
printf '%s\n' "$LAST_OUT" | grep -q 'ownership could not be set' \
  && t_ok "the warning text itself is printed, not discarded" \
  || t_bad "the warning text was swallowed"

# THE DEFECT.  exit 1 is half a database, and it used to print the word
# "warnings".
run_load "exit 1 is a REFUSAL naming the database" \
  1 "pg_restore: error: could not execute query: ERROR:  cannot drop table public.t because other objects depend on it
" REFUSE "n8n"
printf '%s\n' "$LAST_OUT" | grep -q 'cannot drop table' \
  && t_ok "the refusal quotes what pg_restore actually said" \
  || t_bad "the refusal does not quote pg_restore's stderr"
# Flattened first: the sentence is wrapped in the shipped message, so a
# line-wise grep for it would fail against correct text.
printf '%s\n' "$LAST_OUT" | tr '\n' ' ' | grep -q 'nothing after it has been touched' \
  && t_ok "the refusal states what was and was not restored" \
  || t_bad "the refusal does not state what was and was not restored"
printf '%s\n' "$LAST_OUT" | grep -Eqi 'idempotent' \
  && t_ok "the refusal says the restore can be re-run" \
  || t_bad "the refusal does not say the restore can be re-run"

run_load "exit 1 with an empty stderr is still a refusal" 1 "" REFUSE "n8n"

run_load "a truncated archive member (exit 1) is a refusal" \
  1 "pg_restore: error: could not read from input file: end of file
" REFUSE 'end of file'

printf '\n-- D. the same cases against the pre-NOM-405 code --\n\n'

# THE TEETH.  Both reconstructions are built out of the shipped block, so if
# the shipped code is reshaped past the point where the reconstruction applies,
# this section skips loudly instead of passing.

# D1. THE SHIPPED LIVE BRANCH ITSELF, run twice over the same running stack:
# once as it ships, and once with the guard call deleted, which is what shipped
# before this ticket.  This drives the branch rather than the function, so it
# is also the one check here that cannot pass while the call site is wrong.
# `--yes` is set, because the pre-NOM-405 form would otherwise stop at the
# prompt for a reason that has nothing to do with the stack.
run_branch() {
  # $1 = the branch body to run.  Echoes PROCEED or REFUSE.
  NOM405_PS="aistack-postgres aistack
aistack-n8n aistack
" NOM405_RC=0 PATH="$TMP/bin:$PATH" ARCHIVE="/backups/x.enc" NOM405_BRANCH="$1" \
  bash -c '
    set -euo pipefail
    die() { printf "REFUSE\n%s\n" "$*"; exit 1; }
    ASSUME_YES=1
    PROJECT="" VOL_PREFIX="" COMPOSE_FILE_ARGS=()
    '"$GUARD"'
    eval "$NOM405_BRANCH"
    printf "PROCEED project=%s\n" "$PROJECT"
  ' 2>&1
}

out="$(run_branch "$LIVE_BRANCH")"
case "$out" in
  REFUSE*) t_ok "the shipped live branch refuses over a running n8n" ;;
  *)       t_bad "the shipped live branch did not refuse: $out" ;;
esac

OLD_BRANCH="$(printf '%s\n' "$LIVE_BRANCH" | grep -v 'require_stack_down')"
if [ "$OLD_BRANCH" = "$LIVE_BRANCH" ]; then
  t_skip "could not remove the guard call from the live branch; cannot rebuild the old form"
else
  out="$(run_branch "$OLD_BRANCH")"
  case "$out" in
    PROCEED*aistack*) t_ok "with the call deleted it proceeds into project aistack over a running n8n — the defect reproduces" ;;
    *)                t_bad "the pre-NOM-405 reconstruction produced: $out" ;;
  esac
fi

# D2. The pg_restore line as it shipped: `|| echo "(reported warnings)"`.
# Rebuilt by substituting the refusal out of the shipped function, so the
# reconstruction tracks the real block.
OLD_LOADER="$(printf '%s\n' "$LOADER" | sed -n '/^load_dump_or_die() {/,$p')"
case "$OLD_LOADER" in
  *'die "pg_restore FAILED'*)
    OLD_LOADER='load_dump_or_die() {
  local db="$1" dump="$2" err="$3"
  dc exec -T postgres pg_restore --clean --if-exists -U aistack_admin -d "$db" \
    < "$dump" >/dev/null 2>&1 || echo "      (pg_restore reported warnings for $db)"
}'
    out="$(
      NOM405_DCRC=1 NOM405_DCERR="pg_restore: error: cannot drop table" \
      bash -c '
        set -euo pipefail
        die() { printf "REFUSE\n%s\n" "$*"; exit 1; }
        dc() { wc -c > "$NOM405_STDIN_BYTES"; printf "%s" "$NOM405_DCERR" >&2; return "$NOM405_DCRC"; }
        '"$OLD_LOADER"'
        load_dump_or_die n8n "$NOM405_DUMP" "$NOM405_ERR"
        printf "OK\n"
      ' 2>&1
    )"
    case "$out" in
      *REFUSE*) t_bad "the pre-NOM-405 pg_restore line refused; the reconstruction is wrong" ;;
      *'reported warnings'*OK)
        t_ok "the pre-NOM-405 line called a failed pg_restore a warning and carried on — the defect reproduces" ;;
      *) t_bad "the pre-NOM-405 reconstruction produced neither outcome: $out" ;;
    esac ;;
  *)
    t_skip "the shipped loader no longer refuses with 'die \"pg_restore FAILED'; cannot rebuild the old form" ;;
esac

printf '\n-- E. the docs say it too --\n\n'

# "A line in a document is not enough" cuts both ways: the script asserts it,
# and the operator-facing instruction has to say it.  rollback.sh prints the
# only restore instruction an operator reaches mid-incident.
RB="$ROOT/scripts/rollback.sh"
if [ -r "$RB" ]; then
  awk '/bin\/aistack restore/ { if (prev ~ /bin\/aistack down/) ok = 1 } { prev = $0 } END { exit ok ? 0 : 1 }' "$RB" \
    && t_ok "scripts/rollback.sh prints 'bin/aistack down' directly above its restore line" \
    || t_bad "scripts/rollback.sh's printed instruction does not put 'bin/aistack down' first"
else
  t_skip "scripts/rollback.sh is not readable"
fi

UP="$ROOT/docs/upgrade.md"
if [ -r "$UP" ]; then
  grep -q 'bin/aistack down' "$UP" \
    && t_ok "docs/upgrade.md names 'bin/aistack down'" \
    || t_bad "docs/upgrade.md never names 'bin/aistack down'"
  awk '/bin\/aistack restore/ { if (prev ~ /bin\/aistack down/) ok = 1 } { prev = $0 } END { exit ok ? 0 : 1 }' "$UP" \
    && t_ok "docs/upgrade.md puts 'bin/aistack down' directly above a restore" \
    || t_bad "docs/upgrade.md does not put 'bin/aistack down' above a restore"
else
  t_skip "docs/upgrade.md is not readable"
fi

printf '\n== %d ok, %d failed, %d skipped ==\n\n' "$PASS" "$FAIL" "$SKIP"

# A floor, so that a reshaped restore.sh cannot quietly reduce this to two
# assertions and a pass.
EVALUATED=$((PASS + FAIL))
if [ "$EVALUATED" -lt 30 ]; then
  printf '  REFUSED: only %d assertions were evaluated; this file carries more than that.\n\n' "$EVALUATED" >&2
  exit 2
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
