#!/usr/bin/env bash
# AI Stack 2026 — backup (final-design §7.4).
#
# Named "LOCAL ROLLBACK BACKUP", not "disaster recovery".  A same-host backup
# is a rollback aid.  No DR claim is permitted without a restore from an
# off-host copy, which is B3 and is 1.0.
#
# IN THE SET:  pg_dump --format=custom per database, pg_dumpall --globals-only,
#              secrets/ (including N8N_ENCRYPTION_KEY), .env + versions.env +
#              config/, and tars of n8n-data, openwebui-data, caddy-data,
#              authelia-data.
# EXCLUDED BY DESIGN, AND SAID OUT LOUD: every model volume.  They are
#              re-downloadable and are over 90% of the bytes.
#
# The integrity design, and why each piece is there:
#   * MANIFEST.json lists EVERY member with its path and SHA-256.
#   * The HMAC covers the CANONICALISED manifest INCLUDING that inventory, so
#     neither a member nor the LIST of members can change undetected.
#   * The HMAC key is a SEPARATE FILE from the encryption key, so possession of
#     the archive never confers the ability to forge its manifest.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
DEST="${AISTACK_BACKUP_DIR:-$ROOT/backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ENC_KEY="$ROOT/secrets/backup.key"
HMAC_KEY="$ROOT/secrets/backup.hmac"
OFFSITE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --offsite) OFFSITE="${2:?--offsite needs a destination}"; shift 2 ;;
    *) echo "backup: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

die() { printf 'backup: %s\n' "$*" >&2; exit 1; }

[ -s "$ENC_KEY" ]  || die "missing $ENC_KEY — run scripts/gen-secrets.sh"
[ -s "$HMAC_KEY" ] || die "missing $HMAC_KEY — run scripts/gen-secrets.sh"

# --- can we actually read everything we are about to promise? -------------
# Checked UP FRONT, because the alternative is what we measured: the backup
# dumps four databases and four volumes, then dies on `tar: Cannot open:
# Permission denied` and leaves a partial archive with a confident name.
#
# secrets/ and config/authelia/users.yml are deliberately root-owned so the
# services can read them and nothing else can, which means BACKUP IS A
# PRIVILEGED OPERATION. That is a real constraint, not an oversight, and it
# belongs in the first ten lines rather than the last.
UNREADABLE=()
while IFS= read -r f; do
  [ -r "$f" ] || UNREADABLE+=("$f")
done < <(find "$ROOT/secrets" "$ROOT/config" -type f 2>/dev/null)
if [ "${#UNREADABLE[@]}" -gt 0 ]; then
  cat >&2 <<EOF

backup: cannot read ${#UNREADABLE[@]} file(s) that belong in the archive, including:
  ${UNREADABLE[0]}

These are root-owned on purpose: it is what lets each service read its own
secret and nothing else read it. Taking a complete backup therefore needs
privilege. Run:

    sudo bin/aistack backup

Refusing to write a partial archive under a name that claims to be complete.
EOF
  exit 1
fi

mkdir -p "$DEST" "$WORK/payload"
STAGE="$WORK/payload"

dc() { ( cd "$ROOT" && docker compose "$@" ); }

echo "Backing up to $DEST/aistack-$STAMP.tar.gz.enc"

# --- postgres ---------------------------------------------------------------
echo "  pg_dumpall --globals-only"
dc exec -T postgres pg_dumpall --globals-only -U aistack_admin > "$STAGE/globals.sql"
# WHICH databases, DERIVED — not another literal copy of the app list.  A
# hardcoded list fails here in the worst available direction: an app added to
# gen-secrets.sh but not to this line is an app whose database is simply
# absent from an archive that reports success, and nothing says so until a
# restore comes up short.  The preflight above has already asserted every file
# under secrets/ is readable, so this read cannot be the thing that fails.
APP_DBS="$(sed -n 's/^\([A-Za-z0-9_][A-Za-z0-9_]*\)=.*/\1/p' "$ROOT/secrets/app_db_passwords" | sort -u)"
[ -n "$APP_DBS" ] || die "secrets/app_db_passwords names no databases; run scripts/gen-secrets.sh"
for db in $APP_DBS; do
  echo "  pg_dump $db"
  dc exec -T postgres pg_dump --format=custom -U aistack_admin -d "$db" > "$STAGE/$db.dump"
done

# --- volumes ----------------------------------------------------------------
# Model volumes are NOT here.  That is deliberate and is in the docs.
for vol in aistack-n8n-data aistack-openwebui-data aistack-caddy-data aistack-authelia-data; do
  echo "  tar $vol"
  # STREAMED TO STDOUT, and the HOST writes the file.
  #
  # The obvious form — bind the staging directory in and let the container
  # write there — fails with "tar: can't open '/out/...': Permission denied",
  # because the helper drops ALL capabilities and therefore has no
  # DAC_OVERRIDE, so even as uid 0 it cannot write into a 0700 directory owned
  # by the operator. Loosening the staging directory to 0777 would put
  # database dumps in a world-writable path on a shared host, and granting
  # DAC_OVERRIDE would hand a broad write bypass to a container that only
  # needs to read.
  #
  # Streaming avoids the question: the container writes to a pipe, the shell
  # writes the file as the user who already owns the directory.
  # DAC_READ_SEARCH is still needed to READ volume contents owned by other
  # uids, and it is the narrow one — read and directory-search only, no write
  # bypass. Same reasoning as E7 on Postgres.
  docker run --rm -i -v "$vol:/src:ro" \
    --read-only --cap-drop ALL --cap-add DAC_READ_SEARCH \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    docker.io/library/busybox:stable \
    tar czf - -C /src . > "$STAGE/${vol}.tar.gz" 2>/dev/null
done

# --- config and secrets -----------------------------------------------------
echo "  config, .env, versions.env, secrets/"
tar czf "$STAGE/config.tar.gz" -C "$ROOT" config
cp "$ROOT/.env" "$STAGE/env" 2>/dev/null || true
cp "$ROOT/versions.env" "$STAGE/versions.env"
# secrets/ INCLUDING N8N_ENCRYPTION_KEY: without it every stored n8n credential
# in the dump above is undecryptable, and a backup that restores a workflow
# list but no credentials is not a backup.
tar czf "$STAGE/secrets.tar.gz" -C "$ROOT" secrets

# --- the member digest inventory -------------------------------------------
echo "  building MANIFEST.json"
python3 - "$STAGE" "$STAMP" <<'PY'
import hashlib, json, os, sys
stage, stamp = sys.argv[1], sys.argv[2]
members = []
for name in sorted(os.listdir(stage)):
    p = os.path.join(stage, name)
    if not os.path.isfile(p):
        continue
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    members.append({"path": name, "sha256": h.hexdigest(), "bytes": os.path.getsize(p)})
manifest = {
    "schema": "aistack.backup.v1",
    "created_at": stamp,
    "kind": "local rollback backup",
    "excluded_by_design": [
        "aistack-ollama-models", "aistack-docling-models",
        "aistack-whisper-models", "aistack-kokoro-models", "aistack-comfyui-data",
    ],
    "excluded_reason": "model weights are re-downloadable and are >90% of the bytes",
    "members": members,
}
# Canonicalised: sorted keys, no insignificant whitespace.  The HMAC is taken
# over exactly these bytes, so the verifier can recompute them.
with open(os.path.join(stage, "MANIFEST.json"), "w") as fh:
    fh.write(json.dumps(manifest, sort_keys=True, separators=(",", ":")))
print("    %d members" % len(members))
PY

# HMAC over the canonicalised manifest INCLUDING the inventory.
openssl dgst -sha256 -hmac "$(cat "$HMAC_KEY")" -hex "$STAGE/MANIFEST.json" \
  | awk '{print $NF}' > "$STAGE/MANIFEST.hmac"

# --- pack and encrypt -------------------------------------------------------
ARCHIVE="$DEST/aistack-$STAMP.tar.gz.enc"
tar czf "$WORK/payload.tar.gz" -C "$STAGE" .
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
  -in "$WORK/payload.tar.gz" -out "$ARCHIVE" -pass "file:$ENC_KEY"
chmod 0600 "$ARCHIVE"

echo "  wrote $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

if [ -n "$OFFSITE" ]; then
  echo "  copying to $OFFSITE"
  cp "$ARCHIVE" "$OFFSITE/" || die "offsite copy failed"
  echo "  NOTE: an off-site COPY is not a tested restore.  Until B3 runs —"
  echo "        a restore FROM that copy, on a separate host — this remains a"
  echo "        rollback aid and must not be described as disaster recovery."
fi

# Warn at EVERY run until the operator confirms both key files are held
# off-host.  Not once, every run: an un-exported key is a backup that cannot
# be read, and the day you find that out is the day you needed it.
if [ ! -f "$ROOT/.backup-keys-confirmed" ]; then
  cat <<EOF

  ---------------------------------------------------------------------------
  TWO KEY FILES MUST BE HELD OFF-HOST, AS FILES:
    secrets/backup.key    without it this archive cannot be decrypted
    secrets/backup.hmac   without it a restore REFUSES TO START

  They are separate on purpose: whoever holds the archive must not thereby be
  able to forge its manifest.  Copy them through your own channel.  Their
  contents are not printed here and must not be pasted anywhere.

  When both are safely off-host:  touch $ROOT/.backup-keys-confirmed
  ---------------------------------------------------------------------------
EOF
fi
