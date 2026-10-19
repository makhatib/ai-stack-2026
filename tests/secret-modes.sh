#!/usr/bin/env bash
# Per-service secret modes (S13), and the two properties NOM-307 cost us.
#
#   1. The uid:gid decision READS manifest.yaml WITHOUT PyYAML.  PyYAML is not
#      a documented prerequisite; on a machine that has only what
#      docs/install.md asks for, the old Python heredoc hit
#      `except ImportError: sys.exit(0)`, printed nothing, exited 0, and every
#      secret in the stack was written 0600 root:root behind a WARN.
#   2. AN UNRESOLVABLE CONSUMER IS A STOP.  That WARN-and-continue branch is
#      the one path in gen-secrets.sh that did not fail loudly, and it is the
#      path a missing library drove everything down.
#
# Both are asserted by BEHAVIOUR here, not by reading the source: the reader is
# run, and gen-secrets.sh is run against a manifest with the entry removed.
#
# Needs: bash, awk, sed, openssl.  Deliberately NOT python3 and NOT PyYAML —
# this test must pass on the documented-minimum machine too.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
RC=0
ok()   { printf '  [ ok ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; RC=1; }
skip() { printf '  [skip] %s\n' "$*"; }

READER="$ROOT/scripts/manifest-runtime-ids.sh"
printf '\nsecret modes — the manifest read and the refusal\n\n'

# --- 1. every declared consumer resolves, and the value is a real uid:gid ---
DECLARED="$(awk '
  /^[^[:space:]#]/ { top=$0; sub(/:.*$/,"",top); name=""; next }
  /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ {
      name=$0; sub(/^  /,"",name); sub(/:[[:space:]]*(#.*)?$/,"",name); next }
  (top=="services" || top=="helpers") && /^    runtime_ids:/ { print name }
' manifest.yaml)"
[ -n "$DECLARED" ] || bad "no runtime_ids entries found in manifest.yaml at all"
for svc in $DECLARED; do
  ids="$("$READER" "$svc" 2>/dev/null)"
  case "$ids" in
    *[0-9]:*[0-9]) ok "$svc -> $ids" ;;
    *) bad "$svc declares runtime_ids in manifest.yaml but the reader returned '$ids'" ;;
  esac
done

# --- 2. the read does not go through Python at all --------------------------
# ASSERTED BY BEHAVIOUR, not by grepping the source for the word "python": the
# files carry comments about the Python heredoc they replaced, and a textual
# check would either fail on those comments or need an allowlist, which is how
# a check stops being one.  So python3 is REPLACED on PATH by a stub that
# refuses to run and leaves a marker.  If the marker appears, something in the
# path still needs an interpreter.
STUBDIR="$(mktemp -d)"
cat > "$STUBDIR/python3" <<'STUB'
#!/bin/sh
printf 'called\n' >> "$PYSTUB_MARKER"
echo "python3 stub: refusing to run" >&2
exit 9
STUB
chmod +x "$STUBDIR/python3"
export PYSTUB_MARKER="$STUBDIR/called"
TMP=""; TMP2=""
trap 'rm -rf "$STUBDIR" "$TMP" "$TMP2"' EXIT
# NOPY is used for every run below, so sections 4 and 5 assert the same
# property for the whole gen-secrets path and not only for the reader.
NOPY="$STUBDIR:$PATH"
if ids="$(PATH="$NOPY" "$READER" postgres 2>/dev/null)" \
   && [ "$ids" = "999:999" ] && [ ! -e "$PYSTUB_MARKER" ]; then
  ok "postgres -> 999:999 with python3 replaced by a stub that refuses to run"
else
  bad "the manifest read still depends on python3 (got '${ids:-}', marker: $([ -e "$PYSTUB_MARKER" ] && echo called || echo absent))"
fi

# --- 3. an unknown consumer is reported, not answered with silence ----------
out="$("$READER" definitely-not-a-service 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "the reader exited 0 for a service that does not exist (printed: '$out')"
elif [ -n "$out" ]; then
  bad "the reader printed '$out' on stdout for a service that does not exist"
else
  ok "an unknown consumer exits non-zero with nothing on stdout"
fi

# --- 4. gen-secrets.sh REFUSES when it cannot resolve a consumer ------------
# A temporary root with postgres's runtime_ids deleted.  Nothing is written
# into the real repository.
TMP="$(mktemp -d)"
mkdir -p "$TMP/scripts"
cp scripts/gen-secrets.sh scripts/manifest-runtime-ids.sh "$TMP/scripts/"
sed '/^  postgres:$/,/^  [^ ]/{/^    runtime_ids:/d}' manifest.yaml > "$TMP/manifest.yaml"
if "$TMP/scripts/manifest-runtime-ids.sh" postgres >/dev/null 2>&1; then
  skip "could not remove postgres's runtime_ids from the fixture; refusal not tested"
else
  genout="$(PATH="$NOPY" bash "$TMP/scripts/gen-secrets.sh" </dev/null 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "gen-secrets.sh exited 0 with an unresolvable consumer — this is NOM-307"
  elif printf '%s' "$genout" | grep -q 'runtime_ids' && printf '%s' "$genout" | grep -q 'postgres'; then
    ok "gen-secrets.sh refuses, naming the consumer and runtime_ids (exit $rc)"
  else
    bad "gen-secrets.sh failed (exit $rc) but its output names neither the consumer nor runtime_ids"
  fi
  if printf '%s' "$genout" | grep -qi 'WARN.*no runtime_ids'; then
    bad "the WARN-and-continue branch is still reachable"
  fi
fi

# --- 5. the applied mode, end to end ----------------------------------------
# Only root can chgrp to a group it is not in, which is the case the installer
# actually runs in.  Unprivileged, this is reported as skipped rather than as
# a pass over a check that did not run.
if [ "$(id -u)" != "0" ]; then
  skip "not root: the 0640 root:999 assertion needs the privilege the installer has"
else
  TMP2="$(mktemp -d)"
  mkdir -p "$TMP2/scripts"
  cp scripts/gen-secrets.sh scripts/manifest-runtime-ids.sh "$TMP2/scripts/"
  cp manifest.yaml "$TMP2/manifest.yaml"
  if PATH="$NOPY" bash "$TMP2/scripts/gen-secrets.sh" </dev/null >"$TMP2/log" 2>&1; then
    for f in postgres_superuser_password app_db_passwords; do
      mode="$(stat -c '%a %u:%g' "$TMP2/secrets/$f" 2>/dev/null)"
      case "$mode" in
        "640 0:999") ok "secrets/$f is $mode (postgres runs as 999:999)" ;;
        *) bad "secrets/$f is '$mode', expected '640 0:999'" ;;
      esac
    done
    mode="$(stat -c '%a %u:%g' "$TMP2/secrets/n8n_encryption_key" 2>/dev/null)"
    case "$mode" in
      "640 0:1000") ok "secrets/n8n_encryption_key is $mode (n8n runs as 1000:1000)" ;;
      *) bad "secrets/n8n_encryption_key is '$mode', expected '640 0:1000'" ;;
    esac
    if grep -q 'WARN' "$TMP2/log"; then
      bad "a clean run still printed a WARN:"; sed 's/^/           /' "$TMP2/log" | grep WARN
    else
      ok "a clean run printed no WARN at all, on a machine with no usable python3"
    fi
    if [ -e "$PYSTUB_MARKER" ]; then
      bad "gen-secrets.sh called python3; the secret path must not need one"
    else
      ok "gen-secrets.sh never called python3"
    fi
  else
    bad "gen-secrets.sh failed on an unmodified manifest:"; sed 's/^/           /' "$TMP2/log"
  fi
fi

printf '\n'
[ "$RC" -eq 0 ] && printf 'secret modes: all checks passed.\n' || printf 'secret modes: PROBLEMS FOUND.\n'
exit $RC
