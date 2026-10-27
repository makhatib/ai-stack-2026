#!/usr/bin/env python3
"""Stand-in for LiteLLM's /v1/chat/completions, for the security-proof fixture only.

It exists so the webhook proof can tell a REFUSED request from an ACCEPTED one by
counting model calls: a refused payload must never cost an inference.  Every call
appends one line to /state/llm-calls.log.  Stdlib only.
"""
import json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.environ.get("STUB_LOG", "/state/llm-calls.log")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        with open(LOG, "a") as fh:
            fh.write("call\n")
        body = json.dumps({"choices": [{"message": {"role": "assistant",
                                                    "content": "synthetic answer"}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST


ThreadingHTTPServer(("0.0.0.0", 4000), H).serve_forever()
