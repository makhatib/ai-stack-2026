#!/usr/bin/env bash
# The optional profiles of DoD 2.4 (NOM-415), as properties of the repo.
#
# A. PRESENT WHEN SELECTED, ABSENT WHEN NOT.  For each COMPOSE_PROFILES value,
#    `docker compose config --services` must list exactly the expected set of
#    optional services: none of them with no optional profile, and each
#    profile's own services and no other profile's with it.
#
# B. THE DERIVED SETTINGS.  `aistack pin|up` writes the AISTACK-PROFILE-ENV
#    block into .env from COMPOSE_PROFILES.  The shipped function is extracted
#    from bin/aistack and run against fixture .env files: empty with no
#    profile (Open WebUI as the MVP had it), the Arabic parser with
#    docs-arabic, the speech URLs with voice-arabic, idempotent on a re-run,
#    and the rest of .env untouched.
#
# C. THE GUARD HAS A POSITIVE CONTROL.  I19 passing on the repo says nothing
#    unless it fails on what it exists to stop.  Each case copies the repo,
#    breaks ONE property, and requires I19 (or I17, for the gVisor runtime) to
#    FAIL; the unmodified copy must pass every invariant first.
#
# Needs the docker CLI (compose renders the file; no daemon call starts
# anything) and python3.  Refuses (exit 2) if an extraction is empty or if
# fewer than MIN_ASSERTIONS ran.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
RC=0
TOTAL=0
MIN_ASSERTIONS=30
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

refuse() { printf 'optional profiles: CANNOT VERIFY -- %s\n' "$1" >&2; exit 2; }
ok()   { TOTAL=$((TOTAL + 1)); printf '  [ ok ] %s\n' "$1"; }
bad()  { TOTAL=$((TOTAL + 1)); printf '  [FAIL] %s\n' "$1"; RC=1; }

docker compose version >/dev/null 2>&1 || refuse "no docker compose CLI"

OPTIONAL="docling-arabic openclaw openclaw-sandbox stt-arabic tts-arabic"

# ---------------------------------------------------------------------------
printf '\n  A. present when selected, absent when not\n'
# ---------------------------------------------------------------------------
# Profiles are applied only to an INTERPOLATED render (`--no-interpolate
# --services` lists every service whatever COMPOSE_PROFILES says), so render
# with the pins plus a placeholder for every required variable (an IP
# address, because one of them is a bind address and any string fits the rest).
ENVF="$TMPD/render.env"
{ grep -E '^[A-Z0-9_]+=' versions.env
  grep -oE '\$\{[A-Z0-9_]+:\?' compose.yaml | sed -E 's/^\$\{([A-Z0-9_]+):\?$/\1=127.0.0.1/' | sort -u
} > "$ENVF"
services_for() {  # $1 = COMPOSE_PROFILES -> sorted optional services in the render
  COMPOSE_PROFILES="$1" docker compose -f compose.yaml --env-file "$ENVF" config --services 2>"$TMPD/err" \
    | grep -xF -f <(tr ' ' '\n' <<<"$OPTIONAL") | sort | paste -sd' ' -
}
expect_set() {  # $1 profiles, $2 expected (space-separated, sorted)
  local got; got="$(services_for "$1")"
  if [ -s "$TMPD/err" ] && grep -qi error "$TMPD/err"; then
    bad "COMPOSE_PROFILES='$1': compose did not render: $(head -1 "$TMPD/err")"; return
  fi
  if [ "$got" = "$2" ]; then ok "$(printf '%-52s -> %s' "COMPOSE_PROFILES='$1'" "${got:-(none)}")"
  else bad "COMPOSE_PROFILES='$1': expected '${2:-(none)}', got '${got:-(none)}'"; fi
}
NONE="$(COMPOSE_PROFILES= docker compose -f compose.yaml --env-file "$ENVF" config --services 2>"$TMPD/err" | wc -l)"
ALL_SVCS="$(COMPOSE_PROFILES='*' docker compose -f compose.yaml --env-file "$ENVF" config --services 2>/dev/null | wc -l)"
[ "$NONE" -gt 0 ] || refuse "compose renders no services with no profile: $(head -1 "$TMPD/err")"
# A filter that is not filtering would pass every "absent" case below.
[ "$ALL_SVCS" -gt "$NONE" ] || refuse "every profile on renders $ALL_SVCS services, none renders $NONE: profiles are not being applied"
expect_set ""                                  ""
expect_set "knowledge"                         ""
expect_set "knowledge,tracing"                 ""
expect_set "openclaw"                          "openclaw openclaw-sandbox"
expect_set "voice-arabic"                      "stt-arabic tts-arabic"
expect_set "docs-arabic"                       "docling-arabic"
expect_set "knowledge,openclaw,voice-arabic,docs-arabic" "$(tr ' ' '\n' <<<"$OPTIONAL" | sort | paste -sd' ' -)"
# Nothing optional sits in the default (no-profile) set by another route.
for s in $OPTIONAL; do
  # --format json renders only active services, so ask with every profile on.
  prof="$(COMPOSE_PROFILES='*' docker compose -f compose.yaml config --no-interpolate --format json 2>/dev/null \
    | python3 -c "import json,sys; print(','.join(json.load(sys.stdin)['services']['$s'].get('profiles') or []))")"
  case "$prof" in
    openclaw|voice-arabic|docs-arabic) ok "$(printf '%-52s -> profiles: [%s]' "$s" "$prof")" ;;
    *) bad "$s has profiles [$prof]; it must belong to exactly one optional profile" ;;
  esac
done

# ---------------------------------------------------------------------------
printf '\n  B. derived settings (render_profile_env, extracted from bin/aistack)\n'
# ---------------------------------------------------------------------------
FN="$TMPD/render.sh"
sed -n '/^render_profile_env() {$/,/^}$/p' bin/aistack > "$FN"
[ -s "$FN" ] || refuse "render_profile_env() could not be extracted from bin/aistack"
[ "$(grep -c '^render_profile_env() {$' bin/aistack)" = 1 ] || refuse "render_profile_env() is defined more than once"
grep -q 'render_profile_env || return 1' bin/aistack || refuse "_up no longer calls render_profile_env"
grep -q '^cmd_pin()    { render_pins; render_profile_env; }' bin/aistack || refuse "cmd_pin no longer calls render_profile_env"
render() {  # $1 = COMPOSE_PROFILES line value
  mkdir -p "$TMPD/r"; printf 'AISTACK_TZ=UTC\nCOMPOSE_PROFILES=%s\nOTHER=keep me\n' "$1" > "$TMPD/r/.env"
  ( ROOT="$TMPD/r"; die() { echo "DIE $*" >&2; exit 1; }; unset COMPOSE_PROFILES
    # shellcheck disable=SC1090
    . "$FN"; render_profile_env >/dev/null )
}
block() { sed -n '/^# AISTACK-PROFILE-ENV:BEGIN/,/^# AISTACK-PROFILE-ENV:END/p' "$TMPD/r/.env" | grep -v '^#'; }

render "knowledge"
if [ -z "$(block)" ] && grep -q '^# AISTACK-PROFILE-ENV:BEGIN' "$TMPD/r/.env"; then ok "no optional profile: block present and empty (MVP behaviour)"
else bad "no optional profile: expected an empty block, got: $(block | paste -sd' ' -)"; fi
render "knowledge,docs-arabic"
if block | grep -qx 'AISTACK_DOCLING_URL=http://docling-arabic:5001' && block | grep -q '"ocr_lang": \["ara", "eng"\]' \
   && ! block | grep -q AISTACK_STT; then ok "docs-arabic: parser is docling-arabic, OCR ara+eng, no speech settings"
else bad "docs-arabic block wrong: $(block | paste -sd' ' -)"; fi
render "voice-arabic"
if block | grep -qx 'AISTACK_STT_URL=http://stt-arabic:8000/v1' && block | grep -qx 'AISTACK_TTS_URL=http://tts-arabic:8000/v1' \
   && ! block | grep -q DOCLING; then ok "voice-arabic: STT and TTS point at the local services, parser untouched"
else bad "voice-arabic block wrong: $(block | paste -sd' ' -)"; fi
cp "$TMPD/r/.env" "$TMPD/before"
( ROOT="$TMPD/r"; die() { exit 1; }; unset COMPOSE_PROFILES; . "$FN"; render_profile_env >/dev/null )
if cmp -s "$TMPD/before" "$TMPD/r/.env"; then ok "a second run changes nothing (idempotent)"; else bad "a second run changed .env"; fi
if [ "$(grep -c AISTACK-PROFILE-ENV:BEGIN "$TMPD/r/.env")" = 1 ] && grep -qx 'OTHER=keep me' "$TMPD/r/.env"; then
  ok "one block, the rest of .env untouched"; else bad "block duplicated or other lines lost"; fi
# Turning a profile OFF must remove its settings, or Open WebUI would call a
# service that no longer exists.
sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=knowledge/' "$TMPD/r/.env"
( ROOT="$TMPD/r"; die() { exit 1; }; unset COMPOSE_PROFILES; . "$FN"; render_profile_env >/dev/null )
if [ -z "$(block)" ]; then ok "profile turned off by hand in .env: its settings are removed on the next up"
else bad "profile turned off but settings remain: $(block | paste -sd' ' -)"; fi
if [ "$(stat -c %a "$TMPD/r/.env")" = 600 ]; then ok ".env stays 0600"; else bad ".env mode is $(stat -c %a "$TMPD/r/.env")"; fi

# ---------------------------------------------------------------------------
printf '\n  C. I19 has a positive control: each broken copy must FAIL\n'
# ---------------------------------------------------------------------------
COPY="$TMPD/copy"
fresh() {
  rm -rf "$COPY"; mkdir -p "$COPY"
  tar -C "$ROOT" --exclude=./.git --exclude=./secrets --exclude=./backups --exclude=./.env -cf - . | tar -C "$COPY" -xf -
  git -C "$COPY" init -q   # I6 asks git what is ignored; a copy without a repo is UNKNOWN there
}
inv() { (cd "$COPY" && python3 ci/invariants.py --root "$COPY" 2>&1); }

fresh
out="$(inv)"; if printf '%s' "$out" | grep -q '^All [0-9]* invariants pass'; then ok "negative control: the unmodified copy passes every invariant"
else bad "negative control: the unmodified copy does not pass: $(printf '%s' "$out" | grep FAIL | head -3 | paste -sd' ' -)"; fi

mutate() {  # $1 label, $2 invariant that must fail, $3 python edit run in $COPY
  fresh
  (cd "$COPY" && python3 -c "$3") || { bad "$1: the mutation itself failed to apply"; return; }
  out="$(inv)"
  if printf '%s\n' "$out" | grep -q "^  \[FAIL\] $2 "; then ok "$(printf '%-60s -> %s FAIL' "$1" "$2")"
  else bad "$1: $2 did not fail"; fi
}
J='import json; p="config/openclaw/openclaw.json"; c=json.load(open(p));'
W='json.dump(c, open(p,"w"))'
mutate "openclaw sandbox mode off for non-main sessions" I19 "$J c['agents']['defaults']['sandbox']['mode']='non-main'; $W"
mutate "openclaw sandbox on the docker backend"           I19 "$J c['agents']['defaults']['sandbox']['backend']='docker'; $W"
mutate "install policy given an exec command (ClawHub on)" I19 "$J c['security']['installPolicy']['exec']={'command':'/bin/true'}; $W"
mutate "bundled skills allowed"                           I19 "$J c['skills']['allowBundled']=['github']; $W"
mutate "install policy covers skills only, not plugins"  I19 "$J c['security']['installPolicy']['targets']=['skill']; $W"
mutate "empty bundled-skill list (OpenClaw reads: no list)" I19 "$J c['skills']['allowBundled']=[]; $W"
mutate "skill workshop learning on"                       I19 "$J c['skills']['workshop']['autonomous']['mode']='auto'; $W"
mutate "gateway bound to lan"                             I19 "$J c['gateway']['bind']='lan'; $W"
mutate "elevated tools on"                                I19 "$J c['tools']['elevated']['enabled']=True; $W"
mutate "a channel configured"                             I19 "$J c['channels']={'telegram':{'enabled':True}}; $W"
mutate "OpenClaw older than 2026.4.22"                    I19 "import re; p='versions.env'; t=open(p).read(); open(p,'w').write(re.sub(r'(?m)^OPENCLAW_TAG=.*$', 'OPENCLAW_TAG=2026.4.1', t))"
mutate "a non-commercial licence in the STT lock"         I19 "p='build/stt-arabic/models.lock'; t=open(p).read(); open(p,'w').write(t.replace(' Apache-2.0\n', ' CC-BY-NC-4.0\n', 1))"
mutate "a weight row without a commit revision"           I19 "p='build/tts-arabic/models.lock'; t=open(p).read(); open(p,'w').write(t.replace('5bb1f6ee58e50c3b8d408bc82a6d3740c2db6e18', 'main', 1))"
mutate "Dockerfile ADDs a file models.lock does not list" I19 "p='build/docling-arabic/Dockerfile'; t=open(p).read(); open(p,'w').write(t.replace('sha256:ab9d', 'sha256:0b9d', 1))"
mutate "TTS server gains voice cloning"                   I19 "p='build/tts-arabic/server.py'; open(p,'a').write('\n# model.prepare_conditionals(path)\n')"
mutate "a service requests a GPU"                         I19 "p='compose.yaml'; t=open(p).read(); open(p,'w').write(t.replace('    container_name: aistack-stt-arabic\n', '    container_name: aistack-stt-arabic\n    gpus: all\n', 1))"
mutate "openclaw-sandbox loses its gVisor runtime"        I17 "p='compose.yaml'; t=open(p).read(); i=t.index('  openclaw-sandbox:\n'); j=t.index('    runtime: runsc\n', i); open(p,'w').write(t[:j]+t[j+len('    runtime: runsc\n'):])"

printf '\n  %s assertions evaluated\n' "$TOTAL"
[ "$TOTAL" -ge "$MIN_ASSERTIONS" ] || refuse "only $TOTAL of at least $MIN_ASSERTIONS assertions ran"
echo
if [ "$RC" -eq 0 ]; then echo "optional profiles: PASS"; else echo "optional profiles: FAIL"; fi
exit "$RC"
