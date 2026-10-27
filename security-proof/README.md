# Security proof scripts (DoD 2.6)

Three scripts to run on camera. Each prints `PASS` / `FAIL` / `NOT MEASURED` as its last line
(exit 0 / 1 / 2) and takes well under a minute (about 7 s each on the sandbox).

| Script | Shows |
|---|---|
| `01-port-scan.sh HOST` | From another machine, only 80 and 443 answer; 22 only if kept, and then it is key-only (a password is refused). TCP only. |
| `02-webhook-refused.sh` | Hostile payloads to the shipped W4 webhook are refused and leave no trace (no row stored, no model call). A positive control runs first. |
| `03-mcp-blocked.sh --fixture` | A non-allowlisted MCP tool, and an unapproved argument, are blocked at the gateway and never reach the backend. A changed tool definition (v1 to v2) does not become callable. |

## Sandbox run

    security-proof/fixture/up.sh        # first start takes a few minutes (n8n and LiteLLM migrations)
    security-proof/run-all.sh --fixture
    security-proof/fixture/down.sh      # removes every nom-417-* container, the network and .state

The fixture binds 127.0.0.1 only, uses synthetic data, and generates its secrets per run into
`fixture/.state/` (0600, git-ignored, never printed). The route, workflow and `web` allowlist under test
are the shipped files, mounted unchanged; the model server and MCP backend are stubs.

## Real server (VPS, once it exists)

    security-proof/run-all.sh VPS_HOST --url https://n8n.<domain>/webhook/w4-demo \
        --token-file F --counter '<cmd printing rows stored + model calls>'

Run proof 1 from your laptop, not from the server. The MCP gateway is not published on a real server,
so proof 3 always runs against the fixture.

## Limits (read before over-claiming)

- Proof 1 is TCP only and sees what one network path allows. A dropped packet counts as closed.
- Proof 3 checks tool names and argument NAMES, not types or required fields.
- The scripts were drilled to FAIL: an extra listener on port 2222 turned proof 1 red.
