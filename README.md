# AI Stack 2026

A self-hosted AI and automation server you can install on one machine, read
end to end, and take apart again.

**Nine containers.** Chat, documents, local models and workflow automation,
behind one locked door.

## What is in it

| | |
|---|---|
| **Open WebUI** | chat, RAG and the document pipeline |
| **n8n** | workflow automation — the only place a mutating action can run |
| **Ollama** | local models, on your own hardware |
| **LiteLLM** | the one authorised front door to every model |
| **Docling** | "chat with your PDF" — document parsing, isolated |
| **PostgreSQL + pgvector** | one datastore, one backup procedure |
| **Authelia** | login and two-factor, in front of everything |
| **Caddy** | TLS and routing, with a static config |
| **Homepage** | the front door |

## Where it listens

<!-- AISTACK-LOCAL-MODE:BEGIN -->
Not published to the internet. Reachable on this machine; reachable from other devices on your network if your network allows it — we have not tested that.
<!-- AISTACK-LOCAL-MODE:END -->

That sentence is the project's exact wording about exposure and it lives in
exactly one file, `strings/local-mode.txt`. Everywhere it appears it is
rendered from there, and CI checks the copy matches.

## Install

```sh
git clone <this repo> aistack && cd aistack
./install.sh
```

The installer runs pre-flight checks, generates every secret, and refuses to
continue rather than leaving you with a stack that starts and then fails.

Then:

```sh
bin/aistack status      # what is running, and the counts, separately
bin/aistack doctor      # health, pins, secret readability, host listeners
bin/aistack models pull llama3.2:3b
```

## What this release does NOT do

Stated here rather than discovered later:

- **No internet research.** There is no web-search group and Open WebUI's web
  search is off in every profile.
- **No agent tool gateway.** It was planned, and its pre-build gate failed —
  see `docs/security-faq.md` and `gate/G-AGENTS-result.json`. The honest
  summary: the gateway enforces tool *names* and does not validate arguments
  against the tool's declared schema, so it was not shipped.
- **No GPU paths tested.** GPU support is a later release.
- **No voice, no images, no code execution, no VPN, no public mode.**
- **No containment claim.** The stack makes no promise that a compromised
  container cannot reach your LAN or a service listening on your host. See
  the security FAQ, which says exactly what is and is not claimed.

## Documentation

- [Install](docs/install.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Upgrade and rollback](docs/upgrade.md)
- [Security FAQ](docs/security-faq.md)
- [Backup and restore](docs/backup-restore.md)
