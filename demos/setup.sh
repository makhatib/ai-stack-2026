#!/usr/bin/env bash
# demos/setup.sh -- make the six demos runnable on a running stack.  Idempotent.
#
#   bin/aistack up && bin/aistack samples setup     (models, demo DB, W3, credentials)
#   demos/setup.sh                                  (this: what the demos add on top)
#
# It adds only synthetic things, and says what it did:
#   - the d2_tasks table in the demo database (demo 2 writes there);
#   - the demo 2 workflow, imported with a fixed id, NOT published, available to MCP;
#   - and it reports the two owner steps it cannot do for you: the n8n MCP token
#     (demo 2) and the Telegram bot token (demo 1's Telegram leg).
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
dc() { ( cd "$ROOT" && docker compose "$@" ); }
die() { printf 'demos/setup: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

dc ps --status running --services 2>/dev/null | grep -qx n8n || die "the stack is not running: bin/aistack up"
dc exec -T postgres psql -U aistack_admin -d postgres -tAc "select 1 from pg_database where datname='aistack_demo'" \
  | grep -qx 1 || die "no demo database yet: bin/aistack samples setup"

info "== demo 2: task table"
dc exec -T postgres psql -v ON_ERROR_STOP=1 -q -U aistack_demo -d aistack_demo <<'SQL'
CREATE TABLE IF NOT EXISTS d2_tasks (
    task_id    bigserial   PRIMARY KEY,
    title      text        NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
    source     text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
SQL
info "  d2_tasks ready in aistack_demo"

info "== demo 2: workflow"
dc exec -T n8n sh -c 'umask 077; mkdir -p /home/node/.cache; cat > /home/node/.cache/aistack-d2.json' \
  < "$HERE/02-hermes-runs-n8n/workflow.json"
dc exec -T n8n n8n import:workflow --input=/home/node/.cache/aistack-d2.json >/dev/null 2>&1 \
  || die "importing the demo 2 workflow failed"
dc exec -T n8n rm -f /home/node/.cache/aistack-d2.json
# The import keeps the id; n8n decides itself whether it keeps `availableInMCP`,
# so the setting is asserted (and set) rather than assumed.
dc exec -T postgres psql -v ON_ERROR_STOP=1 -q -U aistack_admin -d n8n -c \
  "update workflow_entity set active = false,
          settings = (coalesce(settings::jsonb, '{}'::jsonb) || '{\"availableInMCP\": true}'::jsonb)::json
    where id = 'aistackDemoD2001'" >/dev/null
st="$(dc exec -T postgres psql -U aistack_admin -d n8n -tAc \
  "select active, settings::jsonb->>'availableInMCP' from workflow_entity where id = 'aistackDemoD2001'")"
[ "$st" = "f|true" ] || die "demo 2 workflow state is '$st', expected not published + available to MCP"
info "  'Demo 2 - add a follow-up task' imported (aistackDemoD2001): not published, available to MCP"

info "== owner steps (not done for you)"
if dc exec -T litellm sh -c 'test "${N8N_MCP_TOKEN:-__SET_ME__}" != "__SET_ME__"'; then
  info "  n8n MCP token: set"
else
  info "  n8n MCP token: NOT SET -- demo 2 is BLOCKED until you run: sudo bin/aistack mcp n8n-token"
fi
if dc exec -T hermes sh -c "grep -q '^TELEGRAM_BOT_TOKEN=..' /opt/data/.env"; then
  info "  Telegram bot token: set"
else
  info "  Telegram bot token: not set -- demo 1 runs without its Telegram leg (sudo bin/aistack telegram token)"
fi
info "Ready: demos/run.sh"
