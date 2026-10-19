#!/usr/bin/env bash
# AI Stack 2026 — secret generator (final-design §7.3).
#
# THE ABSOLUTE RULE: this script prints the PATH, never the VALUE.  Not at
# install, not in `status`, not in a next-steps banner, not in an error.  A CI
# test (tests/no-secret-output.bats) runs the installer non-interactively with a
# planted canary and asserts no generated value appears in stdout, stderr, the
# log file, a config diff, a backup listing, or `aistack support-bundle`.
#
# IDEMPOTENT AND LOAD-BEARING: an existing secret is REUSED, never regenerated.
# The stack this replaces rotated every password on every run against live
# volumes, which is how an "idempotent" installer locks you out of your own
# database.
#
# FILE MODE IS PER SERVICE, NOT A BLANKET 0600 (S13).  A blanket 0600 and "each
# service can read its own secret" cannot both be true for a non-root
# container.  We write 0640 root:<service-gid> where the consumer is non-root
# and 0600 root:root where it runs as root.  The GIDs come from
# config/image-facts.yaml, which is MEASURED by `aistack probe-images` rather
# than guessed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="$ROOT/secrets"
FACTS="$ROOT/config/image-facts.yaml"

umask 077

log() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# WHO IS THE OPERATOR?  Not "whoever root's environment says".
#
# MEASURED (NOM-258, 2026-10-18).  Installed from a root SHELL rather than
# through sudo — `su -`, or an ssh login as root, which is how a large share
# of home-server installs actually happen — SUDO_UID/SUDO_GID are unset and
# `id -u`/`id -g` are 0, so every artefact of the install became root:root.
# The ordinary user who then ran `aistack up` got nothing but
#
#     open /…/.env: permission denied
#
# and NO container was created, because the Docker CLI reads `.env` and every
# `env_file` as the INVOKING user, not as the container.
#
# The operator is whoever owns this checkout, because that is who will run
# `aistack`.  Prefer sudo's answer, fall back to the checkout's own owner, and
# only then to the current process.  Returning 0 is correct when the operator
# really is root.
operator_uid() {
  local uid="" ruid=""
  [ -n "${SUDO_UID:-}" ] && uid="$SUDO_UID"
  if [ -z "$uid" ] || [ "$uid" = "0" ]; then
    ruid="$(stat -c %u "$ROOT" 2>/dev/null || true)"
    if [ -n "$ruid" ] && [ "$ruid" != "0" ]; then uid="$ruid"; fi
  fi
  [ -n "$uid" ] || uid="$(id -u)"
  printf '%s' "$uid"
}

operator_gid() {
  local gid="" rgid=""
  [ -n "${SUDO_GID:-}" ] && gid="$SUDO_GID"
  if [ -z "$gid" ] || [ "$gid" = "0" ]; then
    rgid="$(stat -c %g "$ROOT" 2>/dev/null || true)"
    if [ -n "$rgid" ] && [ "$rgid" != "0" ]; then gid="$rgid"; fi
  fi
  [ -n "$gid" ] || gid="$(id -g)"
  printf '%s' "$gid"
}

# THE OPERATOR MUST OWN THE THINGS ONLY THE OPERATOR READS.
#
# MEASURED (NOM-258, 2026-10-18), and this is the correction to the first fix
# rather than a new case.  Giving `secrets/*.env` the operator's GROUP is
# necessary and NOT sufficient: after a root-shell install `secrets/` itself
# was root:root 0700, so the 0640 group mode on the files inside could never
# be reached — the directory denied traversal first.  `.env` was root:root
# 0600 for the same reason and failed even earlier, since compose reads it
# before it reads any env_file.
#
# These paths are host artefacts that ONLY the operator's CLI reads; no
# container mounts them (the per-service secret FILES are separate, stay
# root-owned, and keep their measured per-service modes).  So they are owned
# by the operator at 0700/0600 — which is what a plain `sudo ./install.sh`
# produced all along, and is strictly narrower than root:group 0750/0640.
claim_for_operator() {
  local path="$1" mode="$2" uid gid
  [ -e "$path" ] || return 0
  uid="$(operator_uid)"; gid="$(operator_gid)"
  if chown "${uid}:${gid}" "$path" 2>/dev/null && chmod "$mode" "$path" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 \
     && sudo -n chown "${uid}:${gid}" "$path" </dev/null 2>/dev/null \
     && sudo -n chmod "$mode" "$path" </dev/null 2>/dev/null; then
    return 0
  fi
  # Unprivileged and already correct is the common case; only complain when
  # the operator genuinely cannot reach it, because that is the failure whose
  # only other symptom is a bare "permission denied" from compose.
  if [ ! -r "$path" ]; then
    log "  NOTE    cannot fix ownership of $path and $(id -un) cannot read it."
    log "          Run: sudo bash scripts/gen-secrets.sh"
  fi
}

if [ ! -d "$SECRETS" ]; then
  mkdir -p "$SECRETS"
fi
claim_for_operator "$SECRETS" 0700

# The MEASURED runtime ids of each service, from manifest.yaml `runtime_ids`.
#
# Why this is read from the manifest and not probed here: the probe that gives
# the right answer needs the service RUNNING, and secrets must exist before it
# can start.  `scripts/probe-runtime.sh` takes the measurement against a live
# stack and `aistack doctor` re-checks readability by asking the service, so a
# stale value here is caught rather than trusted.
#
# AND IT READS THE MANIFEST WITH awk, NOT WITH PyYAML.
#
# MEASURED (NOM-307, 2026-10-19).  This was a Python heredoc guarded by
# `try: import yaml / except ImportError: sys.exit(0)`.  PyYAML is not in
# docs/install.md's prerequisites, so on a machine that has only what the
# guide asks for the import failed, the heredoc printed nothing and exited 0,
# and apply_mode below read that as "no ids declared" — for EVERY consumer.
# The whole of S13's per-service mode logic was switched off by a missing
# library, silently, with the correct value sitting in manifest.yaml unread.
# scripts/manifest-runtime-ids.sh carries the full account.
service_ids() {
  "$ROOT/scripts/manifest-runtime-ids.sh" "$1" 2>/dev/null || true
}

# Apply the mode S13 requires, and FAIL LOUDLY if it cannot be applied.
#
# The failure this replaces is the one that actually happened during the build:
# a secret written 0600 root:root for a service running as uid 999, which
# Docker bind-mounts unchanged, so Postgres crash-looped on "Permission denied"
# against a path the operator cannot inspect.  A warning was not enough — the
# install continued and produced a stack that could not start.
apply_mode() {
  local path="$1" consumer="$2" ids uid gid

  # THE CONSUMER IS SOMETIMES THE OPERATOR, AND THAT IS NOT A SERVICE.
  #
  # MEASURED (NOM-258, 2026-10-18).  backup.key and backup.hmac were declared
  # with consumer `backup-helper`, which resolved to gid 999 — but NOTHING
  # mounts them: `scripts/backup.sh` and `scripts/restore.sh` run `openssl`
  # ON THE HOST with `-pass file:…`, so the reader is whoever runs `aistack`.
  # After a root-shell install that left them root:999 0640 and the operator
  # could not read the two files this script's own closing message tells them
  # to copy off-host — the instruction was unfollowable in the install path it
  # was printed in, while a sudo install happened to work.
  #
  # If a helper container is ever given these keys it will come with a mount,
  # and this mode has to be revisited together with it.
  if [ "$consumer" = "operator" ]; then
    claim_for_operator "$path" 0600
    return 0
  fi

  ids="$(service_ids "$consumer")"

  # NO IDS IS A STOP, NOT A DEFAULT.
  #
  # MEASURED (NOM-307, 2026-10-19).  This branch used to chmod 0600 root:root,
  # log a WARN and RETURN 0.  That is the one path in this script that only
  # warns, and it is the path a missing PyYAML drove every consumer down: the
  # install continued and produced exactly the stack this file's header says
  # a warning was not enough to prevent — Postgres unable to read
  # app_db_passwords as uid 999, its first-boot init script dead, and seven
  # WARN lines as the only trace.  An unresolvable consumer now fails here.
  if [ -z "$ids" ]; then
    die_no_ids "$path" "$consumer"
  fi

  uid="${ids%%:*}"; gid="${ids##*:}"

  if [ "$uid" = "0" ] && [ "$gid" = "0" ]; then
    # A root consumer still needs the file OWNED BY uid 0.
    #
    # MEASURED (NOM-258, 2026-10-18), and it is the single most
    # counter-intuitive thing in this script: under `cap_drop: ALL` a
    # container process running as uid 0 DOES NOT BYPASS FILE PERMISSIONS.
    # The bypass is CAP_DAC_OVERRIDE / CAP_DAC_READ_SEARCH, and we drop both.
    # So a 0600 secret owned by the installing user is unreadable by a
    # "root" container — Authelia failed with "permission denied" on four
    # secrets at once while running as uid 0.
    #
    # "Root can read anything" is false in a hardened container, and a
    # chmod-only branch here quietly relies on it.
    if [ "$(stat -c %u "$path")" = "0" ]; then
      chmod 0600 "$path"
      return 0
    fi
    if chown 0:0 "$path" 2>/dev/null && chmod 0600 "$path" 2>/dev/null; then
      return 0
    fi
    if command -v sudo >/dev/null 2>&1 \
       && sudo -n chown 0:0 "$path" </dev/null 2>/dev/null \
       && sudo -n chmod 0600 "$path" </dev/null 2>/dev/null; then
      return 0
    fi
    die_unreadable_root "$path" "$consumer"
  fi

  # Non-root consumer.  The property we need is exactly: THIS SERVICE CAN READ
  # IT AND NOTHING ELSE CAN.  Root ownership is not part of that property, so
  # try the unprivileged move first — chgrp to a group the installing user
  # already belongs to needs no privilege at all, and that covers the common
  # case where the stack runs as the same uid the image does.
  if chgrp "$gid" "$path" 2>/dev/null && chmod 0640 "$path" 2>/dev/null; then
    return 0
  fi

  # Otherwise it needs privilege.  Try a non-interactive sudo; never prompt,
  # because this may be running under `--non-interactive`.
  #
  # `</dev/null` is not decoration.  With `Defaults use_pty` in sudoers — the
  # default on current Ubuntu — sudo's behaviour depends on what stdin is, and
  # we measured it fail inside a script while the identical command succeeded
  # at the prompt one line earlier.  Handing it a closed stdin makes the
  # outcome depend on the sudo POLICY rather than on who happened to pipe what
  # into the installer.
  if command -v sudo >/dev/null 2>&1 \
     && sudo -n chown "0:${gid}" "$path" </dev/null 2>/dev/null \
     && sudo -n chmod 0640 "$path" </dev/null 2>/dev/null; then
    return 0
  fi

  die_unreadable "$path" "$consumer" "$gid"
}

die_no_ids() {
  local path="$1" consumer="$2"
  cat >&2 <<EOF

FATAL: cannot determine which uid/gid must read $(basename "$path").

'$consumer' has no usable \`runtime_ids\` entry in:

    $ROOT/manifest.yaml

Docker Compose bind-mounts a file secret WITH ITS HOST OWNERSHIP, so the host
mode is the only control over who can read it.  Without the consumer's
measured uid:gid this script would have to guess, and the guess that looks
safest — 0600 root:root — is unreadable by every service that does not run as
uid 0.  That is a stack that installs and then cannot start.

Fix the manifest entry, then re-run the installer:

    services:
      $consumer:
        runtime_ids: "<uid>:<gid>"   # from 'aistack probe-images'

Refusing to continue rather than writing a mode that cannot work.
EOF
  exit 1
}

die_unreadable_root() {
  local path="$1" consumer="$2"
  cat >&2 <<EOF

FATAL: cannot give '$consumer' read access to $(basename "$path").

$consumer runs as uid 0 inside its container, but the stack drops ALL
capabilities — including CAP_DAC_OVERRIDE and CAP_DAC_READ_SEARCH. Without
those, uid 0 does NOT bypass file permissions, so a 0600 file owned by
$(id -un) is unreadable by it. The file must be owned by uid 0.

Run these yourself, then re-run the installer:

    sudo chown 0:0 $path
    sudo chmod 0600 $path

EOF
  exit 1
}

die_unreadable() {
  local path="$1" consumer="$2" gid="$3"
  cat >&2 <<EOF

FATAL: cannot give '$consumer' read access to $(basename "$path").

$consumer runs as gid $gid inside its container.  Docker Compose bind-mounts a
file secret WITH ITS HOST OWNERSHIP — the uid/gid/mode fields in compose.yaml
are Swarm-only and are silently ignored here — so the host mode is the only
control, and 0600 root:root would make $consumer crash-loop on a permission
error against a path you cannot see.

You are not in group $gid and passwordless sudo is not available, so neither
the unprivileged path (chgrp) nor the privileged one worked.

Run these yourself, then re-run the installer:

    sudo chown 0:$gid $path
    sudo chmod 0640 $path

Refusing to continue rather than producing a stack that starts and then fails.
EOF
  exit 1
}

# Generate one secret if and only if it does not already exist.
#   $1 name, $2 consumer service (for the measured ids), $3 generator
#
# AN EXISTING SECRET IS REUSED, NEVER REGENERATED.  The stack this replaces
# rotated every password on every run against live volumes, which is how an
# "idempotent" installer locks you out of your own database.
gen() {
  local name="$1" consumer="$2" how="${3:-hex32}" path="$SECRETS/$1"
  if [ -s "$path" ]; then
    log "  reuse   $path"
  else
    case "$how" in
      # NO TRAILING NEWLINE.  Several consumers read a *_FILE secret
      # verbatim: n8n warns that it trimmed whitespace, and anything that
      # does not trim would authenticate with a password that has a \n on
      # the end — a failure that looks like a wrong password.
      hex32) printf '%s' "$(openssl rand -hex 32)" > "$path" ;;
      hex64) printf '%s' "$(openssl rand -hex 64)" > "$path" ;;
      *) echo "unknown generator: $how" >&2; return 1 ;;
    esac
    log "  create  $path"
  fi
  apply_mode "$path" "$consumer"
}

log "Generating secrets into $SECRETS (existing values are reused, never rotated)"

gen postgres_superuser_password     postgres  hex32
gen n8n_encryption_key              n8n       hex32
gen authelia_jwt_secret             authelia  hex64
gen authelia_session_secret         authelia  hex64
gen authelia_storage_encryption_key authelia  hex64

# Backup keys.  TWO FILES, deliberately (final-design §7.4, S11): the HMAC key
# is separate from the encryption key so POSSESSION OF THE ARCHIVE NEVER
# CONFERS THE ABILITY TO FORGE ITS MANIFEST.  Restore refuses to start when the
# HMAC key is absent; it does not fall back to digest-only verification.
gen backup.key                      operator      hex32
gen backup.hmac                     operator      hex32

# --- the per-app database passwords ----------------------------------------
# One file, `name=value` per line, PARSED and never sourced.
APPPW="$SECRETS/app_db_passwords"
touch "$APPPW"
chmod 0600 "$APPPW"
# THE SINGLE DECLARATION OF THE APP LIST.
#
# This loop is the ONLY place in the repository where the set of apps that get
# a Postgres role and database is written out literally.  Everything else
# derives it from the file this loop writes: the first-boot init script, the
# health probe, `db-init` and `doctor` (both of which run the two above) and
# backup.sh all read the key set of app_db_passwords; restore.sh reads the
# archive.  Adding an app is ONE edit, here.
#
# CI invariant I15 fails the build if a second literal copy appears anywhere,
# because the previous arrangement was four copies under a comment promising
# they could not diverge.
for app in authelia openwebui litellm n8n; do
  if grep -q "^${app}=" "$APPPW" 2>/dev/null; then
    log "  reuse   db password for $app"
  else
    printf '%s=%s\n' "$app" "$(openssl rand -hex 24)" >> "$APPPW"
    log "  create  db password for $app"
  fi
done
# Postgres reads this one, and it does NOT run as root.
apply_mode "$APPPW" postgres

# --- one password, ONE source ----------------------------------------------
# Authelia's Postgres role is created by the init script from app_db_passwords,
# and Authelia authenticates with AUTHELIA_STORAGE_POSTGRES_PASSWORD_FILE.
# Those must be THE SAME VALUE.
#
# They were not, in the first cut of this script: `authelia_storage_password`
# was generated independently with its own `openssl rand`, so the role existed
# with one password and Authelia connected with another.  The symptom was
# "Errors occurred performing startup checks" with no mention of
# authentication, which is a long way from the cause.
#
# Deriving it here, from the one file that defines it, makes the two
# impossible to drift apart.
AUTH_PW_FILE="$SECRETS/authelia_storage_password"
AUTH_PW="$(sed -n 's/^authelia=//p' "$APPPW")"
if [ -z "$AUTH_PW" ]; then
  echo "FATAL: no authelia password in $APPPW" >&2
  exit 1
fi
if [ ! -s "$AUTH_PW_FILE" ] || [ "$(cat "$AUTH_PW_FILE")" != "$AUTH_PW" ]; then
  printf '%s' "$AUTH_PW" > "$AUTH_PW_FILE"
  log "  sync    $AUTH_PW_FILE (from app_db_passwords — one password, one source)"
fi
unset AUTH_PW
apply_mode "$AUTH_PW_FILE" authelia

# --- E6: the two env_files -------------------------------------------------
# Open WebUI and LiteLLM have no _FILE indirection upstream, so their secrets
# are environment variables.  Root-owned 0640, their own file, never `.env`,
# never the shell.  The residual is stated in full in the exceptions register
# and in docs/security-faq.md: a compromise of either app can read that app's
# own environment, and host and daemon administrators remain inside the trust
# boundary.  We do not claim otherwise.
write_env_file() {
  local file="$1" consumer="$2"; shift 2
  if [ -s "$file" ]; then
    log "  reuse   $file"
  else
    : > "$file"
    chmod 0600 "$file"
    for kv in "$@"; do printf '%s\n' "$kv" >> "$file"; done
    log "  create  $file"
  fi
  apply_env_file_mode "$file"
}

# E6's env_files are NOT container-side secrets, and that distinction is the
# whole of their threat model.
#
# MEASURED (NOM-258, 2026-10-18): `env_file:` is read by the DOCKER CLI on the
# host, as the user running `docker compose`, and the values are injected into
# the container's environment by the daemon. The container never opens the
# file. So:
#
#   * the consuming service's uid is IRRELEVANT to this file's mode;
#   * the file must be readable by WHOEVER RUNS `aistack`, or compose fails
#     with "permission denied" before a container is created (we hit exactly
#     that: root-owned 0600 litellm.env, invoked as a normal user);
#   * "root-owned 0640" from the design is right only if read as
#     root:<operator-group>, not root:<service-group>.
#
# This also narrows what E6 actually exposes. The file is a host artefact
# protected by host permissions; the SECRET still reaches the application as
# an environment variable, which is the part the exception is about and which
# no file mode here changes.
# The operator group comes from `operator_gid` at the top of this script; the
# same measurement that fixed `secrets/` and `.env` fixes these files, and a
# root-shell install left all three broken for one reason.
apply_env_file_mode() {
  local file="$1" gid gname
  gid="$(operator_gid)"
  gname="$(getent group "$gid" 2>/dev/null | cut -d: -f1)"
  log "  MODE    $(basename "$file") -> 0640 root:${gname:-$gid} (the operator group, so compose can read it)"
  if chown "0:${gid}" "$file" 2>/dev/null && chmod 0640 "$file" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 \
     && sudo -n chown "0:${gid}" "$file" </dev/null 2>/dev/null \
     && sudo -n chmod 0640 "$file" </dev/null 2>/dev/null; then
    return 0
  fi
  # Last resort: leave it owned by the operator, still 0600.  That is no
  # weaker than root:operator-group 0640 against anyone but root.
  chmod 0600 "$file" 2>/dev/null || true
  log "  NOTE    $file left 0600 owned by $(id -un): compose must be able to read it."
}

OWUI_SECRET="$(openssl rand -hex 32)"
LITELLM_MASTER="sk-$(openssl rand -hex 24)"
LITELLM_SALT="$(openssl rand -hex 32)"

write_env_file "$SECRETS/open-webui.env" open-webui \
  "WEBUI_SECRET_KEY=${OWUI_SECRET}"

write_env_file "$SECRETS/litellm.env" litellm \
  "LITELLM_MASTER_KEY=${LITELLM_MASTER}" \
  "LITELLM_SALT_KEY=${LITELLM_SALT}"

unset OWUI_SECRET LITELLM_MASTER LITELLM_SALT

# --- config files a service must READ, under the same DAC rule --------------
# users.yml is not a secret, but it is subject to the identical trap: Authelia
# runs as uid 0 with ALL capabilities dropped, so it does not bypass file
# permissions, and a users.yml owned by the installing user is unreadable to
# it. The symptom is "error reading the authentication database: ... permission
# denied" nested inside a generic startup-check failure.
USERS="$ROOT/config/authelia/users.yml"
if [ -f "$USERS" ]; then
  apply_mode "$USERS" authelia
  log "  mode    $USERS (readable by authelia)"
fi

# The writable one-file bind Authelia needs under `read_only: true`.
mkdir -p "$ROOT/.runtime"
if [ ! -f "$ROOT/.runtime/authelia-healthcheck.env" ]; then
  : > "$ROOT/.runtime/authelia-healthcheck.env"
fi
chmod 0660 "$ROOT/.runtime/authelia-healthcheck.env" 2>/dev/null || true
chown 0:0 "$ROOT/.runtime/authelia-healthcheck.env" 2>/dev/null \
  || sudo -n chown 0:0 "$ROOT/.runtime/authelia-healthcheck.env" </dev/null 2>/dev/null || true
# The FILE stays root:root — Authelia writes it as uid 0.  The DIRECTORY is
# the operator's, or `aistack doctor`, `support-bundle` and the ordinary
# `ls .runtime` all stop at "permission denied" after a root-shell install.
claim_for_operator "$ROOT/.runtime" 0700

# .env AND THE INSTALL LOG, which only the operator's CLI ever reads.
#
# `.env` is created by install.sh step 10, BEFORE this script runs, and `cp`
# onto an existing file keeps the existing owner — so this is reached as a
# repair on an upgrade and as the first owner on a fresh install.  It is the
# file compose opens first, which makes it the file whose wrong ownership
# hides every other one: `open /…/.env: permission denied` and nothing else.
#
# Doing it HERE is deliberate.  `aistack doctor` names exactly one repair
# command for this whole class — `sudo bash scripts/gen-secrets.sh` — so that
# command has to fix the whole class, not the part this script happens to
# create.
claim_for_operator "$ROOT/.env" 0600
claim_for_operator "$ROOT/install.log" 0640

log ""
log "Done.  Secrets are in: $SECRETS"
log "No value was printed.  To confirm a service can read its own secret and"
log "cannot read another's, run:  aistack doctor"
log ""
log "COPY THESE TWO FILES OFF-HOST THROUGH YOUR OWN CHANNEL, as FILES:"
log "  $SECRETS/backup.key    (without it an encrypted backup cannot be read)"
log "  $SECRETS/backup.hmac   (without it a restore REFUSES to start)"
log "Their contents are not printed here and must not be pasted anywhere."
