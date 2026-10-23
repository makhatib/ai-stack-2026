#!/usr/bin/env bash
# AI Stack 2026 — collation preflight for a base-image change (NOM-354).
#
# WHY THIS EXISTS.  versions.env has carried this sentence since NOM-341:
# "Taking it as an in-place base swap under an EXISTING PGDATA requires a
# REINDEX, and nothing in this repo performs one.  Do not move an existing
# cluster onto this pin without that plan."  Nothing enforced it.  `aistack
# update` renders the new pin and recreates the container, so on 2026-10-20 a
# plain `aistack update` would have moved this cluster from Debian 12
# (glibc 2.36) to the committed Debian 13 pin (glibc 2.41) with no reindex.
#
# Postgres records, per database, the collation version it built its text
# indexes with.  When the operating system provides a different one, every
# such index is unverified: postgres warns on every connect and comparisons
# may no longer match the stored order.  The fix is a REINDEX plus
# ALTER DATABASE ... REFRESH COLLATION VERSION, per database.
#
# MEASURED (NOM-354, 2026-10-20) on a throwaway copy of this cluster's shape:
# the warning fires on every connect to every database; en_US.utf8 ordering
# did NOT move between 2.36 and 2.41 over 6000 mixed latin/accented/Arabic
# strings, and the 2.36-built index still agreed with a fresh 2.41 sort, so
# this is a correctness gate rather than observed corruption.  It is still a
# gate: "we checked one locale and one sample" is not "any locale is safe".
#
# PERFORMED, 2026-10-23 (NOM-354): this cluster was moved onto the trixie pin
# with the procedure below.  Doing it measured what the rehearsal had missed --
# the base swap moved TWO providers, glibc 2.36 -> 2.41 AND ICU 153.120 ->
# 153.128, and the database-level refresh leaves pg_collation untouched.  See
# the live-staleness section further down; that check exists because this
# script reported "ok" over 5663 stale rows.
#
# This is BOTH a preventive check and the proof the migration finished.  It
# exits non-zero and the caller stops.
#
# Usage: preflight-collation.sh [--image <ref>] [--container <name>]
#   --image      image reference to test against (default: the rendered pin)
#   --container  postgres container to read (default: from compose config)
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; cd "$ROOT"

IMAGE=""; CONTAINER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="${2:?--image needs a value}"; shift 2 ;;
    --container) CONTAINER="${2:?--container needs a value}"; shift 2 ;;
    *) echo "preflight-collation: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# Take the service's container name and image from compose, never derive
# them: the measured lesson in doctor.sh is that deriving "aistack-$svc"
# silently skipped a service whose container_name did not match.
CFG="$(docker compose config --format json 2>/dev/null)"
if [ -z "$CFG" ]; then
  echo "preflight-collation: REFUSE — could not render compose config, so no pin could be read." >&2
  exit 2
fi
read -r C_NAME C_IMAGE <<EOF2
$(printf '%s' "$CFG" | python3 -c '
import json,sys
d=json.load(sys.stdin); s=(d.get("services") or {}).get("postgres") or {}
print(s.get("container_name") or "postgres", s.get("image") or "")
')
EOF2
[ -n "$CONTAINER" ] && C_NAME="$CONTAINER"
[ -n "$IMAGE" ] && C_IMAGE="$IMAGE"
if [ -z "$C_IMAGE" ]; then
  echo "preflight-collation: REFUSE — compose names no image for the postgres service." >&2
  exit 2
fi

# A cluster that does not exist yet has nothing to migrate.  A FRESH install
# on this pin is the case NOM-341 called a non-issue, and it is this one.
if ! docker ps --format '{{.Names}}' | grep -qx "$C_NAME"; then
  echo "preflight-collation: ok — $C_NAME is not running, so there is no existing PGDATA to migrate."
  exit 0
fi

# What collation version does the TARGET image provide?  For the glibc
# provider postgres uses the glibc release string, so ask the image.
PROVIDES="$(docker run --rm --entrypoint sh "$C_IMAGE" -c 'ldd --version 2>/dev/null | head -1' 2>/dev/null \
            | sed -n 's/.*) \([0-9][0-9.]*\)$/\1/p')"
if [ -z "$PROVIDES" ]; then
  echo "preflight-collation: REFUSE — could not read the glibc version from $C_IMAGE, so no comparison was made." >&2
  exit 2
fi

# What does the live cluster record?  Any database whose recorded version is
# not what the target provides has indexes built under a different one.
RECORDED="$(docker exec "$C_NAME" sh -c 'psql -U "$POSTGRES_USER" -d postgres -At -F" " -c "SELECT datname, datcollversion FROM pg_database WHERE datcollversion IS NOT NULL AND datcollversion <> chr(32) ORDER BY datname"' 2>/dev/null)"
if [ -z "$RECORDED" ]; then
  echo "preflight-collation: REFUSE — $C_NAME is running but reported no recorded collation versions, so nothing was checked." >&2
  exit 2
fi

N=0; NBAD=0; BAD=""
while read -r db ver; do
  [ -n "${db:-}" ] || continue
  N=$((N+1))
  if [ "$ver" != "$PROVIDES" ]; then
    NBAD=$((NBAD+1))
    BAD="$BAD
                     $db records $ver"
  fi
done <<EOF3
$RECORDED
EOF3

# --- IS THE CLUSTER CONSISTENT WITH THE BASE IT IS ALREADY ON? -------------
# Everything above compares the TARGET image against pg_database, which is
# what you need BEFORE a swap.  It is not sufficient AFTER one, and this is
# measured, not theoretical: on 2026-10-23 this script reported
#
#     ok — all 7 databases record collation version 2.41
#
# on a cluster that still had 5663 STALE pg_collation rows.  Two reasons:
#
#   * pg_database is not the only catalog with a version.  Every row in
#     pg_collation carries its own collversion, and ALTER DATABASE ...
#     REFRESH COLLATION VERSION does not touch them.  Postgres warns when
#     such a collation is USED, so the warning survives a migration that
#     looks finished.
#   * glibc is not the only provider.  The Debian 12 -> 13 base swap moved
#     BOTH: glibc 2.36 -> 2.41 and ICU 153.120 -> 153.128.  Reading only
#     ldd's version sees half of the change -- 2 stale libc rows per
#     database, and 807 stale ICU ones.
#
# So ask the running cluster what it still records against what it NOW
# provides.  That question is provider-agnostic and needs no knowledge of
# the image, and it is the one that makes this script usable as the final
# proof of the migration rather than only as the gate before it.
DBLIST="$(docker exec "$C_NAME" sh -c 'psql -U "$POSTGRES_USER" -d postgres -At -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY datname"' 2>/dev/null)"
if [ -z "$DBLIST" ]; then
  echo "preflight-collation: REFUSE — could not list the connectable databases, so live staleness was not checked." >&2
  exit 2
fi

STALE_DB=0; STALE_COLL=0; NDB=0; STALE_DETAIL=""
for db in $DBLIST; do
  row="$(docker exec "$C_NAME" sh -c 'psql -U "$POSTGRES_USER" -d "$1" -At -F" " -c "
    SELECT
      (SELECT count(*) FROM pg_database d
         WHERE d.datname = current_database()
           AND d.datcollversion IS NOT NULL AND d.datcollversion <> chr(32)
           AND d.datcollversion <> coalesce(pg_database_collation_actual_version(d.oid), d.datcollversion)),
      (SELECT count(*) FROM pg_collation c
         WHERE c.collversion IS NOT NULL AND c.collversion <> chr(32)
           AND c.collversion <> coalesce(pg_collation_actual_version(c.oid), c.collversion))
  "' sh "$db" 2>/dev/null)"
  # "could not measure" is never reported as "nothing stale".
  case "$row" in
    [0-9]*' '[0-9]*) : ;;
    *) echo "preflight-collation: REFUSE — could not read collation staleness from database '$db', so it was not checked." >&2
       exit 2 ;;
  esac
  NDB=$((NDB+1))
  sdb="${row%% *}"; scoll="${row##* }"
  STALE_DB=$((STALE_DB+sdb)); STALE_COLL=$((STALE_COLL+scoll))
  if [ "$sdb" != "0" ] || [ "$scoll" != "0" ]; then
    STALE_DETAIL="$STALE_DETAIL
                     $db: $sdb stale database default, $scoll stale pg_collation row(s)"
  fi
done

if [ -n "$STALE_DETAIL" ]; then
  cat >&2 <<MSG2
preflight-collation: REFUSE — this cluster is already inconsistent with the
base it is running on, so a swap is not the next thing to fix.

  databases checked $NDB
  stale database defaults      $STALE_DB
  stale pg_collation rows      $STALE_COLL
$STALE_DETAIL

Finish the migration that was started.  Per database, and it is idempotent:

  bash scripts/migrate-collation.sh --yes

or by hand, per database:

  psql -c 'REINDEX DATABASE <db>'
  psql -c 'ALTER DATABASE <db> REFRESH COLLATION VERSION'
  psql -c 'ALTER COLLATION <name> REFRESH VERSION'   -- per stale row

Refreshing a collation whose indexes were built under the old version
records a version that is not true of those indexes, so REINDEX first.
MSG2
  exit 1
fi

if [ -z "$BAD" ]; then
  echo "preflight-collation: ok — all $N databases record collation version $PROVIDES, which $C_IMAGE provides."
  echo "preflight-collation: ok — $NDB databases are consistent with the base they run on (0 stale database defaults, 0 stale pg_collation rows)."
  exit 0
fi

cat >&2 <<MSG
preflight-collation: REFUSE — the target image changes the collation version
under an existing cluster, and nothing here reindexes.

  target image     $C_IMAGE
  it provides      $PROVIDES
  $NBAD of $N databases disagree:$BAD

Every text index in those databases was built under the recorded version.
Do not proceed with a plain recreate.  The supported path:

  1. bash scripts/backup.sh              # the way back.  Note that it dumps
                                         # only the databases named in
                                         # secrets/app_db_passwords.
  2. docker compose up -d postgres       # the new base
  3. bash scripts/migrate-collation.sh --yes
                                         # REINDEX, then refresh the database
                                         # default AND the pg_collation rows,
                                         # per database, for every provider
  4. bash scripts/preflight-collation.sh # must now say both oks
  5. bin/aistack doctor                  # must be clean

A base swap can move MORE THAN ONE collation provider: Debian 12 -> 13 moved
glibc 2.36 -> 2.41 and ICU 153.120 -> 153.128 together.  The glibc number
above is the trigger, not the whole change.

See NOM-354 for the rehearsal this procedure was measured on, and the
POSTGRES block in versions.env for the condition that came with the pin.
MSG
exit 1
