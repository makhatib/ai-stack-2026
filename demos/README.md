# The six demos (DoD 2.5)

Six things the stack does, each with a **camera script** (what to click, what to
say, what you should see) and an **automatic check** (the same thing done by a
script that decides PASS or FAIL from evidence, not from how fluent the answer
sounds). Synthetic data only — see `fixtures/README.md`.

| # | Demo | Camera script | Check | Needs |
|---|---|---|---|---|
| 1 | Telegram → Hermes does a web research task with citations | `01-telegram-research/CAMERA.md` | `check.py` | core; Telegram token for the Telegram leg |
| 2 | Hermes triggers an n8n workflow through MCP | `02-hermes-runs-n8n/CAMERA.md` | `check.py` | core; n8n MCP token |
| 3 | Chat with my documents in Open WebUI (English + Arabic) | `03-chat-with-documents/CAMERA.md` | `check_owui.py` | core |
| 4 | Business automation with human approval (MVP W3) | `04-approval-automation/CAMERA.md` | `check.sh` | core |
| 5 | Arabic voice: speak Arabic, get an Arabic answer | `05-arabic-voice/CAMERA.md` | `check_owui.py` | profile `voice-arabic` |
| 6 | Arabic scanned document → text → question answered | `06-arabic-scan-to-answer/CAMERA.md` | `check_owui.py` | profile `docs-arabic` |

## Run the checks

```bash
bin/aistack up
bin/aistack samples setup          # models, demo database, W3 (once)
demos/setup.sh                     # demo 2's table and workflow (once)
sudo bin/aistack mcp n8n-token     # demo 2: the token from n8n -> Settings -> MCP (once)
sudo bin/aistack telegram token    # demo 1's Telegram leg (optional)

demos/run.sh                       # all six
demos/run.sh 3 6                   # some
DEMO_CHAT_MODEL=local-chat demos/run.sh   # the small model (8 GB servers)
demos/run.sh selftest              # prove the graders FAIL bad answers (no docker)
```

Exit code: **0** every demo that ran passed · **1** a demo failed · **2** nothing
failed but something was not measured (a demo `BLOCKED` on an owner step, or
`NOT RUN` because its profile is off). 2 is never a pass.

## What the checks hold an answer to

- **Grounded values, not fluency.** Every answer is scored *match / wrong / absent*
  against a value fixed before the run. A fluent wrong number is a FAIL.
- **No invented sources.** Demo 1 fails if a cited URL or the release tag did not
  come back from a tool. Demo 3 fails if a question the documents cannot answer
  gets a number.
- **The effect, not the reply.** Demo 2 passes on the database row its workflow
  wrote (with a random marker made for that run), not on Hermes saying "done".
  Demo 4 passes on the delivery table and the approval log, not on n8n's exit code.
- **Stages apart.** Retrieval vs answer (demo 3), OCR text vs answer (demo 6),
  hearing the question vs speaking the answer (demo 5) are scored separately,
  so a failure points at the right part.
- **The graders can fail.** `demos/run.sh` runs `lib/selftest.py` first: each
  rule is shown a bad answer of the kind the rehearsal really produced and must
  reject it.

## How the checks reach the stack

Nothing is published for them. Demos 1–2 run `hermes chat` inside the Hermes
container, through Hermes' own gateway (the process that serves Telegram).
Demos 3, 5 and 6 run inside the Open WebUI container and call Open WebUI's own
API — the calls its chat box, upload, microphone and read-aloud buttons make —
signed in with the header Authelia sets, as the owner. Demo 4 is
`bin/aistack samples`.

## Measured results

Tier 1 / Tier 2 pass/fail, run times and what is not tested are in the `demos`
document on NOM-416 (they are measurements of one machine, not a promise for
another).
