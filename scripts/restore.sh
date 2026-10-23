#!/usr/bin/env bash
# AI Stack 2026 — restore (final-design §7.4).
#
# ORDER MATTERS AND IS THE WHOLE POINT: verify completely, THEN overwrite.
# Every refusal below happens before a single byte of live data is touched.
#
# `--into-drill-project <name>` restores into a FRESH THROWAWAY PROJECT instead
# of over the live one.  That is B4, the Tier-A positive restore, and it is how
# the drill proves a GOOD backup restores without any chance of touching live
# volumes.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ARCHIVE=""
DRILL_PROJECT=""
ASSUME_YES=0
VERIFY_ONLY_FLAG=0

while [ $# -gt 0 ]; do
  case "$1" in
    --into-drill-project) DRILL_PROJECT="${2:?needs a project name}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    # READ-ONLY.  Verify the archive and state what it can and cannot
    # return, then stop.  Without this the only way to ask "which
    # databases is this archive?" was to begin a restore that overwrites
    # live data at step 4 -- not a question anyone should have to risk
    # asking, and the docs promised an answer that did not exist
    # (NOM-378).
    --verify-only) VERIFY_ONLY_FLAG=1; shift ;;
    -*) echo "restore: unknown option '$1'" >&2; exit 2 ;;
    *) ARCHIVE="$1"; shift ;;
  esac
done

die() { printf 'restore: %s\n' "$*" >&2; exit 1; }

# >>> verify-only resolution: tests/backup-db-set.sh extracts and runs these lines >>>
# READ-ONLY IS REQUESTED OUT OF BAND, not only by an appended flag.
#
# bin/aistack used to build the call as `restore.sh "$@" --verify-only`, with
# the flag AFTER the caller's arguments.  `aistack verify a.enc
# --into-drill-project` therefore let --into-drill-project consume
# `--verify-only` as its project name, VERIFY_ONLY stayed 0, and execution
# continued past the read-only exit.  Whether a command can write must not
# depend on how argv happens to land, so the environment variable is the
# primary channel and the flag stays for anyone driving this script directly.
#
# Fail-safe direction: an AISTACK_VERIFY_ONLY left set in a shell turns a
# restore into a verification that changes nothing and says so.  The opposite
# mistake is the one that costs data.
verify_only_requested() {
  # $1 = the --verify-only flag's value.
  [ "${AISTACK_VERIFY_ONLY:-0}" = "1" ] && return 0
  [ "${1:-0}" = "1" ] && return 0
  return 1
}
# <<< verify-only resolution <<<

[ -n "$ARCHIVE" ] || die "usage: aistack restore <archive.tar.gz.enc> [--into-drill-project NAME] [--verify-only]"
[ -f "$ARCHIVE" ] || die "no such archive: $ARCHIVE"

ENC_KEY="$ROOT/secrets/backup.key"
HMAC_KEY="$ROOT/secrets/backup.hmac"

[ -s "$ENC_KEY" ] || die "missing $ENC_KEY — the archive cannot be decrypted"
# Checked here as well as inside verify-archive.py so the refusal happens
# before we spend time decrypting a multi-gigabyte file.
[ -s "$HMAC_KEY" ] || die "missing $HMAC_KEY.
Restore REFUSES to start rather than falling back to digest-only verification.
The digests live inside the manifest, so a forged manifest with matching
digests would pass every other check. Retrieve secrets/backup.hmac from
wherever you copied it off-host."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/payload"

echo "1/4  decrypting"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in "$ARCHIVE" -out "$WORK/payload.tar.gz" -pass "file:$ENC_KEY" \
  || die "decryption failed — wrong key, or the archive is corrupt"

echo "2/4  unpacking through the audited extractor"
python3 - "$WORK/payload.tar.gz" "$WORK/payload" <<'PY' || exit 1
import sys, os, tarfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.environ.get("AISTACK_ROOT", "."), "scripts"))
# Import the audit from the one place it is defined.
here = os.path.dirname(os.path.abspath(sys.argv[0])) if sys.argv[0] else "."
for cand in (here, os.path.join(here, "scripts"), "scripts"):
    p = os.path.join(cand, "verify_archive.py")
    if os.path.exists(p):
        sys.path.insert(0, cand)
        break
try:
    from verify_archive import audit_member, Refuse
except ImportError:
    # scripts/verify-archive.py has a hyphen; load it by path.
    import importlib.util
    root = os.environ.get("AISTACK_ROOT") or os.getcwd()
    spec = importlib.util.spec_from_file_location(
        "verify_archive", os.path.join(root, "scripts", "verify-archive.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    audit_member, Refuse = mod.audit_member, mod.Refuse

src, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)
with tarfile.open(src, "r:gz") as tf:
    for m in tf:
        # RE-CHECKED AS WE WRITE, not in a pre-pass.  A pre-pass over an
        # archive somebody else can still write is a TOCTOU window.
        try:
            audit_member(m, dest)
        except Refuse as e:
            print("REFUSED: %s" % e, file=sys.stderr)
            sys.exit(1)
        tf.extract(m, dest, filter="data")
print("    unpacked")
PY

echo "3/4  verifying (set equality, digests, HMAC) — BEFORE anything is overwritten"
AISTACK_ROOT="$ROOT" python3 "$ROOT/scripts/verify-archive.py" \
  --payload-dir "$WORK/payload" --hmac-key "$HMAC_KEY" || die "archive refused; nothing was changed"

# --- WHAT THIS ARCHIVE CAN AND CANNOT RETURN (NOM-378) ----------------------
#
# Printed BEFORE the confirmation prompt below, because this is exactly the
# thing an operator needs in front of them while deciding to overwrite live
# data, and after verification, because an unverified manifest is not a
# statement about anything.
#
# It is read from the ARCHIVE, never from this checkout: the archive is the
# authoritative statement of what there was to restore, and a four-app
# checkout must be able to restore a five-app archive.  scripts/backup.sh
# records the set; scripts/verify-archive.py owns the one function that reads
# it, so this script and `aistack verify` cannot drift in what they say.
DBSTATE="$WORK/dbstate.sh"
AISTACK_ROOT="$ROOT" python3 - "$WORK/payload/MANIFEST.json" "$DBSTATE" <<'PY' || die "could not read the archive's database set; nothing was changed"
import importlib.util, json, os, shlex, sys

root = os.environ.get("AISTACK_ROOT") or os.getcwd()
spec = importlib.util.spec_from_file_location(
    "verify_archive", os.path.join(root, "scripts", "verify-archive.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

manifest = json.load(open(sys.argv[1]))
st = mod.database_statement(manifest)

apps = [e["name"] for e in st["returns"] if e.get("kind") == "app"]
others = [e["name"] for e in st["returns"] if e.get("kind") != "app"]

print("    databases this archive RETURNS:")
for e in st["returns"]:
    print("      %-14s (%s)" % (e["name"], e.get("kind", "app")))
if st["does_not_return"]:
    print("    databases it does NOT return, by design:")
    for e in st["does_not_return"]:
        print("      %-14s %s" % (e["name"], e["reason"]))
    print("    Anything stored directly in those is not in this archive and")
    print("    will be whatever initdb created, not what you had.")
elif not st["recorded"]:
    print("    this archive does NOT state what it left out:")
    print("      %s" % st["note"])
    print("    Treat the list above as the complete contents and nothing more;")
    print("    in particular a pre-NOM-378 archive carries no `aistack` dump.")

with open(sys.argv[2], "w") as fh:
    fh.write("RESTORE_APP_DBS=%s\n" % shlex.quote(" ".join(apps)))
    fh.write("RESTORE_OTHER_DBS=%s\n" % shlex.quote(" ".join(others)))
    fh.write("RESTORE_DB_RECORDED=%s\n" % ("1" if st["recorded"] else "0"))
PY
# shellcheck source=/dev/null
. "$DBSTATE"

# THE READ-ONLY EXIT (NOM-378).  Everything above this line reads; step 4
# below is the first thing that writes.  Exiting here is non-destructive BY
# CONSTRUCTION rather than by promise -- there is no branch to get wrong,
# because the code that overwrites has not been reached yet.
if verify_only_requested "$VERIFY_ONLY_FLAG"; then
  echo "verify-only: the archive verified and stated its database set above."
  echo "             Nothing was restored and nothing was changed."
  exit 0
fi

echo "4/4  restoring"

if [ -n "$DRILL_PROJECT" ]; then
  echo "    into throwaway project '$DRILL_PROJECT' — live volumes are not touched"
  PROJECT="$DRILL_PROJECT"
  VOL_PREFIX="$DRILL_PROJECT"
  # MUST use compose.drill.yaml, not compose.yaml.
  #
  # compose.yaml pins `container_name:` and an explicit volume `name:`, and
  # BOTH IGNORE THE PROJECT NAME. Restoring with it under a drill project
  # therefore attaches to the LIVE volumes — we watched a drill restore a
  # backup over the live database, with only a scrollable Docker warning to
  # say so. compose.drill.yaml names nothing explicitly, so Compose prefixes
  # every volume and container with the project.
  COMPOSE_FILE_ARGS=(-f compose.drill.yaml)
else
  if [ "$ASSUME_YES" -ne 1 ]; then
    cat <<EOF

    THIS OVERWRITES LIVE DATA in the running stack.

    If an image migration has run since this backup was taken, restoring is
    the ONLY reverse path — and a major-version rollback means restoring a
    backup, in those words.

    Type RESTORE to continue:
EOF
    read -r reply
    [ "$reply" = "RESTORE" ] || die "aborted; nothing was changed"
  fi
  PROJECT="aistack"
  VOL_PREFIX="aistack"
  COMPOSE_FILE_ARGS=(-f compose.yaml)
fi

dc() { ( cd "$ROOT" && docker compose -p "$PROJECT" "${COMPOSE_FILE_ARGS[@]}" "$@" ); }

# Databases first: the volume tars below include application state that
# references rows in these dumps.
echo "    databases"
dc up -d postgres
for _ in $(seq 1 60); do
  dc exec -T postgres pg_isready -U aistack_admin >/dev/null 2>&1 && break
  sleep 2
done
dc exec -T postgres psql -U aistack_admin -d postgres < "$WORK/payload/globals.sql" >/dev/null 2>&1 || true
# WHICH databases, read from the ARCHIVE — not from a literal list and not
# from the host's secrets.  The payload is the authoritative statement of what
# there is to restore: a four-app checkout must be able to restore a five-app
# archive rather than silently dropping the fifth, and step 3/4 above has
# already verified this payload for set equality, digests and HMAC before
# anything here overwrites a byte.
#
# WHAT THIS RESTORE PUT BACK, written out for the caller that asks.
# scripts/drill.sh asserts one non-superuser role per restored database, and it
# has to assert over THE SAME SET this loop walks.  Re-deriving that set there
# from a literal `IN (...)` list is how a hardcoded `R = 4` certified a
# five-app archive whose fifth role never came back: the fifth app could
# neither be counted present nor counted missing.  Unset in normal operation,
# in which case nothing is written and nothing changes.
#
# IT IS THE APP DATABASES, NOT EVERY RESTORED DATABASE (NOM-378).  The set this
# loop walks now includes `aistack`, which is the POSTGRES_DB and is owned by
# the superuser -- there is no non-superuser `aistack` role and there should
# not be one.  Writing it here would make the drill look for a role that
# correctly does not exist and fail a good restore.
#
# The split still comes from the ARCHIVE (the manifest's recorded kinds), not
# from a list retyped here and not from this checkout's secrets, so the
# property NOM-307 bought is intact: a fifth app in the archive gets its role
# asserted without anyone editing the drill.  A pre-NOM-378 archive records no
# kinds, and every dump in one is an app database, so RESTORE_DB_RECORDED=0
# falls back to exactly the old behaviour.
RESTORED_DBS_FILE="${AISTACK_RESTORED_DBS_FILE:-}"
if [ -n "$RESTORED_DBS_FILE" ]; then
  : > "$RESTORED_DBS_FILE" \
    || die "cannot write AISTACK_RESTORED_DBS_FILE=$RESTORED_DBS_FILE"
fi

# ...AND THE KIND OF EVERY DATABASE THE LOOP WALKS, which is the half the drill
# did not get (NOM-392).  The file above is app databases only, for a good
# reason -- the drill asserts a non-superuser ROLE per entry and a cluster-kind
# database has none -- but "drop it" and "say nothing about it" were the same
# line of code, so `aistack` could restore EMPTY and the drill still passed.
#
# Two facts per line, `<kind> <name>`, because the drill needs both: which
# databases to assert presence-and-contents for, and whether this archive
# states kinds AT ALL.  Without the second, an empty cluster-kind set is
# ambiguous -- a pre-NOM-378 archive legitimately has none, and so does a
# recording that quietly broke.  `legacy` names the first case, so the drill
# can take the one as a note and the other as a failure instead of treating
# both as nothing to do.  Unset in normal operation, in which case nothing is
# written and nothing changes.
RESTORED_DB_KINDS_FILE="${AISTACK_RESTORED_DB_KINDS_FILE:-}"
if [ -n "$RESTORED_DB_KINDS_FILE" ]; then
  : > "$RESTORED_DB_KINDS_FILE" \
    || die "cannot write AISTACK_RESTORED_DB_KINDS_FILE=$RESTORED_DB_KINDS_FILE"
fi

# FUNCTIONS, not ifs inside the restore loop, for one reason: the loop body
# also runs pg_restore against a live cluster, so the only way to test these
# decisions inline would be to perform a restore.  Out here,
# tests/backup-db-set.sh extracts these lines and runs THEM -- the drill's
# expectation and the CREATE DATABASE owner are both derived from the first
# decision, and a decision nothing can test without downtime is one that gets
# verified by hoping.
#
# >>> restored-db classification: tests/backup-db-set.sh extracts and runs these lines >>>
# IS THIS AN APP DATABASE -- one with its own non-superuser role of the same
# name?  Read from the ARCHIVE's recorded kinds, never from this checkout.  Two
# callers depend on it and they must not disagree: what the drill is told to
# expect a role for, and whose name goes in CREATE DATABASE ... OWNER.
#
# A pre-NOM-378 archive records no kinds, and every dump in one is an app
# database, so the fallback is exactly the old behaviour.
is_app_db() {
  local db="$1" a
  if [ "${RESTORE_DB_RECORDED:-0}" != "1" ]; then
    return 0   # legacy archive: every dump in one is an app database
  fi
  for a in ${RESTORE_APP_DBS:-}; do
    if [ "$a" = "$db" ]; then return 0; fi
  done
  return 1
}

# WHAT KIND OF DATABASE THIS IS, as a recorded fact rather than as an absence.
#
# `app` and `cluster` are the two kinds a current archive records.  `legacy` is
# the third state and it is NOT a kind the manifest carries: it means the
# archive states no kinds, so is_app_db() is answering from its fallback and
# calling every dump an app.  A reader that only saw `app` lines could not tell
# that case from a current archive whose cluster-kind recording stopped
# working, and those two must not look alike -- one is a note, the other is the
# defect this function exists to stop.
#
# The `!= 1` test is the same condition is_app_db() falls back on, written out
# here because the ANSWER is different: is_app_db() has to say "app" for a
# legacy archive (that is the old behaviour, and the OWNER clause depends on
# it), while this has to say "we were never told".  tests/backup-db-set.sh runs
# both against the same inputs so the two cannot drift apart unnoticed.
restored_db_kind() {
  local db="$1"
  if [ "${RESTORE_DB_RECORDED:-0}" != "1" ]; then printf 'legacy\n'; return 0; fi
  if is_app_db "$db"; then printf 'app\n'; else printf 'cluster\n'; fi
}

record_restored_db() {
  local db="$1"
  if [ -n "${RESTORED_DB_KINDS_FILE:-}" ]; then
    printf '%s %s\n' "$(restored_db_kind "$db")" "$db" >> "$RESTORED_DB_KINDS_FILE"
  fi
  [ -n "${RESTORED_DBS_FILE:-}" ] || return 0
  is_app_db "$db" || return 0
  printf '%s\n' "$db" >> "$RESTORED_DBS_FILE"
}

# THE OWNER COMES FROM THE KIND, NOT FROM THE DATABASE NAME.
#
# This used to be `CREATE DATABASE %I OWNER %I` with :'db' for both, which
# holds only where role and database share a name.  That is true of the four
# app databases and false of the kind NOM-378 widened the set to include:
# `aistack` is owned by aistack_admin, and a non-superuser `aistack` role
# deliberately does not exist.
#
# On the live stack and in the drill project it was masked -- POSTGRES_DB
# creates `aistack`, so WHERE NOT EXISTS short-circuits.  The reachable case is
# the one the widening was written for: an operator creates `metrics`, owned by
# the superuser, it is now dumped, and a restore into a FRESH cluster ran
# `CREATE DATABASE metrics OWNER metrics` -> role does not exist -> swallowed,
# then pg_restore reported "warnings" because the database was not there.  A
# restore onto a fresh host is the disaster-recovery path; it is the last place
# that should degrade a missing database to a warning.
#
# For a cluster-kind database the OWNER clause is omitted, which makes the
# owner the connecting superuser -- aistack_admin, which is what the live
# cluster has.  The identifier is still quoted by format() from a psql
# variable, never spliced by this shell.
create_database_sql() {
  local db="$1"
  if is_app_db "$db"; then
    printf "SELECT format('%s', :'db', :'db')\n" 'CREATE DATABASE %I OWNER %I'
  else
    printf "SELECT format('%s', :'db')\n" 'CREATE DATABASE %I'
  fi
  printf '%s\n' "WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db')" '\gexec'
}

db_exists() {
  # Over stdin, not -c: psql does not expand :'var' in a -c string -- the same
  # query through -c fails with `syntax error at or near ":"`, measured.
  #
  # Any answer that is not "yes" counts as absent, including one we could not
  # obtain: under `set -o pipefail` a psql that cannot connect fails the
  # pipeline and this returns 1.  Refusing on an unanswerable question is the
  # safe direction, since the alternative is loading a dump into nothing.
  dc exec -T postgres psql -tAq -U aistack_admin -d postgres -v db="$1" 2>/dev/null <<'SQL' | grep -qx 1
SELECT 1 FROM pg_database WHERE datname = :'db'
SQL
}

# A DUMP THAT CANNOT BE LOADED AT ALL IS NOT A WARNING.  If the create above
# failed for any reason, pg_restore's own failure is reduced to a one-line
# "(pg_restore reported warnings)" and a database that IS in the archive does
# not come back -- this ticket's defect, moved into the restore path.  Refusing
# here stops with the reason named while the operator is still watching.
require_database_present() {
  local db="$1"
  if db_exists "$db"; then return 0; fi
  die "'$db' is in this archive but does not exist after the create attempt, so
$db.dump cannot be loaded.  Databases restored before this one are already in
place; nothing after it has been touched.  Check the cluster for a missing
owner role, then re-run the restore -- it is idempotent."
}
# <<< restored-db classification <<<
for dump in "$WORK"/payload/*.dump; do
  [ -f "$dump" ] || continue
  db="$(basename "$dump" .dump)"
  echo "      $db"
  # Recorded BEFORE the restore of this database is attempted, so a dump that
  # fails to load is still a database the drill expects a role for.  An
  # expectation that shrinks when the thing it measures fails is not one.
  record_restored_db "$db"
  # CREATE THE DATABASE IF IT IS NOT THERE.
  #
  # `pg_restore -d n8n` needs `n8n` to already exist, and into a LIVE stack it
  # always does — the init script made it. Into a FRESH drill project it does
  # not, so every per-app restore silently did nothing and the drill asserted
  # against four empty databases. The roles came back (pg_dumpall globals
  # creates those) which made the failure look like a dump problem rather than
  # a missing database.
  #
  # Guarded by `WHERE NOT EXISTS` rather than `IF NOT EXISTS`, which CREATE
  # DATABASE does not support, and run through \gexec so the identifier is
  # quoted by format() rather than interpolated by the shell.  Whose database
  # it is comes from the archive's recorded kind — see create_database_sql().
  create_database_sql "$db" \
    | dc exec -T postgres psql -v ON_ERROR_STOP=1 -U aistack_admin -d postgres \
        -v db="$db" >/dev/null 2>&1 || true
  # ... and the create either worked or this restore stops. `|| true` above is
  # still right — the database usually already exists — but "it is not there
  # afterwards" is a refusal, not a warning.
  require_database_present "$db"
  dc exec -T postgres pg_restore --clean --if-exists -U aistack_admin -d "$db" \
    < "$WORK/payload/$db.dump" >/dev/null 2>&1 || echo "      (pg_restore reported warnings for $db)"
done

echo "    volumes"
for vol in n8n-data openwebui-data caddy-data authelia-data; do
  src="$WORK/payload/aistack-${vol}.tar.gz"
  [ -f "$src" ] || continue
  # Compose names a project volume `<project>_<key>` with an UNDERSCORE.
  # Getting this wrong creates a correctly-named orphan that nothing mounts,
  # and the drill then asserts against an empty database and passes nothing.
  if [ -n "$DRILL_PROJECT" ]; then
    target="${VOL_PREFIX}_${vol}"
  else
    target="${VOL_PREFIX}-${vol}"
  fi
  docker volume create "$target" >/dev/null
  echo "      $target"
  # STREAMED IN, mirroring the backup side: the host reads the file and the
  # container only writes into the volume it is restoring. DAC_OVERRIDE is
  # needed here and not on the backup side, because restoring genuinely has
  # to write files owned by other uids into a directory it does not own.
  docker run --rm -i -v "$target:/dst" \
    --read-only --cap-drop ALL --cap-add DAC_OVERRIDE --cap-add CHOWN \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    docker.io/library/busybox:stable \
    sh -c "rm -rf /dst/* /dst/.[!.]* 2>/dev/null; tar xzf - -C /dst" \
    < "$WORK/payload/aistack-${vol}.tar.gz"
done

echo ""
echo "Restore complete into project '$PROJECT'."
if [ -z "$DRILL_PROJECT" ]; then
  echo "Bring the stack up with:  aistack up"
fi
