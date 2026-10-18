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
  if [ "$app" = "openwebui" ]; then
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

for app in authelia openwebui litellm n8n; do
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
