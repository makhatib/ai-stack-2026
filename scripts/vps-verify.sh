#!/usr/bin/env bash
# AI Stack 2026 — VPS mode verifier (NOM-414).
#
#   sudo scripts/vps-verify.sh --local           on the VPS: firewall, SSH, published
#                                                ports, listeners, and what every app
#                                                subdomain answers WITHOUT a login
#   scripts/vps-verify.sh --remote HOST          from ANOTHER machine: a TCP connect
#                                                scan of all 65535 ports; open ports must
#                                                be exactly 22, 80 and 443
#
# DETECTIVE, NOT PREVENTIVE.  It reports what is, by asking the running system
# and, for the network claims, by asking from the OUTSIDE: `ufw status` says what
# ufw intends, and Docker's published ports bypass ufw, so the scan is the proof.
#
# IT COUNTS WHAT IT LOOKED AT.  Exit 0 = every check ran and passed.  Exit 1 =
# a check failed.  Exit 2 = a check could not run (missing tool, no ufw, no
# stack): that property was NOT measured, which is neither a pass nor a fail.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  [ ok ] %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  [skip] %s  (NOT MEASURED)\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
envval() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2-; }

ALLOWED_PORTS="22 80 443"

# ---------------------------------------------------------------------------
remote_scan() {
  local host="$1"
  hdr "Port scan of $host (TCP connect, ports 1-65535)"
  local out
  out="$(python3 - "$host" "${AISTACK_SCAN_TIMEOUT:-1.5}" <<'PY'
import asyncio, sys
host, timeout = sys.argv[1], float(sys.argv[2])
open_ports = []
sem = asyncio.Semaphore(1500)
async def probe(p):
    async with sem:
        try:
            r, w = await asyncio.wait_for(asyncio.open_connection(host, p), timeout)
            w.close()
            open_ports.append(p)
        except Exception:
            pass
async def main():
    await asyncio.gather(*(probe(p) for p in range(1, 65536)))
asyncio.run(main())
print(" ".join(map(str, sorted(open_ports))))
PY
)" || { skip "port scan could not run"; return; }
  printf '  open: %s\n' "${out:-(none)}"
  local extra="" p
  for p in $out; do case " $ALLOWED_PORTS " in *" $p "*) ;; *) extra="$extra $p" ;; esac; done
  [ -z "$extra" ] && ok "only ${out:-nothing} answered; nothing outside 22/80/443" || bad "unexpected open ports:$extra"
  case " $out " in *" 443 "*) ok "443 answers" ;; *) bad "443 does not answer" ;; esac
  case " $out " in *" 22 "*) ok "22 answers (SSH, key-only — see the sshd check on the host)" ;; *) ok "22 does not answer" ;; esac
}

# ---------------------------------------------------------------------------
local_checks() {
  [ -f .env ] || { skip "no .env here: is this the stack's directory?"; return; }
  local mode domain ip cacert
  mode="$(envval AISTACK_MODE)"
  if [ "$mode" != vps ]; then skip "AISTACK_MODE is '${mode:-home}', not vps: nothing to verify here"; return; fi
  domain="$(envval AISTACK_DOMAIN)"; ip="$(envval AISTACK_BIND_ADDR)"
  [ -n "$domain" ] && [ -n "$ip" ] || { bad ".env has no AISTACK_DOMAIN / AISTACK_BIND_ADDR"; return; }

  hdr "Firewall"
  if command -v ufw >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    local v; v="$(ufw status verbose 2>/dev/null)"
    grep -q '^Status: active' <<<"$v" && ok "ufw is active" || bad "ufw is NOT active"
    grep -q 'Default: deny (incoming)' <<<"$v" && ok "default incoming: deny" || bad "default incoming is not deny"
    local extra
    extra="$(ufw status | awk 'NR>4 && /ALLOW/ && $0 !~ /\(v6\)/ {print $1}' | grep -v '^Anywhere' | sed 's#/tcp##;s#/udp##' | sort -u | grep -vxE '22|80|443' || true)"
    [ -z "$extra" ] && ok "ufw allows only 22, 80, 443" || bad "ufw allows other ports: $(echo "$extra" | tr '\n' ' ')"
  else skip "ufw status (needs root and ufw)"; fi

  hdr "SSH"
  if command -v sshd >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    local t; t="$(sshd -T 2>/dev/null)"
    grep -qi '^passwordauthentication no$' <<<"$t" && ok "sshd: PasswordAuthentication no" || bad "sshd: PasswordAuthentication is not no"
    grep -qi '^kbdinteractiveauthentication no$' <<<"$t" && ok "sshd: KbdInteractiveAuthentication no" || bad "sshd: KbdInteractiveAuthentication is not no"
    grep -qi '^pubkeyauthentication yes$' <<<"$t" && ok "sshd: PubkeyAuthentication yes" || bad "sshd: PubkeyAuthentication is not yes"
  else skip "sshd -T (needs root and sshd)"; fi

  hdr "Published ports and listeners"
  if docker info >/dev/null 2>&1; then
    local pub bad_pub
    pub="$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E '(->)' || true)"
    bad_pub="$(printf '%s\n' "$pub" | grep -oE '[0-9a-f.:\[\]*]+:[0-9]+->' | sed -E 's/->$//' | awk -F: '{print $NF}' | sort -u | grep -vxE '80|443' || true)"
    [ -z "$bad_pub" ] && ok "Docker publishes only 80 and 443 ($(printf '%s\n' "$pub" | grep -c .) containers with a published port)" \
                      || bad "Docker publishes other host ports: $(echo "$bad_pub" | tr '\n' ' ')"
    printf '%s\n' "$pub" | grep -qE '(^|[ ,])(0\.0\.0\.0|\[::\]|:::)' && bad "a published port is bound to a WILDCARD address" || ok "no published port is bound to a wildcard address"
  else skip "docker ps (docker not answering)"; fi
  if command -v ss >/dev/null 2>&1; then
    local lst
    lst="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|::1)' | awk -F: '{print $NF}' | sort -un | grep -vxE '22|80|443' || true)"
    [ -z "$lst" ] && ok "no TCP listener on a non-loopback address other than 22/80/443" \
                  || bad "other TCP listeners on non-loopback addresses: $(echo "$lst" | tr '\n' ' ')"
  else skip "ss (iproute2 missing)"; fi

  hdr "What answers without a login (https, name pinned to $ip)"
  if ! command -v curl >/dev/null 2>&1; then skip "curl missing"; return; fi
  local cacert_args=() cafile; cafile="$(envval AISTACK_ACME_ROOT_FILE)"
  if [ -n "$cafile" ]; then cacert_args=(--cacert "$cafile"); fi
  local name url code loc
  for name in chat dash n8n; do
    url="https://$name.$domain"
    read -r code loc < <(curl -sS -o /dev/null --max-time 15 --resolve "$name.$domain:443:$ip" "${cacert_args[@]}" \
                         -w '%{http_code} %{redirect_url}\n' "$url/" 2>&1 | tail -1)
    case "$code" in
      302|303|401|403)
        case "$loc" in
          "https://auth.$domain/"*|"") ok "$name.$domain / -> $code ${loc:+to auth.$domain}" ;;
          *) bad "$name.$domain / redirects somewhere other than auth.$domain: $loc" ;;
        esac ;;
      000|"") bad "$name.$domain: no HTTPS answer (certificate or connection problem)" ;;
      *) bad "$name.$domain / answered $code WITHOUT a login" ;;
    esac
  done
  # A deep path and an API path must not be the exception.
  for path in chat:/api/v1/auths/ chat:/api/config n8n:/rest/settings n8n:/webhook-test/x dash:/api/services; do
    name="${path%%:*}"; path="${path#*:}"
    read -r code loc < <(curl -sS -o /dev/null --max-time 15 --resolve "$name.$domain:443:$ip" "${cacert_args[@]}" \
                         -w '%{http_code} %{redirect_url}\n' "https://$name.$domain$path" 2>&1 | tail -1)
    case "$code" in 302|303|401|403) ok "$name.$domain$path -> $code" ;; *) bad "$name.$domain$path answered $code WITHOUT a login" ;; esac
  done
  # The portal itself is reachable (it has to be), the forward-auth endpoint is not.
  code="$(curl -sS -o /dev/null --max-time 15 --resolve "auth.$domain:443:$ip" "${cacert_args[@]}" -w '%{http_code}' "https://auth.$domain/" 2>/dev/null)"
  [ "$code" = 200 ] && ok "auth.$domain / -> 200 (the login portal)" || bad "auth.$domain / answered '$code', expected the portal (200)"
  code="$(curl -sS -o /dev/null --max-time 15 --resolve "auth.$domain:443:$ip" "${cacert_args[@]}" -w '%{http_code}' "https://auth.$domain/api/authz/forward-auth" 2>/dev/null)"
  [ "$code" = 404 ] && ok "auth.$domain/api/authz/forward-auth -> 404 (not exposed)" || bad "auth.$domain/api/authz/forward-auth answered '$code', expected 404"
  # The one documented exception: n8n webhooks.  n8n answers (404 for an
  # unknown path), not Authelia.
  code="$(curl -sS -o /dev/null --max-time 15 --resolve "n8n.$domain:443:$ip" "${cacert_args[@]}" -w '%{http_code}' "https://n8n.$domain/webhook/does-not-exist" 2>/dev/null)"
  [ "$code" = 404 ] && ok "n8n.$domain/webhook/* reaches n8n without a session (documented exception; n8n answers 404 for an unknown path)" \
                    || bad "n8n.$domain/webhook/does-not-exist answered '$code', expected n8n's 404"
  # A request for a name we do not serve, by IP, gets no content.
  code="$(curl -sS -k -o /dev/null --max-time 10 "https://$ip/" -w '%{http_code}' 2>/dev/null || true)"
  case "$code" in 000|"") ok "https://$ip/ (no server name) gives no content" ;; *) bad "https://$ip/ with no server name answered $code" ;; esac

  hdr "Certificates"
  local issuer
  for name in "$domain" dash.$domain chat.$domain n8n.$domain auth.$domain; do
    issuer="$(echo | timeout 10 openssl s_client -connect "$ip:443" -servername "$name" 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null | tr '\n' ' ')"
    if [ -n "$issuer" ] && ! grep -qi 'Caddy Local Authority' <<<"$issuer"; then ok "$name: $issuer"
    elif [ -n "$issuer" ]; then bad "$name has a Caddy LOCAL (self-made) certificate, not one from an ACME CA: $issuer"
    else bad "$name: no certificate served (ACME has not issued yet, or failed: bin/aistack logs caddy)"; fi
  done
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  --local)  hdr "VPS mode check (on this machine)"; local_checks ;;
  --remote) [ -n "${2:-}" ] || { echo "usage: $0 --remote HOST" >&2; exit 2; }; remote_scan "$2" ;;
  *) echo "usage: $0 --local | --remote HOST" >&2; exit 2 ;;
esac

printf '\nvps-verify: %s passed, %s failed, %s not measured.\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -gt 0 ] && exit 1
[ "$PASS" -eq 0 ] && { echo "vps-verify: nothing was examined."; exit 2; }
[ "$SKIP" -gt 0 ] && exit 2
exit 0
