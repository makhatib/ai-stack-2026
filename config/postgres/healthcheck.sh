#!/bin/sh
# AI Stack 2026 — the Postgres health probe.
#
# IT ANSWERS A SOCKET QUESTION AND A CONTENT QUESTION, because only one of
# them was ever being asked and it was the wrong one.
#
# MEASURED (NOM-307, 2026-10-19), from an empty volume on the isolated QA
# target.  The probe was `pg_isready -U aistack_admin -d aistack`.  This is
# what that certifies as healthy:
#
#   1. First boot runs /docker-entrypoint-initdb.d/01-roles-and-databases.sh.
#      It could not read /run/secrets/app_db_passwords (uid 999, file written
#      0600 root:root — the D1 defect) and exited non-zero under
#      `set -euo pipefail`, so the entrypoint aborted PART WAY THROUGH INIT.
#   2. `restart: unless-stopped` restarted the container.
#   3. The entrypoint found a non-empty PGDATA and printed "PostgreSQL
#      Database directory appears to contain a database; Skipping
#      initialization".  THE INIT SCRIPTS WILL NEVER RUN AGAIN BY THEMSELVES.
#   4. The cluster came up holding exactly one role — aistack_admin — and none
#      of the four application roles or databases.
#   5. pg_isready answered, so health=healthy, restartCount=1.
#
# A socket that answers was true.  "This database can serve this stack" was
# false, and remained false for as long as the volume lived.  LiteLLM found
# out instead, with `Role "litellm" does not exist`, which names a consequence
# and not a cause.
#
# So this probe asserts the END STATE OF FIRST-BOOT INIT: one role and one
# database per application, plus the control table the init script creates
# last.  When that is absent the container is reported unhealthy WITH THE
# MISSING OBJECTS NAMED, which is the difference between a health gate and a
# rubber stamp.  `aistack doctor` makes the same assertion, and
# `aistack db-init` repairs it in place.
#
# THE EXPECTED LIST IS NOT HARDCODED HERE.  It is the key set of
# app_db_passwords — the same file 01-roles-and-databases.sh iterates — so the
# two cannot drift.  Keys only; this script never reads a value and never
# prints one.
#
# Cost: two psql round trips over the local socket every interval, both
# reading catalogues.  Measured at well under a tenth of a second.
set -u

PW_FILE="${APP_DB_PASSWORDS_FILE:-/run/secrets/app_db_passwords}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_NAME="${POSTGRES_DB:-postgres}"

fail() { printf '%s\n' "$*"; exit 1; }

# --- 1. the socket ---------------------------------------------------------
pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1 \
  || fail "pg_isready: the server is not accepting connections yet"

# --- 2. can the init script's own input even be read? ----------------------
# Reported HERE rather than being left to the init script's stderr, because
# this is the probe whose answer the installer and every `depends_on` waits
# on.  The mode is printed; the content is not.
if [ ! -r "$PW_FILE" ]; then
  fail "cannot read $PW_FILE as uid $(id -u) — $(ls -ln "$PW_FILE" 2>/dev/null | awk '{print $1" "$3":"$4}'). The first-boot init script reads this file; re-run scripts/gen-secrets.sh on the host."
fi

APPS="$(sed -n 's/^\([A-Za-z0-9_][A-Za-z0-9_]*\)=.*/\1/p' "$PW_FILE" | sort -u)"
[ -n "$APPS" ] || fail "$PW_FILE holds no application names, so no role can be checked"

# Spliced into SQL below.  The sed pattern above accepts ONLY [A-Za-z0-9_] as
# a key, so there is no quoting hazard to carry — and that filter, not a
# shell quote, is what makes the splice safe (S06).
LIST=""
for app in $APPS; do
  LIST="$LIST${LIST:+,}'$app'"
done

# --- 3. the end state first-boot init is supposed to leave behind ----------
# The query prints a 'checked:' SENTINEL, so an answer that did not arrive can
# never be read as an answer of "nothing is missing".  This file exists
# because something empty was treated as something benign.
ANSWER="$(psql -tAq -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" 2>/dev/null <<SQL
SELECT 'checked:' || coalesce(string_agg(missing, ' ' ORDER BY missing), '') FROM (
    SELECT 'role:' || a AS missing
      FROM unnest(ARRAY[$LIST]) AS a
     WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = a)
    UNION ALL
    SELECT 'database:' || d
      FROM unnest(ARRAY[$LIST]) AS d
     WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = d)
    UNION ALL
    SELECT 'table:aistack_slot'
     WHERE NOT EXISTS (
         SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relname = 'aistack_slot' AND n.nspname = 'public')
) s;
SQL
)" || fail "the server answered pg_isready but the catalogue query failed — this is NOT a clean cluster"

case "$ANSWER" in
  checked:) exit 0 ;;                      # the query ran; nothing is missing
  checked:*) MISSING="${ANSWER#checked:}" ;;
  *) fail "the catalogue query returned no answer (${ANSWER:-empty}) — 'I could not check' is not 'I checked'" ;;
esac

fail "FIRST-BOOT INIT DID NOT COMPLETE — missing: $MISSING
  The entrypoint only runs /docker-entrypoint-initdb.d on an EMPTY data
  directory, so a restart over a half-initialised cluster skips it silently.
  Repair in place (idempotent):  bin/aistack db-init
  Diagnose:                      docker logs aistack-postgres | head -40"
