#!/usr/bin/env bash
# AI Stack 2026 — doctor.
#
# DETECTIVE, NOT PREVENTIVE, and it says so in its own output.  Everything
# here reports what IS, by asking the running system; nothing here enforces.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
RC=0
ok()   { printf '  [ ok ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; RC=1; }
warn() { printf '  [warn] %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

printf '\nAI Stack 2026 — doctor\n'
printf 'This is a DETECTIVE check. It reports; it does not enforce.\n'

hdr "Containers"
while read -r svc state health; do
  [ -z "$svc" ] && continue
  if [ "$state" = running ] && [ "$health" != unhealthy ]; then ok "$svc ($state${health:+/$health})"
  else bad "$svc ($state${health:+/$health})"; fi
done < <(docker compose ps -a --format json 2>/dev/null | python3 -c '
import json,sys
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    print(d.get("Service",""), (d.get("State") or "").lower(), (d.get("Health") or "").lower())')

hdr "Pins"
# Catches a dependency-bot PR merged without re-rendering .env.
MISMATCH=0
while IFS= read -r line; do
  key="${line%%=*}"; val="${line#*=}"
  case "$key" in *_DIGEST|*_TAG|*_IMAGE) ;; *) continue ;; esac
  envval="$(grep -E "^${key}=" .env 2>/dev/null | head -1 | cut -d= -f2-)"
  if [ "$envval" != "$val" ]; then
    bad "$key differs: versions.env=$val .env=$envval"
    MISMATCH=1
  fi
done < <(grep -E '^[A-Z0-9_]+=' versions.env)
[ "$MISMATCH" -eq 0 ] && ok "the rendered .env pin block matches versions.env"

for img in $(docker compose config --images 2>/dev/null); do
  case "$img" in *@sha256:*) ;; *) bad "not digest-pinned: $img" ;; esac
done
ok "every rendered image reference carries a digest"

hdr "Secrets"
# VERIFIED BY ASKING THE SERVICE, not inferred from the file mode.  A mode
# that looks right and a process that cannot read it are different things,
# and only one of them matters.
for pair in "postgres:/run/secrets/postgres_superuser_password" \
            "n8n:/run/secrets/n8n_encryption_key" \
            "authelia:/run/secrets/authelia_session_secret"; do
  svc="${pair%%:*}"; path="${pair#*:}"
  c="aistack-$svc"
  docker ps --format '{{.Names}}' | grep -q "^${c}$" || { warn "$svc is not running; cannot check"; continue; }
  if docker exec "$c" sh -c "head -c1 '$path' >/dev/null 2>&1"; then
    ok "$svc can read its own secret"
  else
    bad "$svc CANNOT read $path — it will fail at startup with an application error, not a file error"
  fi
done
# And that it cannot read another service's.
if docker ps --format '{{.Names}}' | grep -q '^aistack-n8n$'; then
  if docker exec aistack-n8n sh -c "head -c1 /run/secrets/postgres_superuser_password >/dev/null 2>&1"; then
    bad "n8n can read postgres's secret — the secret set is too wide"
  else
    ok "n8n cannot read another service's secret"
  fi
fi

# THE ONE FAILURE THAT STOPS EVERY COMMAND, WITH THE LEAST USEFUL MESSAGE.
# An `env_file` is read by the Docker CLI as the INVOKING user, not by the
# container.  If the operator cannot read it, `aistack up` creates nothing and
# prints only
#     open /…/secrets/litellm.env: permission denied
# MEASURED (NOM-258): installing from a root shell rather than through sudo
# left these files root:root 0640 and did exactly that — and it also turned
# `security-check`'s scan half into a clean report over zero images, because
# the image list it iterates comes from the same failing command.  Detecting
# it here is the difference between a one-line repair and an evening lost.
UNREADABLE=""
for f in "$ROOT"/secrets/*.env; do
  [ -e "$f" ] || continue
  [ -r "$f" ] || UNREADABLE="$UNREADABLE $(basename "$f")"
done
if [ -n "$UNREADABLE" ]; then
  bad "$(id -un) cannot read env_file(s):$UNREADABLE"
  printf '         Every aistack command will fail with a bare "permission\n'
  printf '         denied" and create no container.  Repair:\n'
  printf '             sudo bash scripts/gen-secrets.sh\n'
elif ! docker compose config -q 2>/dev/null; then
  bad "every env_file is readable, but 'docker compose config' still fails:"
  docker compose config 2>&1 >/dev/null | head -3 | sed 's/^/         /'
else
  ok "every env_file is readable by the operator ($(id -un)); compose resolves"
fi

hdr "Exposure"
sed -n '/AISTACK-LOCAL-MODE:BEGIN/,/AISTACK-LOCAL-MODE:END/p' .env 2>/dev/null \
  | grep -v 'AISTACK-LOCAL-MODE' | sed 's/^# \?/  /'
BIND="$(grep -E '^AISTACK_BIND_ADDR=' .env | cut -d= -f2-)"
case "$BIND" in
  127.0.0.1|::1) ok "bound to loopback only ($BIND)" ;;
  0.0.0.0|::)    bad "BOUND TO A WILDCARD ADDRESS ($BIND) — every interface on this machine" ;;
  *)             warn "bound to $BIND. Other devices on that network may reach it; untested." ;;
esac
for p in $(docker compose ps --format json 2>/dev/null | python3 -c '
import json,sys
for l in sys.stdin:
    l=l.strip()
    if not l: continue
    try: d=json.loads(l)
    except Exception: continue
    print(d.get("Publishers") or "", end=" ")' 2>/dev/null); do :; done

hdr "Host listeners"
echo "  Sockets bound to a wildcard address. A container can reach these."
echo "  This release makes NO claim that it cannot."
ss -tulnH 2>/dev/null | awk '{print $1, $5}' | grep -E '(\*|0\.0\.0\.0|\[::\]):[0-9]+$' | sort -u | sed 's/^/    /' \
  || echo "    (none found)"

hdr "Backup keys"
for f in secrets/backup.key secrets/backup.hmac; do
  [ -s "$f" ] && ok "$f present" || bad "$f MISSING — a restore would refuse to start"
done
[ -f .backup-keys-confirmed ] \
  && ok "operator has confirmed both key files are held off-host" \
  || warn "backup keys not yet confirmed off-host; 'aistack backup' will keep nagging"

hdr "Disk"
AVAIL=$(df -BG --output=avail . | tail -1 | tr -dc '0-9')
[ "${AVAIL:-0}" -ge 10 ] && ok "${AVAIL} GB free" || bad "only ${AVAIL} GB free"

printf '\n'
[ "$RC" -eq 0 ] && printf 'doctor: no problems found.\n' || printf 'doctor: PROBLEMS FOUND (see FAIL above).\n'
exit $RC
