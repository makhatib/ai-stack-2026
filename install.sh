#!/usr/bin/env bash
# AI Stack 2026 — installer.
#
# A CLI WIZARD IN BASH.  Not a web wizard: that needs an HTTP listener before
# any authentication exists, which is the original stack's single worst
# failure class.  Not a TUI: a host dependency that breaks over non-TTY SSH
# and cannot be driven in CI.
#
#   ./install.sh                              interactive
#   ./install.sh --non-interactive --answers answers.conf
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

while [ $# -gt 0 ]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --answers) ANSWERS="${2:?--answers needs a file}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "install: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

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

[ -n "$ANSWERS" ] && parse_answers "$ANSWERS"

say ""
say "AI Stack 2026 — installer"
say "9 containers. Chat, documents, local models and workflow automation."
say ""

# ===========================================================================
# 1-6  PRE-FLIGHT.  Every failure here is a HARD STOP with the reason, not a
#      warning the installer continues past (H1, S02, S14, H4).
# ===========================================================================
head2 "[1/14] Docker"
command -v docker >/dev/null || die "docker is not installed."
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon. Is it running, and are you in the docker group?"
say "  $(docker --version)"

head2 "[2/14] Compose v2"
docker compose version >/dev/null 2>&1 || die "the Docker Compose v2 plugin is not installed."
say "  $(docker compose version | head -1)"

head2 "[3/14] Disk"
AVAIL_GB=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc '0-9')
say "  ${AVAIL_GB} GB available at $ROOT"
[ "${AVAIL_GB:-0}" -ge 40 ] || die "at least 40 GB free is needed; ${AVAIL_GB} GB available.
Model weights alone are tens of gigabytes. Free some space and re-run."
[ "${AVAIL_GB:-0}" -ge 60 ] || warn "60 GB is the Starter recommendation; you have ${AVAIL_GB} GB."

head2 "[4/14] Memory"
TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
say "  ${TOTAL_MB} MB total"
[ "${TOTAL_MB:-0}" -ge 7000 ] || die "at least 8 GB of RAM is needed; this machine has ${TOTAL_MB} MB."
if [ "${TOTAL_MB:-0}" -lt 15000 ]; then
  warn "below 16 GB the document parser (knowledge group) is the heaviest"
  warn "service on a CPU-only box. It remains available, but expect it to be slow."
fi

head2 "[5/14] GPU"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  say "  $(nvidia-smi -L | head -1)"
  say "  NOT USED IN THIS RELEASE. GPU support is a later version, and no GPU"
  say "  path in this build has been tested. Nothing here will touch it."
else
  say "  none detected — expected, and nothing in this release needs one."
fi

head2 "[6/14] Host listeners"
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
# 7   ANSWERS
# ===========================================================================
head2 "[7/14] Configuration"
ask AISTACK_HOSTNAME    "Hostname to serve"        "aistack.localhost" valid_hostname
ask AISTACK_BIND_ADDR   "Address to bind to"       "127.0.0.1"         valid_bind_addr
ask AISTACK_ADMIN_EMAIL "Admin email (no mail is ever sent)" "admin@localhost"
ask AISTACK_TZ          "Timezone"                 "UTC"

if [ -z "${ANS[COMPOSE_PROFILES]:-}" ]; then
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
  fi
fi

head2 "[8/14] Port availability"
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
# 9   .env  — shown as a diff before it is written
# ===========================================================================
head2 "[9/14] Writing .env"
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

if [ -f .env ]; then
  if diff -u .env "$NEW_ENV" > /tmp/env.diff 2>&1; then
    say "  .env is unchanged."
  else
    say "  .env would change:"
    grep -E '^[+-]' /tmp/env.diff | grep -vE '^[+-]{3}' | grep -viE 'password|secret|key' | sed 's/^/    /' | head -20
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
# 10  SECRETS
# ===========================================================================
head2 "[10/14] Secrets"
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
                 ("N8N_DB_PASSWORD", "n8n")):
    text = re.sub(rf"^{key}=.*$", f"{key}={pw[app]}", text, flags=re.M)
open(".env", "w").write(text)
PY
chmod 0600 .env

# ===========================================================================
# 11  OWNER BOOTSTRAP, PHASE 1 (S05)
# ===========================================================================
head2 "[11/14] Owner account (phase 1 of 2)"
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
  say "  Phase 2 is your first login: open the stack, use the reset flow, set"
  say "  your own password and enrol a second factor. Until you do, no"
  say "  protected route resolves."
  say ""
  say "  There is therefore no window in which an account exists that can"
  say "  reach a service with a password this installer printed."
fi
bash scripts/gen-secrets.sh < /dev/null >/dev/null   # apply modes to users.yml

# ===========================================================================
# 12-14  PINS, PULL, START
# ===========================================================================
head2 "[12/14] Rendering pins"
bin/aistack pin

head2 "[13/14] Pulling images by digest"
say "  Nine images. This is the slow part."
docker compose pull --quiet

head2 "[14/14] Starting"
bin/aistack up || die "the stack did not become healthy. The failing service and its
last 50 redacted lines are above. 'bin/aistack support-bundle' collects a
shareable artefact; 'bin/aistack logs <service>' shows more."

cat <<EOF

────────────────────────────────────────────────────────────────────────────
 Installed.

   https://${ANS[AISTACK_HOSTNAME]}/

 Your browser will warn about the certificate. That is expected: local mode
 uses an internal certificate authority, because a publicly trusted
 certificate would need a DNS record anyone can look up.

 FIRST LOGIN IS PHASE 2 OF THE BOOTSTRAP. Use the reset flow, set your own
 password, enrol a second factor.

 Then:
   bin/aistack models pull llama3.2:3b     # ~2 GB, through the egress helper
   bin/aistack status
   bin/aistack doctor

 Secrets are in ./secrets — paths only were printed, never values.
 COPY secrets/backup.key AND secrets/backup.hmac OFF THIS MACHINE.
────────────────────────────────────────────────────────────────────────────
EOF
