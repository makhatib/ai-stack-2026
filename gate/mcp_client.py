#!/usr/bin/env python3
"""Minimal MCP Streamable-HTTP client for gate G-AGENTS and for the
`agentgateway-verify` helper.

Stdlib only.  Prints one JSON object on stdout describing the outcome, so the
caller can assert on it without parsing prose.

Usage:
  mcp_client.py <url> list [--bearer TOKEN]
  mcp_client.py <url> call <tool> <json-args> [--bearer TOKEN]
"""

import json
import sys
import urllib.error
import urllib.request

PROTOCOL_VERSION = "2025-06-18"


class Client:
    def __init__(self, url, bearer=None):
        self.url = url
        self.bearer = bearer
        self.session = None
        self._id = 0

    def _headers(self):
        h = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": PROTOCOL_VERSION,
        }
        if self.bearer:
            h["Authorization"] = "Bearer " + self.bearer
        if self.session:
            h["Mcp-Session-Id"] = self.session
        return h

    def rpc(self, method, params=None, notification=False):
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        if not notification:
            self._id += 1
            body["id"] = self._id
        req = urllib.request.Request(
            self.url, data=json.dumps(body).encode(), headers=self._headers(), method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                sid = resp.headers.get("Mcp-Session-Id")
                if sid:
                    self.session = sid
                raw = resp.read().decode()
                return {"http_status": resp.status, "body": _parse(raw), "raw": raw}
        except urllib.error.HTTPError as e:
            raw = e.read().decode()
            return {"http_status": e.code, "body": _parse(raw), "raw": raw}
        except Exception as e:  # connection refused, timeout, ...
            return {"http_status": None, "transport_error": repr(e), "body": None, "raw": ""}

    def initialize(self):
        r = self.rpc(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "g-agents-client", "version": "1"},
            },
        )
        self.rpc("notifications/initialized", {}, notification=True)
        return r


def _parse(raw):
    """Accept a plain JSON body or an SSE frame carrying one."""
    raw = (raw or "").strip()
    if not raw:
        return None
    if raw.startswith("event:") or raw.startswith("data:"):
        for line in raw.splitlines():
            if line.startswith("data:"):
                try:
                    return json.loads(line[5:].strip())
                except Exception:
                    return {"unparsed_sse": line}
        return {"unparsed_sse": raw}
    try:
        return json.loads(raw)
    except Exception:
        return {"unparsed": raw[:2000]}


def main():
    args = list(sys.argv[1:])
    bearer = None
    if "--bearer" in args:
        i = args.index("--bearer")
        bearer = args[i + 1]
        del args[i : i + 2]

    url, action = args[0], args[1]
    c = Client(url, bearer)
    out = {"url": url, "action": action}
    out["initialize"] = c.initialize()

    if action == "list":
        out["result"] = c.rpc("tools/list", {})
    elif action == "call":
        tool = args[2]
        params = json.loads(args[3]) if len(args) > 3 else {}
        out["tool"] = tool
        out["result"] = c.rpc("tools/call", {"name": tool, "arguments": params})
    else:
        out["error"] = "unknown action"

    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
