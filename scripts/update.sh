#!/usr/bin/env bash
# AI Stack 2026 — update.  Ordered, stops on the first failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; cd "$ROOT"

echo "[1/6] validating configuration"
docker compose config -q

echo "[2/6] backup first — the update ABORTS if this fails"
# Not a courtesy. Steps 4-6 can run a schema migration, and the pre-update
# dump is the only reverse path once one has.
bash scripts/backup.sh || { echo "UPDATE ABORTED: the backup failed, so there would be no way back." >&2; exit 1; }

echo "[3/6] recording the current pins"
cp versions.env versions.prev.env

echo "[4/6] pulling by digest"
bin/aistack pin
docker compose pull --quiet

echo "[5/6] starting"
echo "[6/6] bounded health gate"
bin/aistack up
