# Demo 2 — Hermes triggers an n8n workflow through MCP

**What the viewer sees:** you ask Hermes, in plain words, to add a follow-up
task. Hermes finds the right n8n workflow and runs it. The task appears in the
database.

**What is really happening:** Hermes → LiteLLM's MCP gateway (the same one
allowlist) → n8n's built-in MCP server → the workflow *Demo 2 - add a follow-up
task* → one row in the demo database. Only workflows you marked "available in
MCP" are visible; Hermes may only search them, read them, and run them.

## Before you record (once)

1. `bin/aistack samples setup` and `demos/setup.sh` (the demo database and the workflow).
2. Connect n8n to the gateway. In the browser open **n8n** → **Settings** → **MCP** →
   copy the access token. Then on the server, **off camera**:
   ```bash
   sudo bin/aistack mcp n8n-token
   ```
   Paste it. LiteLLM and Hermes restart.
3. Rehearse: `demos/run.sh 2` must say `PASS`.

## On camera

| Step | You do | You say | You should see |
|---|---|---|---|
| 1 | In n8n, open **Demo 2 - add a follow-up task**. | "A normal n8n workflow. I allowed my agent to use it." | Three nodes: Task request → Validate → Store. The workflow is **not published**. |
| 2 | In Telegram (or `docker compose exec hermes hermes chat`), send: **`Add a follow-up task: call Al Waha Trading about invoice 2041 next Monday.`** | "I just say what I want." | Hermes replies that it ran the workflow, with an execution id. |
| 3 | In n8n, open **Executions**. | "n8n ran it, because the agent asked." | A new successful execution. |
| 4 | Show the row: `docker compose exec postgres psql -U aistack_demo -d aistack_demo -c "select * from d2_tasks order by task_id desc limit 3"` | "The task is stored. Nothing was sent to anyone." | Your task text, `source = n8n-mcp`. |

## If it goes wrong

- **Hermes says it has no n8n tool:** step 2 of "before you record" was skipped. `docker compose exec hermes hermes mcp test aistack` must list `n8n-execute_workflow`.
- **"Parameters … are not allowed":** an old allowlist. `config/litellm/config.yaml` must allow `workflowId, executionMode, triggerNodeName, inputs`.
- **Hermes picks the wrong workflow or invents a result:** say the workflow name in your message.

## Automatic check

`demos/run.sh 2`: asks Hermes to add a task that carries a random marker, then
passes only if Hermes called `execute_workflow` through the gateway, the call
was accepted, **the row with that marker is in `d2_tasks`**, and n8n recorded the
execution as a success. Without the n8n token it is `BLOCKED`, not failed.
