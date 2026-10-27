"""demos/lib/hermes_run.py -- ask Hermes one question, the way a Telegram
message would, and return everything it did.  Host side, standard library.

    from hermes_run import ask, tools_visible
    run = ask(dc, "question", toolsets="aistack,memory", timeout=1800)
    run.calls    -> [(tool_name, input_dict)]
    run.results  -> [(tool_name, output_text, is_error)]
    run.text     -> the final answer;  run.exit_code, run.tokens, run.wall_s

`dc` is the compose prefix (e.g. ["docker", "compose"]) so the same check runs
against an install and against a renamed rehearsal copy.

The one-shot runs `hermes chat --format stream-json` inside the hermes
container.  It goes through Hermes' own gateway (the process that serves
Telegram), so it uses the same model route, the same MCP gateway and the same
allowlist as a Telegram message.  `-t aistack,memory` names the toolsets the
shipped config gives the `telegram` platform (config/hermes/config.yaml):
measured, the one-shot path does not apply platform_toolsets by itself.
"""
import json
import re
import subprocess
import time

URL_RE = re.compile(r"https?://[^\s\)\]\}>\"'`*,]+")


class Run:
    def __init__(self):
        self.calls, self.results, self.text = [], [], ""
        self.exit_code, self.tokens, self.error, self.wall_s, self.raw = None, {}, None, 0.0, []

    def tool_output_text(self):
        return "\n".join(o for _, o, _ in self.results)

    def cited_urls(self):
        return sorted({u.rstrip(".") for u in URL_RE.findall(self.text)})


def ask(dc, question, toolsets="aistack,memory", timeout=1800, max_turns=12):
    cmd = dc + ["exec", "-T", "hermes", "hermes", "chat", "--query-file", "-", "-t", toolsets,
                "--format", "stream-json", "--max-turns", str(max_turns)]
    run = Run()
    t0 = time.monotonic()
    try:
        p = subprocess.run(cmd, input=question.encode(), capture_output=True, timeout=timeout)
        out = p.stdout.decode("utf-8", "replace")
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf-8", "replace")
        run.error = f"timed out after {timeout}s"
    run.wall_s = round(time.monotonic() - t0, 1)
    for line in out.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        run.raw.append(e)
        t = e.get("type")
        if t == "tool_use":
            run.calls.append((e.get("name", ""), e.get("input") or {}))
        elif t == "tool_result":
            run.results.append((e.get("name", ""), str(e.get("output", "")), bool(e.get("is_error"))))
        elif t == "result":
            run.text = (e.get("text") or "").strip()
            run.exit_code = e.get("exit_code")
            run.tokens = e.get("tokens") or {}
            run.error = run.error or e.get("error")
    return run


def tools_visible(dc, timeout=180):
    """What Hermes discovers on its MCP server right now (`hermes mcp test aistack`)."""
    p = subprocess.run(dc + ["exec", "-T", "hermes", "hermes", "mcp", "test", "aistack"],
                       capture_output=True, timeout=timeout)
    out = p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")
    return sorted(set(re.findall(r"^\s+((?:web|n8n)-[a-z_]+)\s", out, flags=re.M)))
