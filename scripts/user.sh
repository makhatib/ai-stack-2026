#!/usr/bin/env bash
# AI Stack 2026 — accounts.  `aistack user …`.
#
# WHY THIS FILE EXISTS (NOM-402).
#
# Owner bootstrap is two phases.  Phase 1 is the installer: it writes one
# account with a random argon2id hash and never prints the password, so nobody
# — including the operator — knows it.  Phase 2 is the operator setting their
# own password and enrolling a second factor.
#
# Phase 2 had no implementation.  `config/authelia/configuration.yml` said
# `aistack user add` writes users.yml and that `aistack user reset` was "the
# supported path"; the installer's closing message and docs/install.md sent the
# operator to the web reset flow; and the same configuration.yml disables that
# flow with `password_reset.disable: true` because there is no SMTP in the MVP.
# Meanwhile `bin/aistack` had no `user` command at all, so the one documented
# route exited 1 with "unknown command 'user'".  Four surfaces, four different
# answers, and no way through.  This is the one path, and the other three now
# describe it.
#
# THREE THINGS HERE WERE MEASURED RATHER THAN ASSUMED, all on 2026-10-24
# against the pinned Authelia 4.39.28:
#
# 1. `watch: true` DOES NOT RELOAD users.yml IN THIS DEPLOYMENT, so every
#    change here is followed by a restart.  compose bind-mounts users.yml as a
#    SINGLE FILE, and Authelia's watcher does not see a host-side write through
#    that.  Both shapes were tried: an in-place truncate-write and an atomic
#    rename.  Two minutes after each, a login as the newly added user still
#    failed with `user not found`; a `docker restart` picked it up immediately.
#    `docker kill -s HUP` is not a reload either — it kills the container
#    (exit 129).  So the restart is not belt-and-braces, it is the mechanism.
#
# 2. ENROLLING A SECOND FACTOR NEEDS A ONE-TIME CODE, and the only place that
#    code exists is a file inside the container.  `PUT
#    /api/secondfactor/totp/register` answers `{"elevation":true}` until the
#    session is elevated, and elevation consumes a code Authelia hands to the
#    notifier.  There is no SMTP, so the notifier is the filesystem one and the
#    code lands in /data/notification.txt.  The pinned binary's config keys are
#    `identity_validation.elevated_session.{characters,code_lifespan,
#    elevation_lifespan,skip_second_factor,require_second_factor}` — none of
#    them waives the code.  `aistack user code` is therefore part of the
#    bootstrap, not a debugging aid.
#
# 3. THE PASSWORD CANNOT GO THROUGH A PIPE.  See scripts/authelia-users.py's
#    header: the hashing CLI takes a password from a terminal or from argv and
#    nowhere else, and argv is not an option.  That is why this script insists
#    on a terminal instead of reading stdin.
#
# ROLLBACK.  Delete scripts/user.sh, scripts/authelia-users.py and the `user`
# entries in bin/aistack (cmd_user, the dispatch case, the usage block), then
# restore the `aistack user` references in config/authelia/configuration.yml,
# config/authelia/users.yml.example, install.sh step 12 and docs/install.md's
# phase-2 section to whatever they said before.  Nothing here writes outside
# config/authelia/users.yml and the authelia database, and removing it leaves
# an account nobody can log in as — which is the state this ticket is about.

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

AUTH_DIR="${AISTACK_AUTHELIA_DIR:-$ROOT/config/authelia}"
export AISTACK_AUTHELIA_DIR="$AUTH_DIR"
USERS="$AUTH_DIR/users.yml"
EDIT=(python3 "$ROOT/scripts/authelia-users.py")

# The shortest password this command will set.  Authelia's file backend has no
# policy of its own in this configuration, so without a floor here there is
# none anywhere, and the one account that opens every service is the wrong
# place to find that out.  Length only: a character-class rule on a local
# single-owner stack buys less than the twelve characters it costs.
MIN_LEN=12

err()  { printf 'aistack user: %s\n' "$*" >&2; return 1; }
die()  { err "$*" || :; exit 1; }
info() { printf '%s\n' "$*"; }

dc() { ( cd "$ROOT" && docker compose "$@" ); }

usage() {
  cat <<'EOF'
aistack user — the accounts Authelia authenticates

  list                  who exists, their groups, and whether each has a
                        second factor enrolled
  reset <name>          set that account's password.  This is owner bootstrap
                        phase 2: the installer's random password is not
                        recoverable, so this is how the owner gets one.
  add <name>            create an account and set its password
                        [--display-name X] [--email Y] [--groups a,b]
  remove <name>         delete an account
  reset-2fa <name>      forget their enrolled second factor so they enrol
                        again.  The recovery path for a lost authenticator.
  code                  show the one-time code Authelia issued for a
                        second-factor enrolment.  There is no SMTP, so this
                        is how that code reaches you.

A password is typed at a prompt and never echoed.  It is not an argument and
not read from a pipe: the pinned Authelia image's hashing CLI accepts a
password from a terminal or from its own argv, and argv would show it to every
local `ps`.  Each change restarts Authelia, which is the only thing that makes
it re-read the file; sessions live in Postgres and survive that.
EOF
}

# --- preconditions ----------------------------------------------------------

need_docker() {
  docker version >/dev/null 2>&1 \
    || die "the docker daemon does not answer. users.yml is root-owned and
the password hash is computed by the pinned Authelia image, so both halves of
this command need docker."
}

authelia_container() { dc ps -q authelia 2>/dev/null | head -1; }

authelia_running() {
  local cid
  cid="$(authelia_container)"
  [ -n "$cid" ] || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" = true ]
}

# --- the password prompt ----------------------------------------------------

prompt_password() {
  # $1 = the account the password is for.  Writes the password to fd 3's pipe
  # by way of the caller's command substitution, so nothing here echoes it and
  # nothing stores it.
  local who="$1" p1 p2
  # A TERMINAL IS REQUIRED, AND SAYING SO IS BETTER THAN THE ALTERNATIVE.  The
  # obvious convenience — read the password from stdin so a script can supply
  # it — would make the password a thing that lives in whatever produced that
  # stdin: a file, a shell history line, a CI variable.  The one supported way
  # to set a password on this stack is a person typing it.
  #
  # IT READS fd 0, NOT /dev/tty, and the two are not interchangeable here.
  # /dev/tty is the process's CONTROLLING terminal, which a caller that handed
  # us a pty without making itself a session leader does not have -- the read
  # then fails with echo still on, which is the one way this prompt could leak
  # the password to a terminal.  Measured exactly that on 2026-10-24.  fd 0 is
  # also the descriptor the guard below tests, so the thing checked and the
  # thing read are the same thing.
  if [ ! -t 0 ]; then
    die "this needs a terminal: the password is typed, never piped.
Run it from a shell you are sitting at, not from a script or over a pipe."
  fi
  #
  # THE PROMPT IS PRINTED BY `read -p`, NOT BY A PREVIOUS printf, and that is
  # not a style choice.  `printf 'Repeat it: '; read -rs p2` leaves a window
  # between the prompt appearing and read turning echo off, and anything typed
  # inside that window IS echoed.  MEASURED 2026-10-24: driving this prompt
  # from a pty, the second password came back on the terminal in full while
  # the first -- typed into an already-open read -- did not.  `read -rsp`
  # closes the window because bash writes the prompt after it has the terminal
  # in no-echo mode.
  IFS= read -rsp "New password for $who (not echoed): " p1 \
    || die "could not read the password"
  printf '\n' >&2
  IFS= read -rsp "Repeat it: " p2 || die "could not read the password"
  printf '\n' >&2
  if [ "$p1" != "$p2" ]; then
    unset p1 p2
    die "the two did not match; nothing was changed"
  fi
  # The length is taken BEFORE the password is dropped.  `unset p1` and then
  # ${#p1} in the message is an unbound-variable abort under `set -u`, which
  # reports a bug in this script instead of a password that is too short.
  local len="${#p1}"
  if [ "$len" -lt "$MIN_LEN" ]; then
    unset p1 p2
    die "that is $len characters; this command will not set a password
shorter than $MIN_LEN. One account opens every service on this stack."
  fi
  printf '%s' "$p1"
  unset p1 p2
}

# --- reload -----------------------------------------------------------------

restart_authelia() {
  # See note 1 in the header: this is the only reload that works.
  if ! authelia_running; then
    info ""
    info "  Authelia is not running, so there was nothing to reload."
    info "  The change is in $USERS and takes effect at the next 'aistack up'."
    return 0
  fi
  info ""
  info "  Restarting Authelia so it re-reads the file..."
  dc restart authelia >/dev/null 2>&1 \
    || die "the change is written, but Authelia did not restart. Run
'aistack restart' — until it has restarted it is still using the old file."
  # Bounded wait on the container's own healthcheck rather than a flat sleep:
  # a password that is correct and a service that is not up yet look identical
  # from a login page.
  local i state cid
  for i in $(seq 1 60); do
    cid="$(authelia_container)"
    state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
             "$cid" 2>/dev/null || true)"
    case "$state" in
      healthy|running) info "  Authelia is back ($state)."; return 0 ;;
    esac
    sleep 1
  done
  err "Authelia has not reported healthy $i seconds after the restart.
The change IS written. 'aistack logs authelia' will say why it is unhappy."
  return 1
}

# --- subcommands ------------------------------------------------------------

sub_list() {
  need_docker
  local rows
  rows="$("${EDIT[@]}" names)" || exit 1

  local second_factor="" have_db=0
  if authelia_running; then
    # AN EMPTY RESULT IS ALSO AN ANSWER.  "asked, and nobody has enrolled one"
    # and "could not ask" are different facts and the column below says which
    # it is, so the reachability of the database is established FIRST and the
    # answer read second.  Deriving have_db from a non-empty result would
    # report '?' for a healthy stack on which nobody has enrolled yet — the
    # exact state a fresh install is in.
    if dc exec -T postgres psql -qtAX -U authelia -d authelia -c "select 1" \
         </dev/null >/dev/null 2>&1; then
      have_db=1
      # The enrolled second factors are rows in the authelia database, not
      # lines in users.yml, which is why this cannot be answered from the file.
      second_factor="$(dc exec -T postgres psql -qtAX -U authelia -d authelia -c \
        "select username from totp_configurations
         union select username from webauthn_credentials
         union select username from duo_devices" </dev/null 2>/dev/null || true)"
    fi
  fi

  printf '\n%-16s %-22s %-24s %s\n' USER "DISPLAY NAME" GROUPS "2ND FACTOR"
  local name display email groups mark
  while IFS=$'\t' read -r name display email groups; do
    [ -z "$name" ] && continue
    if [ "$have_db" = 1 ]; then
      if printf '%s\n' "$second_factor" | grep -qxF "$name"; then
        mark="enrolled"
      else
        mark="NOT ENROLLED"
      fi
    else
      mark="?"
    fi
    printf '%-16s %-22s %-24s %s\n' "$name" "$display" "${groups:--}" "$mark"
  done <<< "$rows"

  if [ "$have_db" != 1 ]; then
    printf '\n  2ND FACTOR is "?" because the authelia database did not answer.\n'
    printf '  That column is NOT in %s; it is in Postgres.\n' "${USERS#"$ROOT"/}"
    printf '  Start the stack ("aistack up") to see it.\n'
  fi
  printf '\n  An account with NOT ENROLLED cannot open any service: every route\n'
  printf '  is two_factor, so a correct password alone does not resolve one.\n'
  printf '  See "Owner bootstrap, phase 2" in docs/install.md.\n\n'
}

sub_reset() {
  local who="${1:-}"
  [ -n "$who" ] || die "usage: aistack user reset <name>"
  need_docker
  local pw
  pw="$(prompt_password "'$who'")" || exit 1
  printf '%s' "$pw" | "${EDIT[@]}" set-password "$who" || exit 1
  unset pw
  info ""
  info "  Password set for '$who'. It was not printed and is not stored
  anywhere but the argon2id hash in $USERS."
  restart_authelia || exit 1
  info ""
  info "  Next: log in, and if '$who' has no second factor yet, enrol one."
  info "  Authelia will ask for a one-time code; 'aistack user code' shows it."
}

sub_add() {
  local who="" display="" email="" groups=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --display-name) display="${2:-}"; shift ;;
      --email)        email="${2:-}";   shift ;;
      --groups)       groups="${2:-}";  shift ;;
      --*) die "unknown option '$1' (try: aistack user)" ;;
      *) [ -z "$who" ] || die "one name at a time"; who="$1" ;;
    esac
    shift
  done
  [ -n "$who" ] || die "usage: aistack user add <name> [--display-name X] [--email Y] [--groups a,b]"
  need_docker
  # AN ARRAY, NOT ${var:+--flag "$var"}.  That form is expanded unquoted, so a
  # display name with a space in it arrives as two arguments and the second
  # looks like a second username.
  local -a opts=()
  [ -n "$display" ] && opts+=(--display-name "$display")
  [ -n "$email" ]   && opts+=(--email "$email")
  [ -n "$groups" ]  && opts+=(--groups "$groups")
  local pw
  pw="$(prompt_password "the new account '$who'")" || exit 1
  printf '%s' "$pw" | "${EDIT[@]}" add "$who" "${opts[@]+"${opts[@]}"}" || exit 1
  unset pw
  info ""
  info "  Created '$who'${groups:+ in groups: $groups}."
  restart_authelia || exit 1
  info ""
  info "  '$who' has NO second factor yet and so cannot open anything until"
  info "  they enrol one. They log in, Authelia asks for a one-time code, and"
  info "  'aistack user code' is where that code appears."
}

sub_remove() {
  local who="${1:-}"
  [ -n "$who" ] || die "usage: aistack user remove <name>"
  need_docker
  "${EDIT[@]}" remove "$who" || exit 1
  info "  Removed '$who' from $USERS."
  # Their enrolled factors are database rows keyed by username, and leaving
  # them behind means a later account with the same name silently inherits
  # somebody else's authenticator.
  if authelia_running; then
    forget_second_factor "$who" || true
  else
    info "  Their enrolled second factor is still in the database; run"
    info "  'aistack user reset-2fa $who' once the stack is up."
  fi
  restart_authelia || exit 1
}

forget_second_factor() {
  local who="$1" out rc
  # THE NAME GOES INTO SQL, SO THE NAME IS CHECKED HERE TOO.  Every caller has
  # already matched it against users.yml, but "a key in a YAML file somebody
  # may have hand-edited" is not the same guarantee as "contains no quote", and
  # this is the one place in the stack that builds a statement out of a name.
  case "$who" in
    *[!a-zA-Z0-9._-]*|"") err "'$who' is not a usable account name"; return 1 ;;
  esac
  out="$(dc exec -T postgres psql -qtAX -v ON_ERROR_STOP=1 -U authelia -d authelia -c \
    "delete from totp_configurations where username = '$who';
     delete from webauthn_credentials where username = '$who';
     delete from duo_devices where username = '$who';
     delete from user_preferences where username = '$who';" </dev/null 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    err "could not clear the enrolled second factor for '$who': $out"
    return 1
  fi
  info "  Cleared any enrolled second factor for '$who'."
}

sub_reset_2fa() {
  local who="${1:-}"
  [ -n "$who" ] || die "usage: aistack user reset-2fa <name>"
  need_docker
  authelia_running || die "the stack is not running, and the enrolled factors
are rows in the authelia database rather than lines in a file. 'aistack up'
first."
  # Refuse a name that is not an account.  Deleting rows for a username that
  # does not exist reports success over a typo, which is the shape of mistake
  # that gets discovered at the next login attempt.
  "${EDIT[@]}" names | cut -f1 | grep -qxF "$who" \
    || die "there is no user '$who' in $USERS. 'aistack user list' shows who there is."
  forget_second_factor "$who" || exit 1
  info ""
  info "  '$who' now has no second factor. Their password is unchanged."
  info "  At their next login Authelia will ask them to enrol one, which needs"
  info "  a one-time code — 'aistack user code' shows it."
}

sub_code() {
  need_docker
  authelia_running || die "the stack is not running, so there is no one-time
code to show. 'aistack up' first."
  # The filesystem notifier keeps ONE notification: each new one replaces the
  # last.  So "the most recent notification" is the whole file, and whether it
  # is a code at all is a question this has to answer rather than assume.
  local body
  body="$(dc exec -T authelia cat /data/notification.txt </dev/null 2>/dev/null || true)"
  if [ -z "$body" ]; then
    info ""
    info "  Authelia has not sent a notification yet, so there is no code."
    info ""
    info "  It issues one when you ask: log in with your password, start the"
    info "  second-factor enrolment it offers, and run this again."
    return 0
  fi
  local subject when code revoke
  subject="$(printf '%s\n' "$body" | sed -n 's/^Subject:[[:space:]]*//p' | head -1)"
  when="$(printf '%s\n' "$body" | sed -n 's/^Date:[[:space:]]*//p' | head -1)"
  code="$(printf '%s\n' "$body" | grep -oE '^[A-Z0-9]{6,12}$' | tail -1)"
  revoke="$(printf '%s\n' "$body" | grep -oE 'https?://[^[:space:]]*revoke[^[:space:]]*' | tail -1)"
  info ""
  if [ -n "$code" ]; then
    info "  One-time code: $code"
    info ""
    info "  Type it into the prompt your browser is showing."
    info ""
    info "  Issued: ${when:-unknown}"
    [ -n "$subject" ] && info "  Subject: $subject"
    [ -n "$revoke" ] && info "  Revoke it:  $revoke"
    info ""
    info "  It is single-use, it expires in minutes, and it opens nothing"
    info "  without the account's password — which is why printing it here is"
    info "  not a disclosure. If you did NOT just ask for it, somebody else"
    info "  has that password: 'aistack user reset <name>' now."
  else
    # A NON-CODE NOTIFICATION IS NOT A FAILURE TO PARSE.  Authelia also writes
    # here to say a factor WAS added, and reporting that as a broken read sends
    # the operator looking for a bug instead of starting the enrolment.
    info "  Authelia's most recent notification is not a one-time code."
    info ""
    info "  Subject: ${subject:-(none)}"
    info "  Issued:  ${when:-unknown}"
    info ""
    info "  Start the second-factor enrolment in your browser and run this"
    info "  again; the code replaces this notification. The whole of it:"
    info ""
    printf '%s\n' "$body" | sed 's/^/  | /'
  fi
  info ""
}

case "${1:-}" in
  list)      shift; sub_list "$@" ;;
  reset)     shift; sub_reset "$@" ;;
  add)       shift; sub_add "$@" ;;
  remove)    shift; sub_remove "$@" ;;
  reset-2fa) shift; sub_reset_2fa "$@" ;;
  code)      shift; sub_code "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown user subcommand '$1' (try: aistack user)" ;;
esac
