#!/usr/bin/env bash
# Remove the security-proof fixture.  Only touches nom-417-* names this fixture created.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in nom-417-litellm nom-417-backend nom-417-caddy nom-417-edge nom-417-n8n nom-417-llm nom-417-db; do
  docker rm -f "$c" >/dev/null 2>&1 || true
done
docker network rm nom-417-net >/dev/null 2>&1 || true
rm -rf "$HERE/.state"
echo "fixture removed"
