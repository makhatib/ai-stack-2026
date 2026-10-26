# VPS mode

One command turns a fresh Ubuntu 24.04 server into the AI Stack behind
automatic HTTPS and a second login factor on every app.

```bash
# on the server, as root, after you added your SSH key and the DNS records below
git clone <repository-url> ai-stack-2026 && cd ai-stack-2026
sudo ./install.sh --mode vps --domain example.com          # same as: sudo bin/aistack install --mode vps --domain example.com
```

It asks nothing. The domain is the only answer.

## Before you run it (3 things, the installer checks all three)

1. **Ubuntu 24.04**, a public IPv4 address, 2 vCPU / 8 GB or more (a Hostinger KVM 2 is the minimum).
2. **An SSH key already works** for the user you run the installer as. VPS mode turns
   SSH password login **off**. With no key the installer stops and changes nothing.
3. **Five DNS A records** pointing at the server (or one wildcard `*.example.com`):
   `example.com`, `dash.`, `chat.`, `n8n.`, `auth.` — all to the server's IPv4 address.
   Do not add AAAA records. If a name does not resolve to this machine the installer
   prints the exact records and stops, before any certificate is requested.

## What it does, in order

| Step | What | Where |
|---|---|---|
| 0 | checks: Ubuntu 24.04, domain, SSH key, public address, DNS | `install.sh` |
| 0 | `apt` base packages, Docker CE (version pinned), gVisor | `scripts/vps-host.sh`, `scripts/install-gvisor.sh`, `config/vps-pins.env` |
| 0 | `ufw`: deny incoming; allow 22, 80, 443 (tcp) | `vps_firewall` |
| 0 | SSH key-only drop-in, verified with `sshd -T` | `vps_ssh_keyonly` |
| 1–15 | the normal installer: secrets, config, pins, pull by digest, start | `install.sh` |
| end | `scripts/vps-verify.sh --local` | prints what answers without a login |

Caddy then asks Let's Encrypt for one certificate per name (HTTP-01 on port 80).
Allow a minute before the first visit.

## Then, the same two steps as home mode

```bash
bin/aistack user reset owner      # your own password, typed at a prompt
bin/aistack user code             # the one-time code enrolment asks for
```

Open `https://auth.example.com/`, log in, enrol a second factor (TOTP), enter the code.
After that `https://dash.example.com/` and `https://chat.example.com/` open.

## The security promise, and how it is checked

| Promise | Enforced by | Checked by |
|---|---|---|
| Every app needs password **and** a second factor | Authelia `*.domain` = `two_factor`, default policy `deny`; Caddy `forward_auth` on every app route | `ci/invariants.py` I18; `vps-verify.sh` (what answers without a login) |
| One exception only: `n8n.<domain>/webhook/*` | the one `bypass` rule; n8n webhooks are called by machines, not people | I18 counts bypass rules; `vps-verify.sh` |
| Real certificates | `acme_ca` set; no `local_certs`, no `tls internal` | I18; `vps-verify.sh` rejects a Caddy-local issuer |
| Only 22, 80, 443 reachable | `ufw`; the stack publishes only Caddy's 80/443 (I2) | `vps-verify.sh --remote <ip>` scans all 65535 ports **from another machine** |
| SSH key-only | drop-in `00-aistack-keyonly.conf` | `sshd -T` |
| No Docker socket, nothing else published | unchanged from home mode (I2, I6) | `ci/invariants.py` |

**Why the port scan comes from outside.** Docker's published ports bypass `ufw`
(they are NATed, not filtered by INPUT). `ufw status` shows intent; only a scan from
another machine shows what is reachable:

```bash
scripts/vps-verify.sh --remote <server-ip>      # run on your laptop or any other host
sudo scripts/vps-verify.sh                       # on the server: firewall, SSH, listeners, per-app answers
```

Exit 0 = every check ran and passed. 1 = a check failed. 2 = a check could not run
(never read as a pass).

## Options

| Flag | Meaning |
|---|---|
| `--tailscale` | **Off by default.** Also installs Tailscale (pinned) and allows `tailscale0` in `ufw`. Joining a tailnet is yours to do: `sudo tailscale up`. Port 22 stays open publicly until you close it yourself (`sudo ufw delete allow 22/tcp`) — do that only after you have logged in over Tailscale. |
| `--acme-ca staging` | Let's Encrypt staging: for rehearsals. Browsers do not trust it. |
| `--acme-ca <https-url>` / `--acme-ca-root <pem>` | A private ACME CA (used by the rehearsal below). |
| `--skip-dns-check` | Install before the DNS records exist. Certificates fail until they do. |

## Undo / rollback

```bash
cd ai-stack-2026
bin/aistack down                                  # stop the stack (data kept in volumes)
sudo rm /etc/ssh/sshd_config.d/00-aistack-keyonly.conf && sudo systemctl reload ssh   # password login back
sudo ufw disable                                  # firewall off (or: sudo ufw reset)
./install.sh                                      # a home-mode re-run removes every VPS key from .env
```

Docker and gVisor stay installed (they are held with `apt-mark hold`; `apt-mark unhold` to release).

## Re-running

Safe. Existing secrets are reused; every `.env` change shows a diff and leaves a `.bak`.

@@TESTED@@
