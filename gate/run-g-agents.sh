#!/usr/bin/env bash
# Gate G-AGENTS (final-design §0.1).
#
# The `agents` group is in the MVP ONLY IF this gate passes, on the pinned
# agentgateway digest, BEFORE anything else in that group is built.
#
#   (a) Unknown-name rejection.  A tools/call naming a tool absent from
#       tools.lock.json is REJECTED, not merely hidden from tools/list.
#   (b) Changed definitions are unusable — EXERCISED, not inferred.  A synthetic
#       MCP backend serves definition v1 at startup and v2 afterwards.
#       agentgateway must fail the request rather than dispatch against v2, and
#       must fail BEFORE the call reaches the backend.
#   (c) Fail-closed startup.  A startup verification that fails leaves the group
#       unusable rather than warning.
#
# If any of the three fails, `agents` leaves both the MVP and 1.0: the MVP is 9
# containers and 1.0 is 12.  Regenerate the counts from manifest.yaml; do not
# edit prose.
#
# Runs on its own throwaway docker network.  Touches nothing else on the host.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/versions.env"

AGW_IMAGE="${AGENTGATEWAY_IMAGE}@${AGENTGATEWAY_DIGEST}"
NET="g-agents-net"
BACKEND="g-agents-backend"
GATEWAY="g-agents-gateway"
WORK="$(mktemp -d /tmp/g-agents.XXXXXX)"
PROXY_PORT=13000
RESULT="$HERE/G-AGENTS-result.json"

PASS_A=unknown
PASS_B=unknown
PASS_C=unknown
declare -a EVIDENCE=()

note() { printf '\n=== %s\n' "$*"; }
eva()  { EVIDENCE+=("$1"); printf '    %s\n' "$1"; }

cleanup() {
  docker rm -f "$BACKEND" "$GATEWAY" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
mkdir -p "$WORK/state" "$WORK/config"
chmod 777 "$WORK/state"
echo v1 > "$WORK/state/version"
: > "$WORK/state/requests.log"
chmod 666 "$WORK/state/version" "$WORK/state/requests.log"
cp "$HERE/mcp_backend.py" "$WORK/"

# tools.lock.json — the lock the gateway config is generated from.  ONE tool.
#
# MEASURED, not assumed (NOM-258, 2026-10-18): with `prefixMode: always`
# agentgateway joins the target and tool names with an UNDERSCORE, so the wire
# name is `parse_convert`, not `parse:convert`.  `qualified_name` records the
# wire name because that is what tools/list returns and what the verifier
# compares against.
cat > "$WORK/config/tools.lock.json" <<'JSON'
{
  "schema": "aistack.tools.lock.v1",
  "generated_from": "manifest.yaml + config/agentgateway.yaml",
  "tools": [
    {
      "backend": "parse",
      "name": "convert",
      "qualified_name": "parse_convert",
      "input_schema_sha256": "PLACEHOLDER_SET_BY_LOCK_GENERATOR"
    }
  ]
}
JSON

# agentgateway config.  mcpAuthorization rules are CEL; the default is DENY, so
# the single permit below is the allowlist.  failureMode: failClosed.
#
# prefixMode: always is deliberate.  The default is `conditional`, which omits
# the target prefix when there is only one target — so the tool's wire name
# would change from `convert` to `parse_convert` the day a second backend is
# added, silently invalidating every lock entry.  Pinning the mode makes the
# name a property of the config rather than of how many backends happen to
# exist.
#
# MEASURED (NOM-258, 2026-10-18), because both of these are easy to get wrong:
#   * the prefix separator is an UNDERSCORE: the wire name is `parse_convert`.
#   * the CEL rule does NOT see the wire name.  `mcp.tool.name` binds to the
#     UNPREFIXED name (`convert`) and `mcp.tool.target` binds to the backend
#     (`parse`).  A rule written against the wire name matches nothing and
#     therefore denies everything — which is the safe direction, but it is a
#     silent total outage, so both terms are written out explicitly below.
cat > "$WORK/config/agentgateway.yaml" <<YAML
binds:
- port: 3000
  listeners:
  - routes:
    - policies:
        mcpAuthorization:
          rules:
          - 'mcp.tool.target == "parse" && mcp.tool.name == "convert"'
      backends:
      - mcp:
          prefixMode: always
          failureMode: failClosed
          targets:
          - name: parse
            mcp:
              host: ${BACKEND}
              port: 8900
              path: /mcp
YAML

# ---------------------------------------------------------------------------
# Stand the pair up on a throwaway network
# ---------------------------------------------------------------------------
note "Gate G-AGENTS on ${AGW_IMAGE}"
cleanup
docker network create "$NET" >/dev/null

docker run -d --name "$BACKEND" --network "$NET" \
  -v "$WORK/mcp_backend.py:/app/mcp_backend.py:ro" \
  -v "$WORK/state:/state" \
  -e MCP_PORT=8900 \
  python:3.12-alpine python /app/mcp_backend.py >/dev/null

docker run -d --name "$GATEWAY" --network "$NET" --platform linux/amd64 \
  -v "$WORK/config:/config:ro" \
  -p "127.0.0.1:${PROXY_PORT}:3000" \
  "$AGW_IMAGE" -f /config/agentgateway.yaml >/dev/null

URL="http://127.0.0.1:${PROXY_PORT}/mcp"
for _ in $(seq 1 60); do
  if python3 "$HERE/mcp_client.py" "$URL" list 2>/dev/null | grep -q '"tools"'; then break; fi
  sleep 1
done

# Count tools/call entries the BACKEND actually received.  `grep -c` exits 1 on
# zero matches, so the count must be taken without letting that status trigger a
# second write — the obvious `grep -c ... || echo 0` emits "0\n0".
backend_calls() {
  local n
  n=$(grep -c '"method": "tools/call"' "$WORK/state/requests.log" 2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

note "Baseline: tools/list through the gateway"
python3 "$HERE/mcp_client.py" "$URL" list > "$WORK/list-v1.json"
LOCKED_TOOL=$(python3 - "$WORK/list-v1.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
tools=(d.get("result",{}).get("body") or {}).get("result",{}).get("tools",[])
names=[t.get("name") for t in tools]
sys.stderr.write("    tools visible: %r\n" % (names,))
print(names[0] if names else "")
PY
)
if [ -z "$LOCKED_TOOL" ]; then
  echo "ABORT: the gateway exposed no tools; the gate cannot run." >&2
  exit 1
fi
eva "the gateway exposes the locked tool as '${LOCKED_TOOL}' (prefixMode: always)"

# Populate the lock's schema hashes from the v1 surface.  This is what
# `aistack tools lock` does, and it is what makes the (b) cross-check below a
# comparison against recorded bytes rather than against a placeholder.
python3 "$ROOT/scripts/agentgateway-verify.py" --url "$URL" \
  --lock "$WORK/config/tools.lock.json" --write-schema-hashes >/dev/null
eva "tools.lock.json schema hash recorded from the v1 surface: $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tools"][0]["input_schema_sha256"])' "$WORK/config/tools.lock.json")"

# ---------------------------------------------------------------------------
# (a) Unknown-name rejection
#
# Two shapes, because they fail differently.  A gateway that only strips unknown
# names from tools/list would still forward an unknown name it was handed, and a
# gateway that validates only the prefix would pass one of the two.
# ---------------------------------------------------------------------------
note "(a) Unknown-name rejection"
A_OK=1
for UNKNOWN in "parse:exfiltrate" "exfiltrate"; do
  BEFORE=$(backend_calls)
  python3 "$HERE/mcp_client.py" "$URL" call "$UNKNOWN" '{"x":1}' > "$WORK/a-$UNKNOWN.json" 2>/dev/null || true
  AFTER=$(backend_calls)
  if python3 - "$WORK/a-$UNKNOWN.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
r=(d.get("result") or {}); body=r.get("body") or {}
raw=json.dumps(body)
# A pass-through that returns BACKEND_EXECUTED is a FAIL however it is dressed.
if "BACKEND_EXECUTED" in raw: sys.exit(1)
if body.get("error") or (r.get("http_status") or 0) >= 400: sys.exit(0)
if (body.get("result") or {}).get("isError"): sys.exit(0)
sys.exit(1)
PY
  then
    if [ "$AFTER" -eq "$BEFORE" ]; then
      eva "(a) '${UNKNOWN}' rejected by the GATEWAY - the backend recorded no tools/call (before=$BEFORE after=$AFTER)"
    else
      eva "(a) '${UNKNOWN}' rejected, but the backend SAW the call (before=$BEFORE after=$AFTER) - the refusal is at least partly the backend's own"
      A_OK=2
    fi
  else
    eva "(a) '${UNKNOWN}' was NOT rejected"
    A_OK=0
  fi
done
case "$A_OK" in
  1) PASS_A=pass ;;
  2) PASS_A=pass-weak ;;
  *) PASS_A=fail ;;
esac

# ---------------------------------------------------------------------------
# (b) Changed definitions are unusable — exercised
# ---------------------------------------------------------------------------
note "(b) Changed definition from a running backend"
echo v2 > "$WORK/state/version"
eva "backend flipped to v2 (same tool name, altered inputSchema: adds exfiltrate_to, additionalProperties true)"
sleep 2

python3 "$HERE/mcp_client.py" "$URL" list > "$WORK/list-v2.json"
V2_VISIBLE=$(python3 - "$WORK/list-v2.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
tools=(d.get("result",{}).get("body") or {}).get("result",{}).get("tools",[])
for t in tools:
    if "v2" in (t.get("description") or "") or "exfiltrate_to" in json.dumps(t.get("inputSchema") or {}):
        print("yes"); break
else:
    print("no")
PY
)
eva "tools/list after the flip shows the v2 definition: $V2_VISIBLE"

BEFORE=$(backend_calls)
python3 "$HERE/mcp_client.py" "$URL" call "$LOCKED_TOOL" \
  '{"document":"synthetic.pdf","exfiltrate_to":"http://attacker.invalid/"}' > "$WORK/b.json" || true
AFTER=$(backend_calls)

if python3 - "$WORK/b.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
r=(d.get("result") or {}); body=r.get("body") or {}
raw=json.dumps(body)
if "BACKEND_EXECUTED" in raw:
    # Did the v2-only parameter actually reach the tool?
    try:
        txt=json.loads(body["result"]["content"][0]["text"])
        got=txt.get("received_arguments") or {}
    except Exception:
        got={}
    if "exfiltrate_to" in got:
        print("    the v2-only argument was DISPATCHED to the backend:", json.dumps(got)[:300]); sys.exit(1)
    print("    dispatched, but the v2-only argument was stripped:", json.dumps(got)[:300]); sys.exit(2)
if body.get("error") or (r.get("http_status") or 0) >= 400:
    print("    failed the request:", json.dumps(body.get("error") or {"http": r.get("http_status")})[:300]); sys.exit(0)
res=body.get("result") or {}
if res.get("isError"):
    print("    failed via isError:", json.dumps(res)[:300]); sys.exit(0)
print("    neither:", raw[:400]); sys.exit(1)
PY
then
  if [ "$AFTER" -eq "$BEFORE" ]; then
    PASS_B=pass
    eva "(b) PASS - the request failed and never reached the backend (before=$BEFORE after=$AFTER)"
  else
    PASS_B=fail
    eva "(b) FAIL - the request failed, but only AFTER reaching the backend (before=$BEFORE after=$AFTER). §0.1 requires it to fail before the call reaches the backend"
  fi
else
  rc=$?
  if [ "$rc" -eq 2 ]; then
    PASS_B=fail
    eva "(b) FAIL - the gateway dispatched against v2. It stripped the v2-only argument, which is schema coercion, not refusal: §0.1 requires the request to FAIL, and 'a gateway that silently forwards fails this gate'"
  else
    PASS_B=fail
    eva "(b) FAIL - the gateway dispatched the v2 definition's extra argument to the backend"
  fi
fi

# Characterisation, so the verdict names a MECHANISM rather than a symptom.
# Back on v1, whose schema is {required:[document], additionalProperties:false}:
# send an argument the schema forbids and omit the one it requires.  If that is
# dispatched, the gateway does no argument validation at all, and (b) is not a
# quirk of the v1->v2 flip — it is the absence of the whole check.
echo v1 > "$WORK/state/version"
sleep 2
BEFORE=$(backend_calls)
python3 "$HERE/mcp_client.py" "$URL" call "$LOCKED_TOOL" '{"surprise":"not-in-schema"}' \
  > "$WORK/b2.json" 2>/dev/null || true
AFTER=$(backend_calls)
if grep -q 'BACKEND_EXECUTED' "$WORK/b2.json"; then
  eva "(b) MECHANISM: with the backend on v1, an argument forbidden by the advertised schema (additionalProperties:false) was dispatched, and the required 'document' argument was absent. agentgateway 1.6.0 performs NO argument validation against the tool inputSchema; the advertised definition is advisory to the client and the gateway enforces tool NAMES only. (backend calls before=$BEFORE after=$AFTER)"
else
  eva "(b) MECHANISM: an out-of-schema argument on v1 was refused, so the v2 failure is specific to the definition change rather than to a missing validator"
fi

# Defence in depth, recorded separately and NEVER as the control (§0.1: the
# five-minute tools/list comparison stays detective).  Does our own verifier
# notice the v2 schema while the backend is still serving it?
echo v2 > "$WORK/state/version"
sleep 2
set +e
python3 "$ROOT/scripts/agentgateway-verify.py" --url "$URL" --lock "$WORK/config/tools.lock.json" \
  > "$WORK/b-verify.json" 2>&1
RC_BV=$?
set -e
eva "(b) detective cross-check: agentgateway-verify against the v2 surface exits $RC_BV (expect non-zero: the recorded schema hash no longer matches). This is DETECTIVE, not the control."

echo v1 > "$WORK/state/version"
sleep 2

# ---------------------------------------------------------------------------
# (c) Fail-closed startup verification
# ---------------------------------------------------------------------------
note "(c) Fail-closed startup verification"
# Our own verifier is the subject here: agentgateway-verify runs once at `up`
# and must exit non-zero when the live tool surface does not equal
# tools.lock.json, so the compose dependency leaves the group unusable rather
# than warning.  Drive it against a lock file that deliberately disagrees.
cat > "$WORK/config/tools.lock.bad.json" <<'JSON'
{
  "schema": "aistack.tools.lock.v1",
  "tools": [
    { "backend": "parse", "name": "convert",   "qualified_name": "parse:convert" },
    { "backend": "parse", "name": "summarise", "qualified_name": "parse:summarise" }
  ]
}
JSON

set +e
python3 "$ROOT/scripts/agentgateway-verify.py" --url "$URL" --lock "$WORK/config/tools.lock.json" \
  > "$WORK/c-good.json" 2>&1
RC_GOOD=$?
python3 "$ROOT/scripts/agentgateway-verify.py" --url "$URL" --lock "$WORK/config/tools.lock.bad.json" \
  > "$WORK/c-bad.json" 2>&1
RC_BAD=$?
python3 "$ROOT/scripts/agentgateway-verify.py" --url "http://127.0.0.1:1/mcp" --lock "$WORK/config/tools.lock.json" \
  > "$WORK/c-down.json" 2>&1
RC_DOWN=$?
set -e

eva "verify against the matching lock -> exit $RC_GOOD (expect 0)"
eva "verify against a mismatched lock -> exit $RC_BAD (expect non-zero)"
eva "verify against an unreachable gateway -> exit $RC_DOWN (expect non-zero: unreachable is not 'verified')"

if [ "$RC_GOOD" -eq 0 ] && [ "$RC_BAD" -ne 0 ] && [ "$RC_DOWN" -ne 0 ]; then
  PASS_C=pass
  eva "(c) PASS - the verifier fails closed on both mismatch and unreachability"
else
  PASS_C=fail
  eva "(c) FAIL - good=$RC_GOOD bad=$RC_BAD down=$RC_DOWN"
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
VERDICT=pass
case "$PASS_A" in pass|pass-weak) ;; *) VERDICT=fail ;; esac
[ "$PASS_B" = pass ] || VERDICT=fail
[ "$PASS_C" = pass ] || VERDICT=fail

python3 - "$RESULT" "$VERDICT" "$PASS_A" "$PASS_B" "$PASS_C" "$AGW_IMAGE" "${AGENTGATEWAY_DIGEST}" <<PY
import json,sys,datetime
result, verdict, a, b, c, image, digest = sys.argv[1:8]
evidence = $(printf '%s\n' "${EVIDENCE[@]}" | python3 -c 'import json,sys;print(json.dumps([l.rstrip("\n") for l in sys.stdin if l.strip()]))')
json.dump({
  "gate": "G-AGENTS",
  "source": "final-design NOM-257 §0.1",
  "run_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "image": image,
  "digest": digest,
  "checks": {"a_unknown_name_rejection": a, "b_changed_definition_unusable": b, "c_fail_closed_startup": c},
  "verdict": verdict,
  "consequence": ("agents stays in the MVP: 10 containers, 1.0 is 13"
                  if verdict == "pass" else
                  "agents leaves the MVP AND 1.0: the MVP is 9 containers, 1.0 is 12. Regenerate counts from manifest.yaml."),
  "evidence": evidence,
}, open(result,"w"), indent=2)
print()
print("G-AGENTS verdict:", verdict.upper())
PY

cp "$WORK/state/requests.log" "$HERE/G-AGENTS-backend-requests.log" 2>/dev/null || true
echo "Result: $RESULT"
[ "$VERDICT" = pass ]
