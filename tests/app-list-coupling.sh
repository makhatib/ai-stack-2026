#!/usr/bin/env bash
# AI Stack 2026 — the app list is ONE list, measured against a real cluster.
#
# WHAT THIS TEST EXISTS TO STOP (NOM-307 review, 2026-10-19).
#
# The health probe derived its EXPECTED set of roles and databases from the key
# set of secrets/app_db_passwords.  The first-boot init script did NOT iterate
# that file — it iterated a literal `for app in authelia openwebui litellm n8n`
# — under a comment in healthcheck.sh asserting the two "cannot drift".  Three
# more literal copies lived in gen-secrets.sh, backup.sh and restore.sh.
# Nothing coupled any of them: no invariant, no test.
#
# So adding a fifth app produced this, on an ALREADY-HEALTHY deployment, within
# one 10s health interval:
#
#   * postgres goes unhealthy, because the probe expects a role nothing creates
#   * every service behind `depends_on: service_healthy` stops starting
#   * the probe reports "FIRST-BOOT INIT DID NOT COMPLETE" — which is FALSE
#   * it names `bin/aistack db-init` as the repair, and db-init re-ran the same
#     literal list, created nothing, and died saying the cluster still does not
#     hold what it should
#
# CI invariant I15 holds the declaration down statically.  This test measures
# the BEHAVIOUR that invariant is a proxy for: that a key appearing in
# app_db_passwords is a role and database the init script actually creates, and
# therefore that db-init is a genuine repair for list drift rather than a no-op.
#
# It uses a THROWAWAY container and a SYNTHETIC password file.  No real secret
# is read and the live stack is never touched.  The file is world-readable here
# deliberately: the 0640 root:<gid> mode property is a different assertion and
# tests/secret-modes.sh owns it.
#
# Run:  tests/app-list-coupling.sh        (needs docker; ~40s)

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
source "$ROOT/versions.env"

C="aistack-applist-test"
WORK="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker volume rm -f "${C}-data" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

ok()   { printf '  ok    %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
note() { printf '        %s\n' "$*"; }

probe() { docker exec "$C" /usr/local/bin/aistack-pg-health 2>&1; }

# The repair path a drifted list sends an operator down.  `bin/aistack db-init`
# wraps exactly this plus a lifecycle lock; re-running the init script in place
# against the running container IS the repair, which is why it is what gets
# measured.
db_init() { docker exec "$C" bash /docker-entrypoint-initdb.d/01-roles-and-databases.sh 2>&1; }

roles() {
  docker exec "$C" psql -tAq -U aistack_admin -d aistack \
    -c "SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'pg\\_%' ORDER BY 1" 2>/dev/null
}
databases() {
  docker exec "$C" psql -tAq -U aistack_admin -d aistack \
    -c "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY 1" 2>/dev/null
}

printf '\n== app-list coupling: one declaration, every consumer derives it ==\n\n'

# --- the synthetic secret, four apps, matching gen-secrets.sh's declaration --
printf 'authelia=%s\nopenwebui=%s\nlitellm=%s\nn8n=%s\n' \
  "$(openssl rand -hex 12)" "$(openssl rand -hex 12)" \
  "$(openssl rand -hex 12)" "$(openssl rand -hex 12)" > "$WORK/app_db_passwords"
printf 'test-only-%s' "$(openssl rand -hex 12)" > "$WORK/superuser"
chmod 0644 "$WORK/app_db_passwords" "$WORK/superuser"

docker rm -f "$C" >/dev/null 2>&1 || true
docker volume rm -f "${C}-data" >/dev/null 2>&1 || true

docker run -d --name "$C" \
  -v "${C}-data:/var/lib/postgresql/data" \
  -v "$ROOT/config/postgres/init/01-roles-and-databases.sh:/docker-entrypoint-initdb.d/01-roles-and-databases.sh:ro" \
  -v "$ROOT/config/postgres/healthcheck.sh:/usr/local/bin/aistack-pg-health:ro" \
  -v "$WORK/app_db_passwords:/run/secrets/app_db_passwords:ro" \
  -v "$WORK/superuser:/run/secrets/postgres_superuser_password:ro" \
  -e POSTGRES_USER=aistack_admin \
  -e POSTGRES_DB=aistack \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_superuser_password \
  -e APP_DB_PASSWORDS_FILE=/run/secrets/app_db_passwords \
  "${POSTGRES_IMAGE}:${POSTGRES_TAG}@${POSTGRES_DIGEST}" >/dev/null \
  || { bad "could not start the throwaway postgres"; exit 1; }

# First boot has to finish before anything is asserted.  The probe IS the
# readiness signal under test, so it cannot be the thing that is waited on; the
# init script's own last line is.
for _ in $(seq 1 60); do
  docker logs "$C" 2>&1 | grep -q 'aistack control tables ready' && break
  sleep 1
done
docker logs "$C" 2>&1 | grep -q 'aistack control tables ready' \
  || { bad "first-boot init never completed; logs:"; docker logs "$C" 2>&1 | tail -20; exit 1; }
# ... and the server must be accepting connections for the catalogue queries.
for _ in $(seq 1 30); do
  docker exec "$C" pg_isready -U aistack_admin -d aistack >/dev/null 2>&1 && break
  sleep 1
done

# --- 1. a four-app file produces four roles and a probe that passes ----------
OUT="$(probe)"; RC=$?
[ "$RC" -eq 0 ] && ok "four-app file: probe exits 0" \
                || { bad "four-app file: probe exits $RC"; note "$OUT"; }

GOT="$(roles | tr '\n' ' ')"
case "$GOT" in
  *aistack_admin*authelia*litellm*n8n*openwebui*) ok "four-app file: roles are $GOT" ;;
  *) bad "four-app file: roles are '$GOT'" ;;
esac

# --- 2. THE REVIEW'S SCENARIO: a fifth app is declared ----------------------
# This is the single edit someone makes first, because without a password there
# is nothing to hand the role.  In production it is one line in gen-secrets.sh;
# here it is the file that loop writes.
printf 'grafana=%s\n' "$(openssl rand -hex 12)" >> "$WORK/app_db_passwords"
note ""
note "a fifth app (grafana) is now declared in the password file"

OUT="$(probe)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'role:grafana' \
                   && printf '%s' "$OUT" | grep -q 'database:grafana'; then
  ok "fifth app declared: probe reports it missing and NAMES it"
else
  bad "fifth app declared: probe exit=$RC did not name the missing grafana objects"
  note "$OUT"
fi

# --- 3. THE DEFECT THIS TEST EXISTS FOR -------------------------------------
# Before the fix, db-init re-ran a literal four-app list: it created nothing and
# died with "init ran but the cluster still does not hold what it should", so
# the stack stayed wedged with the probe blaming a first boot that had long
# since completed.  It must now actually create the fifth app.
OUT="$(db_init)"; RC=$?
[ "$RC" -eq 0 ] && ok "db-init repair: exits 0" \
                || { bad "db-init repair: exits $RC"; note "$OUT"; }

printf '%s' "$OUT" | grep -q 'role+database ready: grafana' \
  && ok "db-init repair: created the fifth app from the password file" \
  || { bad "db-init repair: never created grafana — the list is still not one list"; note "$OUT"; }

GOT="$(roles | tr '\n' ' ')"
case "$GOT" in
  *grafana*) ok "db-init repair: grafana is a role ($GOT)" ;;
  *) bad "db-init repair: grafana is not a role; roles are '$GOT'" ;;
esac
GOT="$(databases | tr '\n' ' ')"
case "$GOT" in
  *grafana*) ok "db-init repair: grafana is a database ($GOT)" ;;
  *) bad "db-init repair: grafana is not a database; databases are '$GOT'" ;;
esac

# --- 4. and the gate agrees, with no volume wipe ----------------------------
OUT="$(probe)"; RC=$?
[ "$RC" -eq 0 ] && ok "after repair: probe exits 0 — in place, no volume wipe" \
                || { bad "after repair: probe still exits $RC"; note "$OUT"; }

# --- 5. the empty-file guard ------------------------------------------------
# An unreadable file has its own message (and its own test); a readable file
# with no names must not be read as "no apps are required".
: > "$WORK/app_db_passwords"
OUT="$(probe)"; RC=$?
[ "$RC" -eq 1 ] && ok "empty password file: probe refuses (exit 1) rather than passing vacuously" \
                || { bad "empty password file: probe exit=$RC"; note "$OUT"; }

OUT="$(db_init)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'no application names'; then
  ok "empty password file: init refuses and says why"
else
  bad "empty password file: init exit=$RC did not refuse with a reason"
  note "$OUT"
fi

printf '\n== %d passed, %d failed ==\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
