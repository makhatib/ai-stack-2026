#!/usr/bin/env python3
"""Demo 2 -- Hermes triggers an n8n workflow through MCP.

Hermes is asked, in plain words, to add a follow-up task.  It has to find the
workflow, read how to call it, and run it -- through n8n's MCP server, behind
the ONE allowlist in LiteLLM.  The proof is not Hermes' reply: it is the row
the workflow writes, carrying a random marker made for this run, so an old row
or a made-up "done" cannot pass.

BLOCKED (exit 2), not FAIL, when the owner has not connected n8n yet:
`sudo bin/aistack mcp n8n-token` (see the camera script, step 0).
"""
import os
import secrets
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from hermes_run import ask, tools_visible  # noqa: E402
from report import Report  # noqa: E402

DC = os.environ.get("DEMO_DC", "docker compose").split()
TIMEOUT = int(os.environ.get("DEMO_HERMES_TIMEOUT", "2400"))
WF_ID, WF_NAME = "aistackDemoD2001", "Demo 2 - add a follow-up task"


def sql(db, q):
    p = subprocess.run(DC + ["exec", "-T", "postgres", "psql", "-U", "aistack_admin", "-d", db, "-tAc", q],
                       capture_output=True)
    return p.stdout.decode().strip()


r = Report("02-hermes-runs-n8n")
tools = tools_visible(DC)
need = {"n8n-search_workflows", "n8n-get_workflow_details", "n8n-execute_workflow"}
if not need <= set(tools):
    r.check("Hermes sees the three n8n tools through the gateway", False, ", ".join(tools) or "none")
    r.finish(blocked="n8n is not connected to the gateway: sudo bin/aistack mcp n8n-token (camera script step 0)")
r.check("Hermes sees the three n8n tools through the gateway", True, ", ".join(sorted(need)))
wf = sql("n8n", f"select active, settings->>'availableInMCP' from workflow_entity where id = '{WF_ID}'")
r.check(f"workflow '{WF_NAME}' is imported, NOT published, and available to MCP", wf == "f|true",
        f"active|availableInMCP = {wf or 'missing (run demos/setup.sh)'}")

marker = "D2-" + secrets.token_hex(3)
task = f"Call Al Waha Trading about invoice 2041 ({marker})"
question = (f"Use the n8n workflow \"{WF_NAME}\" to add this follow-up task: \"{task}\". "
            "Then tell me the execution id n8n gives you.")
t_start = sql("aistack_demo", "select now()")
run = ask(DC, question, timeout=TIMEOUT)
r.times["hermes_s"] = run.wall_s
r.info["tokens"] = run.tokens
r.info["tool_calls"] = [n for n, _ in run.calls]
r.note(f"question: {question}")
for n, inp in run.calls:
    r.note(f"tool call: {n} {str(inp)[:200]}")
r.note(f"answer ({run.wall_s} s): {run.text[:400]!r}")

execs = [i for n, i in run.calls if n.endswith("n8n_execute_workflow")]
r.check("Hermes called n8n's execute_workflow through the gateway", bool(execs),
        str(execs[0])[:200] if execs else "no execute_workflow call")
errs = [o[:200] for n, o, e in run.results if n.endswith("n8n_execute_workflow") and (e or '"error"' in o)]
r.check("the call was accepted (not refused by the allowlist or by n8n)", bool(execs) and not errs, "; ".join(errs))

row = ""
for _ in range(30):                       # execute_workflow returns before the run ends
    row = sql("aistack_demo", f"select task_id, source from d2_tasks where title like '%{marker}%' "
                              f"and created_at >= '{t_start}'")
    if row:
        break
    time.sleep(2)
r.check(f"the workflow wrote the task with this run's marker ({marker})", bool(row) and row.endswith("|n8n-mcp"),
        f"d2_tasks row: {row or 'none'}")
st = sql("n8n", f"select status from execution_entity where \"workflowId\" = '{WF_ID}' "
                f"and \"startedAt\" >= '{t_start}' order by \"startedAt\" desc limit 1")
r.check("n8n records that execution as a success", st == "success", f"status: {st or 'no execution'}")
r.finish()
