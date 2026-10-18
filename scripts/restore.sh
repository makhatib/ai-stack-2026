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

while [ $# -gt 0 ]; do
  case "$1" in
    --into-drill-project) DRILL_PROJECT="${2:?needs a project name}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -*) echo "restore: unknown option '$1'" >&2; exit 2 ;;
    *) ARCHIVE="$1"; shift ;;
  esac
done

die() { printf 'restore: %s\n' "$*" >&2; exit 1; }

[ -n "$ARCHIVE" ] || die "usage: aistack restore <archive.tar.gz.enc> [--into-drill-project NAME]"
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

echo "4/4  restoring"

if [ -n "$DRILL_PROJECT" ]; then
  echo "    into throwaway project '$DRILL_PROJECT' — live volumes are not touched"
  PROJECT="$DRILL_PROJECT"
  VOL_PREFIX="$DRILL_PROJECT"
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
fi

dc() { ( cd "$ROOT" && docker compose -p "$PROJECT" "$@" ); }

# Databases first: the volume tars below include application state that
# references rows in these dumps.
echo "    databases"
dc up -d postgres
for _ in $(seq 1 60); do
  dc exec -T postgres pg_isready -U aistack_admin >/dev/null 2>&1 && break
  sleep 2
done
dc exec -T postgres psql -U aistack_admin -d postgres < "$WORK/payload/globals.sql" >/dev/null 2>&1 || true
for db in authelia openwebui litellm n8n; do
  [ -f "$WORK/payload/$db.dump" ] || continue
  echo "      $db"
  dc exec -T postgres pg_restore --clean --if-exists -U aistack_admin -d "$db" \
    < "$WORK/payload/$db.dump" >/dev/null 2>&1 || echo "      (pg_restore reported warnings for $db)"
done

echo "    volumes"
for vol in n8n-data openwebui-data caddy-data authelia-data; do
  src="$WORK/payload/aistack-${vol}.tar.gz"
  [ -f "$src" ] || continue
  target="${VOL_PREFIX}-${vol}"
  docker volume create "$target" >/dev/null
  echo "      $target"
  docker run --rm -v "$target:/dst" -v "$WORK/payload:/in:ro" \
    --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    docker.io/library/busybox:stable \
    sh -c "rm -rf /dst/* /dst/.[!.]* 2>/dev/null; tar xzf /in/aistack-${vol}.tar.gz -C /dst"
done

echo ""
echo "Restore complete into project '$PROJECT'."
if [ -z "$DRILL_PROJECT" ]; then
  echo "Bring the stack up with:  aistack up"
fi
