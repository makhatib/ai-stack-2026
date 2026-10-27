#!/usr/bin/env python3
"""One MCP request through the gateway, reported as one JSON line.  Stdlib only.

  mcp_probe.py URL KEYFILE list
  mcp_probe.py URL KEYFILE call TOOL 'JSON-ARGS'

The key is read from a file, never taken from argv (argv is visible in `ps`).
Output: {"outcome": "ok"|"blocked"|"unreachable", "detail": "...", "tools": {name: [arg keys]}}
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gate"))
from mcp_client import Client  # noqa: E402  (the G-AGENTS client, reused unchanged)

url, keyfile, action = sys.argv[1:4]
key = open(keyfile).read().strip()
c = Client(url, key)
init = c.initialize()
out = {"outcome": "unreachable", "detail": "", "tools": {}}
if init.get("http_status") is None:
    out["detail"] = init.get("transport_error", "")
    print(json.dumps(out)); sys.exit(0)
if init.get("http_status") in (401, 403):
    out.update(outcome="blocked", detail="HTTP %s at initialize (key refused)" % init["http_status"])
    print(json.dumps(out)); sys.exit(0)

if action == "list":
    r = c.rpc("tools/list", {})
    body = r.get("body") or {}
    tools = ((body.get("result") or {}).get("tools")) or []
    out["tools"] = {t["name"]: sorted(((t.get("inputSchema") or {}).get("properties") or {}).keys()) for t in tools}
    out.update(outcome="ok" if r.get("http_status") == 200 and "error" not in body else "blocked",
               detail="HTTP %s" % r.get("http_status"))
else:
    tool, args = sys.argv[4], json.loads(sys.argv[5]) if len(sys.argv) > 5 else {}
    r = c.rpc("tools/call", {"name": tool, "arguments": args})
    body = r.get("body") or {}
    res = body.get("result") or {}
    text = " ".join(x.get("text", "") for x in (res.get("content") or []) if isinstance(x, dict))
    if r.get("http_status") is None:
        out.update(outcome="unreachable", detail=r.get("transport_error", ""))
    elif "BACKEND_EXECUTED" in text:
        out.update(outcome="ok", detail="the backend ran the tool")
    elif "error" in body:
        out.update(outcome="blocked", detail="error: %s" % str(body["error"].get("message", ""))[:200])
    elif res.get("isError"):
        out.update(outcome="blocked", detail="refused: %s" % text[:200])
    elif r.get("http_status") and r["http_status"] >= 400:
        out.update(outcome="blocked", detail="HTTP %s %s" % (r["http_status"], (r.get("raw") or "")[:160]))
    else:
        out.update(outcome="ok", detail="answered: %s" % text[:120])
print(json.dumps(out))
