#!/usr/bin/env bash
# Installer idempotency, and the no-secret-in-output rule (S13, §7.5).
#
#   install -> install again -> assert .env, secrets/ and every resolved image
#   digest are IDENTICAL, and that no secret value appeared in any output.
#
# The second half uses a PLANTED CANARY: a known value written into a secret
# file before the run.  Grepping output for "looks like a password" cannot
# prove absence; grepping for a value we know IS a secret can.
#
# WHY THIS TEST REFUSES TO RUN UNPRIVILEGED.
#
# `secrets/*.env` is root-owned, and an `env_file` is read by the DOCKER CLI
# as the invoking user (E6).  So as an ordinary user `docker compose config`
# exits 1 and prints NOTHING.  Every check below then compares empty output to
# empty output and passes:
#
#   - the digest comparison compares "" with "" and reports "unchanged"
#   - each canary probe greps empty output and reports "not in: <probe>"
#
# That is four green lines for four checks that never ran — the same failure
# this test exists to catch.  Preflight therefore PROVES the probes produce
# output before trusting any of them, and exits 2 (cannot verify) otherwise.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
RC=0
ok()   { printf '  [ ok ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; RC=1; }
# SKIPPED IS NOT PASSED, and it is not FAILED either.  Conflating "the check
# could not run" with either one is how a suite reports green on a property
# nobody verified — the same reason security-check reports an unrun scan as
# NOT RUN rather than clean.
skip() { printf '  [skip] %s\n' "$*"; SKIPPED=$((SKIPPED + 1)); }
SKIPPED=0
cannot() { printf '\ninstaller idempotency: CANNOT VERIFY — %s\n' "$*" >&2; exit 2; }

[ -f .env ] || cannot "no .env; run the installer once first"

# --- preflight: the probes must actually produce output --------------------
if ! docker compose config -q 2>/dev/null; then
  printf '\n' >&2
  docker compose config 2>&1 >/dev/null | sed 's/^/  /' >&2
  cannot "\`docker compose config\` fails as $(id -un).

  secrets/*.env is root-owned and the Docker CLI reads env_file as the
  invoking user, so every check in this test would compare empty output to
  empty output and PASS.  Run it the way it needs to run:

      sudo bash tests/installer-idempotent.sh
"
fi
BEFORE_DIGESTS="$(docker compose config --images | sort)"
[ -n "$BEFORE_DIGESTS" ] || cannot "compose resolved zero images; nothing to compare"
NIMG="$(printf '%s\n' "$BEFORE_DIGESTS" | grep -c .)"

CANARY="CANARY-$(openssl rand -hex 12)"
SNAP="$(mktemp -d)"
CANARY_FILE="$ROOT/secrets/.canary"
trap 'rm -rf "$SNAP"; rm -f "$CANARY_FILE"' EXIT

echo
echo "Installer idempotency"

# Plant the canary in a real secret file so it IS a secret by definition.
printf '%s' "$CANARY" > "$CANARY_FILE" || cannot "cannot write into secrets/"
chmod 0600 "$CANARY_FILE"

# Snapshot .env and secrets/.  This must capture EVERY file: a tar that
# silently skipped the unreadable ones would compare the readable half twice.
tar cf "$SNAP/before.tar" .env secrets 2>"$SNAP/tar.err" \
  || cannot "cannot read all of .env and secrets/ as $(id -un): $(tr '\n' ' ' < "$SNAP/tar.err")"

# Re-run the secret generator, which is the idempotent core of the installer.
OUTPUT="$(bash scripts/gen-secrets.sh </dev/null 2>&1)"; GEN_RC=$?
[ "$GEN_RC" -eq 0 ] || bad "gen-secrets.sh exited $GEN_RC on a second run"

tar cf "$SNAP/after.tar" .env secrets 2>/dev/null \
  || cannot "the second snapshot could not be taken"
AFTER_DIGESTS="$(docker compose config --images | sort)"

# Compare CONTENTS, not tar bytes (mtimes differ legitimately).
mkdir -p "$SNAP/b" "$SNAP/a"
tar xf "$SNAP/before.tar" -C "$SNAP/b"
tar xf "$SNAP/after.tar"  -C "$SNAP/a"
if diff -r "$SNAP/b" "$SNAP/a" >/dev/null 2>&1; then
  ok "a second run left .env and secrets/ byte-identical — nothing was rotated"
else
  bad "a second run CHANGED .env or secrets/:"
  diff -rq "$SNAP/b" "$SNAP/a" 2>&1 | head -5 | sed 's/^/         /'
fi

if [ "$BEFORE_DIGESTS" = "$AFTER_DIGESTS" ]; then
  ok "all $NIMG resolved image digests are unchanged"
else
  bad "image digests changed across runs"
fi

echo
echo "No secret in any output"
if printf '%s' "$OUTPUT" | grep -qF "$CANARY"; then
  bad "THE CANARY APPEARED IN INSTALLER OUTPUT"
else
  ok "the planted canary does not appear in installer output ($(printf '%s' "$OUTPUT" | wc -l) lines)"
fi
# Each probe must PRODUCE OUTPUT before its clean result means anything.
probe() {
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    bad "probe produced no usable output (rc=$rc): $*"
  elif printf '%s' "$out" | grep -qF "$CANARY"; then
    bad "the canary appears in: $*"
  else
    ok "not in: $* ($(printf '%s' "$out" | wc -l) lines searched)"
  fi
}
probe docker compose config
probe docker compose ps -a
probe bash scripts/doctor.sh

# support-bundle deliberately REFUSES to run unprivileged, because it cannot
# blank the literal value of a secret it cannot read.  So this sub-check needs
# privilege.  When privilege is unavailable the honest result is SKIPPED:
# nothing about the bundle was observed either way.
#
# `</dev/null` matters.  And note a measured subtlety: a sudo timestamp
# primed in a parent shell does NOT carry into `sudo -n` inside this script,
# so "sudo: a password is required" here is a PRIVILEGE outcome, not a bundle
# failure, and must be classified as such.
if [ "$(id -u)" -eq 0 ]; then
  BUNDLE_OUT="$(bash scripts/support-bundle.sh </dev/null 2>&1 || true)"
else
  BUNDLE_OUT="$(sudo -n bash scripts/support-bundle.sh </dev/null 2>&1 || true)"
fi
B="$(printf '%s' "$BUNDLE_OUT" | grep -o '/.*support-bundle-[^ ]*\.tar\.gz' | head -1)"
if [ -n "$B" ] && [ -f "$B" ]; then
  if tar xzf "$B" -O </dev/null 2>/dev/null | grep -qF "$CANARY"; then
    bad "THE CANARY APPEARS IN THE SUPPORT BUNDLE"
  else
    ok "not in the support bundle ($(du -h "$B" | cut -f1))"
  fi
  rm -f "$B"
elif printf '%s' "$BUNDLE_OUT" | grep -qE 'refusing to run|password is required|not allowed'; then
  skip "support bundle: needs root to redact; re-run this test with sudo"
else
  bad "could not produce a support bundle, and not because of privilege:"
  printf '%s\n' "$BUNDLE_OUT" | tail -3 | sed 's/^/         /'
fi

echo
if [ "$RC" -ne 0 ]; then
  echo "installer idempotency: FAIL"
elif [ "$SKIPPED" -gt 0 ]; then
  echo "installer idempotency: PASS, with $SKIPPED check(s) SKIPPED — see above."
  echo "A skipped check is not a passed one. Re-run with sudo for the full set."
else
  echo "installer idempotency: PASS (all checks ran)"
fi
exit "$RC"
