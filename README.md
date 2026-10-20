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
