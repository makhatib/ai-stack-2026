#!/usr/bin/env bash
# NOM-354 — proves the collation gate and the migration behind it.
#
# WHY A TEST AND NOT ANOTHER AD-HOC DRILL.  Both scripts under test were first
# exercised by hand against the live cluster, and both were wrong in a way
# that only showed up when the OTHER half ran:
#
#   * preflight-collation.sh reported "ok — all 7 databases record collation
#     version 2.41" over 5663 stale pg_collation rows, because it read
#     pg_database and glibc only, and the Debian 12 -> 13 swap also moved ICU
#     (153.120 -> 153.128).
#   * migrate-collation.sh's first draft refused whenever an object depended
#     on a stale collation -- which is the normal case for an explicit-
#     collation index, so it refused exactly the cluster it was for.  It
#     passed by hand only because no object in that cluster used one.
#
# Case 5 is that second defect: a table with an explicit-collation index is
# the fixture, and the old guard cannot pass it.
#
# EVERYTHING RUNS AGAINST A THROWAWAY CONTAINER with its own PGDATA.  The live
# cluster is never named, never connected to, and never read.  The fixture
# needs allow_system_table_mods, which is postmaster-level and so is passed as
# a server argument at start -- it cannot be SET at runtime, which is also why
# the live cluster could not host this test even if that were acceptable.
#
# HOW STALENESS IS FAKED.  pg_collation.collversion is overwritten with a
# value that is not what the provider reports, which is exactly the state a
# base swap produces.  THE PLANT IS ASSERTED BEFORE IT IS USED: a planting
# step that silently fails reads as "the check missed it", and that mistake
# has been made in this repo before.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PRE="$ROOT/scripts/preflight-collation.sh"
MIG="$ROOT/scripts/migrate-collation.sh"
FAIL=0; CHECKS=0
pass() { CHECKS=$((CHECKS+1)); printf '  [ ok ] %s\n' "$*"; }
fail() { CHECKS=$((CHECKS+1)); FAIL=1; printf '  [FAIL] %s\n' "$*"; }
refuse() { printf '\n  REFUSE: %s\n' "$*" >&2; exit 2; }

for f in "$PRE" "$MIG"; do [ -r "$f" ] || refuse "missing $f"; done
docker info >/dev/null 2>&1 || refuse "no usable docker daemon"

cd "$ROOT"
IMAGE="$(docker compose config --format json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
print(((d.get("services") or {}).get("postgres") or {}).get("image") or "")
')"
[ -n "$IMAGE" ] || refuse "could not read the postgres image from compose config"

C="nom354-collation-test-$$"
PGU="testadmin"
# -v IS LOAD-BEARING: `docker rm -f` leaves the container's ANONYMOUS
# volume behind, so without it every run of this test leaks a ~48 MB
# PGDATA.  Measured: nine such volumes after one afternoon of runs, on a
# host whose disk filling up was its own incident (NOM-350).
cleanup() { docker rm -fv "$C" >/dev/null 2>&1 || true; }
trap cleanup EXIT

printf '\nNOM-354 collation gate and migration\n'
printf '\nthrowaway container %s from %s\n' "$C" "$IMAGE"

docker run -d --name "$C" \
  -e POSTGRES_USER="$PGU" -e POSTGRES_PASSWORD=testonly-not-a-secret \
  -e POSTGRES_DB=testdb "$IMAGE" \
  -c allow_system_table_mods=on >/dev/null 2>&1 \
  || refuse "could not start the throwaway container"

# READINESS IS TWO WAITS, NOT ONE, and this is measured: the entrypoint runs a
# TEMPORARY server to run initdb and the init scripts, then shuts it down and
# starts the real one.  pg_isready answers during that temporary server, so a
# single readiness loop can return, and then every later query fails with
# "the database system is shutting down".  Wait for the init marker in the log
# FIRST, and only then for a query to answer.
ready=0
for _ in $(seq 1 90); do
  if docker logs "$C" 2>&1 | grep -q "init process complete"; then ready=1; break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || refuse "the throwaway cluster never finished initdb"
ready=0
for _ in $(seq 1 60); do
  if docker exec "$C" psql -U "$PGU" -d testdb -At -c 'SELECT 1' >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || refuse "the throwaway cluster never answered a query"

q() { docker exec "$C" psql -U "$PGU" -d "${2:-testdb}" -At -c "$1" 2>/dev/null | tail -1; }
stale_count() { q "SELECT count(*) FROM pg_collation c WHERE c.collversion IS NOT NULL AND c.collversion <> chr(32) AND c.collversion <> coalesce(pg_collation_actual_version(c.oid), c.collversion)" "${1:-testdb}"; }

# --- 1. a consistent cluster passes ----------------------------------------
printf '\n1. a cluster consistent with its own base\n'
out="$(bash "$PRE" --container "$C" --image "$IMAGE" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit $rc; output: $out"
printf '%s\n' "$out" | grep -q "consistent with the base they run on" \
  && pass "says the cluster is consistent with its base" \
  || fail "no live-consistency line; output: $out"

# --- 2. the planted stale row is seen --------------------------------------
printf '\n2. one stale pg_collation row (the state a base swap leaves)\n'
before="$(stale_count)"
[ "$before" = "0" ] || refuse "fixture is not clean: $before stale rows before planting"
q "UPDATE pg_collation SET collversion = 'STALE-TEST' WHERE collname = 'en_US.utf8'" >/dev/null
planted="$(stale_count)"
# THE PLANT IS ASSERTED, NOT ASSUMED.
[ "$planted" -ge 1 ] 2>/dev/null \
  || refuse "the plant did not take ($planted stale rows), so nothing below would mean anything"
pass "plant verified: $planted stale row(s) present"

out="$(bash "$PRE" --container "$C" --image "$IMAGE" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "preflight exits 1 on a cluster inconsistent with its own base" \
                || fail "expected exit 1, got $rc; output: $out"
# Matched on one line, not on a phrase the message wraps across two.
printf '%s\n' "$out" | grep -q "already inconsistent" \
  && pass "names the condition" || fail "message does not name the condition: $out"
printf '%s\n' "$out" | grep -q "stale pg_collation row" \
  && pass "reports the stale pg_collation count" || fail "no pg_collation count: $out"

# --- 3. migrate refuses without --yes, and --dry-run changes nothing -------
printf '\n3. migrate-collation.sh consent and dry run\n'
out="$(bash "$MIG" --container "$C" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "refuses without --yes (exit 2)" || fail "expected exit 2, got $rc; output: $out"
[ "$(stale_count)" = "$planted" ] && pass "a refusal changed nothing" || fail "the refusal altered the cluster"

out="$(bash "$MIG" --container "$C" --dry-run 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "--dry-run exits 0" || fail "--dry-run exit $rc; output: $out"
printf '%s\n' "$out" | grep -q "nothing was changed" \
  && pass "--dry-run says so" || fail "--dry-run output does not say it changed nothing: $out"
[ "$(stale_count)" = "$planted" ] && pass "--dry-run really changed nothing" \
  || fail "--dry-run modified the cluster"

# --- 4. migrate clears it, and the gate then passes ------------------------
printf '\n4. migrate-collation.sh --yes\n'
out="$(bash "$MIG" --container "$C" --yes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || fail "exit $rc; output: $out"
after="$(stale_count)"
[ "$after" = "0" ] && pass "0 stale rows afterwards (was $planted)" || fail "$after stale rows remain"
printf '%s\n' "$out" | grep -q "verified: 0 stale" \
  && pass "verifies its own result per database" || fail "no self-verification line: $out"

out="$(bash "$PRE" --container "$C" --image "$IMAGE" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "the gate now passes" || fail "gate still exits $rc; output: $out"

out="$(bash "$MIG" --container "$C" --yes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "a second run is idempotent (exit 0)" || fail "re-run exit $rc; output: $out"
printf '%s\n' "$out" | grep -q "already consistent" \
  && pass "the second run reports nothing to do" || fail "re-run does not report a no-op: $out"

# --- 5. an object DEPENDING on the stale collation ------------------------
# The case the first draft of migrate-collation.sh could not pass.  A table
# with an explicit-collation index is the ordinary shape, not a corner case.
printf '\n5. an index that depends on the stale collation\n'
q "CREATE TABLE coll_dep (c text COLLATE \"en_US.utf8\")" >/dev/null
q "INSERT INTO coll_dep SELECT 'row-' || g FROM generate_series(1,50) g" >/dev/null
q "CREATE INDEX coll_dep_c_idx ON coll_dep (c)" >/dev/null
dep="$(q "SELECT count(*) FROM pg_depend d JOIN pg_collation c ON c.oid = d.refobjid AND d.refclassid = 'pg_collation'::regclass WHERE c.collname = 'en_US.utf8'")"
[ "${dep:-0}" -ge 1 ] 2>/dev/null \
  || refuse "the dependency fixture did not take (dep=$dep), so case 5 would prove nothing"
pass "fixture verified: $dep object(s) depend on en_US.utf8"

q "UPDATE pg_collation SET collversion = 'STALE-TEST' WHERE collname = 'en_US.utf8'" >/dev/null
[ "$(stale_count)" -ge 1 ] 2>/dev/null && pass "re-planted staleness with a dependent index present" \
  || refuse "re-plant did not take"

out="$(bash "$MIG" --container "$C" --yes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "migrates a database that HAS a dependent index (exit 0)" \
                || fail "exit $rc with a dependent index; output: $out"
[ "$(stale_count)" = "0" ] && pass "0 stale rows afterwards" || fail "$(stale_count) stale rows remain"
rows="$(q "SELECT count(*) FROM coll_dep")"
[ "$rows" = "50" ] && pass "the dependent table still has its 50 rows" || fail "row count is $rows, not 50"
inv="$(q "SELECT count(*) FROM pg_index WHERE NOT indisvalid")"
[ "$inv" = "0" ] && pass "no invalid index left behind" || fail "$inv invalid index(es)"
idx="$(q "SELECT count(*) FROM coll_dep WHERE c = 'row-7'")"
[ "$idx" = "1" ] && pass "the reindexed index still finds its row" || fail "lookup returned $idx, not 1"

# --- 6. "could not measure" is never "nothing stale" ----------------------
# A RUNNING container that cannot be read.  Not the stopped case -- that one
# is a FRESH install and passing it is correct.  An earlier draft sabotaged
# psql inside the postgres container with `rm`; the binary lives elsewhere, so
# the sabotage silently failed and the case reported the script as broken
# while actually proving nothing.  A container that never had psql cannot
# fail to be unreadable.
printf '\n6. a running container that cannot be read is refused, not passed\n'
C2="nom354-unreadable-$$"
docker rm -f "$C2" >/dev/null 2>&1 || true
if ! docker run -d --name "$C2" --entrypoint sh "$IMAGE" -c 'while :; do sleep 5; done' >/dev/null 2>&1; then
  refuse "could not start the unreadable-case container"
fi
trap 'cleanup; docker rm -fv "$C2" >/dev/null 2>&1 || true' EXIT
# Prove the premise: this container really has no usable psql for our user.
docker exec "$C2" sh -c 'command -v psql >/dev/null 2>&1 && psql -U nosuchuser -d postgres -c "SELECT 1" >/dev/null 2>&1'
[ $? -ne 0 ] || refuse "the unreadable-case container answered a query, so the case would prove nothing"
pass "premise verified: the container is running and answers no query"
out="$(bash "$PRE" --container "$C2" --image "$IMAGE" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "preflight exits 2 when it cannot read the cluster" \
                || fail "expected exit 2 for unreadable, got $rc; output: $out"
printf '%s\n' "$out" | grep -qi "refuse" && pass "says REFUSE rather than reporting a result" \
  || fail "no refusal wording: $out"

printf '\nchecks: %d   failed: %s\n' "$CHECKS" "$([ "$FAIL" -eq 0 ] && echo 0 || echo yes)"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
