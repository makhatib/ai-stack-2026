#!/usr/bin/env bash
# Start the security-proof FIXTURE on this machine (the dev sandbox).  Everything
# is named nom-417-*, binds 127.0.0.1 only, and `down.sh` removes it all.
#
#   nom-417-db       Postgres (pinned, from versions.env)   holds w4_results
#   nom-417-llm      stub model server                      counts model calls
#   nom-417-n8n      pinned n8n, SHIPPED W4 workflow, published
#   nom-417-caddy    pinned Caddy, SHIPPED sites-vps.d/30-n8n.caddy
#   nom-417-backend  synthetic MCP backend (web_search, fetch_page, delete_everything)
#   nom-417-litellm  pinned LiteLLM, the SHIPPED `web` allowlist block
#
# Synthetic data only.  Secrets are generated per run into .state/ (0600), never printed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
STATE="$HERE/.state"
# shellcheck disable=SC1091
source "$ROOT/versions.env"
img() { local n="$1"; eval "printf '%s:%s@%s' \"\$${n}_IMAGE\" \"\$${n}_TAG\" \"\$${n}_DIGEST\""; }
NET=nom-417-net
DOMAIN=fixture.test


"$HERE/down.sh" >/dev/null 2>&1 || true
umask 077
mkdir -p "$STATE/mcp" "$STATE/llm" "$STATE/litellm"
chmod 777 "$STATE/mcp" "$STATE/llm"
openssl rand -hex 24 > "$STATE/w4_token"
openssl rand -hex 16 > "$STATE/db_pw"
openssl rand -hex 24 > "$STATE/master_key"
openssl rand -hex 16 > "$STATE/n8n_enc"
echo v1 > "$STATE/mcp/version"; : > "$STATE/mcp/requests.log"; : > "$STATE/llm/llm-calls.log"
chmod 666 "$STATE/mcp/"* "$STATE/llm/"*

docker network create "$NET" >/dev/null

# --- webhook half -----------------------------------------------------------
docker run -d --name nom-417-db --network "$NET" \
  -e POSTGRES_PASSWORD="$(cat "$STATE/db_pw")" -e POSTGRES_USER=proof -e POSTGRES_DB=proof \
  "$(img POSTGRES)" >/dev/null
docker run -d --name nom-417-llm --network "$NET" --network-alias litellm \
  -v "$HERE/stub_llm.py:/stub_llm.py:ro" -v "$STATE/llm:/state" \
  docker.io/library/python:3.12-alpine python /stub_llm.py >/dev/null
# initdb starts a throwaway server first and restarts it: "ready" appears twice.
for _ in $(seq 1 90); do
  [ "$(docker logs nom-417-db 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ] && break; sleep 1
done
docker exec -i nom-417-db psql -q -U proof -d proof < "$ROOT/samples/fixtures/schema.sql" >/dev/null 2>&1 || {
  # schema.sql wants the full stack's roles/extensions; W4 needs only its table.
  docker exec -i nom-417-db psql -q -U proof -d proof -c \
    "CREATE TABLE IF NOT EXISTS w4_results (result_id bigserial PRIMARY KEY, prompt text NOT NULL, answer text NOT NULL, created_at timestamptz NOT NULL DEFAULT now());" >/dev/null; }

docker run -d --name nom-417-n8n --network "$NET" --network-alias n8n --entrypoint sh \
  -e N8N_ENCRYPTION_KEY="$(cat "$STATE/n8n_enc")" \
  -e PROOF_DB_PW="$(cat "$STATE/db_pw")" -e PROOF_W4_TOKEN="$(cat "$STATE/w4_token")" \
  -e N8N_HOST="n8n.$DOMAIN" -e N8N_PROTOCOL=https -e WEBHOOK_URL="https://n8n.$DOMAIN/" -e N8N_PROXY_HOPS=1 \
  -e N8N_DIAGNOSTICS_ENABLED=false -e N8N_VERSION_NOTIFICATIONS_ENABLED=false -e N8N_TEMPLATES_ENABLED=false \
  -e N8N_BLOCK_ENV_ACCESS_IN_NODE=true -e N8N_SECURE_COOKIE=true -e N8N_RUNNERS_ENABLED=true \
  -v "$HERE/n8n-seed.sh:/seed.sh:ro" -v "${PROOF_W4_JSON:-$ROOT/workflows/W4-webhook-to-model.json}:/shipped/W4-webhook-to-model.json:ro" \
  "$(img N8N)" /seed.sh >/dev/null

# The "edge" is what a scanner on the internet would reach on a VPS: sshd (key-only,
# as the installer configures it) and Caddy share one network namespace, so the
# only listeners on that address are 22, 80 and 443.  The fixture's other
# services (n8n, Postgres, LiteLLM, the backend) are NOT in this namespace.
docker build -q -t nom-417-edge-img -f "$HERE/Dockerfile.edge" "$HERE" >/dev/null
docker run -d --name nom-417-edge --network "$NET" -p 127.0.0.1:18443:443 nom-417-edge-img \
  sh -c 'ssh-keygen -A >/dev/null && mkdir -p /run/sshd && exec /usr/sbin/sshd -D -e -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o PermitRootLogin=prohibit-password' >/dev/null
docker run -d --name nom-417-caddy --network container:nom-417-edge \
  -e AISTACK_DOMAIN="$DOMAIN" \
  -v "$HERE/Caddyfile.fixture:/etc/caddy/Caddyfile:ro" \
  -v "$ROOT/config/caddy/sites-vps.d/30-n8n.caddy:/shipped/30-n8n.caddy:ro" \
  "$(img CADDY)" >/dev/null
docker inspect nom-417-edge --format '{{(index .NetworkSettings.Networks "nom-417-net").IPAddress}}' > "$STATE/edge_ip"

# --- MCP half ---------------------------------------------------------------
docker run -d --name nom-417-backend --network "$NET" \
  -e MCP_PORT=8900 -v "$STATE/mcp:/state" \
  -v "$ROOT/gate/mcp_backend.py:/app/mcp_backend.py:ro" -v "$HERE/mcp_backend_proof.py:/app/mcp_backend_proof.py:ro" \
  -w /app docker.io/library/python:3.12-alpine python /app/mcp_backend_proof.py >/dev/null

# The allowlist under test is the SHIPPED `web:` block; only its url is repointed.
{
  printf 'model_list: []\ngeneral_settings:\n  master_key: os.environ/LITELLM_MASTER_KEY\n  database_url: os.environ/DATABASE_URL\n  enable_mcp: true\nmcp_servers:\n'
  awk '/^mcp_servers:/{f=1;next} f&&/^  web:/{w=1} f&&/^  n8n:/{w=0} f&&/^[^ ]/{f=0} w' "$ROOT/config/litellm/config.yaml" \
    | sed 's#^\(    url:\).*#\1 http://nom-417-backend:8900/mcp#'
} > "$STATE/litellm/config.yaml"
grep -q 'allowed_params' "$STATE/litellm/config.yaml" || { echo "could not extract the shipped web allowlist" >&2; exit 1; }
docker exec -i nom-417-db psql -q -U proof -d proof -c "CREATE DATABASE litellm;" >/dev/null
docker run -d --name nom-417-litellm --network "$NET" -p 127.0.0.1:18400:4000 \
  -e LITELLM_MASTER_KEY="$(cat "$STATE/master_key")" \
  -e DATABASE_URL="postgresql://proof:$(cat "$STATE/db_pw")@nom-417-db:5432/litellm" \
  -v "$STATE/litellm/config.yaml:/config/config.yaml:ro" \
  "$(img LITELLM)" --config /config/config.yaml --port 4000 >/dev/null

echo "waiting for n8n, Caddy and LiteLLM (first start takes a few minutes: DB migrations)..."
for _ in $(seq 1 300); do
  curl -sf -o /dev/null http://127.0.0.1:18400/health/liveliness && l=1 || l=0
  curl -sk -o /dev/null --resolve "n8n.$DOMAIN:18443:127.0.0.1" "https://n8n.$DOMAIN:18443/healthz" && n=1 || n=0
  [ "$l$n" = 11 ] && break; sleep 2
done
[ "$l$n" = 11 ] || { echo "fixture did not come up (litellm=$l n8n=$n)" >&2; exit 1; }
# n8n answers /healthz before it has registered the published webhook; wait for
# the webhook itself (a wrong token gets 403 once it is registered, 404 before).
for _ in $(seq 1 60); do
  c="$(curl -sk -o /dev/null -w '%{http_code}' --resolve "n8n.$DOMAIN:18443:127.0.0.1" -X POST \
      -H 'X-Aistack-Token: x' -H 'Content-Type: application/json' -d '{}' "https://n8n.$DOMAIN:18443/webhook/w4-demo")"
  [ "$c" != 404 ] && [ "$c" != 502 ] && break; sleep 2
done
[ "$c" = 403 ] || { echo "W4 webhook is not registered (got $c)" >&2; exit 1; }

# A virtual key that sees only the `web` server, like Hermes's.
curl -s -X POST http://127.0.0.1:18400/key/generate -H "Authorization: Bearer $(cat "$STATE/master_key")" \
  -H 'Content-Type: application/json' \
  -d '{"key_alias":"nom417-proof","object_permission":{"mcp_servers":["web"]}}' \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["key"])' > "$STATE/mcp_key"
echo "fixture up. state: $STATE (secrets, 0600)"
