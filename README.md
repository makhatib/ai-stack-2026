# AI Stack 2026

A private AI and automation server for **one owner**, installed with one
command on a VPS or a home server. Every app sits behind one login with a
second factor. Nothing else is published.

> **Single owner, not multi-user.** This release has one owner account and no
> user roles. Do not give other people accounts on it. Multi-user is a later
> release.

## What is in it

| | |
|---|---|
| **Hermes Agent** | your personal agent (Telegram optional) |
| **n8n** | workflow automation, with its MCP server on |
| **Open WebUI** | chat, and chat with your documents |
| **Ollama** | local models, internal only (port 11434 is never published) |
| **LiteLLM** | the one gateway to every model and the shared MCP tool allowlist, per-app keys and spend limits |
| **gVisor** | sandbox runtime for agent code execution |
| **Mem0** | memory for the agent |
| **PostgreSQL + pgvector** | one datastore, one backup procedure |
| **SearXNG + Crawl4AI** | private web search and page extraction, internal only |
| **Langfuse** | tracing (optional; needs 16 GB) |
| **Authelia** | login and two-factor, in front of every app |
| **Caddy** | HTTPS and routing, with a static config |
| **Homepage** | the dashboard |

Optional profiles, chosen at install: `knowledge` (document parsing),
`docs-arabic` (Arabic OCR), `voice-arabic` (Arabic speech-to-text and
text-to-speech, needs 16 GB), `openclaw` (OpenClaw agent in a gVisor sandbox).
Sizes and details: [docs/vps-mode.md](docs/vps-mode.md#profiles).

## Install

```sh
git clone https://github.com/makhatib/ai-stack-2026.git && cd ai-stack-2026
```

**Home server** (private, nothing published):

```sh
./install.sh
```

If gVisor is missing, the installer stops and tells you to run
`sudo scripts/install-gvisor.sh`. Run it, then run `./install.sh` again.

**VPS** (fresh Ubuntu 24.04, your domain, an SSH key that already works):

```sh
sudo ./install.sh --mode vps --domain example.com
```

VPS mode sets the firewall to 22, 80 and 443 only, turns SSH password login
off, and gets real HTTPS certificates. Read [docs/vps-mode.md](docs/vps-mode.md)
first: it lists the DNS records you need before you run it.

**Then, in both modes, create your owner login:**

```sh
bin/aistack user reset owner      # set your password at the prompt
bin/aistack user code             # the one-time code that two-factor enrolment asks for
```

Full steps: [docs/install.md](docs/install.md).

## Where it listens

Home mode:

<!-- AISTACK-LOCAL-MODE:BEGIN -->
Not published to the internet. Reachable on this machine; reachable from other devices on your network if your network allows it — we have not tested that.
<!-- AISTACK-LOCAL-MODE:END -->

VPS mode: only ports 80 and 443 for the apps, and 22 for SSH with a key.

## What was tested for this release

Tested on Ubuntu 24.04, x86-64, 4 vCPU / 16 GB, on our own test machines:

- Home install, owner login with two-factor, dashboard, chat and the n8n
  editor open.
- The webhook refuses hostile requests and stores nothing.

**Not tested for this release:** answers from local models (agent, chat,
document chat, voice, OCR), Telegram, GPU, and a real Hostinger VPS with a
public certificate. VPS mode was tested on an earlier commit with a private
test CA only.

## Tests

One command, and it is named in `bin/aistack help`:

```sh
bin/aistack test              # the fast tier: no docker, no root, ~35s
bin/aistack test list         # every test and exactly what it needs
bin/aistack test stack        # needs a working docker daemon, ~85s
sudo bin/aistack test root    # needs to read root-owned secrets/
bin/aistack test all
```

The tiers split on **prerequisite, not speed**, because the prerequisite is
what decides whether you can run a test at all right now:

| tier | needs | cost |
|---|---|---|
| `fast` | python3 and coreutils, nothing else | ~35s |
| `stack` | a working docker daemon | ~85s |
| `root` | sudo, to read root-owned `secrets/` | re-runs the installer |
| `archive` | `--archive <path>` to an encrypted backup | ~10s |

`fast` is the set to run routinely: it starts no container, reads no secret
and touches no live data.

**A test that cannot run says so.** Several here refuse with exit 2 rather
than report on a property they were unable to measure —
`installer-idempotent.sh` when it cannot read `secrets/`, `test-scan-gate.sh`
when its baseline evidence is not clean. The runner gives refusals their own
count and their own exit code, and it reprints any `[skip]` from inside a
passing test, because a green line over a check that never ran is the defect
most of these tests were written against.

| runner exit | meaning |
|---|---|
| 0 | every selected test ran and passed |
| 1 | a test failed, or `tests/` and the runner's registry disagree |
| 2 | nothing failed, but a test refused, or nothing ran at all |
| 3 | `--strict` only: a check inside a passing test was skipped |

`bin/aistack test all` as an ordinary user ends at exit 2 **by design**: the
`root` tier cannot measure anything without privilege, and saying so is more
useful than passing.

Every executable in `tests/` must be registered in `tests/run.sh`, with its
prerequisites. An unregistered test file fails the run. That check is what
keeps `tests/` from drifting back into a directory of scripts nothing calls.

## What this release does NOT do

- **No multi-user.** One owner account, no roles.
- **No GPU paths tested.** The `gpu` profile is a later release.
- **No images or video generation, no coding agents.**
- **No containment claim.** The stack makes no promise that a compromised
  container cannot reach your LAN or a service listening on your host. See
  the security FAQ, which says exactly what is and is not claimed.

## Documentation

- [Install](docs/install.md)
- [VPS mode](docs/vps-mode.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Upgrade and rollback](docs/upgrade.md)
- [Security FAQ](docs/security-faq.md)
- [Backup and restore](docs/backup-restore.md)
