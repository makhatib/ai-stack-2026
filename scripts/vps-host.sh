# AI Stack 2026 — VPS host preparation (NOM-414).  SOURCED by install.sh, never
# executed.  Paths that a test would need to redirect are variables.
#
# Each function does ONE thing to the host, prints what it did, and returns
# non-zero (never exits) when it cannot.  install.sh decides what a failure
# means.  Nothing here prints a credential: there is none to print.
#
# Rollback for the whole file is in docs/vps-mode.md ("Undo").

# Paths are variables so a test can point them at a scratch directory.
VPS_SSHD_DROPIN="${VPS_SSHD_DROPIN:-/etc/ssh/sshd_config.d/00-aistack-keyonly.conf}"
VPS_OS_RELEASE="${VPS_OS_RELEASE:-/etc/os-release}"
VPS_APPS="${VPS_APPS:-dash chat n8n auth}"   # one subdomain per app, plus the bare domain

vps_say()  { printf '  %s\n' "$*"; }
vps_warn() { printf '  ! %s\n' "$*"; }

# --- pins ------------------------------------------------------------------
# config/vps-pins.env holds the Docker and Tailscale package versions this
# release was tested with.  A package manager that "just installs docker" gets
# whatever is newest today, which is not what was tested.
vps_load_pins() {
  [ -f "$ROOT/config/vps-pins.env" ] || { vps_warn "config/vps-pins.env is missing"; return 1; }
  # shellcheck disable=SC1091
  . "$ROOT/config/vps-pins.env"
  : "${DOCKER_CE_VERSION:?}" "${DOCKER_COMPOSE_PLUGIN_VERSION:?}" "${CONTAINERD_VERSION:?}" "${TAILSCALE_VERSION:?}"
}

# --- checks (read-only) ----------------------------------------------------
vps_check_os() {
  local id ver
  id="$(. "$VPS_OS_RELEASE" 2>/dev/null; echo "${ID:-}")"
  ver="$(. "$VPS_OS_RELEASE" 2>/dev/null; echo "${VERSION_ID:-}")"
  if [ "$id" != ubuntu ] || [ "$ver" != "24.04" ]; then
    vps_warn "VPS mode is tested on Ubuntu 24.04 only; this is ${id:-unknown} ${ver:-?}."
    return 1
  fi
  vps_say "Ubuntu 24.04"
}

# A domain, not an IP, not a wildcard, not a bare label.  Lowercase letters,
# digits and hyphens; at least one dot; each label 1-63 chars.
vps_valid_domain() {
  local d="$1" label
  [ -n "$d" ] && [ "${#d}" -le 200 ] || return 1
  [[ "$d" == *.* ]] || return 1
  [[ "$d" =~ ^[0-9.]+$ ]] && return 1           # an IPv4 address is not a domain
  local IFS=.
  for label in $d; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  done
  return 0
}

# The address this machine reaches the internet from.  Caddy binds to it
# (never a wildcard — I2), and DNS must point at it.
vps_public_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [ -n "$ip" ] && printf '%s' "$ip"
}

# 10/8, 172.16/12, 192.168/16, 100.64/10 (CGNAT), 127/8, 169.254/16.
vps_is_private_ip() {
  python3 - "$1" <<'PY'
import ipaddress, sys
a = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if (a.is_private or a.is_loopback or a.is_link_local or a in ipaddress.ip_network("100.64.0.0/10")) else 1)
PY
}

# Every app name must resolve to THIS machine before Caddy asks for a
# certificate.  A wrong record costs a failed HTTP-01 attempt each time and the
# CA rate-limits repeated failures, so this is checked first and stops the
# install with the exact records to create.
vps_check_dns() {
  local domain="$1" ip="$2" bad=0 name got a
  for name in "$domain" $(for a in $VPS_APPS; do printf '%s.%s ' "$a" "$domain"; done); do
    got="$(python3 - "$name" <<'PY'
import socket, sys
try:
    print(" ".join(sorted({r[4][0] for r in socket.getaddrinfo(sys.argv[1], 80, socket.AF_INET, socket.SOCK_STREAM)})))
except OSError:
    pass
PY
)"
    if [ "$got" = "$ip" ]; then vps_say "$name -> $ip"
    else vps_warn "$name resolves to '${got:-nothing}', expected $ip"; bad=1; fi
  done
  return "$bad"
}

vps_dns_instructions() {
  local domain="$1" ip="$2" a
  printf '\n  Create these DNS records at your DNS provider (type A, any TTL), wait for\n'
  printf '  them to resolve, then run the same command again:\n\n'
  printf '    %-24s A  %s\n' "$domain" "$ip"
  for a in $VPS_APPS; do printf '    %-24s A  %s\n' "$a.$domain" "$ip"; done
  printf '\n  Do not create AAAA records unless this machine serves IPv6: the certificate\n'
  printf '  authority would try IPv6 first.  A wildcard record (*.%s) also works.\n' "$domain"
}

# The invoking user's SSH keys.  Disabling password login on a machine whose
# only way in is a password locks the owner out for good, so this gate runs
# BEFORE anything is changed.
vps_have_ssh_key() {
  local user home
  user="${SUDO_USER:-$(id -un)}"
  home="$(getent passwd "$user" | cut -d: -f6)"
  [ -n "$home" ] && [ -s "$home/.ssh/authorized_keys" ] \
    && grep -v '^[[:space:]]*#' "$home/.ssh/authorized_keys" \
       | grep -Eq '(^|[ ,])(ssh-(ed25519|rsa)|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) '
}

vps_ssh_key_instructions() {
  printf '\n  This machine has no SSH public key for the user running the installer, and\n'
  printf '  VPS mode turns password login for SSH OFF.  Doing that now would lock you\n'
  printf '  out.  Nothing has been changed.\n\n'
  printf '  Add your key first.  On YOUR computer:\n\n'
  printf '      ssh-copy-id root@<this-server-ip>     # or add the key in your host panel\n\n'
  printf '  Then confirm that a NEW terminal logs in without a password, and re-run.\n'
}

# --- changes ---------------------------------------------------------------
vps_install_packages() {
  vps_say "apt: base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || return 1
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl gnupg python3 openssl ufw iproute2 zstd tar util-linux \
    diffutils coreutils gawk sed grep openssh-server >/dev/null || return 1
}

vps_docker_ok() { docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }

vps_install_docker() {
  if vps_docker_ok; then vps_say "Docker already present: $(docker --version)"; return 0; fi
  vps_load_pins || return 1
  vps_say "installing Docker CE $DOCKER_CE_VERSION from download.docker.com"
  export DEBIAN_FRONTEND=noninteractive
  install -m0755 -d /etc/apt/keyrings
  curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || return 1
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable\n' \
    "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq || return 1
  apt-get install -y -qq \
    "docker-ce=$DOCKER_CE_VERSION" "docker-ce-cli=$DOCKER_CE_VERSION" \
    "containerd.io=$CONTAINERD_VERSION" "docker-compose-plugin=$DOCKER_COMPOSE_PLUGIN_VERSION" >/dev/null || return 1
  apt-mark hold docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
  systemctl enable --now docker >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
  vps_docker_ok || return 1
  vps_say "$(docker --version); $(docker compose version | head -1)"
}

# SSH: keys only.  A drop-in named 00-* is read FIRST, and sshd keeps the first
# value it sees for a keyword, so this wins over cloud-init's
# 50-cloud-init.conf (which sets PasswordAuthentication yes on many images).
vps_ssh_keyonly() {
  mkdir -p "$(dirname "$VPS_SSHD_DROPIN")"
  printf '%s\n' \
    '# Written by AI Stack 2026 install.sh --mode vps.  Remove this file and' \
    '# `systemctl reload ssh` to undo.' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin prohibit-password' \
    'PubkeyAuthentication yes' \
    'AuthenticationMethods publickey' > "$VPS_SSHD_DROPIN"
  chmod 0644 "$VPS_SSHD_DROPIN"
  if ! sshd -t 2>/dev/null; then
    rm -f "$VPS_SSHD_DROPIN"; vps_warn "sshd rejected the new configuration; removed it."; return 1
  fi
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true
  vps_ssh_effective
}

# What sshd will actually do, asked of sshd and not of the file we wrote.
vps_ssh_effective() {
  local t; t="$(sshd -T 2>/dev/null)" || return 1
  if grep -qi '^passwordauthentication no$' <<<"$t" \
     && grep -qi '^kbdinteractiveauthentication no$' <<<"$t" \
     && grep -qi '^pubkeyauthentication yes$' <<<"$t"; then
    vps_say "sshd: password login off, key login on (sshd -T)"; return 0
  fi
  vps_warn "sshd -T does not show key-only login:"
  grep -iE '^(passwordauth|kbdinteractive|pubkeyauth|authenticationmethods)' <<<"$t" | sed 's/^/      /'
  return 1
}

# Ports sshd listens on, so the firewall rule matches the daemon.
vps_ssh_ports() {
  sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' '
}

# Firewall: default deny in, allow 22/80/443 tcp.  ufw's rules are added BEFORE
# `ufw enable`, so an SSH session survives it.
#
# NOTE ON DOCKER.  Published container ports are DNAT'd in the nat table and
# traverse FORWARD, which ufw's INPUT rules do not govern; a `ports:` entry
# bypasses ufw entirely.  That is why this stack publishes exactly two ports
# (caddy 80/443, invariant I2) and why `scripts/vps-verify.sh` checks the
# result from OUTSIDE rather than trusting `ufw status`.
vps_firewall() {
  local ports p extra
  ports="$(vps_ssh_ports)"; : "${ports:=22}"
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    # Someone already runs ufw.  Anything beyond our allow-list is a port the
    # "nothing else open" claim would be false about, so stop and say which.
    extra="$(ufw status | awk 'NR>4 && /ALLOW/ {print $1}' | sed 's#/tcp##;s#/udp##' | sort -u | grep -vxE '22|80|443' || true)"
    if [ -n "$extra" ]; then
      vps_warn "ufw is already active and allows other ports: $(echo "$extra" | tr '\n' ' ')"
      vps_warn "VPS mode promises only 22, 80 and 443.  Remove them (ufw delete allow <port>) and re-run."
      return 1
    fi
  fi
  ufw --force reset >/dev/null 2>&1 || return 1
  ufw default deny incoming >/dev/null || return 1
  ufw default allow outgoing >/dev/null || return 1
  for p in $ports; do ufw allow "$p/tcp" comment 'ssh' >/dev/null || return 1; done
  ufw allow 80/tcp comment 'http (ACME + redirect)' >/dev/null || return 1
  ufw allow 443/tcp comment 'https' >/dev/null || return 1
  if [ "${VPS_TAILSCALE:-0}" = 1 ]; then
    ufw allow in on tailscale0 comment 'tailscale admin' >/dev/null || return 1
  fi
  ufw --force enable >/dev/null || return 1
  vps_say "ufw: default deny incoming; allow ${ports}/tcp, 80/tcp, 443/tcp"
}

# Tailscale for ADMIN access (OFF unless --tailscale).  Installs the pinned
# package and opens the tailscale0 interface; joining a tailnet needs the
# owner's login, so that step is left as the printed command.
vps_tailscale() {
  vps_load_pins || return 1
  vps_say "installing Tailscale $TAILSCALE_VERSION"
  export DEBIAN_FRONTEND=noninteractive
  curl -fsSL --retry 3 https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg || return 1
  curl -fsSL --retry 3 https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list || return 1
  apt-get update -qq || return 1
  apt-get install -y -qq "tailscale=$TAILSCALE_VERSION" >/dev/null || return 1
  apt-mark hold tailscale >/dev/null
  systemctl enable --now tailscaled >/dev/null 2>&1 || true
  vps_say "Tailscale installed.  Join your tailnet yourself:   sudo tailscale up"
  vps_say "Public port 22 stays open until you close it yourself (docs/vps-mode.md)."
}
