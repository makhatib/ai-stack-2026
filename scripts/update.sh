#!/usr/bin/env bash
# AI Stack 2026 — update.  Ordered, stops on the first failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; cd "$ROOT"

echo "[1/7] validating configuration"
docker compose config -q

echo "[2/7] collation preflight — would the committed pin change it?"
# Runs BEFORE anything is rendered, pulled or recreated, and against the pin
# in the COMMITTED versions.env rather than the currently rendered one, so a
# refusal leaves the host exactly as it was.  The condition it enforces has
# been written in the POSTGRES block of versions.env since NOM-341 -- "do not
# move an existing cluster onto this pin without that plan" -- and until
# NOM-354 nothing enforced it, so a plain `aistack update` would have done it.
PG_TARGET="$(set -a; . ./versions.env; set +a; printf '%s:%s@%s' \
  "${POSTGRES_IMAGE:?}" "${POSTGRES_TAG:?}" "${POSTGRES_DIGEST:?}")"
bash scripts/preflight-collation.sh --image "$PG_TARGET" || {
  echo "UPDATE ABORTED: nothing was changed. Follow the procedure above." >&2; exit 1; }

echo "[3/7] backup first — the update ABORTS if this fails"
# Not a courtesy. Steps 4-6 can run a schema migration, and the pre-update
# dump is the only reverse path once one has.
bash scripts/backup.sh || { echo "UPDATE ABORTED: the backup failed, so there would be no way back." >&2; exit 1; }

echo "[4/7] recording the current pins"
cp versions.env versions.prev.env

echo "[5/7] pulling by digest"
bin/aistack pin
docker compose pull --quiet

echo "[6/7] starting"
echo "[7/7] bounded health gate"
bin/aistack up
