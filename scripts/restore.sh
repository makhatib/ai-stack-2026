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
VERIFY_ONLY=0

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
    --verify-only) VERIFY_ONLY=1; shift ;;
    -*) echo "restore: unknown option '$1'" >&2; exit 2 ;;
    *) ARCHIVE="$1"; shift ;;
  esac
done

die() { printf 'restore: %s\n' "$*" >&2; exit 1; }

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
if [ "$VERIFY_ONLY" -eq 1 ]; then
  echo "--verify-only: the archive verified and stated its database set above."
  echo "               Nothing was restored and nothing was changed."
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

# A FUNCTION, not three ifs inside the restore loop, for one reason: the loop
# body also runs pg_restore against a live cluster, so the only way to test the
# classification inline would be to perform a restore.  Out here,
# tests/backup-db-set.sh extracts these lines and runs THEM -- the drill's
# expectation is derived from this decision, and a decision nothing can test
# without downtime is one that gets verified by hoping.
#
# >>> restored-db classification: tests/backup-db-set.sh extracts and runs these lines >>>
record_restored_db() {
  local db="$1" a is_app=0
  [ -n "${RESTORED_DBS_FILE:-}" ] || return 0
  if [ "${RESTORE_DB_RECORDED:-0}" = "1" ]; then
    for a in ${RESTORE_APP_DBS:-}; do
      if [ "$a" = "$db" ]; then is_app=1; break; fi
    done
  else
    is_app=1   # legacy archive: every dump in one is an app database
  fi
  [ "$is_app" = "1" ] || return 0
  printf '%s\n' "$db" >> "$RESTORED_DBS_FILE"
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
  # quoted by format() rather than interpolated by the shell.
  dc exec -T postgres psql -v ON_ERROR_STOP=1 -U aistack_admin -d postgres \
    -v db="$db" >/dev/null 2>&1 <<'SQL' || true
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'db')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db')
\gexec
SQL
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
