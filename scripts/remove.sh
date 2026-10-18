#!/usr/bin/env bash
# AI Stack 2026 — remove.
#
# Containers and DATA are separate decisions and this script will not make the
# second one for you.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; cd "$ROOT"
KEEP_DATA=1; ASSUME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --delete-data) KEEP_DATA=0; shift ;;
    --yes) ASSUME=yes; shift ;;
    *) echo "remove: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

echo "Stopping and removing containers and networks..."
docker compose down --remove-orphans

if [ "$KEEP_DATA" -eq 1 ]; then
  cat <<'EOF'

Containers and networks are gone. YOUR DATA IS STILL HERE:

  docker volumes   aistack-postgres-data, aistack-n8n-data,
                   aistack-openwebui-data, aistack-authelia-data,
                   aistack-caddy-data, and the model volumes
  on disk          ./secrets, ./.env, ./backups

To remove the data as well, re-run with --delete-data.
Take a backup first if there is any chance you want it:  bin/aistack backup
EOF
  exit 0
fi

echo ""
echo "THIS DELETES EVERY VOLUME AND THE SECRETS DIRECTORY."
echo "Chats, workflows, documents, embeddings, credentials, and the keys that"
echo "would let you read an existing backup. There is no undo."
if [ "$ASSUME" != yes ]; then
  read -r -p 'Type DELETE to continue: ' reply
  [ "$reply" = DELETE ] || { echo "Aborted; nothing was removed."; exit 1; }
fi

for v in aistack-postgres-data aistack-n8n-data aistack-openwebui-data \
         aistack-authelia-data aistack-caddy-data aistack-caddy-config \
         aistack-ollama-models aistack-docling-models; do
  docker volume rm "$v" >/dev/null 2>&1 && echo "  removed volume $v" || true
done
rm -rf secrets .runtime .env
echo ""
echo "Removed. ./backups was left alone — delete it yourself if you mean to."
