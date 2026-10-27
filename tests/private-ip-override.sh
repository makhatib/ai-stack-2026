#!/usr/bin/env bash
# The VPS public-address gate and its test-only override (NOM-426).
#
# AISTACK_ALLOW_PRIVATE_IP=1 exists so the sandbox QA rig can install VPS mode
# on a private address against a private ACME CA (Pebble).  The founder's
# conditions: off by default, loud when on, and no behaviour change without
# it.  This test drives the SHIPPED vps_address_gate from scripts/vps-host.sh
# (sourced, not retyped) and checks all three, plus the refusal to pair the
# override with Let's Encrypt.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/vps-host.sh
. scripts/vps-host.sh
if ! declare -F vps_address_gate >/dev/null; then
  echo "private-ip override: CANNOT VERIFY — vps_address_gate is gone from scripts/vps-host.sh" >&2
  exit 2
fi
RC=0; N=0
PEBBLE=https://172.31.219.2:14000/dir
LE=https://acme-v02.api.letsencrypt.org/directory
LE_STAGING=https://acme-staging-v02.api.letsencrypt.org/directory

# case <name> <override value or -> <ip> <acme-ca> <expect rc> <expect banner: yes|no>
case_() {
  local name="$1" ov="$2" ip="$3" ca="$4" want="$5" wantb="$6" err got banner
  if [ "$ov" = - ]; then
    err="$(unset AISTACK_ALLOW_PRIVATE_IP; vps_address_gate "$ip" "$ca" 2>&1 >/dev/null)"; got=$?
  else
    err="$(export AISTACK_ALLOW_PRIVATE_IP="$ov"; vps_address_gate "$ip" "$ca" 2>&1 >/dev/null)"; got=$?
  fi
  case "$err" in *"TEST-ONLY OVERRIDE"*) banner=yes ;; *) banner=no ;; esac
  N=$((N+1))
  if [ "$got" = "$want" ] && [ "$banner" = "$wantb" ]; then
    printf '  [ ok ] %-58s rc=%s banner=%s\n' "$name" "$got" "$banner"
  else
    printf '  [FAIL] %-58s expected rc=%s banner=%s, got rc=%s banner=%s\n' "$name" "$want" "$wantb" "$got" "$banner"
    RC=1
  fi
}

echo "private-ip override (vps_address_gate from scripts/vps-host.sh)"
echo
echo "Without the override (default behaviour, unchanged):"
case_ "unset, public IP, LE production"            -  8.8.8.8     "$LE"         0 no
case_ "unset, private 172.17/12, LE staging"       -  172.17.0.5  "$LE_STAGING" 1 no
case_ "unset, private 192.168/16, custom CA"       -  192.168.1.5 "$PEBBLE"     1 no
case_ "unset, CGNAT 100.64/10"                     -  100.64.1.1  "$LE"         1 no
case_ "=0, private IP"                             0  172.17.0.5  "$PEBBLE"     1 no
case_ "=true (not exactly 1), private IP"          true 172.17.0.5 "$PEBBLE"    1 no
case_ "=yes (not exactly 1), private IP"           yes 172.17.0.5 "$PEBBLE"     1 no
case_ "empty value, private IP"                    "" 172.17.0.5  "$PEBBLE"     1 no
echo
echo "With AISTACK_ALLOW_PRIVATE_IP=1:"
case_ "private IP, Pebble URL"                     1  172.31.219.10 "$PEBBLE"   0 yes
case_ "private IP, LE production refused"          1  172.31.219.10 "$LE"       2 yes
case_ "private IP, LE staging URL refused"         1  172.31.219.10 "$LE_STAGING" 2 yes
case_ "private IP, 'staging' keyword refused"      1  172.31.219.10 staging     2 yes
case_ "private IP, no --acme-ca refused"           1  172.31.219.10 ""          2 yes
case_ "public IP, still warns, still needs custom CA" 1 8.8.8.8   "$LE"         2 yes

echo
printf 'cases: %s   failed: %s\n' "$N" "$( [ "$RC" = 0 ] && echo 0 || echo some)"
[ "$N" -ge 14 ] || { echo "CANNOT VERIFY — fewer than 14 cases ran" >&2; exit 2; }
exit "$RC"
