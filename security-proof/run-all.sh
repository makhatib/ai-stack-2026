#!/usr/bin/env bash
# Run the three security proofs in order.  Exit 0 only if all three PASS.
#
#   ./run-all.sh --fixture          sandbox: starts nothing, expects fixture/up.sh to have run
#   ./run-all.sh HOST --url https://n8n.<domain>/webhook/w4-demo --token-file F --counter '<cmd>'
#                                   a real server: proof 1 against HOST, proof 2 against the URL.
#                                   Proof 3 (the MCP gateway) is not published on a real server and
#                                   runs against the fixture; see README.md.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
if [ "${1:-}" = "--fixture" ]; then
  "$HERE/01-port-scan.sh" "$(cat "$HERE/fixture/.state/edge_ip")" || rc=1
  "$HERE/02-webhook-refused.sh" --fixture || rc=1
  "$HERE/03-mcp-blocked.sh" --fixture || rc=1
else
  host="$1"; shift
  "$HERE/01-port-scan.sh" "$host" || rc=1
  "$HERE/02-webhook-refused.sh" "$@" || rc=1
  "$HERE/03-mcp-blocked.sh" --fixture || rc=1
fi
[ $rc = 0 ] && echo "ALL THREE SECURITY PROOFS PASS" || echo "AT LEAST ONE SECURITY PROOF DID NOT PASS"
exit $rc
