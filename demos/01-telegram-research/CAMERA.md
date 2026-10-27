# Demo 1 — Telegram → Hermes does a web research task with citations

**What the viewer sees:** you send a question from your phone. Hermes searches
the web, reads a page, and answers in Telegram with the link it used.

**What is really happening:** Telegram → `telegram-gate` (the only way out for
Hermes) → Hermes (gVisor sandbox) → LiteLLM → the one MCP allowlist → `mcp-web`
→ SearXNG (search) and Crawl4AI (read one page). Hermes has no internet route
of its own and only the tools on the allowlist.

## Before you record (once)

1. Make a bot: in Telegram, open **@BotFather**, send `/newbot`, pick a name. Copy the token.
2. Find your own user id: message **@userinfobot**; it replies with a number.
3. On the server:
   ```bash
   sudo bin/aistack telegram token
   ```
   Paste the token, then your user id. Nothing is shown on screen. Hermes restarts.
   **Do this off camera:** the token is a password.
4. Rehearse once: `demos/run.sh 1` must say `PASS`.

## On camera

| Step | You do | You say (short) | You should see |
|---|---|---|---|
| 1 | Open the chat with your bot on the phone. Send: **`Research: what is the newest release of gVisor on GitHub? Cite the page you used.`** | "I ask my own agent, from my phone." | Hermes is typing. |
| 2 | Wait. | "It searches the web through my own search engine, SearXNG. No cloud search API." | After 1–3 minutes on a GPU or cloud model; **much longer on a CPU-only VPS** (see the `demos` doc for measured times). |
| 3 | Show the answer. | "It gives the tag and the page it read." | A tag like `release-2026…` and a `github.com/google/gvisor/releases` link. |
| 4 | Open the link on the phone. | "I can check the source myself." | The same tag on GitHub. |
| 5 | (optional) On the server: `docker compose logs --tail 20 mcp-web` | "Every tool call went through one allowlist." | `web_search` and `fetch_page` lines. |

## If it goes wrong

- **No reply in Telegram:** check that the id in step 2 is yours. Hermes answers only that account. `docker compose logs --tail 50 hermes` shows `telegram` errors.
- **"Budget has been exceeded":** each app has a daily token cap (200k). Rehearsals use it up. It resets at midnight UTC.
- **An answer without a link, or a link that does not open:** that is the model making it up. On a small CPU model this happens. Re-ask, or use a stronger model (see the doc).

## Automatic check

`demos/run.sh 1`: asks the same kind of question through Hermes' gateway and
passes only if Hermes **searched**, the tag in the answer **is in what the tools
returned**, and **every cited URL came from a tool result**. It cannot send a
Telegram message (that needs you and a phone); it reports the Telegram leg as
`NOT TESTED` when no token is set.
