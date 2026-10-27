# Install

One machine, one command, about fifteen minutes plus however long your
internet takes to pull nine images.

## Before you start

| | |
|---|---|
| **OS** | Linux with Docker Engine 24+ and the Compose v2 plugin |
| **Host tools** | `python3`, `openssl`, `tar`, and the usual base utilities: `awk`, `sed`, `grep`, `diff`, `df`, `flock`, `ss` |
| **CPU** | 4 cores (Starter) · 4–8 (AI Automation) |
| **RAM** | 8–16 GB (Starter) · 16–32 GB (AI Automation) |
| **Disk** | 60 GB (Starter) · 150 GB (AI Automation) |
| **GPU** | not used in this release |

**These are estimates, not measurements.** They are the figures we will write
into the compose file, not an observed peak on your hardware.

The host-tools row is not an estimate — it is the list the installer actually
invokes, and step 1 checks every entry before it does anything else. On
Debian/Ubuntu: `apt install python3 openssl coreutils diffutils util-linux
iproute2 tar`. No Python library is needed; a plain `python3` is enough.

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

1. **Pre-flight checks.** The host tools above, Docker version, Compose
   plugin, free disk, free RAM, and whether the ports you chose are already in
   use. Any failure is a **hard stop** with the reason, not a warning it
   continues past.
2. **Host listener enumeration.** It lists every socket on your machine bound
   to `0.0.0.0` or `::`, with its address family. Read this list. It is the
   one thing the stack cannot protect you from and it tells you what a
   container could reach if it were compromised.
3. **Secret generation.** Every secret is generated locally and written to
   `secrets/`. **The installer prints paths, never values** — not at install,
   not in `status`, not in an error.
4. **Owner bootstrap, phase 1.** One account, with a random password stored as
   an argon2id hash. Nobody ever sees that password, including you — which is
   why phase 2 below is a command you run, not a link you click.
5. **Pin rendering, image pull, start, and a bounded health gate.**

### Owner bootstrap, phase 2

The installer left you an account you cannot log in as. That is phase 1 working:
the password it generated was random, was never printed, and is not recoverable
by anybody, including us. Phase 2 is you giving that account a password you
chose and a second factor. It is two commands and one browser visit, and until
all three are done no protected route resolves.

**There is no temporary password to hand around, and no web reset flow.**
Authelia's self-service password reset is switched off in
`config/authelia/configuration.yml`, because it works by emailing a link and
this stack has no mail server. A reset page that cannot send mail is a dead end
that looks like a feature, so the path is a local command instead — which also
means setting the owner's password requires a shell on this machine, not a
browser session from somewhere else.

#### 1. Set your password

```sh
bin/aistack user reset owner
```

It asks twice, at a prompt, and echoes nothing. The password is not an argument
and is not read from a pipe — typing it is the only supported way to supply it,
because an argument would show up in `ps` and a pipe would mean the password
lives in whatever produced it. Minimum twelve characters. The command stores
only an argon2id hash, in `config/authelia/users.yml`, and then restarts
Authelia so it re-reads that file.

#### 2. Log in and enrol a second factor

Open `https://<your-hostname>/`. Sign in with `owner` and the password you just
set. Authelia will tell you a second factor is required and offer to register
one — start that, and it will ask for a one-time code.

#### 3. Read the one-time code

```sh
bin/aistack user code
```

That code is the one thing Authelia will not show you in the browser: it
normally arrives by email, and with no mail server it is written to a file
inside the Authelia container instead. The command reads it out and prints it,
along with when it was issued and a link that cancels it. It is single-use, it
expires in minutes, and it is worth nothing without the password — if one
appears that you did not ask for, somebody else has the password, and
`bin/aistack user reset owner` is the answer.

Type the code into the browser prompt, scan the QR code with an authenticator
app, and confirm with a generated code. That is phase 2 finished.

#### Checking, and what to do when it goes wrong

```sh
bin/aistack user list
```

prints every account, its groups, and whether it has a second factor enrolled.
`NOT ENROLLED` on a row means that account cannot open anything: every route is
`two_factor`, so a correct password on its own gets a redirect back to the login
page and no content.

- **Lost the authenticator.** `bin/aistack user reset-2fa owner` forgets the
  enrolled factor and leaves the password alone. The next login starts step 2
  again.
- **Forgot the password.** `bin/aistack user reset owner` again. It does not
  need the old one — a shell on this machine is the authority.
- **A second person needs access.** `bin/aistack user add <name>`, then they do
  steps 2 and 3 for themselves. New accounts get no groups unless you pass
  `--groups`.
- **`bin/aistack user code` says the latest notification is not a code.** It is
  showing you the last thing Authelia sent, which after a successful enrolment
  is a confirmation. Start an enrolment and run it again.

## Where it listens

<!-- AISTACK-LOCAL-MODE:BEGIN -->
Not published to the internet. Reachable on this machine; reachable from other devices on your network if your network allows it — we have not tested that.
<!-- AISTACK-LOCAL-MODE:END -->

If you set the bind address to `127.0.0.1`, only this machine can reach it.
If you set it to your network address, other machines may be able to — that
depends on your own network, and we have not tested it.

## First things to do

Phase 2 above comes first: until it is done these commands work but nothing in
a browser does.

```sh
bin/aistack user list                   # is phase 2 actually finished
bin/aistack status                      # what is running
bin/aistack models pull qwen3.5:2b      # ~2.7 GB (see docs/install.md for the rest)
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
