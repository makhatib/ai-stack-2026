# Security FAQ

Written to be read by someone deciding whether to trust this on their own
machine. Where the answer is "we don't know", it says so.

## Where does it listen?

<!-- AISTACK-LOCAL-MODE:BEGIN -->
Not published to the internet. Reachable on this machine; reachable from other devices on your network if your network allows it — we have not tested that.
<!-- AISTACK-LOCAL-MODE:END -->

That sentence lives in one file and is rendered into every surface from
there, so it cannot drift between the README, the installer and this page.

**"We have not tested that" is literal.** Reaching the stack from a second
machine needs a second machine to test from, and this release was built and
validated on one. Two browser profiles on the same computer prove user
separation; they share a network stack, so they prove nothing about a second
client. We would rather say "untested" than imply either answer.

## Can a compromised container reach my other machines, or services on my host?

**We do not claim that it cannot.**

This release ships what the design calls Tier A, and Tier A makes **no
containment claim at all**. Here is precisely what you do and do not get.

**What you do get**, and it is real: eight of the ten networks are created
with `internal: true`, which means Docker installs **no default route and no
masquerade** for them. Nothing on such a network has a path to the internet.
We verified this rather than asserting it — Ollama, which sits on one, cannot
resolve its own update server.

**What you do not get**, stated at its own size:

- A container **can** reach services on your host that are listening on all
  addresses. The installer enumerates those for you at install time, and that
  list is the thing to act on.
- The design makes **no claim either way** about whether a container can reach
  your local network, or link-local metadata addresses. We did not test it, so
  we will not tell you it is blocked.
- Two containers that share a network **can** connect to each other, in both
  directions. The document parser is alone on a network with Open WebUI, and
  it can attempt a connection back to Open WebUI's authenticated port. It
  holds no credential and has no route off the host, but "cannot reach"
  overstates it.

Closing those three needs host firewall rules, which this release does not
install and does not require. That is a later version.

## Why is there no agent tool gateway? It was announced.

Because it failed its own pre-build gate, and we would rather ship nine
containers than a security control that does not control anything.

The plan was `agentgateway` as a policy enforcement point in front of the
document parser: a locked list of tools, and nothing outside it callable. The
gate had three tests, run against the exact pinned image before writing any
of the group:

1. **Reject an unknown tool name** — not merely hide it. **Passed.** A call to
   a tool absent from the lock file is refused by the gateway, and the backend
   never sees it.
2. **A changed tool definition must be unusable.** **Failed.** We stood up a
   backend that served one definition at startup and a modified one
   afterwards, and the gateway forwarded a call made against the modified
   definition straight through.
3. **A failed startup verification must leave the group unusable**, not warn.
   **Passed.**

Then we characterised test 2 rather than leaving it as a symptom. With the
backend serving its *original* definition — which declares one required
parameter and forbids extras — we sent a call with the required parameter
missing and a forbidden one present. It was dispatched. **The gateway does
not validate arguments against the declared tool schema at all; it enforces
tool names.**

That is not a defect report about a bad project. Name enforcement is a real
control and the component does it. It is simply not the control the design
needed, and the design said in advance that a gateway which silently forwards
fails the gate. So the group is deferred, the stack is nine containers, and
the full result is in `gate/G-AGENTS-result.json` with the harness that
produced it in `gate/` so you can re-run it against a newer version.

## Where are the secrets?

In `secrets/`, generated on your machine, `0700`, never committed, and
**never printed** — not at install, not in `status`, not in an error message.
A test runs the installer with a planted canary and fails the build if that
value appears in any output, log, config diff, backup listing or support
bundle.

Two applications — Open WebUI and LiteLLM — receive a secret as an
environment variable, because neither supports reading one from a file. That
is recorded as a named exception with its residual stated: a compromise of
either application can read that application's own environment, and anyone
with root on the host, or access to the Docker daemon, is inside the trust
boundary. We do not claim otherwise.

## Does anything get access to the Docker socket?

No, and nothing in any profile does. This is the single biggest privilege
removed compared to the stack this replaces. A read-only socket proxy was
considered and rejected: read access to the containers API returns every
container's environment, which is exactly where the two exceptions above put
a secret. A read-only socket proxy here would be a credential-disclosure
endpoint wearing a least-privilege label.

## Can the operator account read the secrets?

Some of them, and the honest answer is that it does not matter much on a
single-operator machine -- but the reason is worth understanding, because
`secrets/` being `0700` does not tell the whole story.

Compose **ignores** `uid`, `gid` and `mode` on a file secret. Those keys are
Swarm-only; `docker compose config` echoes them back to you faithfully and
then Compose bind-mounts the host file with its **host** ownership. So the
host file mode is the only control there is, and it has to be chosen for the
numeric id the process inside the container runs as.

That numeric id collides with host groups. Measured on a fresh root-shell
install (operator `ai`, uid/gid 1000):

| File | Mode | Why | Operator |
|---|---|---|---|
| `authelia_*` (4 files) | `0600 root:root` | Authelia's own entrypoint, uid 0 | cannot read |
| `postgres_superuser_password`, `app_db_passwords` | `0640 root:999` | gid 999 is `postgres` **in the container** | cannot read |
| `n8n_encryption_key` | `0640 root:1000` | gid 1000 is `node` **in the container** | **can** read |
| `litellm.env`, `open-webui.env` | `0640 root:1000` | read by the Docker CLI as the operator | **can** read |
| `backup.key`, `backup.hmac` | `0600 operator` | the operator is told to copy these off-host | **can** read |

Two consequences we are not going to dress up:

- `gid 999` on *this* host happens to resolve to `systemd-journal`, and
  `gid 1000` to the operator's own group. The names are an accident of the
  host's `/etc/group`; the container only ever sees the number. If your host
  puts a *human* in gid 999 or 1000, that human can read the files in those
  rows. Check with `ls -l secrets/` and `getent group 999 1000`.
- The operator is in the `docker` group, which is root-equivalent anyway.
  Anyone who can run `docker` can read any secret in this stack regardless
  of file modes, so these rows are not a privilege boundary and are not
  claimed as one. They are listed so you know exactly what is where.

What the modes *do* buy is containment **between services**: a compromise of
n8n cannot read Authelia's session secret or the Postgres superuser
password. `aistack doctor` proves that direction by asking each container,
rather than inferring it from the mode.

## What runs as root?

More than we would like, and it is written down rather than glossed.

Every container drops **all** capabilities and runs with a read-only root
filesystem. Where a container still needs a capability, it is a named
exception with the measurement that justifies it. Postgres has five, each
established by bisecting against the pinned image rather than copied from a
blog post — and one of them only revealed itself on the *second* boot, so the
set is validated against both first install and restart.

One thing worth knowing if you are hardening your own stack: **dropping all
capabilities removes root's ability to bypass file permissions.** A container
running as uid 0 with no capabilities cannot read a file it does not own.
"Root can read anything" is false here, and it cost us four confusing
failures during the build.

## Is my data encrypted?

Backups are, with a key you hold. The database is not encrypted at rest —
that is your disk's job, and claiming otherwise would be theatre.

Backups carry a digest of **every** member and an HMAC over that inventory,
so neither a file nor the *list* of files can be altered undetected. The HMAC
key is a **separate file** from the encryption key, so whoever holds the
archive cannot forge its manifest. **A restore refuses to start without the
HMAC key** rather than falling back to checking digests that live inside the
manifest it cannot verify.

## What has actually been tested?

See `build-report` for the full tested/untested split. The short version:
the stack runs, the login path works, every image is digest-pinned, and the
backup refuses bad archives. Not tested: anything involving a GPU, anything
involving a second machine, and every containment claim — which is why this
page does not make any.
