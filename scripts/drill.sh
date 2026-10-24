#!/usr/bin/env bash
# AI Stack 2026 — the Tier-A restore drill (B4).
#
# Restores an UNTAMPERED backup into a FRESH THROWAWAY PROJECT and asserts the
# data came back: workflow list, CREDENTIAL DECRYPTION, documents, user
# permissions, and the CONTENTS of the cluster-kind databases.  Then destroys
# the project.
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

# WHERE restore.sh WRITES WHAT IT RESTORED.  Assertion 4 below asserts one
# non-superuser role per restored database, and it must assert over the set
# the restore actually walked rather than over a list retyped here.
RESTORED_DBS="$(mktemp "${TMPDIR:-/tmp}/aistack-drill-dbs.XXXXXX")"
export AISTACK_RESTORED_DBS_FILE="$RESTORED_DBS"

# ...AND THE KIND OF EACH, for assertion 5.  The file above is app databases
# only; this one is `<kind> <name>` for every database the restore walked, so
# the cluster-kind ones -- which have no role to assert and were therefore
# asserted about in no way at all -- can be asserted over too (NOM-392).
RESTORED_KINDS="$(mktemp "${TMPDIR:-/tmp}/aistack-drill-kinds.XXXXXX")"
export AISTACK_RESTORED_DB_KINDS_FILE="$RESTORED_KINDS"

trap 'echo; echo "Destroying the drill project..."; clean; rm -f "$RESTORED_DBS" "$RESTORED_KINDS"; exec {LFD}>&-' EXIT

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

  # 4. user permissions — every app role must come back, and come back as a
  #    non-superuser, or the restore has lost an app or quietly escalated one.
  #
  # BOTH THE NAMES AND THE COUNT ARE DERIVED.  This assertion used to read:
  #
  #   R=$(q postgres "... WHERE rolname IN ('authelia','openwebui','litellm','n8n');")
  #   [ "${R:-0}" = "4" ] && ok "all four app roles restored"
  #
  # — a literal list AND a literal count.  On a five-app deployment whose
  # fifth role did not come back, R is still 4 and S is still 0, so the drill
  # printed "all four app roles restored", exited 0 and appended PASS to
  # drill-log.txt.  The fifth app could be counted neither present nor
  # missing.  Deriving the names without deriving the count buys nothing: the
  # `= "4"` is the half that certifies.
  #
  # The set comes from restore.sh, which read it out of the ARCHIVE
  # (payload/*.dump) — the authoritative statement of what there was to
  # restore.  Deriving it from the restored cluster instead would be circular:
  # a role and its database go missing together, so the expectation would
  # shrink to match the damage and pass.
  APPS="$(sort -u "$RESTORED_DBS" 2>/dev/null)"
  EXPECTED=0; PRESENT=0; MISSING=""; SUPER=""; UNANSWERED=""
  for app in $APPS; do
    case "$app" in
      *[!A-Za-z0-9_]*)
        bad "restore reported '$app' as a restored database, which is not a bare identifier"
        continue ;;
    esac
    EXPECTED=$((EXPECTED + 1))
    # `checked:` sentinel, same reason as the health probe: psql answering
    # NOTHING AT ALL — container gone, socket refused, query killed, SQL
    # rejected — must not read as "nothing is wrong with this role".  It
    # earned its place immediately: the first cut of this loop passed the name
    # as `-v app=` and matched `:'app'`, psql does not interpolate a variable
    # in a -c string, every query failed with `syntax error at or near ":"`,
    # and the drill reported 0/4 NOT ANSWERED instead of a vacuous pass.
    #
    # So the name is spliced, and what makes that safe is the filter above:
    # the `case` has already rejected anything outside [A-Za-z0-9_] (S06), the
    # same rule config/postgres/healthcheck.sh splices under.
    A=$(q postgres "SELECT 'checked:' || coalesce((SELECT CASE WHEN rolsuper THEN 'super' ELSE 'ok' END FROM pg_roles WHERE rolname = '$app'), 'missing');")
    case "$A" in
      checked:ok)      PRESENT=$((PRESENT + 1)) ;;
      checked:super)   SUPER="$SUPER $app" ;;
      checked:missing) MISSING="$MISSING $app" ;;
      *)               UNANSWERED="$UNANSWERED $app" ;;
    esac
  done
  if [ "$EXPECTED" -eq 0 ]; then
    bad "the restore reported no restored database, so no app role was checked; an expectation of nothing cannot fail"
  elif [ "$PRESENT" -eq "$EXPECTED" ] && [ -z "$MISSING$SUPER$UNANSWERED" ]; then
    ok "all $EXPECTED app roles restored ($(printf '%s' "$APPS" | tr '\n' ' ')), none of them a superuser"
  else
    bad "app roles after restore: $PRESENT/$EXPECTED present${MISSING:+; MISSING:$MISSING}${SUPER:+; SUPERUSER:$SUPER}${UNANSWERED:+; NOT ANSWERED:$UNANSWERED}"
  fi

  # 5. CLUSTER-KIND DATABASES — PRESENT, AND NOT EMPTY.
  #
  # Assertions 1 and 2 query `n8n`, 3 queries `openwebui`, and 4 walks the APP
  # databases.  Nothing above this line touches `aistack` — the stack's own
  # control database, which NOM-378 put into the archive precisely because it
  # had been in none of them.  A pg_restore that loaded nothing into it printed
  #
  #     (pg_restore reported warnings for aistack)
  #
  # from the `|| echo` in restore.sh's loop, DRILL_RC stayed 0, and this script
  # appended PASS to drill-log.txt.  That is the parent ticket's shape exactly:
  # a dump that is in the archive, does not come back, and is a warning.
  #
  # require_database_present() is not this assertion.  It proves the database
  # EXISTS, which is what an empty one does too; it is a refusal aimed at a
  # failed CREATE, not at a failed load.
  #
  # SO COUNT TABLES AND ROWS, BOTH.  Tables alone pass a schema-only restore,
  # which is a database that did not come back with anything in it.  Neither
  # the names nor the expected counts are typed here: the set is the
  # cluster-kind half of what restore.sh's loop WALKED (read from the archive,
  # same as assertion 4's), and what is counted is whatever that database
  # turns out to hold.
  #
  # THE NAME IS READ LINE-WISE, NOT FIELD-WISE (NOM-393).  restore.sh writes
  # `<kind> <name>` with one space, so the name is EVERYTHING after the first
  # space, spaces included.  The first cut of this took awk's `$2` and looped
  # with `for db in $CLUSTER_DBS`, and both halves truncate on whitespace: a
  # kinds line `cluster my db` arrived here as `my`, the [A-Za-z0-9_] refusal
  # below never saw a space to refuse, and the drill printed
  #
  #     [ ok ] cluster-kind database 'my' restored and is not empty (6 tables, 31 rows)
  #
  # — green, about a database that is not the one in the archive, while the
  # one that IS in the archive went unchecked.  Assertion 4 refuses such a
  # name loudly because it filters the whole name; assertion 5 could not see
  # it.  Fixing only the awk is not enough, which is why the set is an ARRAY
  # and the loop quotes it: unquoted word-splitting would put the truncation
  # straight back.  tests/drill-assertion5.sh drives the shipped block with
  # such a line and fails if it does not reach the refusal.
  #
  # `sed` rather than awk because awk's `$1`/`$2` are the field-wise reading
  # this is getting rid of; `sort -u` keeps the dedup the old pipeline had.
  mapfile -t CLUSTER_DBS < <(sed -n 's/^cluster //p' "$RESTORED_KINDS" 2>/dev/null | sort -u)
  mapfile -t LEGACY_DBS  < <(sed -n 's/^legacy //p'  "$RESTORED_KINDS" 2>/dev/null | sort -u)
  if [ "${#CLUSTER_DBS[@]}" -gt 0 ]; then
    for db in "${CLUSTER_DBS[@]}"; do
      # Same filter and same reason as assertion 4: the name is spliced into
      # SQL below, so anything outside [A-Za-z0-9_] is refused rather than
      # quoted-and-hoped (S06).
      case "$db" in
        *[!A-Za-z0-9_]*)
          bad "restore reported '$db' as a restored cluster-kind database, which is not a bare identifier"
          continue ;;
      esac
      # `checked:` sentinel again: a psql that answers NOTHING — container
      # gone, connection refused, query rejected — must not read as "nothing
      # is wrong with this database".
      E=$(q postgres "SELECT 'checked:' || CASE WHEN EXISTS (SELECT 1 FROM pg_database WHERE datname = '$db') THEN 'present' ELSE 'missing' END;")
      case "$E" in
        checked:present) ;;
        checked:missing)
          bad "cluster-kind database '$db' is in the archive but is not in the cluster after the restore"
          continue ;;
        *)
          bad "cluster-kind database '$db': the cluster did not answer whether it exists"
          continue ;;
      esac
      # Counted over the database's own catalog rather than a table list typed
      # here, so this says "it came back with contents" for any cluster-kind
      # database an operator adds, not only for the one that exists today.
      # query_to_xml runs a real count per table — reltuples is -1 until
      # something analyses, and a restore has not.
      C=$(q "$db" "SELECT 'checked:'
             || (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema')
                    AND n.nspname !~ '^pg_toast')
             || ':'
             || (SELECT coalesce(sum(cnt), 0) FROM (
                   SELECT (xpath('/row/c/text()', query_to_xml(
                             format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname),
                             false, true, '')))[1]::text::bigint AS cnt
                     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog','information_schema')
                      AND n.nspname !~ '^pg_toast') s);")
      case "$C" in checked:*:*) ;; *)
        bad "cluster-kind database '$db' exists but did not answer how much is in it"
        continue ;;
      esac
      REST="${C#checked:}"; TABLES="${REST%%:*}"; ROWS="${REST#*:}"
      case "$TABLES$ROWS" in *[!0-9]*)
        bad "cluster-kind database '$db' answered '$C', which is not two counts"
        continue ;;
      esac
      if [ "$TABLES" -eq 0 ]; then
        bad "cluster-kind database '$db' restored with NO TABLE — it exists and is empty, which is the warning this assertion exists to turn into a failure"
      elif [ "$ROWS" -eq 0 ]; then
        # THE ROW CHECK IS KEPT DELIBERATELY, AND IT HAS A KNOWN FALSE RED
        # (NOM-393).  A cluster-kind database in this stack carries SEEDED
        # reference data, not runtime accumulation — `aistack` restores 6
        # tables / 31 rows, of which 31 are seed rows in
        # action_state_edges (7) and aistack_slot (24) — so zero rows means
        # the load did not happen.  But a cluster-kind database an operator
        # ADDS and has not written to yet would red here on a correct
        # restore.  That is accepted rather than softened: the alternative
        # (require rows only where a manifest says to expect them) adds a
        # manifest field with no producer today and makes the assertion
        # weaker in the only case it was written for.  Named in
        # docs/backup-restore.md so the next operator reads it instead of
        # rediscovering it.
        bad "cluster-kind database '$db' restored $TABLES table(s) and 0 rows — schema only, so its contents did not come back (a cluster-kind database is expected to carry seeded rows; see docs/backup-restore.md)"
      else
        ok "cluster-kind database '$db' restored and is not empty ($TABLES tables, $ROWS rows)"
      fi
    done
  elif [ "${#LEGACY_DBS[@]}" -gt 0 ]; then
    # A pre-NOM-378 archive records no database kinds and carries no `aistack`
    # dump, so there is genuinely no cluster-kind database to assert over.  Say
    # so in those words rather than silently skipping: "nothing to check" and
    # "checked nothing" print the same on a green run.
    echo "  [note] this archive records no database kinds (pre-NOM-378), so it"
    echo "         carries no cluster-kind database and none was asserted."
    echo "         Drill a current archive to exercise assertion 5."
  else
    bad "the restore recorded no cluster-kind database and did not report a legacy archive either, so assertion 5 checked nothing; an expectation of nothing cannot fail"
  fi
fi

echo
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# AISTACK_DRILL_NOTE — why this run is in the log (NOM-393).
#
# drill-log.txt is what an operator reads during an incident, and a FAIL line
# in it says only "this archive did not restore".  NOM-392 proved assertion 5
# by injecting faults into restore.sh, which appended three FAILs that mean
# the opposite of what they look like: the drill WORKED.  The explanation
# lived in a window log outside the repository, on a disposable VM.
#
# So a run that is deliberately faulted, or run for any reason other than
# "does this archive restore", says so IN THE LOG LINE:
#
#   AISTACK_DRILL_NOTE='NOM-392 fault injection: aistack dump not loaded' \
#     bin/aistack drill run
#
# Newlines are stripped so one run stays one line.  No note means no marker,
# so every existing line keeps its meaning and anything reading this file
# field-wise still finds the date, verdict and archive in fields 1-3.
NOTE="$(printf '%s' "${AISTACK_DRILL_NOTE:-}" | tr -d '\n\r')"
if [ "$DRILL_RC" -eq 0 ]; then
  echo "$DATE PASS $ARCHIVE${NOTE:+ # NOTE: $NOTE}" >> "$ROOT/drill-log.txt"
  echo "DRILL PASSED — recorded in drill-log.txt"
  echo
  echo "What this proves: a good backup restores."
  echo "What it does NOT prove: that a restore cannot reach the network."
  echo "That needs host firewall rules and is a later release."
else
  echo "$DATE FAIL $ARCHIVE${NOTE:+ # NOTE: $NOTE}" >> "$ROOT/drill-log.txt"
  echo "DRILL FAILED — recorded in drill-log.txt"
  [ -n "$NOTE" ] && echo "  (logged with the note: $NOTE)"
fi
exit "$DRILL_RC"
