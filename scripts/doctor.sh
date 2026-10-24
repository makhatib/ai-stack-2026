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

# Three states, not two.  The old form ran the loop with stderr discarded and
# then printed its `ok` UNCONDITIONALLY, so a compose render that failed
# outright -- which is exactly what happens when .env is missing a variable --
# produced an empty loop and a clean bill of health.  "I could not check" is
# not "I checked".
IMGS="$(docker compose config --images 2>/dev/null)"
if [ -z "$IMGS" ]; then
  bad "could not render image references, so no pin could be checked (try: docker compose config)"
else
  UNPINNED=0
  for img in $IMGS; do
    case "$img" in *@sha256:*) ;; *) bad "not digest-pinned: $img"; UNPINNED=1 ;; esac
  done
  [ "$UNPINNED" -eq 0 ] && ok "every rendered image reference carries a digest"
fi

# The rendered reference and the RUNNING container are different claims, and
# only the second one is serving traffic.  A merged pin bump that nobody
# `up`-ed leaves the old image running while every file on disk says
# otherwise, and the check above would still pass.  So ask the container.
# Take the container NAME from compose, never derive it.  Measured: deriving
# "aistack-$svc" silently skipped docling-serve, whose container_name is
# `aistack-docling` -- the not-running guard swallowed a name mismatch and the
# check reported a confident "all 8" while 9 were up.  A check that quietly
# examines fewer things than it claims is worse than no check.
PINMAP="$(docker compose config --format json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for n,s in sorted((d.get("services") or {}).items()):
    img=s.get("image") or ""
    if img: print(n, s.get("container_name") or n, img)
')"
DRIFT=0; CHECKED=0; LIVE=0
while IFS=" " read -r svc c ref; do
  [ -n "$svc" ] || continue
  docker ps --format '{{.Names}}' | grep -q "^${c}$" || continue
  LIVE=$((LIVE+1))
  running="$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null)"
  want="$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null)"
  if [ -z "$running" ] || [ -z "$want" ]; then
    warn "$svc: cannot compare running image to its pin (image not present locally?)"
    continue
  fi
  CHECKED=$((CHECKED+1))
  if [ "$running" != "$want" ]; then
    bad "$svc is RUNNING ${running#sha256:} but its pin resolves to ${want#sha256:} -- recreate it: docker compose up -d $svc"
    DRIFT=1
  fi
done <<EOF
$PINMAP
EOF
# Reconcile the count against compose's own view, so a future skip cannot pass
# as a pass.
EXPECTED="$(docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -c . || true)"
if [ "$CHECKED" -eq 0 ]; then
  warn "no running container could be compared against its pin"
else
  if [ -n "$EXPECTED" ] && [ "$LIVE" -ne "$EXPECTED" ]; then
    bad "compared $LIVE running containers but compose reports $EXPECTED running -- some service was skipped, so this section is incomplete"
  elif [ "$DRIFT" -eq 0 ]; then
    ok "all $CHECKED running containers were created from the image their pin names"
  fi
fi

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
#
# CHECK THE PATH IN THE ORDER COMPOSE WALKS IT: `.env`, then the directory,
# then the files.  MEASURED (NOM-258, 2026-10-18): the first version of this
# check tested only `secrets/*.env`, and after a root-shell install that glob
# matched NOTHING — `secrets/` was itself root:root 0700, so the loop found no
# files, reported no unreadable ones, and fell through to printing
#     every env_file is readable, but 'docker compose config' still fails
# which is a claim about files it was never able to look at.  A check that
# cannot see its subject must say so, not pass the question downstream.
REPAIR='             sudo bash scripts/gen-secrets.sh'
if [ -e "$ROOT/.env" ] && [ ! -r "$ROOT/.env" ]; then
  bad "$(id -un) cannot read .env ($(stat -c '%A %U:%G' "$ROOT/.env"))"
  printf '         compose opens .env FIRST, so every aistack command fails\n'
  printf '         with a bare "permission denied" and creates no container.\n'
  printf '         Repair:\n%s\n' "$REPAIR"
elif [ -d "$ROOT/secrets" ] && { [ ! -r "$ROOT/secrets" ] || [ ! -x "$ROOT/secrets" ]; }; then
  bad "$(id -un) cannot traverse secrets/ ($(stat -c '%A %U:%G' "$ROOT/secrets"))"
  printf '         The per-file modes inside are unreachable: the directory\n'
  printf '         denies the lookup before the file mode is ever consulted.\n'
  printf '         Repair:\n%s\n' "$REPAIR"
else
  UNREADABLE=""
  for f in "$ROOT"/secrets/*.env; do
    [ -e "$f" ] || continue
    [ -r "$f" ] || UNREADABLE="$UNREADABLE $(basename "$f")"
  done
  if [ -n "$UNREADABLE" ]; then
    bad "$(id -un) cannot read env_file(s):$UNREADABLE"
    printf '         Every aistack command will fail with a bare "permission\n'
    printf '         denied" and create no container.  Repair:\n%s\n' "$REPAIR"
  elif ! docker compose config -q 2>/dev/null; then
    bad "every env_file is readable, but 'docker compose config' still fails:"
    docker compose config 2>&1 >/dev/null | head -3 | sed 's/^/         /'
  else
    ok "every env_file is readable by the operator ($(id -un)); compose resolves"
  fi
fi

hdr "Database init"
# "ROLE MISSING" IS A FIRST-CLASS CHECK, because the stack can reach that
# state from ANY interrupted first boot — an unreadable secret (NOM-307), a
# power cut, a container killed mid-init — and not only from the one cause we
# measured.  The Postgres entrypoint runs /docker-entrypoint-initdb.d on an
# empty data directory and nowhere else, so a cluster that got half way
# through stays half way through, and before this check the first symptom was
# an application reporting `Role "litellm" does not exist`.
if ! docker ps --format '{{.Names}}' | grep -q '^aistack-postgres$'; then
  warn "postgres is not running; cannot check its roles and databases"
elif ! docker exec aistack-postgres test -x /usr/local/bin/aistack-pg-health 2>/dev/null; then
  warn "this aistack-postgres container predates the first-boot probe, so the"
  warn "roles could not be checked.  Recreate it to get the check (and the"
  warn "health gate that uses it):  docker compose up -d postgres"
else
  if PGHEALTH="$(docker exec aistack-postgres /usr/local/bin/aistack-pg-health 2>&1)"; then
    ok "every application role, database and control table from first-boot init is present"
  else
    bad "the database is missing part of what first-boot init should have created"
    printf '%s\n' "$PGHEALTH" | sed 's/^/         /'
    printf '         Repair in place (idempotent, touches nothing that exists):\n'
    printf '             bin/aistack db-init\n'
  fi
fi

hdr "Locks"
# TWO LOCK DIRECTORIES IS NOT A TIDINESS PROBLEM, IT IS A LOST LOCK.
#
# MEASURED (NOM-258, 2026-10-18): the lock path used to be chosen by the
# CALLER's privilege, so `aistack up` as the operator took
# /run/user/1000/aistack while `sudo aistack backup` took /run/aistack — and
# the backup the lock exists to serialise against never waited for anything.
# bin/aistack now derives the path from the OPERATOR, but a host that ran the
# earlier version still has the second directory, and a leftover lock file
# there is the only visible trace of the window where exclusion was absent.
if [ -z "${AISTACK_RUNDIR:-}" ]; then
  warn "run 'bin/aistack doctor' (not scripts/doctor.sh) to check the lock"
  warn "directory: only the CLI knows which path it picked."
else
  ok "lock directory: $AISTACK_RUNDIR"
  STRAY=""
  for d in /run/aistack /run/user/*/aistack /tmp/aistack-*; do
    [ -d "$d" ] || continue
    [ "$d" = "$AISTACK_RUNDIR" ] && continue
    [ -e "$d/lifecycle.lock" ] || [ -e "$d/helper.lock" ] || continue
    STRAY="$STRAY $d"
  done
  if [ -n "$STRAY" ]; then
    bad "a SECOND lock directory holds lock files:$STRAY"
    printf '         Commands that used it were not mutually excluded with\n'
    printf '         commands using %s.\n' "$AISTACK_RUNDIR"
    printf '         With the stack idle, delete the stray one(s) — they are\n'
    printf '         tmpfs scratch, not state:\n'
    printf '             sudo rm -rf%s\n' "$STRAY"
  else
    ok "no second lock directory — every identity takes the same lock"
  fi
fi

# A FREE LIFECYCLE LOCK IS NOT GOOD NEWS WHILE THE STACK IS SERVING.
#
# MEASURED (NOM-300, 2026-10-18): nine services healthy, the lifecycle lock
# `free`, `flock -n -x` on it exit 0 — so nothing stopped a restore drill from
# starting against live volumes.  Every service was fine and `doctor` said
# nothing, because the only lock question it asked was whether a second lock
# directory existed.  The serving lifetime hold is a process, a process can be
# killed, and the state that leaves behind looks healthy from every other
# angle.  So it is asked about directly.
#
# The three facts come from bin/aistack (AISTACK_SERVING_HOLDER, a pid or
# empty; AISTACK_SERVING_COUNT, a number or `unknown`; AISTACK_SERVING_STARTING,
# non-empty only while the live hold is still inside its startup grace) so that
# `status` and `doctor` share one implementation of each of them.
if [ -z "${AISTACK_RUNDIR:-}" ]; then
  warn "serving lifetime hold: not checked — run 'bin/aistack doctor'."
else
  HOLD="${AISTACK_SERVING_HOLDER:-}"
  NSERV="${AISTACK_SERVING_COUNT:-unknown}"
  STARTING="${AISTACK_SERVING_STARTING:-}"
  # BOTH INCONSISTENT QUADRANTS ARE FAILURES, not just the absent one.
  #
  # MEASURED (NOM-300 review, 2026-10-24): a refusal inside `aistack up` could
  # leave the hold armed with nothing serving, and this check called that `ok`
  # — it reported "held (pid N), 0 container(s) running" as a pass, because the
  # only question it asked about a held hold was whether it existed.  A hold
  # over an empty stack refuses every drill and every restore for up to the
  # 1200s startup grace, so the lock has stopped describing the serving state
  # just as surely as a free lock over nine running services does.
  #
  # BUT "HELD WITH NOTHING RUNNING" IS TWO STATES, and only one of them is a
  # defect.  MEASURED (NOM-395 round 2, 2026-10-24): `up` arms the hold BEFORE
  # it starts anything — the correct order, and the thing that closes the
  # check-then-act race — so every normal startup passes through this quadrant
  # between the arm and the first container reaching `running`.  On a cold
  # install `compose up` pulls multi-GB images first, so that window is
  # minutes long, and this check exited 1 inside it while advising
  # `bin/aistack down`: advice which, followed, tears down a stack that is
  # starting correctly.  The holder keeps the two apart with its own `seen`
  # flag and publishes the open window; nothing outside it could.
  if [ -n "$HOLD" ] && [ "$NSERV" = 0 ] && [ -n "$STARTING" ]; then
    # warn, not bad: the state is correct, and a drill IS refused while it
    # lasts, so an operator who is not waiting for a startup still gets told
    # how to clear it.
    warn "serving lifetime hold: ARMED (pid $HOLD) and waiting for the project's first container."
    case "$STARTING" in
      unknown) printf '         It releases by itself if none ever starts.\n' ;;
      *)       printf '         It releases by itself in %ss if none ever starts.\n' "$STARTING" ;;
    esac
    printf '         This is what a startup looks like from here, not a leak: up\n'
    printf '         arms the hold before it starts anything, and a cold install\n'
    printf '         pulls every missing image before the first container runs.  A\n'
    printf '         drill and a restore are refused until it clears.  If nothing\n'
    printf '         is in fact starting:\n'
    printf '             bin/aistack down\n'
  elif [ -n "$HOLD" ] && [ "$NSERV" = 0 ]; then
    bad "THE SERVING LIFETIME HOLD IS HELD (pid $HOLD) WHILE NOTHING IS RUNNING."
    printf '         The shared mode means "the stack is up" (final-design 2.1), and\n'
    printf '         nothing is.  While it is held a restore drill and a restore are\n'
    printf '         both refused, so this is safe but wrong.  Release it:\n'
    printf '             bin/aistack down\n'
  elif [ -n "$HOLD" ]; then
    ok "serving lifetime hold: held (pid $HOLD), $NSERV container(s) running"
  elif [ "$NSERV" = unknown ]; then
    warn "serving lifetime hold: absent, and docker did not say what is running."
    printf '         Whether that is correct cannot be decided from here.\n'
  elif [ "$NSERV" = 0 ]; then
    ok "serving lifetime hold: absent, and nothing is running — consistent"
  else
    bad "$NSERV CONTAINER(S) ARE RUNNING AND NOTHING HOLDS THE LIFECYCLE LOCK."
    printf '         The shared mode must be held for as long as the stack is up\n'
    printf '         (final-design 2.1).  Without it the kernel is not stopping a\n'
    printf '         restore drill from starting against your live volumes; only\n'
    printf "         the drill's own container check is, and that is the backstop,\n"
    printf '         not the contract.  Re-arm it without restarting anything:\n'
    printf '             bin/aistack up\n'
  fi
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
