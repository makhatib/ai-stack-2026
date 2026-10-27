#!/usr/bin/env bash
# AI Stack 2026 — connect the two things only the owner can create (NOM-416).
#
#   sudo bin/aistack telegram token   the bot token from @BotFather, and the
#                                     owner's own Telegram user id (the only
#                                     account Hermes will answer)
#   sudo bin/aistack mcp n8n-token    the MCP access token n8n shows under
#                                     Settings -> MCP (n8n mints it; we cannot)
#
# Each value is read from a prompt that does not echo, or from stdin when stdin
# is not a terminal (`... | sudo bin/aistack mcp n8n-token`).  It is never an
# argument (argv is visible to every local `ps`) and never printed.  The file
# keeps its owner and mode; only the one line changes.  Then the one service
# that reads it is restarted.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SECRETS="${AISTACK_SECRETS_DIR:-$ROOT/secrets}"
die()  { printf 'aistack: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
dc()   { ( cd "$ROOT" && docker compose "$@" ); }

need_root() {
  [ "$(id -u)" = 0 ] || die "the secrets files are root-owned.  Run: sudo bin/aistack $*"
}

# read_secret <prompt>: one line, no echo on a terminal, trailing whitespace cut
read_secret() {
  local v
  if [ -t 0 ]; then
    printf '%s: ' "$1" >&2
    IFS= read -rs v || true
    printf '\n' >&2
  else
    IFS= read -r v || true
  fi
  v="${v%%[[:space:]]}"
  printf '%s' "$v"
}

SET_ENV_LINE_PY=$(cat <<'PY'
import os, sys
path, key = sys.argv[1], sys.argv[2]
value = sys.stdin.read()
if "\n" in value or not value:
    sys.exit("refusing an empty or multi-line value")
st = os.stat(path)
lines = open(path).read().splitlines()
out, done = [], False
for ln in lines:
    bare = ln.lstrip("# ").split("=", 1)[0]
    if bare == key and not done:
        out.append(f"{key}={value}"); done = True
    elif bare == key:
        continue
    else:
        out.append(ln)
if not done:
    out.append(f"{key}={value}")
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("\n".join(out) + "\n")
os.chown(tmp, st.st_uid, st.st_gid)
os.chmod(tmp, st.st_mode & 0o7777)
os.replace(tmp, path)
PY
)

# set_env_line <file> <key>: the value comes on stdin, so it is never an
# argument of this or any child process.  A commented-out `# KEY=` line is
# replaced in place; otherwise the line is appended.  Owner and mode are kept.
set_env_line() {
  python3 -c "$SET_ENV_LINE_PY" "$1" "$2"
}

cmd_telegram_token() {
  need_root telegram token
  local f="$SECRETS/hermes.env" tok uid
  [ -f "$f" ] || die "$f is missing.  Run the installer first."
  tok="$(read_secret "Telegram bot token (from @BotFather)")"
  [[ "$tok" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$ ]] \
    || die "that does not look like a bot token (digits, a colon, then about 35 characters).  Nothing changed."
  uid="$(read_secret "Your own Telegram user id (digits; ask @userinfobot)")"
  [[ "$uid" =~ ^[0-9]{5,15}$ ]] || die "a Telegram user id is digits only.  Nothing changed."
  printf '%s' "$tok" | set_env_line "$f" TELEGRAM_BOT_TOKEN
  printf '%s' "$uid" | set_env_line "$f" TELEGRAM_ALLOWED_USERS
  unset tok uid
  info "Saved in $f (not printed).  Restarting hermes."
  dc restart hermes >/dev/null 2>&1
  info "Done.  Send your bot a message from that Telegram account; any other account is ignored."
}

cmd_n8n_token() {
  need_root mcp n8n-token
  local f="$SECRETS/litellm.env" tok
  [ -f "$f" ] || die "$f is missing.  Run the installer first."
  tok="$(read_secret "n8n MCP access token (n8n: Settings -> MCP)")"
  [[ "$tok" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] \
    || die "that does not look like n8n's token (three dot-separated parts).  Nothing changed."
  printf '%s' "$tok" | set_env_line "$f" N8N_MCP_TOKEN
  unset tok
  info "Saved in $f (not printed).  Recreating litellm, then restarting hermes (it lists its tools at start)."
  # RECREATE, NOT RESTART: compose reads env_file when it CREATES a container,
  # so `restart` keeps serving the old placeholder (measured, NOM-416).
  dc up -d --no-deps --force-recreate litellm >/dev/null 2>&1
  local i
  for i in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$(dc ps -q litellm)" 2>/dev/null)" = healthy ] && break
    sleep 3
  done
  dc restart hermes >/dev/null 2>&1
  info "Done.  Check: docker compose exec hermes hermes mcp test aistack  (n8n-* tools should be listed)."
}

case "${1:-} ${2:-}" in
  "telegram token") cmd_telegram_token ;;
  "mcp n8n-token")  cmd_n8n_token ;;
  *) die "usage: sudo bin/aistack telegram token | sudo bin/aistack mcp n8n-token" ;;
esac
