#!/usr/bin/env python3
"""Demo 1 -- Telegram -> Hermes does a web research task with citations.

What is checked automatically (no person, no Telegram account):
  1. Hermes sees the two web tools through the ONE MCP allowlist (LiteLLM).
  2. A research question gets an answer that is GROUNDED:
       - Hermes really searched (a web_search call through the gateway);
       - the release tag in the answer appears in what the tools returned
         (an invented tag fails, however fluent);
       - it cites at least one URL, and every cited URL is one the tools
         returned or fetched (an invented source fails).
  3. Telegram: whether a bot token is configured and the gateway connected.
     Sending a Telegram message needs a person and a phone, so the message leg
     is in the camera script, not here.  Without a token this is reported as
     NOT TESTED, never as a pass.

The question goes through Hermes' own gateway process -- the one that serves
Telegram -- with the toolsets the shipped config gives the telegram platform.
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from hermes_run import ask, tools_visible  # noqa: E402
from report import Report  # noqa: E402
from grading import grade_research  # noqa: E402

DC = os.environ.get("DEMO_DC", "docker compose").split()
TIMEOUT = int(os.environ.get("DEMO_HERMES_TIMEOUT", "2400"))
QUESTION = ("Research task: what is the newest release tag of gVisor on GitHub? "
            "Search the web first, then answer in two sentences and cite the page you used.")

r = Report("01-telegram-research")
tools = tools_visible(DC)
r.check("Hermes sees web-web_search and web-fetch_page through the gateway",
        {"web-web_search", "web-fetch_page"} <= set(tools), ", ".join(tools) or "none")

run = ask(DC, QUESTION, timeout=TIMEOUT)
r.times["hermes_research_s"] = run.wall_s
r.info["tokens"] = run.tokens
r.info["tool_calls"] = [n for n, _ in run.calls]
r.note(f"question: {QUESTION}")
for n, inp in run.calls:
    r.note(f"tool call: {n} {str(inp)[:160]}")
r.note(f"answer ({run.wall_s} s, {run.tokens.get('total', '?')} tokens): {run.text[:500]!r}")
for name, ok, detail in grade_research(run):
    r.check(name, ok, detail)

# Telegram: configured?  connected?  (read inside the container: the file is root-owned)
p = subprocess.run(DC + ["exec", "-T", "hermes", "sh", "-c",
                         "grep -c '^TELEGRAM_BOT_TOKEN=..' /opt/data/.env || true"], capture_output=True)
configured = p.stdout.decode().strip() not in ("", "0")
logs = subprocess.run(DC + ["logs", "--tail", "400", "hermes"], capture_output=True).stdout.decode("utf-8", "replace")
bad = [ln for ln in logs.splitlines() if re.search(r"telegram (failed to connect|bot token rejected)", ln, re.I)]
r.info["telegram"] = ("NOT TESTED: no bot token" if not configured else
                      "configured, but the gateway could not connect: " + bad[-1][-160:] if bad else
                      "configured; the message itself is camera script step 1 (needs a person and a phone)")
print(f"  [info] Telegram leg: {r.info['telegram']}"
      + ("" if configured else "  (sudo bin/aistack telegram token; then the camera script, step 1)"), flush=True)
r.finish()
