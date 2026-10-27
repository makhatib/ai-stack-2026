#!/usr/bin/env bash
# AI Stack 2026 — installer.
#
# A CLI WIZARD IN BASH.  Not a web wizard: that needs an HTTP listener before
# any authentication exists, which is the original stack's single worst
# failure class.  Not a TUI: a host dependency that breaks over non-TTY SSH
# and cannot be driven in CI.
#
#   ./install.sh                              interactive (home mode)
#   ./install.sh --non-interactive --answers answers.conf
#   sudo ./install.sh --mode vps --domain example.com     fresh Ubuntu 24.04 VPS
#                                                          (same as: aistack install ...)
#
# VPS mode (NOM-414) prepares the host (Docker, gVisor, firewall, SSH keys only),
# then installs the same stack behind automatic HTTPS and Authelia MFA on one
# subdomain per app.  It asks nothing: the domain is the answer.  See
# docs/vps-mode.md.  Extra VPS flags:
#   --tailscale            also install Tailscale for admin access (off by default)
#   --acme-ca staging|URL  certificate authority (default: Let's Encrypt production)
#   --acme-ca-root FILE    PEM root to trust for a private ACME CA (rehearsals only)
#   --skip-dns-check       do not insist the A records exist yet
#
# IDEMPOTENT AND THAT IS LOAD-BEARING: an existing secret is REUSED, never
# regenerated; every write shows a diff first and leaves a timestamped .bak.
# The stack this replaces rotated every password on every run against live
# volumes, which is how an "idempotent" installer locks you out of your data.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$ROOT"

NON_INTERACTIVE=0
ANSWERS=""
LOG="$ROOT/install.log"
MODE=home
DOMAIN=""
ACME_CA=""
ACME_CA_ROOT=""
TAILSCALE=0
SKIP_DNS_CHECK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --answers) ANSWERS="${2:?--answers needs a file}"; shift 2 ;;
    --mode) MODE="${2:?--mode needs home or vps}"; shift 2 ;;
    --domain) DOMAIN="${2:?--domain needs a domain name}"; shift 2 ;;
    --acme-ca) ACME_CA="${2:?--acme-ca needs staging or a URL}"; shift 2 ;;
    --acme-ca-root) ACME_CA_ROOT="${2:?--acme-ca-root needs a PEM file}"; shift 2 ;;
    --tailscale) TAILSCALE=1; shift ;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "install: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

case "$MODE" in
  home) if [ -n "$DOMAIN$ACME_CA$ACME_CA_ROOT" ] || [ "$TAILSCALE" = 1 ] || [ "$SKIP_DNS_CHECK" = 1 ]; then
          echo "install: --domain, --acme-ca, --acme-ca-root, --tailscale and --skip-dns-check are VPS-mode flags; add --mode vps." >&2; exit 2
        fi ;;
  vps)  [ -n "$DOMAIN" ] || { echo "install: --mode vps needs --domain <your-domain>." >&2; exit 2; }
        NON_INTERACTIVE=1 ;;
  *)    echo "install: --mode must be home or vps (got '$MODE')." >&2; exit 2 ;;
esac

exec > >(tee -a "$LOG") 2>&1

say()  { printf '%s\n' "$*"; }
head2(){ printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# The answer file is PARSED, NEVER SOURCED (S06).
#
# `source` on an answer file executes it.  A value containing $(...) or a
# backtick would run as the installing user — who is frequently root.  This
# parser accepts KEY=VALUE, nothing else, and validates every key against a
# fixed list rather than accepting whatever it finds.
# ---------------------------------------------------------------------------
declare -A ANS=()
VALID_KEYS=" AISTACK_HOSTNAME AISTACK_BIND_ADDR AISTACK_ADMIN_EMAIL AISTACK_TZ COMPOSE_PROFILES "

parse_answers() {
  local file="$1" lineno=0 line key value
  [ -f "$file" ] || die "answer file not found: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) die "answer file line $lineno is not KEY=VALUE: $line" ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    # Strip one layer of matching quotes, and NOTHING else.  No expansion.
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    case " $key " in
      *" $key "*) ;;
    esac
    if [[ ! " $VALID_KEYS " == *" $key "* ]]; then
      die "answer file line $lineno sets unknown key '$key'"
    fi
    if [[ "$key" =~ [^A-Z0-9_] ]]; then
      die "answer file line $lineno has a malformed key: $key"
    fi
    ANS["$key"]="$value"
  done < "$file"
}

ask() {
  # $1 key, $2 prompt, $3 default, $4 validator function name
  local key="$1" prompt="$2" default="$3" validator="${4:-}" value
  if [ -n "${ANS[$key]:-}" ]; then
    value="${ANS[$key]}"
  elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    value="$default"
  else
    read -r -p "  $prompt [$default]: " value
    value="${value:-$default}"
  fi
  if [ -n "$validator" ]; then
    "$validator" "$value" || die "invalid value for $key: $value"
  fi
  ANS["$key"]="$value"
}

valid_hostname() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  # Authelia requires a cookie domain with at least one period.
  [[ "$1" == *.* ]] || { warn "a hostname with no period cannot be a cookie domain"; return 1; }
}

valid_bind_addr() {
  case "$1" in
    0.0.0.0|::|"")
      warn "A WILDCARD BIND ADDRESS IS REFUSED."
      warn "Binding to 0.0.0.0 publishes the stack on every interface this"
      warn "machine has, including ones you may not have thought about."
      warn "Use 127.0.0.1, or your specific network address."
      return 1 ;;
  esac
  [[ "$1" =~ ^[0-9.]+$ || "$1" =~ ^[0-9a-fA-F:]+$ ]] || return 1
}

# OPTIONAL PROFILES (NOM-415, DoD 2.4).  Each is a yes/no, default NO, and each
# adds containers only when it is answered yes.  RAM figures are MEASURED on
# the sandbox (NOM-415 `profiles` doc), idle + while working; they are not a
# promise for another machine.  An answer file sets COMPOSE_PROFILES directly
# and is never asked these.
KNOWN_PROFILES="knowledge tracing openclaw voice-arabic docs-arabic"
ask_optional_profiles() {
  local a
  say ""
  say "  Optional profiles (each one is off unless you say yes):"
  say "    openclaw      OpenClaw agent, tools in a gVisor sandbox, no internet.  ~1.2 GB idle, 1.8 GB working"
  say "    voice-arabic  Arabic speech-to-text and text-to-speech in Open WebUI.  ~__RAM_VOICE__"
  say "    docs-arabic   Arabic OCR for scanned documents (replaces the English-only parser).  ~1.1 GB idle, 2.1 GB working"
  say "    gpu           NOT OFFERED: no 24 GB GPU test machine, so no GPU path is tested."
  for p in openclaw voice-arabic docs-arabic; do
    read -r -p "  Add $p? [y/N]: " a
    case "$a" in
      y|Y|yes|YES) ANS[COMPOSE_PROFILES]="${ANS[COMPOSE_PROFILES]:+${ANS[COMPOSE_PROFILES]},}$p" ;;
    esac
  done
  # docs-arabic's parser reads English as well, and Open WebUI uses ONE parser,
  # so the English-only one would sit idle on ~0.9 GB.  It is dropped here.
  case ",${ANS[COMPOSE_PROFILES]}," in
    *,docs-arabic,*)
      ANS[COMPOSE_PROFILES]="$(printf '%s' "${ANS[COMPOSE_PROFILES]}" | tr ',' '\n' | grep -vx knowledge | paste -sd, -)" ;;
  esac
}
check_profiles() {
  local p
  for p in $(printf '%s' "$1" | tr ',' ' '); do
    case " $KNOWN_PROFILES " in
      *" $p "*) ;;
      *) if [ "$p" = gpu ]; then
           die "the gpu profile is not part of this release: there was no 24 GB GPU
machine to test it on (founder input I5), so it is on the Later list."
         fi
         die "unknown profile '$p' in COMPOSE_PROFILES.  Known: $KNOWN_PROFILES" ;;
    esac
  done
}

[ -n "$ANSWERS" ] && parse_answers "$ANSWERS"

say ""
say "AI Stack 2026 — installer"
say "9 containers. Chat, documents, local models and workflow automation."
say ""

# ===========================================================================
# 1-7  PRE-FLIGHT.  Every failure here is a HARD STOP with the reason, not a
#      warning the installer continues past (H1, S02, S14, H4).
# ===========================================================================
# ===========================================================================
# 0   VPS HOST PREPARATION  (--mode vps only; home mode only checks gVisor)
#     Everything that can be CHECKED is checked before anything is CHANGED:
#     the OS, the domain, an SSH key (password login is about to be switched
#     off), and DNS (a certificate request against a wrong record burns CA rate
#     limit).  Then, in this order: packages, Docker, gVisor, firewall, SSH.
# ===========================================================================
VPS_ENV=()          # extra KEY=VALUE lines for .env, filled in below
ACME_KIND=""
if [ "$MODE" = vps ]; then
  # shellcheck source=scripts/vps-host.sh
  . "$ROOT/scripts/vps-host.sh"
  head2 "[0/15] VPS host"
  [ "$(id -u)" -eq 0 ] || die "VPS mode changes the firewall and SSH settings, so it must run as root:
   sudo ./install.sh --mode vps --domain $DOMAIN"
  vps_check_os || die "this is not Ubuntu 24.04. VPS mode is tested there and nowhere else."
  vps_valid_domain "$DOMAIN" || die "'$DOMAIN' is not a domain name this installer accepts.
Use a plain lowercase name such as example.com (no https://, no wildcard, no IP address)."
  vps_have_ssh_key || { vps_ssh_key_instructions; die "no SSH key for ${SUDO_USER:-$(id -un)} — nothing was changed."; }
  say "  SSH public key present for ${SUDO_USER:-$(id -un)}"
  VPS_IP="$(vps_public_ip)" || true
  [ -n "${VPS_IP:-}" ] || die "could not find this machine's IPv4 address (ip route get 1.1.1.1)."
  if vps_is_private_ip "$VPS_IP" && [ "${AISTACK_ALLOW_PRIVATE_IP:-0}" != 1 ]; then
    die "this machine's address is $VPS_IP, which is not a public address. A certificate authority cannot reach it.
VPS mode is for a server with a public IPv4 address."
  fi
  say "  public address: $VPS_IP"
  if [ "$SKIP_DNS_CHECK" = 1 ]; then
    warn "DNS check skipped: certificates are requested as soon as the stack starts and fail until the A records exist."
  else
    vps_check_dns "$DOMAIN" "$VPS_IP" || { vps_dns_instructions "$DOMAIN" "$VPS_IP"; die "DNS does not point at this machine yet — nothing was changed."; }
  fi
  case "$ACME_CA" in
    "") ACME_CA="https://acme-v02.api.letsencrypt.org/directory"; ACME_KIND="Let's Encrypt (production)" ;;
    staging) ACME_CA="https://acme-staging-v02.api.letsencrypt.org/directory"; ACME_KIND="Let's Encrypt STAGING (browsers do not trust these)" ;;
    https://*) ACME_KIND="custom ACME CA $ACME_CA" ;;
    *) die "--acme-ca must be 'staging' or an https:// URL." ;;
  esac
  if [ -n "$ACME_CA_ROOT" ]; then
    [ -s "$ACME_CA_ROOT" ] || die "--acme-ca-root: no such file: $ACME_CA_ROOT"
  fi
  say "  certificates: $ACME_KIND"

  vps_install_packages || die "could not install the base packages with apt."
  vps_install_docker   || die "could not install Docker."
  bash scripts/install-gvisor.sh || die "could not install gVisor."
  vps_firewall         || die "could not configure the firewall."
  if [ "$TAILSCALE" = 1 ]; then VPS_TAILSCALE=1 vps_tailscale || die "could not install Tailscale."; fi
  vps_ssh_keyonly      || die "could not switch SSH to key-only login."

  if [ -n "$ACME_CA_ROOT" ]; then
    mkdir -p .runtime && cp "$ACME_CA_ROOT" .runtime/acme-ca-root.pem && chmod 0644 .runtime/acme-ca-root.pem
  fi
  # Forced answers: the domain is the hostname, Caddy binds to the public
  # address (never a wildcard, I2).  An answer file cannot change either.
  ANS[AISTACK_HOSTNAME]="$DOMAIN"
  ANS[AISTACK_BIND_ADDR]="$VPS_IP"
  VPS_ENV=(
    "AISTACK_MODE=vps"
    "AISTACK_DOMAIN=$DOMAIN"
    "AISTACK_CADDYFILE=./config/caddy/Caddyfile.vps"
    "AISTACK_CADDY_SITES=./config/caddy/sites-vps.d"
    "AISTACK_AUTHELIA_CONFIG=./config/authelia/configuration.vps.yml"
    "AISTACK_HOMEPAGE_SERVICES=./config/homepage/services.vps.yaml"
    "AISTACK_DASH_HOST=dash.$DOMAIN"
    "AISTACK_CHAT_URL=https://chat.$DOMAIN"
    "AISTACK_N8N_URL=https://n8n.$DOMAIN"
    "AISTACK_N8N_HOST=n8n.$DOMAIN"
    "AISTACK_N8N_WEBHOOK_URL=https://n8n.$DOMAIN/"
    "AISTACK_ACME_CA=$ACME_CA"
  )
  if [ -n "$ACME_CA_ROOT" ]; then
    VPS_ENV+=("AISTACK_ACME_ROOT_FILE=./.runtime/acme-ca-root.pem" "AISTACK_ACME_CA_ROOT=/etc/caddy/acme-ca-root.pem")
  fi
else
  # Home mode needs the gVisor runtime too (Hermes, Crawl4AI).  Installing it
  # restarts Docker and writes /etc/docker/daemon.json, so only root does it.
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && ! bash scripts/install-gvisor.sh --check; then
    if [ "$(id -u)" -eq 0 ]; then
      bash scripts/install-gvisor.sh || die "could not install gVisor."
    else
      die "the gVisor runtime (runsc) is not registered with Docker, and Hermes needs it.
Install it once, as root, then re-run this installer:

    sudo scripts/install-gvisor.sh"
    fi
  fi
fi

head2 "[1/15] Host tools"
# THE TOOLS THIS INSTALLER ACTUALLY INVOKES, CHECKED BEFORE IT INVOKES THEM.
#
# MEASURED (NOM-307, 2026-10-19).  Pre-flight checked docker, disk, RAM and
# ports and never checked an interpreter, while install.sh calls `python3` in
# four places and `openssl` once per secret.  On the isolated QA target — a
# machine carrying only what docs/install.md declares — that absence was not
# the failure; it was worse than the failure, because the one path that
# depended on a missing library DEGRADED QUIETLY instead of stopping, and the
# install went on to build a database it could not authenticate against.
#
# Two rules this list follows:
#   * it names the package, because "python3 not found" without "apt install
#     python3" is half a diagnosis;
#   * `ss` IS REQUIRED, not optional.  Step 8's port check reads `ss` output,
#     and an empty read is indistinguishable from "both ports are free" — a
#     vacuous pass over the one check that stops this stack from fighting
#     another service for :443.
#
# PyYAML IS DELIBERATELY NOT HERE.  Nothing in the install path imports it any
# more (NOM-307); `ci/invariants.py` and `aistack security-check` do, and both
# say so loudly and are developer tools, not install prerequisites.
MISSING=""
for tool in python3 openssl awk sed grep diff df flock ss tar; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
  die "these host tools are missing and the installer needs every one of them:
   $MISSING

On Debian/Ubuntu:   apt install python3 openssl coreutils diffutils util-linux iproute2 tar
On Fedora/RHEL:     dnf install python3 openssl coreutils diffutils util-linux iproute2 tar

They are listed in docs/install.md under 'Before you start'."
fi
say "  $(python3 --version 2>&1), openssl, awk, sed, grep, diff, df, flock, ss, tar"

head2 "[2/15] Docker"
command -v docker >/dev/null || die "docker is not installed."
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon. Is it running, and are you in the docker group?"
say "  $(docker --version)"

head2 "[3/15] Compose v2"
docker compose version >/dev/null 2>&1 || die "the Docker Compose v2 plugin is not installed."
say "  $(docker compose version | head -1)"

head2 "[4/15] Disk"
AVAIL_GB=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc '0-9')
say "  ${AVAIL_GB} GB available at $ROOT"
[ "${AVAIL_GB:-0}" -ge 40 ] || die "at least 40 GB free is needed; ${AVAIL_GB} GB available.
Model weights alone are tens of gigabytes. Free some space and re-run."
[ "${AVAIL_GB:-0}" -ge 60 ] || warn "60 GB is the Starter recommendation; you have ${AVAIL_GB} GB."

head2 "[5/15] Memory"
TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
say "  ${TOTAL_MB} MB total"
[ "${TOTAL_MB:-0}" -ge 7000 ] || die "at least 8 GB of RAM is needed; this machine has ${TOTAL_MB} MB."
if [ "${TOTAL_MB:-0}" -lt 15000 ]; then
  warn "below 16 GB the document parser (knowledge group) is the heaviest"
  warn "service on a CPU-only box. It remains available, but expect it to be slow."
fi

head2 "[6/15] GPU"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  say "  $(nvidia-smi -L | head -1)"
  say "  NOT USED IN THIS RELEASE. GPU support is a later version, and no GPU"
  say "  path in this build has been tested. Nothing here will touch it."
else
  say "  none detected — expected, and nothing in this release needs one."
fi

head2 "[7/15] Host listeners"
# THE ONE THING THE STACK CANNOT PROTECT YOU FROM, enumerated rather than
# glossed (F16).  A container reaches the host through its bridge gateway;
# denying that needs host firewall rules this release does not install.
say "  Sockets on this machine bound to a wildcard address:"
if command -v ss >/dev/null 2>&1; then
  ss -tulnH 2>/dev/null | awk '{print $1, $5}' \
    | grep -E '(\*|0\.0\.0\.0|\[::\]):[0-9]+$' \
    | sort -u | sed 's/^/    /' || say "    (none found)"
else
  warn "ss is not installed; cannot enumerate. Install iproute2 and re-run 'aistack doctor'."
fi
cat <<'EOF'

  READ THAT LIST.  Anything on it is reachable from inside a container on
  this machine.  This release makes NO claim that a container cannot reach
  it — blocking that needs host firewall rules, which this version does not
  install and does not require.  Bind those services narrowly if you care.
EOF

# ===========================================================================
# 8   ANSWERS
# ===========================================================================
head2 "[8/15] Configuration"
if [ "$MODE" = vps ]; then
  # Forced in step 0; still run through the same validators as any other answer.
  valid_hostname "${ANS[AISTACK_HOSTNAME]}" || die "invalid hostname ${ANS[AISTACK_HOSTNAME]}"
  valid_bind_addr "${ANS[AISTACK_BIND_ADDR]}" || die "invalid bind address ${ANS[AISTACK_BIND_ADDR]}"
  say "  VPS mode: serving ${ANS[AISTACK_HOSTNAME]} on ${ANS[AISTACK_BIND_ADDR]}"
else
  ask AISTACK_HOSTNAME    "Hostname to serve"        "aistack.localhost" valid_hostname
  ask AISTACK_BIND_ADDR   "Address to bind to"       "127.0.0.1"         valid_bind_addr
fi
ask AISTACK_ADMIN_EMAIL "Admin email (no mail is ever sent)" "admin@localhost"
ask AISTACK_TZ          "Timezone"                 "UTC"

# AN EXPLICIT EMPTY ANSWER IS AN ANSWER, AND STARTER *IS* THE EMPTY ONE.
#
# MEASURED (NOM-398, 2026-10-24).  On the isolated QA target an answer file
# containing `COMPOSE_PROFILES=` together with --non-interactive installed
# `knowledge` and 9 services.  `-z "${ANS[KEY]:-}"` cannot tell "the operator
# chose Starter" from "the operator said nothing", and Starter is the one
# selection in this installer whose correct value is the empty string.  So
# under that test the Starter fixture was not installable at all through an
# answer file, while interactive option 1 selected it fine -- and the
# noninteractive Starter -> AI Automation check could not be run.
#
# The test is therefore key PRESENCE, not emptiness.  A truly omitted key
# still gets the `knowledge` default; `COMPOSE_PROFILES=` now means Starter,
# exactly as option 1 does.  tests/profile-selection.sh extracts this block
# and drives both paths, including a reconstruction of the `:-` form that
# must still reproduce the bug.
if [ -z "${ANS[COMPOSE_PROFILES]+set}" ]; then
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    ANS[COMPOSE_PROFILES]="knowledge"
  else
    say ""
    say "  Profiles:"
    say "    1) Starter        8 containers — chat, automation, local models"
    say "    2) AI Automation  9 containers — adds document parsing (chat with your PDF)"
    say ""
    say "  There is no third option in this release. The agent tool gateway"
    say "  failed its pre-build security gate and is not shipped; see"
    say "  docs/security-faq.md. An installer screen for a deferred group is"
    say "  how a deferred group comes back, so there is not one."
    read -r -p "  Choose [2]: " choice
    case "${choice:-2}" in
      1) ANS[COMPOSE_PROFILES]="" ;;
      *) ANS[COMPOSE_PROFILES]="knowledge" ;;
    esac
    ask_optional_profiles
  fi
fi
# Every name is checked, whichever path set it: compose ignores an unknown
# profile name, so a typo in an answer file would install less than asked and
# say nothing.  [NOM-415]
check_profiles "${ANS[COMPOSE_PROFILES]}"
# SAY WHICH GROUP WAS SELECTED.  Starter is the empty profile list, so without
# this line a Starter install reports nothing at all about its own selection,
# which is how NOM-398 reached QA as "exit 0, wrong 9 services".
say "  Profiles: ${ANS[COMPOSE_PROFILES]:-(none selected -- this is Starter)}"

head2 "[9/15] Port availability"
# A PORT CONFLICT IS PER ADDRESS, NOT PER PORT.
#
# MEASURED (NOM-258, 2026-10-18).  The first version of this check grepped
# `ss` for the port on ANY address.  On the build host a reverse proxy held
# 192.168.100.52:80 while this stack's own caddy held 127.0.0.1:80 — the two
# coexisted for the entire build — and yet that check refused to install,
# because it looked at the port and never at the address being bound.  For
# the audience this stack is for that is the common case, not the edge: a
# router UI, a LAN reverse proxy or another compose stack on another
# interface's :80 produced a hard STOP for a conflict that does not exist.
#
# It also could not tell this stack's own caddy from a foreign process, so a
# re-install or an in-place upgrade hit the same wall with the same dead-end
# advice.  A real conflict is: the same address, or either side binding a
# wildcard (0.0.0.0, ::, *).
LISTENERS="$(ss -tlnH 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
CONFLICT="$(python3 - "${ANS[AISTACK_BIND_ADDR]}" "$LISTENERS" <<'PY'
import sys
want, listeners = sys.argv[1], sys.argv[2].split()
PORTS = {"80", "443"}

def split_hostport(a):
    # ss prints IPv6 as [::]:443 / [::1]:443 and IPv4 as 0.0.0.0:443.
    if a.startswith("["):
        host, _, port = a[1:].partition("]:")
    else:
        host, _, port = a.rpartition(":")
    return host, port

def wildcard(h):
    return h in ("0.0.0.0", "::", "*", "")

def same(a, b):
    # ::ffff:127.0.0.1 and 127.0.0.1 are the same socket address.
    return a.replace("::ffff:", "") == b.replace("::ffff:", "")

for a in listeners:
    host, port = split_hostport(a)
    if port in PORTS and (wildcard(host) or wildcard(want) or same(host, want)):
        print(f"  {port} is held on {host}")
PY
)"
if [ -n "$CONFLICT" ]; then
  say "$CONFLICT"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^aistack-caddy$'; then
    die "this stack is already running on this host — aistack-caddy holds the
port(s) above. That is not a conflict to resolve, it is an install to repeat:

    cd $ROOT && bin/aistack down     # keeps volumes and secrets
    ./install.sh                     # idempotent: existing secrets are reused

If the holder is NOT aistack-caddy, 'ss -tlnp' will name the process."
  fi
  die "port 80 and/or 443 is already in use on ${ANS[AISTACK_BIND_ADDR]}, the
address this install binds. 'ss -tlnp' will name the process.

A listener on a DIFFERENT address is fine and is not reported above. To put
this stack somewhere else, re-run and answer AISTACK_BIND_ADDR with a free
address."
fi
say "  80 and 443 free on ${ANS[AISTACK_BIND_ADDR]}"

# ===========================================================================
# 10  .env  — shown as a diff before it is written
# ===========================================================================
head2 "[10/15] Writing .env"
NEW_ENV="$(mktemp)"
cp .env.example "$NEW_ENV"
for k in AISTACK_HOSTNAME AISTACK_BIND_ADDR AISTACK_ADMIN_EMAIL AISTACK_TZ COMPOSE_PROFILES; do
  v="${ANS[$k]}"
  python3 - "$NEW_ENV" "$k" "$v" <<'PY'
import re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
pat = re.compile(rf"^{re.escape(key)}=.*$", re.M)
text = pat.sub(f"{key}={val}", text) if pat.search(text) else text + f"\n{key}={val}\n"
open(path, "w").write(text)
PY
done

# VPS keys.  In home mode they are REMOVED, so re-running as home on a machine
# that was once VPS goes back to the home configuration.
VPS_KEYS="AISTACK_MODE AISTACK_DOMAIN AISTACK_CADDYFILE AISTACK_CADDY_SITES AISTACK_AUTHELIA_CONFIG AISTACK_HOMEPAGE_SERVICES AISTACK_DASH_HOST AISTACK_CHAT_URL AISTACK_N8N_URL AISTACK_N8N_HOST AISTACK_N8N_WEBHOOK_URL AISTACK_ACME_CA AISTACK_ACME_ROOT_FILE AISTACK_ACME_CA_ROOT"
python3 - "$NEW_ENV" "$VPS_KEYS" "${VPS_ENV[@]+"${VPS_ENV[@]}"}" <<'PY'
import re, sys
path, keys, pairs = sys.argv[1], sys.argv[2].split(), sys.argv[3:]
text = open(path).read()
text = re.sub(r"\n*# VPS mode \(written by install\.sh.*\n", "\n", text)
for k in keys:
    text = re.sub(rf"^{k}=.*\n?", "", text, flags=re.M)
if pairs:
    text = text.rstrip("\n") + "\n\n# VPS mode (written by install.sh --mode vps; removed by a home-mode re-run)\n" + "\n".join(pairs) + "\n"
open(path, "w").write(text)
PY

if [ -f .env ]; then
  if diff -u .env "$NEW_ENV" > /tmp/env.diff 2>&1; then
    say "  .env is unchanged."
  else
    say "  .env would change:"
    # `head` closing the pipe SIGPIPEs grep; under pipefail that killed the installer
    # silently on any diff longer than 20 lines (home -> VPS re-run).  Display only.
    { grep -E '^[+-]' /tmp/env.diff | grep -vE '^[+-]{3}' | grep -viE 'password|secret|key' | sed 's/^/    /' | head -20; } || true
    cp .env ".env.$(date -u +%Y%m%dT%H%M%SZ).bak"
    say "  (previous .env backed up)"
    cp "$NEW_ENV" .env
  fi
else
  cp "$NEW_ENV" .env
  say "  .env created"
fi
rm -f "$NEW_ENV"
chmod 0600 .env

# ===========================================================================
# 11  SECRETS
# ===========================================================================
head2 "[11/15] Secrets"
bash scripts/gen-secrets.sh < /dev/null

# The database passwords are written into .env because Compose interpolates
# connection strings at render time.  Parsed from the one file that defines
# them, never regenerated here.
python3 - <<'PY'
import re
pw = {}
for line in open("secrets/app_db_passwords"):
    if "=" in line:
        k, v = line.strip().split("=", 1)
        pw[k] = v
text = open(".env").read()
for key, app in (("OPENWEBUI_DB_PASSWORD", "openwebui"),
                 ("LITELLM_DB_PASSWORD", "litellm"),
                 ("N8N_DB_PASSWORD", "n8n"),
                 ("LANGFUSE_DB_PASSWORD", "langfuse")):
    text = re.sub(rf"^{key}=.*$", f"{key}={pw[app]}", text, flags=re.M)
open(".env", "w").write(text)
PY
chmod 0600 .env

# ===========================================================================
# 12  OWNER BOOTSTRAP, PHASE 1 (S05)
# ===========================================================================
#
# PHASE 2 IS `aistack user reset owner`, AND IT IS NOT A SECOND-BEST OPTION.
# The web reset flow this message used to point at is DISABLED in
# config/authelia/configuration.yml -- `password_reset` needs SMTP and there is
# none in the MVP, and a self-service reset that cannot send mail is a dead end
# that looks like a feature.  The message below therefore names the command
# that exists, and `bin/aistack user` is that command.  [NOM-402]
#
# The block between the two markers is EXTRACTED AND RUN by
# tests/owner-bootstrap.sh, which drives the real phase 1 into a fixture root
# and then completes phase 2 against it.  Keep it self-contained: it may use
# `die`, `say`, `head2` and the repository root as its working directory, and
# nothing else from this file.
# AISTACK-OWNER-PHASE1:BEGIN
head2 "[12/15] Owner account (phase 1 of 2)"
if [ -f config/authelia/users.yml ]; then
  say "  users.yml already exists — left alone (an existing account is never reset)."
else
  source versions.env
  HASH="$(docker run --rm "${AUTHELIA_IMAGE}:${AUTHELIA_TAG}@${AUTHELIA_DIGEST}" \
    authelia crypto hash generate argon2 --random --random.length 32 --config /dev/null 2>/dev/null \
    | sed -n 's/^Digest: *//p')"
  [ -n "$HASH" ] || die "could not generate a password hash."
  python3 - "$HASH" <<'PY'
import sys
tmpl = open("config/authelia/users.yml.example").read()
open("config/authelia/users.yml", "w").write(
    tmpl.replace("__ARGON2_HASH_WRITTEN_BY_INSTALLER__", sys.argv[1]))
PY
  unset HASH
  say "  Owner account created with a random password, stored as an argon2id hash."
  say ""
  say "  THE PASSWORD WAS NOT PRINTED AND IS NOT RECOVERABLE — that is the point."
  say "  Phase 2 is one command, and you run it before your first login:"
  say ""
  say "      bin/aistack user reset owner"
  say ""
  say "  It asks for a password at a prompt, does not echo it, and stores it"
  say "  nowhere but as a hash in config/authelia/users.yml.  Then log in and"
  say "  enrol a second factor: Authelia asks for a one-time code, and"
  say "  'bin/aistack user code' is where that code appears, because there is"
  say "  no mail server here to send it to you."
  say ""
  say "  Until both halves are done, no protected route resolves."
  say ""
  say "  There is therefore no window in which an account exists that can"
  say "  open a service with a password this installer printed."
fi
# AISTACK-OWNER-PHASE1:END
bash scripts/gen-secrets.sh < /dev/null >/dev/null   # apply modes to users.yml

# ===========================================================================
# 13-15  PINS, PULL, START
# ===========================================================================
head2 "[13/15] Rendering pins"
bin/aistack pin

head2 "[14/15] Pulling images by digest"
say "  This is the slow part."
docker compose pull --quiet --ignore-buildable
head2 "[14b/15] Building the two local images (mem0, mcp-web)"
docker compose build --quiet

head2 "[15/15] Starting"
bin/aistack up || die "the stack did not become healthy. The failing service and its
last 50 redacted lines are above. 'bin/aistack support-bundle' collects a
shareable artefact; 'bin/aistack logs <service>' shows more."

# THE PER-APP LITELLM KEYS (NOM-413) ARE CHOSEN BY gen-secrets.sh BUT LITELLM
# ONLY LEARNS THEM HERE.  Until NOM-416 nothing called this, so on a fresh
# install Hermes, n8n, Open WebUI and Mem0 were all refused by LiteLLM (401)
# and no model or MCP tool answered.  Idempotent: a re-run updates in place.
say "  Registering one LiteLLM key per app (budget, models, MCP servers)."
bash scripts/litellm-keys.sh || die "could not register the per-app LiteLLM keys (above)."

if [ "$MODE" = vps ]; then
  bash scripts/vps-verify.sh --local || warn "scripts/vps-verify.sh reported problems (above)."
  cat <<EOF

────────────────────────────────────────────────────────────────────────────
 Installed (VPS mode).

   https://dash.${DOMAIN}/    dashboard        https://chat.${DOMAIN}/   Open WebUI
   https://n8n.${DOMAIN}/     n8n              https://auth.${DOMAIN}/   login

 Certificates: ${ACME_KIND}.
 Caddy requests them on first contact; allow a minute before the first visit.

 NOBODY CAN LOG IN UNTIL YOU DO THIS (the same two steps as home mode):

   bin/aistack user reset owner      # set your own password, at a prompt
   bin/aistack user code             # the one-time code enrolment asks for

 Run the first, open https://auth.${DOMAIN}/, log in, enrol a second factor,
 run the second when it asks.  Every app asks for that second factor.

 Then:  bin/aistack models pull qwen3.5:9b   (and qwen3.5:2b, bge-m3, nomic-embed-text)
        bin/aistack status ; bin/aistack doctor
        sudo scripts/vps-verify.sh      (firewall, SSH, and what answers without a login)

 Secrets are in ./secrets — paths only were printed, never values.
 COPY secrets/backup.key AND secrets/backup.hmac OFF THIS MACHINE.
────────────────────────────────────────────────────────────────────────────
EOF
  exit 0
fi

cat <<EOF

────────────────────────────────────────────────────────────────────────────
 Installed.

   https://${ANS[AISTACK_HOSTNAME]}/

 Your browser will warn about the certificate. That is expected: local mode
 uses an internal certificate authority, because a publicly trusted
 certificate would need a DNS record anyone can look up.

 PHASE 2 OF THE BOOTSTRAP IS STILL TO DO, and nobody can log in until it is:

   bin/aistack user reset owner      # set your own password, at a prompt
   bin/aistack user code             # the one-time code enrolment asks for

 Run the first, log in, enrol a second factor, run the second when it asks.

 Then:
   bin/aistack models pull qwen3.5:9b      # the `agent` model, ~6.6 GB, egress helper
   bin/aistack models pull qwen3.5:2b      # `local-chat`, ~2.7 GB
   bin/aistack models pull bge-m3          # `embed` (Arabic-capable), ~1.2 GB
   bin/aistack models pull nomic-embed-text   # `local-embed` (the samples), ~0.3 GB
   bin/aistack status
   bin/aistack doctor

 Secrets are in ./secrets — paths only were printed, never values.
 COPY secrets/backup.key AND secrets/backup.hmac OFF THIS MACHINE.
────────────────────────────────────────────────────────────────────────────
EOF
