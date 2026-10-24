#!/bin/bash
# AI Stack 2026 — one database and ONE NON-SUPERUSER ROLE PER APP.
#
# No application ever connects as a superuser.  That is not a style
# preference: `pg_read_server_files`, `COPY ... PROGRAM` and extension creation
# are all superuser-gated, and an app role that has them turns an SQL injection
# into host access.
#
# Runs once, on an empty PGDATA, from docker-entrypoint-initdb.d.  It is
# idempotent anyway (IF NOT EXISTS throughout) so a volume-aware re-init cannot
# half-apply it.

set -euo pipefail

# Passwords arrive as a file, never as an environment variable and never on the
# command line, where they would be visible in `ps` to anything sharing the PID
# namespace.  (Nothing does — no host PID anywhere — but the habit is the point.)
PW_FILE="${APP_DB_PASSWORDS_FILE:?APP_DB_PASSWORDS_FILE not set}"

# SAY WHY, ONCE, BEFORE THE REDIRECT DOES IT BADLY.
#
# MEASURED (NOM-307, 2026-10-19).  With the secret written 0600 root:root this
# script's only output was
#
#   01-roles-and-databases.sh: line 20: /run/secrets/app_db_passwords: Permission denied
#   FATAL: no password for 'authelia' in /run/secrets/app_db_passwords
#
# — a line number, and then a sentence that reads as "the file lacks an entry"
# when the truth is "this process cannot open the file at all".  The two have
# completely different repairs.  This check costs one stat and replaces both.
if [ ! -r "$PW_FILE" ]; then
  cat >&2 <<EOF
FATAL: cannot READ $PW_FILE (it is not an empty or malformed file).

  running as:  uid $(id -u) gid $(id -g)
  file is:     $(ls -ln "$PW_FILE" 2>/dev/null | awk '{print $1" owner "$3":"$4}' || echo 'not present')

Compose bind-mounts a file secret with its HOST ownership, and this container
drops ALL capabilities, so uid 0 inside it does not bypass file permissions
either.  The host file must be readable by the uid this entrypoint drops to.

On the host, in the stack directory:

    sudo bash scripts/gen-secrets.sh

It reads the measured uid:gid from manifest.yaml and applies the mode, and it
now refuses to continue rather than writing one that cannot work.
EOF
  exit 1
fi

get_pw() {
  # Format: one `name=value` per line.  Parsed, never sourced (S06) — a
  # password containing a backtick must not become a command.
  local key="$1" line value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${key}="*) value="${line#*=}"; printf '%s' "$value"; return 0 ;;
    esac
  done < "$PW_FILE"
  echo "FATAL: no password for '$key' in $PW_FILE" >&2
  return 1
}

create_app() {
  local app="$1" pw
  pw="$(get_pw "$app")"

  # The password is passed as a bound parameter via psql's variable
  # interpolation with quoting, not spliced into the SQL text.
  PGPASSWORD="" psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -v app="$app" -v pw="$pw" <<-'SQL'
		SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app', :'pw')
		WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app')
		\gexec
		SELECT format('CREATE DATABASE %I OWNER %I', :'app', :'app')
		WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app')
		\gexec
	SQL

  # Revoke the PUBLIC grant: by default every role may connect to every new
  # database.  Without this, n8n's role can open open-webui's database.
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -v app="$app" <<-'SQL'
		SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'app') \gexec
		SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'app', :'app') \gexec
	SQL

  # pgvector lives in the one database that holds embeddings.  CREATE EXTENSION
  # is superuser-only, so it happens here, now — not at app startup under a
  # role that would need to be a superuser to run it.
  # openwebui (RAG) and mem0 (the agent's memory) both hold embeddings.
  if [ "$app" = "openwebui" ] || [ "$app" = "mem0" ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$app" \
      -c 'CREATE EXTENSION IF NOT EXISTS vector;'
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$app" \
      -v app="$app" <<-'SQL'
			SELECT format('GRANT ALL ON SCHEMA public TO %I', :'app') \gexec
		SQL
  else
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$app" \
      -v app="$app" <<-'SQL'
			SELECT format('GRANT ALL ON SCHEMA public TO %I', :'app') \gexec
		SQL
  fi

  echo "role+database ready: $app"
}

# THE APP LIST IS NOT DECLARED HERE.  It is the key set of $PW_FILE.
#
# It used to be `for app in authelia openwebui litellm n8n` — a hardcoded copy
# of a list that also lived in gen-secrets.sh, backup.sh and restore.sh, under
# a comment in healthcheck.sh asserting that the probe's list and this one
# "cannot drift".  They could, and the drift was asymmetric in the direction
# that wedges the stack: the probe derived its EXPECTED set from this file
# while this script created a FIXED set.
#
# MEASURED (NOM-307 review, 2026-10-19).  Add a fifth app to gen-secrets.sh —
# the first edit anyone makes, because without it there is no password to hand
# the role — and run the installer, or the repair that docs/troubleshooting.md
# tells an operator to run.  On an ALREADY-HEALTHY deployment, within 10s:
# postgres goes unhealthy because the probe now demands a role nothing
# creates; every service behind `depends_on: service_healthy` stops starting;
# and the probe blames "FIRST-BOOT INIT DID NOT COMPLETE", which is false,
# then names `db-init` as the repair — which re-ran this same fixed list,
# created nothing, and died saying the cluster still does not hold what it
# should.  A gate that wedges the stack and names a cause that is not the
# cause is the same defect as the `except ImportError` this ticket removed.
#
# Deriving both from one file is what makes healthcheck.sh's comment true
# rather than aspirational, and it makes `db-init` a genuine repair for list
# drift instead of a no-op.  The same extraction appears in healthcheck.sh; CI
# invariant I15 holds them together — it fails the build on a copy of this
# list in a `for ... in` loop, a bare assignment or a SQL `IN (...)` set, and
# on any named consumer that stops deriving — and
# tests/app-list-coupling.sh measures it against a real cluster.
APPS="$(sed -n 's/^\([A-Za-z0-9_][A-Za-z0-9_]*\)=.*/\1/p' "$PW_FILE" | sort -u)"
if [ -z "$APPS" ]; then
  cat >&2 <<EOF
FATAL: $PW_FILE holds no application names, so no role can be created.

The file is readable (checked above) but contains no \`name=value\` line.  On
the host, in the stack directory:

    sudo bash scripts/gen-secrets.sh

EOF
  exit 1
fi

for app in $APPS; do
  create_app "$app"
done

# The slot table: limits.yaml v1's aggregate concurrency bound.  FOUR running
# plus TWENTY queued, as FINITE ROWS — not a counter.  A counter can be
# incremented twice by two transactions that both read the same value; a row
# taken with FOR UPDATE SKIP LOCKED cannot be taken twice, which is the whole
# reason the design replaced revision 3's conditional insert.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'SQL'
	CREATE TABLE IF NOT EXISTS aistack_slot (
	    slot_id     integer PRIMARY KEY,
	    kind        text    NOT NULL CHECK (kind IN ('run','queue')),
	    holder      text,
	    lease_until timestamptz
	);
	INSERT INTO aistack_slot (slot_id, kind)
	SELECT g, 'run'   FROM generate_series(1, 4)  AS g
	ON CONFLICT (slot_id) DO NOTHING;
	INSERT INTO aistack_slot (slot_id, kind)
	SELECT g + 100, 'queue' FROM generate_series(1, 20) AS g
	ON CONFLICT (slot_id) DO NOTHING;

	-- Write admission (limits.yaml v1).  One row per filesystem; a reservation
	-- is CONVERTED TO A CHARGE on every terminal outcome rather than released,
	-- so two sequential writers cannot spend the same bytes.
	CREATE TABLE IF NOT EXISTS aistack_fs (
	    fs_path        text PRIMARY KEY,
	    reserve_bytes  bigint NOT NULL,
	    charged_bytes  bigint NOT NULL DEFAULT 0,
	    reserved_bytes bigint NOT NULL DEFAULT 0
	);
	CREATE TABLE IF NOT EXISTS unresolved_writers (
	    writer_id    text PRIMARY KEY,
	    fs_path      text NOT NULL,
	    cgroup_path  text NOT NULL,
	    expired_at   timestamptz NOT NULL DEFAULT now()
	);
SQL

echo "aistack control tables ready"
