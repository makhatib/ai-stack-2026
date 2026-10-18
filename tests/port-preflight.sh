#!/usr/bin/env bash
# The port pre-flight, unit-tested against synthetic listener tables.
#
# WHY THIS TEST EXISTS.  The first version of install.sh's step 8 grepped `ss`
# for the port on ANY address, and refused to install on a host where
# 192.168.100.52:80 was held while this stack binds 127.0.0.1:80 — two
# listeners that coexisted on the build host for the whole build.  A bug about
# addresses needs cases with addresses in them, which is something no amount
# of running the installer on one host can give you.
#
# IT EXTRACTS THE SHIPPED CODE RATHER THAN RE-IMPLEMENTING IT.  A retyped copy
# of the matcher would keep passing after install.sh drifted away from it,
# which is the failure mode of every "unit test" of a shell script.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
RC=0
PY="$(mktemp)"; trap 'rm -f "$PY"' EXIT

sed -n "/^CONFLICT=\"\$(python3 - /,/^PY\$/p" install.sh | sed '1d;$d' > "$PY"
if [ ! -s "$PY" ]; then
  echo "port pre-flight: CANNOT VERIFY — the matcher could not be extracted" >&2
  echo "from install.sh. If step 8 was restructured, update this test." >&2
  exit 2
fi
printf 'port pre-flight (%s lines extracted from install.sh)\n\n' "$(wc -l < "$PY")"

# case <name> <bind-addr> <listeners> <expect: conflict|free>
case_() {
  local name="$1" bind="$2" listeners="$3" expect="$4" out got
  out="$(python3 "$PY" "$bind" "$listeners" 2>&1)"
  if [ -n "$out" ]; then got=conflict; else got=free; fi
  if [ "$got" = "$expect" ]; then
    printf '  [ ok ] %-52s %s\n' "$name" "$got"
  else
    printf '  [FAIL] %-52s expected %s, got %s\n' "$name" "$expect" "$got"
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/           /'
    RC=1
  fi
}

# THE REGRESSION. This is the real listener table of the build host.
case_ "other interface holds :80, we bind loopback" \
      127.0.0.2 "127.0.0.1:80 127.0.0.1:443 192.168.100.52:80" free
case_ "LAN proxy on :80, we bind a different LAN address" \
      192.168.100.60 "192.168.100.52:80" free
case_ "IPv6 loopback holds :443, we bind an IPv4 LAN address" \
      192.168.100.52 "[::1]:443" free
case_ "nothing listening at all" \
      127.0.0.1 "" free
case_ "a port we do not use is busy" \
      127.0.0.1 "127.0.0.1:8080 127.0.0.1:53" free

# AND IT MUST STILL CATCH A REAL CONFLICT. A check that only ever says "free"
# is not a fixed check, it is a deleted one.
case_ "exactly our address and port" \
      127.0.0.1 "127.0.0.1:80" conflict
case_ "IPv4 wildcard holds the port" \
      127.0.0.1 "0.0.0.0:443" conflict
case_ "IPv6 wildcard holds the port" \
      127.0.0.1 "[::]:80" conflict
case_ "'*' wildcard form" \
      10.0.0.5 "*:443" conflict
case_ "we bind the wildcard, someone holds one address" \
      0.0.0.0 "192.168.100.52:80" conflict
case_ "v4-mapped form of our own address" \
      127.0.0.1 "[::ffff:127.0.0.1]:443" conflict

# And against the live table, where the answer is knowable independently:
# this host runs the stack, so its own caddy must register as a conflict.
LIVE="$(ss -tlnH 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
BIND="$(sed -n 's/^AISTACK_BIND_ADDR=//p' .env 2>/dev/null | head -1)"
if [ -n "$LIVE" ] && [ -n "$BIND" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^aistack-caddy$'; then
  if [ -n "$(python3 "$PY" "$BIND" "$LIVE")" ]; then
    printf '  [ ok ] %-52s %s\n' "live table, stack running on $BIND" conflict
  else
    printf '  [FAIL] %-52s %s\n' "live table, stack running on $BIND" \
      "reported free while aistack-caddy holds it"
    RC=1
  fi
else
  printf '  [skip] live table: the stack is not running here\n'
fi

echo
[ "$RC" -eq 0 ] && echo "port pre-flight: PASS" || echo "port pre-flight: FAIL"
exit "$RC"
