#!/usr/bin/env bash
# Security proof 1 of 3 (DoD 2.6): from OUTSIDE, only 80 and 443 answer — and 22,
# key-only, if SSH is kept.
#
#   ./01-port-scan.sh HOST            run from ANOTHER machine, not the server itself
#
# WHAT IT DOES
#   1. TCP-connects to all 65535 ports of HOST and lists the ones that answer.
#   2. PASS needs: 443 and 80 answer, and nothing else except 22.
#   3. If 22 answers it says so on screen and PROVES it is key-only: it offers a
#      password and the server must refuse to take one.
#
# WHAT IT DOES NOT CLAIM
#   TCP only (no UDP).  A scan from one machine sees what that path allows; run
#   it from your laptop on the internet, not from the server.  A firewall that
#   drops packets shows as "closed" and is correct for this proof.
#
# Exit 0 PASS, 1 FAIL, 2 NOT MEASURED (scan blind, no ssh client, nothing answered).
set -uo pipefail
NAME=01-port-scan
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
HOST="${1:-}"
[ -n "$HOST" ] && [ "$HOST" != "-h" ] && [ "$HOST" != "--help" ] || { sed -n 2,17p "$0" | sed 's/^# \{0,1\}//'; exit 2; }

title "1. Port scan from outside" "Target: $HOST   Method: TCP connect, ports 1-65535   (UDP is not scanned)"
OPEN="$(python3 "$HERE/portscan.py" "$HOST" "${AISTACK_SCAN_TIMEOUT:-1.0}" "${AISTACK_SCAN_INFLIGHT:-3000}")"; rc=$?
if [ $rc -ne 0 ]; then skip "the scan could not run to completion (see message above)"; verdict "port scan of $HOST"; fi
printf '  open TCP ports: %s\n' "${OPEN:-(none)}"
if [ -z "$OPEN" ]; then skip "nothing answered at all: $HOST is down, unreachable from here, or the scan was blind"; verdict "port scan of $HOST"; fi

extra=""; for p in $OPEN; do case "$p" in 22|80|443) ;; *) extra="$extra $p" ;; esac; done
case " $OPEN " in *" 443 "*) ok "443 (HTTPS) answers" ;; *) bad "443 does not answer" ;; esac
case " $OPEN " in *" 80 "*) ok "80 (HTTP, redirects to HTTPS / certificate renewal) answers" ;; *) bad "80 does not answer" ;; esac
if [ -z "$extra" ]; then ok "no other port answers (every other TCP port is closed or filtered)"
else bad "unexpected open ports:$extra"; fi

title "2. Port 22 (SSH)" "Open on purpose, key-only. The proof: offer a password and see if the server takes it."
case " $OPEN " in
*" 22 "*)
  if ! command -v ssh >/dev/null; then skip "no ssh client here, so key-only could not be shown"
  else
    out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o PubkeyAuthentication=no \
             -o PreferredAuthentications=password,keyboard-interactive \
             -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
             "proof-$$@$HOST" true 2>&1)"
    info "server said: ${out:-(nothing)}"
    case "$out" in
      *"Permission denied (publickey)"*) ok "SSH offers publickey only: a password is not even an option"
        printf '  %sSTATEMENT: port 22 is kept open for administration. SSH is KEY-ONLY: password login is refused.%s\n' "$B" "$N" ;;
      *"Permission denied"*"password"*|*"Permission denied"*"keyboard-interactive"*) bad "SSH accepts password / keyboard-interactive logins" ;;
      *"Connection"*|*"timed out"*|*"closed"*) skip "SSH did not complete a handshake, so key-only was not shown" ;;
      *) skip "SSH answered in a way this script does not recognise" ;;
    esac
  fi ;;
*) ok "22 does not answer: SSH is not reachable from here at all" ;;
esac

verdict "from outside, $HOST answers only on $(echo "$OPEN" | tr ' ' '/'); SSH, if open, is key-only" "from outside, $HOST is not limited to 22/80/443 with key-only SSH (open: $OPEN)"
