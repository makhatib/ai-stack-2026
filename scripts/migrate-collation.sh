#!/usr/bin/env bash
# AI Stack 2026 — finish a collation migration after a base-image swap (NOM-354).
#
# WHY THIS EXISTS.  versions.env has said since NOM-341 that taking the trixie
# pin under an EXISTING PGDATA "requires a REINDEX, and nothing in this repo
# performs one".  scripts/preflight-collation.sh made that condition
# enforceable; this script makes it performable.  Both halves are needed: a
# gate with no remedy behind it just stops the operator in the same place
# every time.
#
# WHAT IT DOES, per connectable database, in this order and for a reason:
#
#   1. REINDEX DATABASE            rebuild every index from the heap, under
#                                  the collation the OS provides NOW.
#   2. ALTER DATABASE ... REFRESH COLLATION VERSION
#                                  re-record the database default.
#   3. ALTER COLLATION ... REFRESH VERSION, per stale pg_collation row
#                                  re-record the named collations.
#
# STEP 3 IS NOT OPTIONAL AND IS THE ONE THAT GETS MISSED.  Measured on
# 2026-10-23: after steps 1 and 2 this cluster reported every database at
# collation version 2.41 and still held 5663 stale pg_collation rows -- 2 libc
# and 807 ICU per database -- because the Debian 12 -> 13 swap moved BOTH
# providers (glibc 2.36 -> 2.41, ICU 153.120 -> 153.128) and ALTER DATABASE
# touches neither catalog row.  Postgres warns whenever such a collation is
# USED, so the warning outlives a migration that looks finished.
#
# ORDER MATTERS THE OTHER WAY TOO.  Refreshing a collation whose indexes were
# built under the old version records a version that is NOT TRUE of those
# indexes -- it silences the warning and keeps the risk.  That is why step 3
# runs only for a database whose step 1 returned 0: the reindex is what makes
# the new version a true statement, and nothing else does.
#
# IT IS IDEMPOTENT.  A second run finds nothing stale and says so.  The
# reindex is repeated (it is not lossy: indexes are rebuilt from the heap),
# which is the cost of being able to re-run it safely.
#
# IT IS NOT A SUBSTITUTE FOR A BACKUP.  A reindex cannot be undone, only
# redone.  Take scripts/backup.sh first and know that it dumps ONLY the
# databases named in secrets/app_db_passwords -- on 2026-10-23 that was 4 of
# the 7 databases in this cluster.
#
# Usage: migrate-collation.sh --yes [--container <name>] [--dry-run]
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; cd "$ROOT"

CONTAINER=""; YES=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --container) CONTAINER="${2:?--container needs a value}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "migrate-collation: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# Take the container name from compose, never derive it: the measured lesson
# in doctor.sh is that deriving "aistack-$svc" silently skipped a service
# whose container_name did not match.
if [ -z "$CONTAINER" ]; then
  CFG="$(docker compose config --format json 2>/dev/null)"
  if [ -z "$CFG" ]; then
    echo "migrate-collation: REFUSE — could not render compose config, so no container name could be read." >&2
    exit 2
  fi
  CONTAINER="$(printf '%s' "$CFG" | python3 -c '
import json,sys
d=json.load(sys.stdin); s=(d.get("services") or {}).get("postgres") or {}
print(s.get("container_name") or "")
')"
fi
[ -n "$CONTAINER" ] || { echo "migrate-collation: REFUSE — compose names no container for the postgres service." >&2; exit 2; }

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "migrate-collation: REFUSE — '$CONTAINER' is not running; there is nothing to migrate." >&2
  exit 2
fi

if [ "$YES" -ne 1 ] && [ "$DRY" -ne 1 ]; then
  cat >&2 <<EOF
migrate-collation: refusing to run without --yes.

This REINDEXes every database in '$CONTAINER' and re-records collation
versions.  A reindex holds locks on the tables it rebuilds, so the apps will
block on them while it runs.  Take scripts/backup.sh first.

  bash scripts/migrate-collation.sh --dry-run   # what is stale, change nothing
  bash scripts/migrate-collation.sh --yes       # do it
EOF
  exit 2
fi

# The superuser comes from the container's own environment, not from a literal
# here: a name retyped in a second place is a name that can drift from the one
# the cluster was initialised with.
PGU="$(docker exec "$CONTAINER" sh -c 'printf %s "${POSTGRES_USER:-}"' 2>/dev/null)"
if [ -z "$PGU" ]; then
  echo "migrate-collation: REFUSE — '$CONTAINER' exposes no POSTGRES_USER, so no connection was attempted." >&2
  exit 2
fi

psq() { docker exec -i "$CONTAINER" psql -U "$PGU" "$@"; }

DBLIST="$(docker exec "$CONTAINER" sh -c 'psql -U "$1" -d postgres -At -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY datname"' sh "$PGU" 2>/dev/null)"
if [ -z "$DBLIST" ]; then
  echo "migrate-collation: REFUSE — could not list the connectable databases, so nothing was done." >&2
  exit 2
fi

# Counted, so the report is about what was examined rather than about what the
# script hoped to examine.
NDB=0; FAIL=0; REINDEXED=0; DBREFRESHED=0; COLLREFRESHED=0

echo "migrate-collation: container '$CONTAINER'$([ "$DRY" -eq 1 ] && echo ' (DRY RUN — nothing will change)')"

for db in $DBLIST; do
  NDB=$((NDB+1))
  # What is stale here, before anything.
  before="$(docker exec "$CONTAINER" sh -c 'psql -U "$1" -d "$2" -At -F" " -c "
    SELECT
      (SELECT count(*) FROM pg_database d WHERE d.datname = current_database()
         AND d.datcollversion IS NOT NULL AND d.datcollversion <> chr(32)
         AND d.datcollversion <> coalesce(pg_database_collation_actual_version(d.oid), d.datcollversion)),
      (SELECT count(*) FROM pg_collation c WHERE c.collversion IS NOT NULL AND c.collversion <> chr(32)
         AND c.collversion <> coalesce(pg_collation_actual_version(c.oid), c.collversion))
  "' sh "$PGU" "$db" 2>/dev/null)"
  # The dependent-object count is NOT asked here.  It is asked inside the
  # transaction that refreshes, where the set checked is the set acted on;
  # asking twice invites the two answers to disagree.
  case "$before" in
    [0-9]*' '[0-9]*) : ;;
    *) echo "  $db: REFUSE — could not read its collation state, so it was not touched." >&2
       FAIL=$((FAIL+1)); continue ;;
  esac
  sdb="$(printf '%s' "$before" | cut -d' ' -f1)"
  scoll="$(printf '%s' "$before" | cut -d' ' -f2)"

  if [ "$sdb" = "0" ] && [ "$scoll" = "0" ]; then
    echo "  $db: already consistent (0 stale database default, 0 stale pg_collation rows)"
    continue
  fi
  echo "  $db: $sdb stale database default, $scoll stale pg_collation row(s)"
  [ "$DRY" -eq 1 ] && continue

  if ! psq -d "$db" -v ON_ERROR_STOP=1 -q -c "REINDEX DATABASE \"$db\"" >/dev/null 2>&1; then
    echo "    REINDEX failed — stopping here for this database" >&2; FAIL=$((FAIL+1)); continue
  fi
  REINDEXED=$((REINDEXED+1)); echo "    reindexed"

  if [ "$sdb" != "0" ]; then
    if psq -d "$db" -v ON_ERROR_STOP=1 -q -c "ALTER DATABASE \"$db\" REFRESH COLLATION VERSION" >/dev/null 2>&1; then
      DBREFRESHED=$((DBREFRESHED+1)); echo "    database default re-recorded"
    else
      echo "    ALTER DATABASE REFRESH COLLATION VERSION failed" >&2; FAIL=$((FAIL+1))
    fi
  fi

  # Step 3.  WHAT LICENSES THIS IS STEP 1, and only step 1: every index in
  # this database was just rebuilt under the collation the OS provides now, so
  # re-recording that version is a true statement about them.  Reached only on
  # a REINDEX that returned 0 -- the `continue` above is the guard.
  #
  # AN EARLIER DRAFT GUARDED THIS DIFFERENTLY AND WAS WRONG: it refused when
  # any object depended on a stale collation.  But a dependent object is the
  # NORMAL case for an explicit-collation index, and a REINDEX does not clear
  # the recorded version -- only this statement does.  So that guard refused
  # exactly the cluster it was written for, and passed only where no object
  # used an explicit collation at all, which is where it was first tried.
  out="$(psq -d "$db" -v ON_ERROR_STOP=1 -q 2>&1 <<'SQL'
DO $$
DECLARE n int := 0; r record;
BEGIN
  FOR r IN
    SELECT quote_ident(ns.nspname) || '.' || quote_ident(c.collname) AS fq
    FROM pg_collation c JOIN pg_namespace ns ON ns.oid = c.collnamespace
    WHERE c.collversion IS NOT NULL AND c.collversion <> ''
      AND c.collversion <> coalesce(pg_collation_actual_version(c.oid), c.collversion)
  LOOP
    EXECUTE 'ALTER COLLATION ' || r.fq || ' REFRESH VERSION';
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'refreshed % collation row(s)', n;
END $$;
SQL
)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "    pg_collation refresh failed: $(printf '%s' "$out" | grep -m1 -i 'error\|refuse')" >&2
    FAIL=$((FAIL+1))
  else
    echo "    $(printf '%s' "$out" | grep -m1 'refreshed' | sed 's/^NOTICE:  //')"
    COLLREFRESHED=$((COLLREFRESHED+1))
  fi

  # Did it actually take?  Asked again rather than assumed, because a psql
  # that reads EOF instead of its script exits 0 having done nothing -- that
  # is not a hypothetical, it happened while this procedure was being run.
  after="$(docker exec "$CONTAINER" sh -c 'psql -U "$1" -d "$2" -At -c "
    SELECT (SELECT count(*) FROM pg_collation c WHERE c.collversion IS NOT NULL AND c.collversion <> chr(32)
              AND c.collversion <> coalesce(pg_collation_actual_version(c.oid), c.collversion))
         + (SELECT count(*) FROM pg_database d WHERE d.datname = current_database()
              AND d.datcollversion IS NOT NULL AND d.datcollversion <> chr(32)
              AND d.datcollversion <> coalesce(pg_database_collation_actual_version(d.oid), d.datcollversion))
  "' sh "$PGU" "$db" 2>/dev/null)"
  if [ "$after" != "0" ]; then
    echo "    STILL STALE after the attempt: $after — this database is NOT migrated" >&2
    FAIL=$((FAIL+1))
  else
    echo "    verified: 0 stale"
  fi
done

echo
if [ "$DRY" -eq 1 ]; then
  echo "migrate-collation: dry run over $NDB database(s); nothing was changed."
  [ "$FAIL" -eq 0 ] || { echo "migrate-collation: $FAIL database(s) could not be read." >&2; exit 2; }
  exit 0
fi
echo "migrate-collation: $NDB database(s) examined; $REINDEXED reindexed, $DBREFRESHED database default(s) re-recorded, $COLLREFRESHED pg_collation set(s) refreshed; failures: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "migrate-collation: now run  bash scripts/preflight-collation.sh  — it must print both oks."
exit 0
