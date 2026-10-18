#!/usr/bin/env bash
# AI Stack 2026 — rollback to the previous pins.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; cd "$ROOT"
[ -f versions.prev.env ] || { echo "rollback: no versions.prev.env — nothing to roll back to." >&2; exit 1; }
cat <<'EOF'
Rolling back to the previous pins.

IF A SCHEMA MIGRATION RAN during the update you are undoing, this is NOT
enough on its own and can leave a database the older code cannot read.
n8n, Authelia and Open WebUI all migrate. In that case:

    bin/aistack restore <backup-taken-before-the-update>
    bin/aistack rollback

A major-version rollback means restoring a backup.
EOF
cp versions.env versions.failed.env
cp versions.prev.env versions.env
bin/aistack pin
docker compose pull --quiet
bin/aistack up
