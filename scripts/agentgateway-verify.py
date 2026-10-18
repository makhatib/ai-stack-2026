#!/usr/bin/env python3
"""agentgateway-verify — the fail-closed startup verification (G-AGENTS (c)).

Runs once at `aistack up` (flow 17) and MUST exit 0 for the `agents` group to be
usable.  Any other outcome leaves the group unusable rather than warning:

  exit 0  the live tool surface EQUALS tools.lock.json
  exit 2  mismatch — an extra tool, a missing tool, or a changed input schema
  exit 3  the gateway is unreachable or answered something unparseable

Exit 3 matters as much as exit 2.  "I could not check" is not "I checked and it
was fine", and a verifier that treats unreachability as success is a warning
dressed as a gate.

Set equality, not lookup: an EXTRA tool fails exactly as hard as a missing one.
Checking only that each locked tool is present cannot detect a tool the backend
added, which is the case the lock file exists for.
"""

import argparse
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gate"))
from mcp_client import Client  # noqa: E402


def canonical_schema_hash(schema):
    """SHA-256 over the canonicalised input schema.

    A changed definition from a running backend must be detectable even when the
    tool NAME is unchanged, which is the whole of G-AGENTS (b).  Comparing names
    alone would pass a backend that silently widened its own schema.
    """
    blob = json.dumps(schema or {}, sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(blob.encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--lock", required=True)
    ap.add_argument("--bearer", default=os.environ.get("AGENTGATEWAY_BEARER") or None)
    ap.add_argument(
        "--write-schema-hashes",
        action="store_true",
        help="rewrite the lock file's input_schema_sha256 fields from the live "
             "surface. Used ONLY by `aistack tools lock`, never at startup.",
    )
    args = ap.parse_args()

    out = {"url": args.url, "lock": args.lock}

    try:
        with open(args.lock) as fh:
            lock = json.load(fh)
    except Exception as e:
        out["verdict"] = "unreadable-lock"
        out["error"] = repr(e)
        print(json.dumps(out, indent=2))
        return 3

    c = Client(args.url, args.bearer)
    init = c.initialize()
    if init.get("transport_error") or (init.get("http_status") or 0) >= 400:
        out["verdict"] = "unreachable"
        out["detail"] = {k: init.get(k) for k in ("http_status", "transport_error")}
        out["note"] = "unreachable is not verified; the group stays unusable"
        print(json.dumps(out, indent=2))
        return 3

    resp = c.rpc("tools/list", {})
    body = resp.get("body") or {}
    tools = (body.get("result") or {}).get("tools")
    if tools is None:
        out["verdict"] = "unparseable-tools-list"
        out["detail"] = {"http_status": resp.get("http_status"), "raw": resp.get("raw", "")[:800]}
        print(json.dumps(out, indent=2))
        return 3

    live = {}
    for t in tools:
        name = t.get("name")
        live[name] = canonical_schema_hash(t.get("inputSchema"))

    # Compare WIRE NAMES only.  `qualified_name` is whatever tools/list actually
    # returns for that tool — with agentgateway's `prefixMode: always` that is
    # `<target>_<tool>`.  Deliberately no name-normalising heuristic here: a
    # verifier that tries several spellings of a name until one matches will
    # also match a name the lock does not contain, which is the exact failure
    # this check exists to catch.  `aistack tools lock` writes the wire name.
    locked = {}
    for entry in lock.get("tools", []):
        key = entry.get("qualified_name") or entry.get("name")
        locked[key] = entry.get("input_schema_sha256")

    live_keys = set(live)
    locked_keys = set(locked)

    missing = sorted(locked_keys - live_keys)
    extra = sorted(live_keys - locked_keys)

    if args.write_schema_hashes:
        for entry in lock.get("tools", []):
            key = entry.get("qualified_name") or entry.get("name")
            if key in live:
                entry["input_schema_sha256"] = live[key]
        with open(args.lock, "w") as fh:
            json.dump(lock, fh, indent=2)
            fh.write("\n")
        out["verdict"] = "lock-rewritten"
        out["tools"] = sorted(live)
        print(json.dumps(out, indent=2))
        return 0

    changed = []
    for key, want in locked.items():
        got = live.get(key)
        if want and got and want != got and not str(want).startswith("PLACEHOLDER"):
            changed.append({"tool": key, "locked": want, "live": got})

    out["live_tools"] = sorted(live_keys)
    out["locked_tools"] = sorted(locked_keys)
    out["missing"] = missing
    out["extra"] = extra
    out["schema_changed"] = changed

    if missing or extra or changed:
        out["verdict"] = "mismatch"
        out["note"] = "set equality, not lookup: an extra tool fails as hard as a missing one"
        print(json.dumps(out, indent=2))
        return 2

    out["verdict"] = "ok"
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
