#!/usr/bin/env bash
# tests/owner-bootstrap.sh — owner bootstrap, both phases, end to end.
#
# WHAT THIS IS FOR (NOM-402).
#
# The shipped owner bootstrap was documented in four places and implemented in
# none.  `config/authelia/configuration.yml` named `aistack user add` and
# `aistack user reset`; install.sh's closing message and docs/install.md sent
# the operator to Authelia's web reset flow; that flow is disabled by the same
# configuration.yml; and `bin/aistack` had no `user` command, so the one
# documented route exited 1 with "unknown command 'user'".  The installer knows
# no recoverable password, so there was no way at all to reach a protected
# route on a freshly installed stack.
#
# Nothing could have caught that, because nothing ran the bootstrap.  This does,
# and it is deliberately TWO tests in one file:
#
#   SECTION A is the cheap one, and it is the one that would have caught the
#   original defect: every `aistack user …` command named in configuration.yml,
#   users.yml.example, install.sh or docs/install.md must actually dispatch, and
#   every subcommand that dispatches must appear in `aistack` usage.  A prose
#   surface that names a command nothing implements fails here.
#
#   SECTIONS B-F run the thing.  Phase 1 is the SHIPPED install.sh block,
#   extracted between its markers rather than retyped.  Phase 2 is the SHIPPED
#   bin/aistack and scripts/, byte-compared before they are driven.  The
#   password goes in through a pty, because that is the only way the command
#   accepts one and a test that reached for a back door would be testing a
#   path no operator has.
#
# WHAT IT ASSERTS AT THE END, which is the release question A2-A4 ask:
#
#   no session                -> forward-auth DENIES   (302 browser / 401 API)
#   correct password, no 2FA  -> forward-auth DENIES   (302 browser / 401 API)
#   correct password + TOTP   -> forward-auth ALLOWS   (200 either way)
#
# BOTH DENIALS ARE ASSERTED, because Caddy's forward_auth passes the original
# request's headers through: a browser (Accept: text/html) is redirected to the
# portal and an XHR or API client (Accept: application/json) is refused, and the
# status differs.  Asserting only one would leave the other free to become 200.
#
# WHY forward-auth AND NOT A BROWSER.  `/api/authz/forward-auth` is the
# endpoint Caddy asks on every request to every protected route -- all three
# of config/caddy/sites.d/*.caddy call exactly it -- so its verdict IS whether
# protected content resolves.  Asserting there needs no Caddy, no app and no
# TLS, and it is the same verdict: measured by hand through Caddy on the live
# stack, the three states give 302 / 302 / 200 on `/` and on `/n8n/`, which is
# what the three rows below reproduce.
#
# WHAT THE FIXTURE IS NOT.  It runs Postgres and Authelia from the pinned
# digests in versions.env, with the SHIPPED configuration.yml, so the policy
# under test is the one that ships.  Its compose file is written here and is
# NOT the shipped one: no Caddy, no read_only, no cap_drop, secrets as
# environment variables rather than files, and Authelia's port published on
# loopback so the assertions can be made from this host.  Those are the
# hardening properties, and I2/I6/I13/I16 and tests/secret-modes.sh are what
# cover them; this file covers the auth flow and says so rather than implying
# a second opinion on hardening it did not form.
#
# ROLLBACK: delete this file and its REGISTRY line in tests/run.sh.  It writes
# only inside its own fixture directory and its own compose project, and it
# never touches config/authelia/users.yml or any running project.

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
SKIPPED=0
ASSERTS=0
# The floor.  An extraction that silently produced nothing, or a section that
# returned early, has to be a refusal rather than a green run over four
# assertions -- the same reason tests/run.sh refuses an empty selection.
MIN_ASSERTS=68

PROJECT="aistack-ownerboot-$$"
FIXTURE=""

ok()   { ASSERTS=$((ASSERTS+1)); PASS=$((PASS+1)); printf '  [ ok ] %s\n' "$*"; }
no()   { ASSERTS=$((ASSERTS+1)); FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$*"; }
skip() { SKIPPED=$((SKIPPED+1)); printf '[skip] %s\n' "$*"; }
hdr()  { printf '\n%s\n' "$*"; }
refuse() {
  printf '\n[REFUSE] %s\n' "$*"
  printf 'Nothing was measured. This is not a pass.\n'
  teardown
  exit 2
}

# EVAL THROUGH A FUNCTION, NEVER `eval "$(cmd)" || refuse`.  In that form the
# command substitution's exit status is discarded and `eval ""` exits 0, so the
# refusal arm is dead and the assertions that follow read stale variables from
# the previous call.  Here the status is captured before anything is evaluated.
vars() {
  local o
  o="$("$@")" || return 1
  eval "$o"
}

check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1 ($3)"; else no "$1: expected '$2', got '$3'"; fi
}

teardown() {
  if [ -n "$FIXTURE" ] && [ -d "$FIXTURE" ]; then
    ( cd "$FIXTURE" && docker compose down -v --remove-orphans >/dev/null 2>&1 )
    # users.yml inside the fixture is root-owned by then, so the pinned image
    # removes the tree as container root.  A plain rm -rf would leave it.
    if [ -n "${IMG:-}" ]; then
      docker run --rm --network none -v "$FIXTURE:/f" --entrypoint sh "$IMG" \
        -c 'rm -rf /f/config /f/.runtime' >/dev/null 2>&1
    fi
    rm -rf "$FIXTURE" 2>/dev/null || true
  fi
}
trap teardown EXIT

printf '\nowner bootstrap, phases 1 and 2 (NOM-402)\n'

# =============================================================== preconditions
command -v python3 >/dev/null 2>&1 || refuse "python3 is not on PATH"
# NO PyYAML ANYWHERE IN HERE, DELIBERATELY.  docs/install.md declares the host
# tools this stack needs and says a plain python3 is enough, so the machine this
# test has to pass on does not have PyYAML -- and neither the shipped command
# under test nor this test may need it.  A test that refused for a missing
# library would report "not measured" on exactly the target that matters.

# shellcheck disable=SC1091
source versions.env 2>/dev/null || refuse "could not read versions.env"
for v in AUTHELIA_IMAGE AUTHELIA_TAG AUTHELIA_DIGEST \
         POSTGRES_IMAGE POSTGRES_TAG POSTGRES_DIGEST; do
  [ -n "${!v:-}" ] || refuse "versions.env does not define $v"
done
IMG="${AUTHELIA_IMAGE}:${AUTHELIA_TAG}@${AUTHELIA_DIGEST}"
PG="${POSTGRES_IMAGE}:${POSTGRES_TAG}@${POSTGRES_DIGEST}"

# ===================================================== A. the four surfaces
# No docker needed for this section, and it is the one that fails on the
# original defect.
hdr "A. every documented 'aistack user' command dispatches"

SURFACES=(
  config/authelia/configuration.yml
  config/authelia/users.yml.example
  install.sh
  docs/install.md
  README.md
)
NAMED="$(for f in "${SURFACES[@]}"; do
  [ -f "$f" ] || continue
  grep -ohE '\baistack user [a-z][a-z0-9-]*' "$f" 2>/dev/null
done | awk '{print $3}' | sort -u)"

if [ -z "$NAMED" ]; then
  refuse "no 'aistack user <sub>' reference found in any of ${SURFACES[*]}.
Either the documented bootstrap moved or this extraction is stale; a surface
scan that finds nothing measures nothing."
fi

# What bin/aistack's own user surface accepts, read out of its dispatch case
# rather than retyped here.
IMPLEMENTED="$(sed -n '/^case "\${1:-}" in$/,/^esac$/p' scripts/user.sh \
  | grep -oE '^  [a-z][a-z0-9-]*\)' | tr -d ' )' | sort -u)"
[ -n "$IMPLEMENTED" ] \
  || refuse "could not read scripts/user.sh's dispatch case; the anchor moved"

for sub in $NAMED; do
  if printf '%s\n' "$IMPLEMENTED" | grep -qxF "$sub"; then
    ok "documented 'aistack user $sub' is implemented"
  else
    no "'aistack user $sub' is named in a shipped surface but scripts/user.sh
         does not implement it. That is the NOM-402 defect exactly."
  fi
done

# ... and the reverse: an implemented subcommand the operator is never told
# about is a different bug but the same class.
USAGE="$(bin/aistack help 2>&1)"
for sub in $IMPLEMENTED; do
  if printf '%s\n' "$USAGE" | grep -qE "user $sub\b"; then
    ok "'aistack user $sub' appears in aistack usage"
  else
    no "'aistack user $sub' is implemented but 'aistack help' never names it"
  fi
done

# The web reset flow must stay off, because the documented path is the CLI.
# If somebody turns it back on, the docs are wrong again -- in the other
# direction, and with no SMTP behind it.
#
# READ WITH THE SHIPPED READER, not with a retyped one.  scripts/
# authelia-users.py has to get these two values out of configuration.yml
# without PyYAML, so driving ITS reader here measures the config value and the
# reader at the same time; a separate copy would let either drift.
WATCH_RESET="$(AISTACK_AUTHELIA_DIR="$ROOT/config/authelia" python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("au", "scripts/authelia-users.py")
au = importlib.util.module_from_spec(spec)
spec.loader.exec_module(au)
print("%s %s" % (
    au.config_scalars(["authentication_backend", "password_reset"])["disable"],
    au.config_scalars(["authentication_backend", "file"])["watch"]))
PY
)"
check "password_reset stays disabled and watch stays off" "True False" "$WATCH_RESET"

# `aistack user` with no subcommand must print help and succeed, not die: it is
# what an operator types when they have half-remembered the command.
bin/aistack user >/dev/null 2>&1
check "'aistack user' alone exits 0" 0 $?
bin/aistack user no-such-subcommand >/dev/null 2>&1
check "'aistack user <nonsense>' exits 1" 1 $?

# ===================================================== docker from here on
docker version >/dev/null 2>&1 \
  || refuse "the docker daemon does not answer; sections B-F need it"

# ===================================================== B. the fixture + phase 1
hdr "B. phase 1: the SHIPPED install.sh block, in a throwaway root"

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/aistack-ownerboot.XXXXXX")" \
  || refuse "could not make a fixture directory"
chmod 0755 "$FIXTURE"
export FIXTURE
# THE FIXTURE GETS ITS OWN LOCK DIRECTORY.  bin/aistack derives one from the
# owner of its root, which for a fixture owned by the same operator is the
# REAL project's -- so `aistack user` in here would take the live stack's
# helper lock exclusively and make this test and a concurrent `aistack backup`
# wait on each other for no reason.
export AISTACK_RUNDIR="$FIXTURE/run"
mkdir -p "$AISTACK_RUNDIR"

mkdir -p "$FIXTURE/bin" "$FIXTURE/scripts" "$FIXTURE/config/authelia"
cp versions.env "$FIXTURE/versions.env"
cp bin/aistack "$FIXTURE/bin/aistack"
cp scripts/user.sh "$FIXTURE/scripts/user.sh"
cp scripts/authelia-users.py "$FIXTURE/scripts/authelia-users.py"
cp config/authelia/users.yml.example "$FIXTURE/config/authelia/users.yml.example"
cp tests/owner-bootstrap.py "$FIXTURE/owner-bootstrap.py"
chmod 0755 "$FIXTURE/bin/aistack" "$FIXTURE/scripts/user.sh"

# THE COPIES ARE THE SHIPPED FILES, AND THAT IS CHECKED.  Driving a copy is
# only evidence about what ships if the copy is byte-identical to it -- the
# same reason tests/serving-hold.sh byte-compares the CLI it drives.
for f in bin/aistack scripts/user.sh scripts/authelia-users.py; do
  if cmp -s "$f" "$FIXTURE/$f"; then ok "fixture $f is the shipped file"
  else no "fixture $f differs from the shipped one"; fi
done

HOSTNAME_FIX="aistack.ownerboot.test"

# THE FIXTURE CONFIG IS THE SHIPPED FILE WITH ONE SUBSTITUTION, byte for byte
# otherwise -- comments, key order and every policy included.  The shipped file
# reaches the hostname through `{{ env … }}` and Authelia's opt-in templating;
# the fixture renders that here so the fixture compose does not need the
# templating filter switched on.  Nothing else needs changing: the shipped
# server address already binds 0.0.0.0:9091 and the shipped storage address
# already names a host called `postgres`, which is what the compose below calls
# its database.  An earlier version of this test re-dumped the parsed document
# instead, which needed PyYAML and silently dropped every comment.
python3 - "$FIXTURE" <<'PY' || refuse "could not render the fixture Authelia config"
import sys
fix = sys.argv[1]
text = open("config/authelia/configuration.yml", encoding="utf-8").read()
tmpl = '{{ env "AISTACK_HOSTNAME" }}'
n = text.count(tmpl)
if n < 1:
    raise SystemExit("configuration.yml no longer templates the hostname; "
                     "this substitution is stale")
out = text.replace(tmpl, "aistack.ownerboot.test")
# The shipped home config serves under /authelia (NOM-453); this fixture talks
# to Authelia directly with root paths, so serve it at the root.
out = out.replace("tcp://0.0.0.0:9091/authelia", "tcp://0.0.0.0:9091")
for probe in ("tcp://0.0.0.0:9091", "tcp://postgres:5432"):
    if probe not in out:
        raise SystemExit("the shipped config no longer contains %r, so the "
                         "fixture compose would not reach it" % probe)
open(fix + "/config/authelia/configuration.yml", "w", encoding="utf-8").write(out)
print("  [ info ] fixture config: shipped file, %d hostname substitutions" % n)
PY
grep -q 'policy: two_factor' "$FIXTURE/config/authelia/configuration.yml" \
  && ok "fixture config kept the shipped two_factor default" \
  || no "fixture config lost the two_factor rule; it would measure nothing"
grep -q 'disable: true' "$FIXTURE/config/authelia/configuration.yml" \
  && ok "fixture config kept password_reset disabled" \
  || no "fixture config lost password_reset: disable"

# PHASE 1, EXTRACTED FROM install.sh RATHER THAN RETYPED.
PHASE1="$FIXTURE/phase1.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'die()   { printf "phase1: %s\n" "$*" >&2; exit 1; }'
  printf '%s\n' 'say()   { printf "%s\n" "$*"; }'
  printf '%s\n' 'head2() { printf "\n%s\n" "$*"; }'
  sed -n '/^# AISTACK-OWNER-PHASE1:BEGIN$/,/^# AISTACK-OWNER-PHASE1:END$/p' \
    "$ROOT/install.sh" | sed '1d;$d'
} > "$PHASE1"
EXTRACTED="$(grep -c . "$PHASE1")"
[ "$EXTRACTED" -ge 20 ] || refuse \
  "install.sh's AISTACK-OWNER-PHASE1 block extracted only $EXTRACTED lines.
Its markers are gone or moved. An empty extraction measures nothing."
[ "$(grep -c '^# AISTACK-OWNER-PHASE1:BEGIN$' "$ROOT/install.sh")" = 1 ] \
  || refuse "install.sh has no single AISTACK-OWNER-PHASE1:BEGIN marker"
ok "extracted install.sh's phase-1 block ($EXTRACTED lines)"

( cd "$FIXTURE" && bash "$PHASE1" ) > "$FIXTURE/phase1.log" 2>&1
PHASE1_RC=$?
check "the shipped phase-1 block runs clean in a fresh root" 0 "$PHASE1_RC"
if [ "$PHASE1_RC" != 0 ]; then
  sed 's/^/    > /' "$FIXTURE/phase1.log" | tail -20
  refuse "phase 1 did not complete, so phase 2 cannot be measured"
fi

[ -f "$FIXTURE/config/authelia/users.yml" ] \
  && ok "phase 1 created users.yml" \
  || refuse "phase 1 created no users.yml"
grep -q '__ARGON2_HASH_WRITTEN_BY_INSTALLER__' \
     "$FIXTURE/config/authelia/users.yml" \
  && no "users.yml still holds the template placeholder, not a hash" \
  || ok "phase 1 replaced the template placeholder"
grep -qE 'password: "\$argon2id\$v=19\$m=65536,t=3,p=4\$' \
     "$FIXTURE/config/authelia/users.yml" \
  && ok "phase 1 wrote an argon2id hash with the configured parameters" \
  || no "phase 1's hash does not carry the parameters configuration.yml states"

# THE INSTALLER MUST NOT HAVE PRINTED THE PASSWORD.  That is the claim its own
# output makes, and it is cheap to check rather than believe.
if grep -qiE 'password is|temporary password:|password: [^"]' "$FIXTURE/phase1.log"; then
  no "phase 1's output looks like it disclosed a password"
else
  ok "phase 1 disclosed no password"
fi

# What a real install does immediately after this block, via gen-secrets.sh:
# users.yml becomes root:root 0600 because Authelia runs as uid 0 with every
# capability dropped and so does not bypass file permissions.  The fixture
# applies that here so the rest of the test runs against the REAL shape --
# including whether `aistack user` can still write it.
docker run --rm --network none -v "$FIXTURE/config/authelia:/c" \
  --entrypoint sh "$IMG" \
  -c 'chown 0:0 /c/users.yml && chmod 0600 /c/users.yml' >/dev/null 2>&1 \
  || refuse "could not make the fixture users.yml root-owned"
MODE_BEFORE="$(docker run --rm --network none -v "$FIXTURE/config/authelia:/c:ro" \
  --entrypoint sh "$IMG" -c 'stat -c "%u:%g %a" /c/users.yml' 2>/dev/null)"
check "fixture users.yml starts root-owned and 0600" "0:0 600" "$MODE_BEFORE"

# ===================================================== the fixture stack
hdr "C. a throwaway Postgres + Authelia on the pinned digests"

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
PGPW="$(python3 -c 'import secrets;print(secrets.token_hex(16))')"
cat > "$FIXTURE/compose.yaml" <<EOF
name: $PROJECT
services:
  postgres:
    image: $PG
    environment:
      POSTGRES_DB: authelia
      POSTGRES_USER: authelia
      POSTGRES_PASSWORD: $PGPW
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U authelia -d authelia"]
      interval: 3s
      timeout: 5s
      retries: 20
  authelia:
    image: $IMG
    command: ["authelia", "--config", "/config/configuration.yml"]
    volumes:
      - ./config/authelia/configuration.yml:/config/configuration.yml:ro
      # THE SAME SINGLE-FILE BIND THE SHIPPED COMPOSE USES.  Mounting the
      # directory instead would make Authelia's file watcher work and would
      # quietly stop this fixture from reproducing the deployment it is about.
      - ./config/authelia/users.yml:/config/users.yml:ro
      # The notifier writes the one-time code to /data/notification.txt, which
      # is the only place that code ever exists.  Without a writable /data the
      # enrolment half of this test cannot run at all.
      - authelia-data:/data
    environment:
      AUTHELIA_SESSION_SECRET: $(python3 -c 'import secrets;print(secrets.token_hex(32))')
      AUTHELIA_STORAGE_ENCRYPTION_KEY: $(python3 -c 'import secrets;print(secrets.token_hex(32))')
      AUTHELIA_STORAGE_POSTGRES_PASSWORD: $PGPW
      AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET: $(python3 -c 'import secrets;print(secrets.token_hex(32))')
    ports:
      - "127.0.0.1:$PORT:9091"
    depends_on:
      postgres:
        condition: service_healthy
volumes:
  authelia-data:
EOF

( cd "$FIXTURE" && docker compose up -d >/dev/null 2>&1 ) \
  || { ( cd "$FIXTURE" && docker compose logs --tail 30 2>&1 | sed 's/^/    > /' )
       refuse "the fixture stack did not start"; }

BASE="http://127.0.0.1:$PORT"
UP=no
for _ in $(seq 1 60); do
  if python3 -c '
import sys, urllib.request
try:
    urllib.request.urlopen(sys.argv[1] + "/api/health", timeout=3).read()
except Exception:
    raise SystemExit(1)
' "$BASE" 2>/dev/null; then UP=yes; break; fi
  sleep 1
done
if [ "$UP" != yes ]; then
  ( cd "$FIXTURE" && docker compose logs --tail 40 authelia 2>&1 | sed 's/^/    > /' )
  refuse "the fixture Authelia never answered /api/health on $BASE"
fi
ok "fixture Authelia is answering on loopback"

DRIVE=(python3 "$FIXTURE/owner-bootstrap.py")
vars "${DRIVE[@]}" probe-anon "$BASE" "$HOSTNAME_FIX" \
  || refuse "could not ask forward-auth about an anonymous request"
check "ROW 1: no session is DENIED at forward-auth" 302 "$fa"
check "ROW 1: no session is DENIED for an API client too" 401 "$fa_api"

# ===================================================== D. phase 2, the password
hdr "D. phase 2a: 'aistack user reset owner' through a pty"

SYNTH='Owner-bootstrap-synthetic-2026!'
printf '%s' "$SYNTH" > "$FIXTURE/synthetic-password"
chmod 0600 "$FIXTURE/synthetic-password"

# Before the reset, nobody can log in: that is the whole bug this test is
# about, and it is worth having on the record as a measurement rather than as
# a premise.
vars "${DRIVE[@]}" probe-password "$BASE" "$HOSTNAME_FIX" owner \
  || refuse "could not attempt a first-factor login"
check "before phase 2 the installer's account cannot authenticate" KO "$first"

vars env -C "$FIXTURE" "${DRIVE[@]}" drive 300 -- \
  ./bin/aistack user reset owner \
  :: "New password for" "@PASSWORD@" "Repeat it" "@PASSWORD@" \
  || refuse "could not drive 'aistack user reset'"
check "'aistack user reset owner' answered both prompts" "2/2" "$prompts"
check "'aistack user reset owner' exits 0" 0 "$exit"
RESET_TRANSCRIPT="$transcript"

# THE PASSWORD MUST NOT BE IN THE TRANSCRIPT.  The prompt claims it is not
# echoed, and an earlier version of this command echoed the SECOND one in full
# because its prompt was printed before `read` turned echo off (NOM-402).
if grep -qF "$SYNTH" "$RESET_TRANSCRIPT"; then
  no "the password appeared on the terminal: the prompt echoed it"
else
  ok "neither prompt echoed the password"
fi
# And not in the process table of the containers it ran, which is the other
# place a password could have gone: hashing takes --password on argv if asked.
if grep -qF -- "--password" "$RESET_TRANSCRIPT"; then
  no "the hashing step used --password, which puts the password in argv"
else
  ok "the hashing step did not use --password"
fi

MODE_AFTER="$(docker run --rm --network none -v "$FIXTURE/config/authelia:/c:ro" \
  --entrypoint sh "$IMG" -c 'stat -c "%u:%g %a" /c/users.yml' 2>/dev/null)"
check "the write kept users.yml root-owned and 0600" "0:0 600" "$MODE_AFTER"
LEFTOVER="$(docker run --rm --network none -v "$FIXTURE/config/authelia:/c:ro" \
  --entrypoint sh "$IMG" -c 'ls -A /c | grep -c "^\.users" || true' 2>/dev/null)"
check "the atomic write left no temporary file behind" 0 "$LEFTOVER"

vars "${DRIVE[@]}" probe-password "$BASE" "$HOSTNAME_FIX" owner \
  || refuse "could not attempt a first-factor login after the reset"
check "the password set at the prompt authenticates" OK "$first"
check "ROW 2: a password-only session is DENIED at forward-auth" 302 "$fa"
check "ROW 2: a password-only session is DENIED for an API client too" 401 "$fa_api"

# ===================================================== E. phase 2, the factor
hdr "E. phase 2b: enrol a second factor using only shipped steps"

vars "${DRIVE[@]}" elevate-start "$BASE" "$HOSTNAME_FIX" \
  || refuse "could not ask Authelia to start an elevation"
check "Authelia issues a one-time code on request" OK "$elevation"
# THE ELEVATION START REGENERATES THE SESSION ID.  Asserted rather than merely
# handled: a client that keeps the pre-elevation cookie is anonymous from here
# on and every later step fails in a way that reads like a rejected code.
check "the elevation start rotates the session cookie" yes "$rotated"

# `aistack user code` is the ONLY shipped way to read that code: there is no
# SMTP, so it is in a file inside the container and nowhere else.
CODE_OUT="$(cd "$FIXTURE" && ./bin/aistack user code 2>&1)"
OTC="$(printf '%s\n' "$CODE_OUT" | sed -n 's/^  One-time code: *//p' | tail -1)"
if [ -n "$OTC" ]; then
  ok "'aistack user code' produced a one-time code"
else
  printf '%s\n' "$CODE_OUT" | sed 's/^/    > /' | head -20
  no "'aistack user code' did not produce a code; enrolment cannot proceed"
fi

if [ -n "$OTC" ]; then
  vars "${DRIVE[@]}" enrol "$BASE" "$HOSTNAME_FIX" "$OTC" \
    || refuse "could not drive the enrolment"
  check "the code from 'aistack user code' elevates the session" OK "$elevated"
  check "the second factor registers" OK "$registered"
  # Authelia answers some refusals in plain text rather than JSON, so the
  # driver reports the body verbatim; show it when a step did not take.
  if [ "$elevated" != OK ] || [ "$registered" != OK ]; then
    printf '    > Authelia answered: %s\n' "${detail:-<nothing>}"
  fi
else
  skip "enrolment, because no one-time code was available"
fi

vars "${DRIVE[@]}" probe-twofactor "$BASE" "$HOSTNAME_FIX" owner \
  || refuse "could not complete a two-factor login"
check "the second factor completes a login" OK "$second"
check "the session cookie is rotated by the second factor" yes "$rotated"
check "the session reaches authentication level 2" 2 "$level"
check "ROW 3: password + second factor is ALLOWED at forward-auth" 200 "$fa"
check "ROW 3: password + second factor is ALLOWED for an API client too" 200 "$fa_api"

# ===================================================== F. the rest of the surface
hdr "F. list, add, reset-2fa, remove"

LIST="$(cd "$FIXTURE" && ./bin/aistack user list 2>&1)"
printf '%s\n' "$LIST" | grep -qE '^owner .*enrolled' \
  && ok "'user list' reports the owner's second factor as enrolled" \
  || no "'user list' does not report the owner as enrolled: $(printf '%s' "$LIST" | grep owner)"

vars env -C "$FIXTURE" "${DRIVE[@]}" drive 300 -- \
  ./bin/aistack user add analyst --display-name "Second Person" --groups viewers \
  :: "New password for" "@PASSWORD@" "Repeat it" "@PASSWORD@" \
  || refuse "could not drive 'aistack user add'"
check "'aistack user add' exits 0" 0 "$exit"
LIST="$(cd "$FIXTURE" && ./bin/aistack user list 2>&1)"
printf '%s\n' "$LIST" | grep -qE '^analyst .*Second Person .*viewers .*NOT ENROLLED' \
  && ok "the added account is listed with its groups and no second factor" \
  || no "'user list' does not describe the added account: $(printf '%s' "$LIST" | grep analyst)"

# A SECOND ACCOUNT WITH A CORRECT PASSWORD STILL OPENS NOTHING.  This is the
# A2 two-user case, and the interesting half of it is the denial.
vars "${DRIVE[@]}" probe-password "$BASE" "$HOSTNAME_FIX" analyst \
  || refuse "could not attempt a first-factor login as the added account"
check "the added account authenticates with its password" OK "$first"
check "the added account is still DENIED without a second factor" 302 "$fa"
check "the added account is DENIED for an API client too" 401 "$fa_api"

( cd "$FIXTURE" && ./bin/aistack user reset-2fa owner >/dev/null 2>&1 )
check "'aistack user reset-2fa' exits 0" 0 $?
LIST="$(cd "$FIXTURE" && ./bin/aistack user list 2>&1)"
printf '%s\n' "$LIST" | grep -qE '^owner .*NOT ENROLLED' \
  && ok "after reset-2fa the owner has no enrolled factor" \
  || no "reset-2fa did not clear the owner's enrolled factor"

( cd "$FIXTURE" && ./bin/aistack user remove analyst >/dev/null 2>&1 )
check "'aistack user remove' exits 0" 0 $?
LIST="$(cd "$FIXTURE" && ./bin/aistack user list 2>&1)"
printf '%s\n' "$LIST" | grep -qE '^analyst ' \
  && no "the removed account is still listed" \
  || ok "the removed account is gone"

# The last account must not be removable: it would leave a stack nobody can
# log in to and no supported way to make one.
( cd "$FIXTURE" && ./bin/aistack user remove owner >/dev/null 2>&1 )
check "removing the only remaining account is REFUSED" 1 $?

# ===================================================== G. the users.yml reader
# users.yml decides who can log in, and `aistack user` rewrites it with a
# reader and a writer of its own -- it must not need PyYAML, because the machine
# docs/install.md describes does not have it.  A hand-written reader earns that
# only if the shapes it cannot read are REFUSED rather than half-understood, so
# each one below is driven through the shipped command.
hdr "G. the users.yml reader accepts the shipped shape and refuses the rest"

RD="$FIXTURE/reader"
mkdir -p "$RD"

rd_names() { # rd_names <path to a users.yml body>; prints the command's output
  cp "$1" "$RD/users.yml"
  ( cd "$ROOT" && AISTACK_AUTHELIA_DIR="$RD" \
      python3 scripts/authelia-users.py names 2>&1 )
}

expect_refusal() { # expect_refusal <description> <file> <word in the message>
  local out rc
  out="$(rd_names "$2")"
  rc=$?
  if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -qiF -- "$3"; then
    ok "refuses $1"
  else
    no "should have refused $1 naming '$3' (exit $rc): $(
        printf '%s' "$out" | tr '\n' ' ' | cut -c1-110)"
  fi
}

# The shipped template is the shape a fresh install starts from.
if [ "$(rd_names config/authelia/users.yml.example | grep -c 'owner.*Owner.*owner@localhost.*admins,owner')" = 1 ]; then
  ok "reads the shipped users.yml.example, groups and all"
else
  no "cannot read config/authelia/users.yml.example: $(
      rd_names config/authelia/users.yml.example | tr '\n' ' ' | cut -c1-110)"
fi

# Quoting an operator may legitimately have used by hand.
cat > "$RD/ok-quotes.yml" <<'EOF'
users:
  owner:
    displayname: 'A Person'
    password: "$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA"
    email: owner@localhost
    groups: [admins, owner]
  plain:
    displayname: Plain
    password: "$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA"
    email: plain@localhost
    groups: []
EOF
QOUT="$(rd_names "$RD/ok-quotes.yml")"
if printf '%s\n' "$QOUT" | grep -q "^owner.A Person.*admins,owner" \
   && printf '%s\n' "$QOUT" | grep -q "^plain.Plain"; then
  ok "reads single quotes, a flow sequence and an empty one"
else
  no "misread the quoting fixture: $(printf '%s' "$QOUT" | tr '\n' ' ' | cut -c1-110)"
fi

printf 'users:\n  owner:\n\tdisplayname: "Owner"\n' > "$RD/bad-tab.yml"
expect_refusal "a tab in the indentation" "$RD/bad-tab.yml" "tab"

cat > "$RD/bad-dup.yml" <<'EOF'
users:
  owner:
    displayname: "First"
    displayname: "Second"
EOF
expect_refusal "a repeated key" "$RD/bad-dup.yml" "repeats the key"

cat > "$RD/bad-flow.yml" <<'EOF'
users:
  owner:
    displayname: {name: Owner}
EOF
expect_refusal "a flow mapping" "$RD/bad-flow.yml" "does not implement"

cat > "$RD/bad-anchor.yml" <<'EOF'
users:
  owner:
    displayname: &name "Owner"
EOF
expect_refusal "an anchor" "$RD/bad-anchor.yml" "does not implement"

cat > "$RD/bad-block.yml" <<'EOF'
users:
  owner:
    displayname: |
      Owner
EOF
expect_refusal "a block scalar" "$RD/bad-block.yml" "does not implement"

cat > "$RD/bad-noheader.yml" <<'EOF'
accounts:
  owner:
    displayname: "Owner"
EOF
expect_refusal "a file with no users: key" "$RD/bad-noheader.yml" "no top-level"

cat > "$RD/bad-unterminated.yml" <<'EOF'
users:
  owner:
    displayname: "Owner
EOF
expect_refusal "an unterminated quote" "$RD/bad-unterminated.yml" "unterminated"

# THE WRITER'S ESCAPING, round-tripped through the shipped reader.  A display
# name with a quote and a backslash in it is the value that breaks a writer
# which decides per value whether quoting is needed.
EMIT="$( cd "$ROOT" && python3 - <<'PY' 2>&1
import importlib.util
spec = importlib.util.spec_from_file_location("au", "scripts/authelia-users.py")
au = importlib.util.module_from_spec(spec)
spec.loader.exec_module(au)
users = {"odd": {"displayname": 'He said "hi" \\ then left',
                 "password": "$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA",
                 "email": "odd@localhost",
                 "groups": ["a b", "c"]}}
text = au.emit("users:\n", users)   # dies if it does not round-trip
print("roundtrip=%s" % (au.parse_strict(text)["users"] == users))
PY
)"
check "the writer's quoting round-trips a quote and a backslash" \
  "roundtrip=True" "$EMIT"

# ===================================================== summary
printf '\n'
printf 'assertions: %d   passed: %d   failed: %d   skipped: %d\n' \
  "$ASSERTS" "$PASS" "$FAIL" "$SKIPPED"
if [ "$ASSERTS" -lt "$MIN_ASSERTS" ]; then
  refuse "only $ASSERTS assertions were evaluated, fewer than the $MIN_ASSERTS
this file is meant to make. A section returned early; the result is not a pass."
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
