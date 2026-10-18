# Install

One machine, one command, about fifteen minutes plus however long your
internet takes to pull nine images.

## Before you start

| | |
|---|---|
| **OS** | Linux with Docker Engine 24+ and the Compose v2 plugin |
| **CPU** | 4 cores (Starter) · 4–8 (AI Automation) |
| **RAM** | 8–16 GB (Starter) · 16–32 GB (AI Automation) |
| **Disk** | 60 GB (Starter) · 150 GB (AI Automation) |
| **GPU** | not used in this release |

**These are estimates, not measurements.** They are the figures we will write
into the compose file, not an observed peak on your hardware.

You also need a hostname that resolves on the machine you are installing on.
`aistack.localhost` works on most systems; otherwise add a line to
`/etc/hosts`.

## Install

```sh
git clone <repo> aistack
cd aistack
./install.sh
```

The wizard asks four things: the hostname, the address to bind to, which
profile you want, and your email (used only for Caddy's internal CA
bookkeeping — no mail is ever sent, there is no SMTP in this release).

### What it does, in order

1. **Pre-flight checks.** Docker version, Compose plugin, free disk, free RAM,
   and whether the ports you chose are already in use. Any failure is a
   **hard stop** with the reason, not a warning it continues past.
2. **Host listener enumeration.** It lists every socket on your machine bound
   to `0.0.0.0` or `::`, with its address family. Read this list. It is the
   one thing the stack cannot protect you from and it tells you what a
   container could reach if it were compromised.
3. **Secret generation.** Every secret is generated locally and written to
   `secrets/`. **The installer prints paths, never values** — not at install,
   not in `status`, not in an error.
4. **Owner bootstrap, phase 1.** One account, with a random password stored as
   an argon2id hash. Nobody ever sees that password, including you.
5. **Pin rendering, image pull, start, and a bounded health gate.**

### Owner bootstrap, phase 2

Open `https://<your-hostname>/` and follow the reset flow. You set the first
password yourself, and you enrol a second factor before any service resolves.

There is deliberately no window in which an account exists that can reach a
service with a password the installer printed — because the installer never
prints one.

## Where it listens

<!-- AISTACK-LOCAL-MODE:BEGIN -->
Not published to the internet. Reachable on this machine; reachable from other devices on your network if your network allows it — we have not tested that.
<!-- AISTACK-LOCAL-MODE:END -->

If you set the bind address to `127.0.0.1`, only this machine can reach it.
If you set it to your network address, other machines may be able to — that
depends on your own network, and we have not tested it.

## First things to do

```sh
bin/aistack status                      # what is running
bin/aistack models pull llama3.2:3b     # ~2 GB
bin/aistack doctor                      # the full check
```

**Pulling a model from the Open WebUI interface does not work, and that is
deliberate.** Ollama sits on a network with no route off the host; model
weights arrive through a short-lived helper that exists only for the duration
of the pull. Model management is a command-line operation, like the rest of
the lifecycle.

## Uninstall

```sh
bin/aistack remove
```

It asks separately about your data. Removing containers and removing volumes
are different decisions and it will not make the second one for you.
