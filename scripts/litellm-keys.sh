#!/usr/bin/env bash
# AI Stack 2026 — register the per-app LiteLLM virtual keys (NOM-413).
#
# gen-secrets.sh CHOOSES each app's key (secrets/key_<app>); LiteLLM only learns
# it here.  One key per app, each with its own model list, MCP server list,
# request rate and spend cap.  Re-running updates the keys in place.
#
# THE SPEND CAP IS TOKENS, NOT MONEY.  Local models cost nothing, so a money
# budget never trips; config/litellm/config.yaml gives each model a notional
# price of 1 USD per million tokens, which makes max_budget 0.2 per day equal
# 200000 tokens per day (limits.yaml "Model: tokens per key per day").
#
# Needs root (it reads the key files) and a running litellm.  The master key
# never leaves the container: the registration runs inside it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SECRETS="${AISTACK_SECRETS_DIR:-$ROOT/secrets}"
COMPOSE=(docker compose)
[ -n "${AISTACK_COMPOSE_PROJECT:-}" ] && COMPOSE+=(-p "$AISTACK_COMPOSE_PROJECT")

# app : models : mcp servers : requests/min : tokens/day
SPEC='mem0:agent,embed::60:200000
hermes:agent:web,n8n:60:200000
n8n:agent,local-chat,local-chat-large,embed,local-embed:web:60:200000
openwebui:agent,local-chat,local-chat-large,embed,local-embed:web,n8n:60:200000'

JSON="["; sep=""
while IFS=: read -r app models mcp rpm tokens; do
  [ -s "$SECRETS/key_$app" ] || { echo "missing $SECRETS/key_$app (run scripts/gen-secrets.sh)" >&2; exit 1; }
  JSON+="$sep{\"app\":\"$app\",\"key\":\"sk-$(cat "$SECRETS/key_$app")\",\"models\":\"$models\",\"mcp\":\"$mcp\",\"rpm\":$rpm,\"tokens\":$tokens}"
  sep=","
done <<<"$SPEC"
JSON+="]"

PY='
import json, os, sys, urllib.request, urllib.error
master = os.environ["LITELLM_MASTER_KEY"]
def call(path, body):
    r = urllib.request.Request("http://127.0.0.1:4000" + path, json.dumps(body).encode(),
        {"Authorization": "Bearer " + master, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=30) as f:
            return f.status, f.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
for a in json.load(sys.stdin):
    body = {"key": a["key"], "key_alias": "app-" + a["app"],
            "models": a["models"].split(","),
            "max_budget": a["tokens"] / 1_000_000, "budget_duration": "1d",
            "rpm_limit": a["rpm"],
            "object_permission": {"mcp_servers": [m for m in a["mcp"].split(",") if m]}}
    code, text = call("/key/generate", body)
    verb = "created"
    if code != 200:
        code, text = call("/key/update", body)
        verb = "updated"
    if code != 200:
        print("FAILED %s: HTTP %s %s" % (a["app"], code, text[:200].replace(a["key"], "<key>")))
        sys.exit(1)
    print("%-8s %s (models=%s mcp=%s rpm=%s tokens/day=%s)" % (a["app"], verb, a["models"], a["mcp"] or "-", a["rpm"], a["tokens"]))
'
printf "%s" "$JSON" | "${COMPOSE[@]}" exec -T litellm python3 -c "$PY"
