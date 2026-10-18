#!/usr/bin/env bash
# AI Stack 2026 — the Tier-A restore drill (B4).
#
# Restores an UNTAMPERED backup into a FRESH THROWAWAY PROJECT and asserts the
# data came back: workflow list, CREDENTIAL DECRYPTION, documents, and user
# permissions.  Then destroys the project.
#
# It validates RESTORABILITY and the documentation says exactly that.  It does
# NOT claim containment, and it inherits the Tier-A host-listener residual
# like everything else: v1 proves a backup restores and proves a bad backup is
# refused; it does not prove a restore cannot reach the network.
#
# THE DRILL CANNOT TOUCH LIVE DATA, and that is enforced by a lock rather than
# by convention.  The drill holds an EXCLUSIVE flock on the lifecycle lock for
# its whole lifetime; the serving supervisor holds the SHARED mode for as long
# as the stack is up.  Neither can start while the other holds, in either
# direction, and two simultaneous starts are serialised by the kernel —
# not by two one-way startup checks, which can race.
#
#   aistack drill run [archive]
#   aistack drill clean

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

PROJECT="restore-drill-$(date -u +%Y%m%d%H%M%S)"
# AISTACK_RUNDIR is exported by bin/aistack so that the drill and the serving
# supervisor take THE SAME lock. Re-deriving it here would let the two pick
# different files and the mutual exclusion would silently stop existing.
RUNDIR="${AISTACK_RUNDIR:-}"
if [ -z "$RUNDIR" ] || [ ! -w "$RUNDIR" ]; then
  if [ -d /run/aistack ] && [ -w /run/aistack ]; then RUNDIR=/run/aistack
  elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -w "${XDG_RUNTIME_DIR}" ]; then RUNDIR="$XDG_RUNTIME_DIR/aistack"
  else RUNDIR="/tmp/aistack-$(id -u)"; fi
fi
mkdir -p "$RUNDIR" 2>/dev/null || true
LOCK="$RUNDIR/lifecycle.lock"
if ! : >> "$LOCK" 2>/dev/null; then
  echo "drill: cannot write the lifecycle lock at $LOCK." >&2
  echo "Set AISTACK_RUNDIR to a writable tmpfs path, the same one bin/aistack uses." >&2
  exit 1
fi

ok()  { printf '  [ ok ] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; DRILL_RC=1; }
DRILL_RC=0

clean() {
  for p in $(docker ps -a --format '{{.Label "com.docker.compose.project"}}' | grep '^restore-drill-' | sort -u); do
    echo "  tearing down $p"
    docker ps -a --filter "label=com.docker.compose.project=$p" -q | xargs -r docker rm -f >/dev/null 2>&1
  done
  for v in $(docker volume ls -q | grep '^restore-drill-'); do
    docker volume rm "$v" >/dev/null 2>&1 && echo "  removed volume $v"
  done
  for n in $(docker network ls --format '{{.Name}}' | grep '^restore-drill-'); do
    docker network rm "$n" >/dev/null 2>&1 && echo "  removed network $n"
  done
}

case "${1:-run}" in
  clean) echo "Cleaning up any drill leftovers..."; clean; exit 0 ;;
  run) shift ;;
  *) echo "usage: aistack drill {run [archive]|clean}" >&2; exit 2 ;;
esac

ARCHIVE="${1:-$(ls -t "$ROOT"/backups/*.enc 2>/dev/null | head -1)}"
[ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] || { echo "drill: no archive found. Run 'aistack backup' first." >&2; exit 1; }

echo
echo "Tier-A restore drill (B4)"
echo "  archive: $ARCHIVE"
echo "  project: $PROJECT"
echo

# --- the exclusive lock, held for the WHOLE lifetime ------------------------
exec {LFD}>>"$LOCK"
if ! flock -n -x "$LFD"; then
  cat >&2 <<'EOF'
drill: the lifecycle lock is held.

The serving stack holds it in SHARED mode for as long as it is up, so a drill
cannot start while the stack is serving — which is the point: the drill must
not be able to touch live volumes. Stop the stack first:

    bin/aistack down
EOF
  exit 1
fi

# Orphan cleanup and the opposing-project check both run INSIDE the hold,
# which is what closes the check-then-act race.
clean
LIVE=$(docker ps -a --format '{{.Names}}' | grep '^aistack-' || true)
if [ -n "$LIVE" ]; then
  echo "drill: serving containers still exist inside the hold:" >&2
  printf '  %s\n' $LIVE >&2
  echo "Refusing to run: a drill alongside serving is the thing the lock exists to prevent." >&2
  exit 1
fi
ok "lifecycle lock held EXCLUSIVE; no serving container or bridge exists"

trap 'echo; echo "Destroying the drill project..."; clean; exec {LFD}>&-' EXIT

# --- restore into the throwaway project ------------------------------------
echo
echo "Restoring into $PROJECT (live volumes are not touched)..."
if ! bash scripts/restore.sh "$ARCHIVE" --into-drill-project "$PROJECT" --yes 2>&1 | sed 's/^/  /'; then
  bad "the restore itself failed"
  exit 1
fi

# --- assertions -------------------------------------------------------------
echo
echo "Asserting the data came back:"
# Compose names containers <project>-<service>-<n>.  Resolve it by LABEL
# rather than by guessing the string, so a naming-scheme change surfaces as
# "no container" rather than as an assertion against the wrong database.
PG="$(docker ps --format '{{.Names}}' \
      --filter "label=com.docker.compose.project=${PROJECT}" \
      --filter "label=com.docker.compose.service=postgres" | head -1)"

q() { docker exec -i "$PG" psql -tAq -U aistack_admin -d "$1" -c "$2" 2>/dev/null | tr -d ' \n'; }

if [ -z "$PG" ]; then
  bad "no postgres container in the drill project; nothing can be asserted"
else
  # 1. workflow list
  N=$(q n8n "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='workflow_entity';")
  if [ "$N" = "1" ]; then
    W=$(q n8n "SELECT count(*) FROM workflow_entity;")
    ok "workflow table restored (${W:-0} workflows)"
  else
    bad "n8n workflow_entity table is absent after restore"
  fi

  # 2. CREDENTIAL DECRYPTION — the assertion that matters most.
  # A restore that returns a workflow list but no usable credentials is not a
  # restore, and the thing that makes credentials usable is the encryption key
  # being IN the backup set.
  C=$(q n8n "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='credentials_entity';")
  if [ "$C" = "1" ]; then
    CN=$(q n8n "SELECT count(*) FROM credentials_entity;")
    ok "credentials table restored (${CN:-0} credentials)"
    if [ "${CN:-0}" -gt 0 ]; then
      # ACTUALLY DECRYPT ONE.  "The key is in the archive, therefore these are
      # decryptable" is an inference, and the whole point of a drill is to
      # stop inferring. n8n's exporter decrypts with the instance key, so a
      # plaintext marker coming back out is proof that the key in the archive
      # matches the ciphertext in the archive — which is the property that
      # makes a backup worth having.
      echo "  ... starting the drill n8n to decrypt a credential"
      if docker compose -p "$PROJECT" -f compose.drill.yaml up -d n8n >/dev/null 2>&1; then
        N8NC=""
        for _ in $(seq 1 40); do
          N8NC="$(docker ps --format '{{.Names}}' \
                  --filter "label=com.docker.compose.project=${PROJECT}" \
                  --filter "label=com.docker.compose.service=n8n" | head -1)"
          [ -n "$N8NC" ] && docker exec "$N8NC" true >/dev/null 2>&1 && break
          sleep 3
        done
        if [ -n "$N8NC" ] && docker exec "$N8NC" n8n export:credentials --all --decrypted \
             --output=/tmp/dec.json >/dev/null 2>&1; then
          if docker exec "$N8NC" grep -q 'SYNTHETIC-NOT-A-REAL' /tmp/dec.json 2>/dev/null; then
            ok "CREDENTIAL DECRYPTED — the synthetic marker came back as plaintext"
          else
            bad "export succeeded but the decrypted plaintext does not contain the synthetic marker"
          fi
          docker exec "$N8NC" rm -f /tmp/dec.json >/dev/null 2>&1 || true
        else
          bad "could not decrypt a credential in the restored project"
        fi
      else
        bad "the drill n8n would not start, so decryption could not be exercised"
      fi
    else
      echo "  [note] no credentials in this backup to decrypt — add one and re-drill"
      echo "         to exercise the decryption path with real ciphertext."
    fi
  else
    bad "n8n credentials_entity table is absent after restore"
  fi

  # 3. documents and vectors
  V=$(q openwebui "SELECT count(*) FROM pg_extension WHERE extname='vector';")
  [ "$V" = "1" ] && ok "pgvector extension restored in the openwebui database" \
                 || bad "pgvector extension missing after restore"

  # 4. user permissions — the non-superuser roles must come back as
  #    non-superusers, or the restore has quietly escalated every app.
  S=$(q postgres "SELECT count(*) FROM pg_roles WHERE rolname IN ('authelia','openwebui','litellm','n8n') AND rolsuper;")
  R=$(q postgres "SELECT count(*) FROM pg_roles WHERE rolname IN ('authelia','openwebui','litellm','n8n');")
  if [ "${R:-0}" = "4" ] && [ "${S:-1}" = "0" ]; then
    ok "all four app roles restored, none of them a superuser"
  else
    bad "app roles after restore: ${R:-0}/4 present, ${S:-?} are superusers"
  fi
fi

echo
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$DRILL_RC" -eq 0 ]; then
  echo "$DATE PASS $ARCHIVE" >> "$ROOT/drill-log.txt"
  echo "DRILL PASSED — recorded in drill-log.txt"
  echo
  echo "What this proves: a good backup restores."
  echo "What it does NOT prove: that a restore cannot reach the network."
  echo "That needs host firewall rules and is a later release."
else
  echo "$DATE FAIL $ARCHIVE" >> "$ROOT/drill-log.txt"
  echo "DRILL FAILED — recorded in drill-log.txt"
fi
exit "$DRILL_RC"
