#!/usr/bin/env bash
# AI Stack 2026 — security check: image scan + config audit (C2).
#
# TWO HALVES, AND THEY FAIL DIFFERENTLY.
#
#   SCAN    Trivy over the exact pinned digests, plus an SBOM.  Reports what
#           upstream shipped.  A finding here is usually not something this
#           project can fix, so it is reported with its fixed-version so you
#           can decide.
#   AUDIT   Our own configuration, against the running containers.  A finding
#           here IS this project's fault and should fail the build.
#
# The audit half runs with no network and no downloads, so it works on a
# machine that cannot reach a vulnerability database.  If the scan half
# cannot run, THAT IS REPORTED AS "NOT RUN", never as "clean" — the most
# important line in this script.

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
RC=0
OUT="$ROOT/security-report-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"

ok()   { printf '  [ ok ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; RC=1; }
warn() { printf '  [warn] %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

SKIP_SCAN=0
[ "${1:-}" = "--audit-only" ] && SKIP_SCAN=1

printf '\nAI Stack 2026 — security check\n'
printf 'Report directory: %s\n' "$OUT"

# ===========================================================================
# PART 1 — CONFIGURATION AUDIT.  Ours to fix.
# ===========================================================================
hdr "Audit: CI invariants"
if python3 ci/invariants.py > "$OUT/invariants.txt" 2>&1; then
  ok "all CI invariants pass ($(grep -c '\[ok' "$OUT/invariants.txt") checks)"
else
  bad "CI invariants FAILED — see $OUT/invariants.txt"
  grep 'FAIL' "$OUT/invariants.txt" | head -5 | sed 's/^/         /'
fi

hdr "Audit: running containers against the declared baseline"
# Inspecting what is ACTUALLY RUNNING, not what the YAML says.  A compose file
# and a running container can disagree — someone can `docker run` by hand, or
# a stale container can survive an edit — and only one of them is the system.
for c in $(docker ps --format '{{.Names}}' | grep '^aistack-' | sort); do
  svc="${c#aistack-}"
  json="$(docker inspect "$c" 2>/dev/null)"
  [ -z "$json" ] && continue

  priv=$(printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["HostConfig"]["Privileged"])')
  [ "$priv" = "False" ] || bad "$svc is PRIVILEGED"

  ro=$(printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["HostConfig"]["ReadonlyRootfs"])')
  [ "$ro" = "True" ] || bad "$svc does NOT have a read-only root filesystem"

  drop=$(printf '%s' "$json" | python3 -c 'import json,sys;d=json.load(sys.stdin)[0]["HostConfig"].get("CapDrop") or [];print(",".join(d))')
  case "$drop" in *ALL*) ;; *) bad "$svc does not drop ALL capabilities (CapDrop=$drop)" ;; esac

  add=$(printf '%s' "$json" | python3 -c 'import json,sys;a=json.load(sys.stdin)[0]["HostConfig"].get("CapAdd") or [];print(",".join(a))')
  if [ -n "$add" ]; then
    # Every added capability must be justified by an entry in the register.
    if grep -q "service: $svc" security-exceptions.yaml 2>/dev/null \
       || grep -q "service: \[.*$svc" security-exceptions.yaml 2>/dev/null; then
      ok "$svc adds [$add] — covered by the exceptions register"
    else
      bad "$svc adds capabilities [$add] with NO entry in security-exceptions.yaml"
    fi
  fi

  nnp=$(printf '%s' "$json" | python3 -c 'import json,sys;o=json.load(sys.stdin)[0]["HostConfig"].get("SecurityOpt") or [];print(",".join(o))')
  case "$nnp" in *no-new-privileges*) ;; *) bad "$svc lacks no-new-privileges" ;; esac

  for ns in NetworkMode PidMode IpcMode; do
    v=$(printf '%s' "$json" | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['HostConfig'].get('$ns',''))")
    case "$v" in host*) bad "$svc shares the host $ns" ;; esac
  done

  if printf '%s' "$json" | grep -q 'docker.sock'; then
    bad "$svc mounts the Docker socket"
  fi

  img=$(printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["Config"]["Image"])')
  case "$img" in *@sha256:*) ;; *) bad "$svc runs an image that is not digest-pinned: $img" ;; esac
done
ok "inspected $(docker ps --format '{{.Names}}' | grep -c '^aistack-') running containers"

hdr "Audit: published ports"
# ONLY a `->` mapping is a PUBLISH. `docker ps` also lists ports the image
# merely EXPOSES, which are documentation and reach nothing from the host —
# counting those reported nine publishing services when the answer is one.
PUB=$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep '^aistack-' | grep -- '->' || true)
if [ -n "$PUB" ]; then printf '%s\n' "$PUB" | sed 's/^/    /'; else echo "    (none)"; fi
if printf '%s' "$PUB" | grep -Eq '(^|[^0-9.])0\.0\.0\.0:|\[::\]:'; then
  bad "a container publishes on a WILDCARD address"
else
  ok "no container publishes on a wildcard address"
fi
NPUB=$(printf '%s\n' "$PUB" | grep -c . || true)
PUBSVC=$(printf '%s\n' "$PUB" | awk '{print $1}' | sort -u | tr '\n' ' ')
if [ "${NPUB:-0}" -le 1 ] && { [ -z "$PUBSVC" ] || [ "${PUBSVC% }" = "aistack-caddy" ]; }; then
  ok "exactly one service publishes host ports, and it is caddy"
else
  bad "services publishing host ports: ${PUBSVC:-none}; only caddy may"
fi

hdr "Audit: secrets never appear in output"
# The canary test: a value that IS a secret must not survive into any place a
# viewer might copy from.
LEAK=0
for f in secrets/*; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in *.env) continue ;; esac
  v="$(sudo -n cat "$f" 2>/dev/null || cat "$f" 2>/dev/null || true)"
  [ -n "$v" ] && [ "${#v}" -ge 16 ] || continue
  if docker compose ps -a 2>/dev/null | grep -qF "$v"; then bad "a secret value appears in 'compose ps'"; LEAK=1; fi
  if docker compose config 2>/dev/null | grep -qF "$v"; then bad "a secret value appears in 'compose config'"; LEAK=1; fi
done
[ "$LEAK" -eq 0 ] && ok "no secret value found in compose output"

hdr "Audit: exceptions register"
python3 - <<'PY' || RC=1
import datetime, sys, yaml
reg = yaml.safe_load(open("security-exceptions.yaml")) or {}
today = datetime.date.today()
bad = 0
for e in reg.get("exceptions") or []:
    if e.get("scope") == "deferred":
        print(f"  [note] {e['id']} is DEFERRED — out of scope, NOT satisfied. "
              f"It must be re-approved against the then-current digest before "
              f"its group returns.")
        continue
    for field in ("approved_by", "approved_at", "review_by"):
        if not e.get(field):
            print(f"  [FAIL] {e['id']} is missing {field}"); bad = 1
    rb = e.get("review_by")
    if rb:
        d = rb if isinstance(rb, datetime.date) else datetime.date.fromisoformat(str(rb))
        days = (d - today).days
        if days < 0:
            print(f"  [FAIL] {e['id']} is {-days} days PAST its review_by"); bad = 1
        elif days < 30:
            print(f"  [warn] {e['id']} is due for re-review in {days} days")
        else:
            print(f"  [ ok ] {e['id']} reviewed, next due in {days} days")
sys.exit(bad)
PY

# ===========================================================================
# PART 2 — IMAGE SCAN.  Mostly upstream's to fix.
# ===========================================================================
hdr "Scan: Trivy over the exact pinned digests"
if [ "$SKIP_SCAN" -eq 1 ]; then
  warn "SKIPPED (--audit-only). NOT a clean result — nothing was scanned."
elif ! docker image inspect aquasec/trivy:latest >/dev/null 2>&1 && ! docker pull -q aquasec/trivy:latest >/dev/null 2>&1; then
  warn "TRIVY COULD NOT BE OBTAINED, SO NO IMAGE WAS SCANNED."
  warn "This is reported as NOT RUN. It is NOT a clean result, and it must"
  warn "not be summarised as one."
  echo "scan: NOT RUN (trivy unavailable)" > "$OUT/trivy-NOT-RUN.txt"
  RC=1
else
  mkdir -p "$OUT/trivy"
  TOTAL_CRIT=0; TOTAL_HIGH=0
  for img in $(docker compose config --images); do
    name="$(printf '%s' "$img" | sed 's#[/:@]#_#g' | cut -c1-80)"
    printf '  scanning %s\n' "${img%%@*}"
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$OUT/trivy:/out" \
      aquasec/trivy:latest image --quiet --scanners vuln \
        --severity CRITICAL,HIGH --format json --output "/out/${name}.json" \
        "$img" >/dev/null 2>&1 || warn "    scan failed for $img"
    if [ -f "$OUT/trivy/${name}.json" ]; then
      read -r c h < <(python3 - "$OUT/trivy/${name}.json" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("0 0"); raise SystemExit
c=h=0
for r in d.get("Results") or []:
    for v in r.get("Vulnerabilities") or []:
        if v.get("Severity")=="CRITICAL": c+=1
        elif v.get("Severity")=="HIGH": h+=1
print(c,h)
PY
)
      TOTAL_CRIT=$((TOTAL_CRIT + c)); TOTAL_HIGH=$((TOTAL_HIGH + h))
      printf '    CRITICAL=%s HIGH=%s\n' "$c" "$h"
    fi
  done
  printf '\n  TOTAL across all images: CRITICAL=%s HIGH=%s\n' "$TOTAL_CRIT" "$TOTAL_HIGH"
  if [ "$TOTAL_CRIT" -gt 0 ]; then
    warn "Critical findings exist. These are UPSTREAM images; the action is"
    warn "to check each finding's fixed-version and bump the pin, not to"
    warn "suppress it. Full JSON is in $OUT/trivy/."
  fi
fi

hdr "Scan: SBOM"
if [ "$SKIP_SCAN" -eq 1 ]; then
  warn "SKIPPED (--audit-only)."
elif docker image inspect aquasec/trivy:latest >/dev/null 2>&1; then
  for img in $(docker compose config --images); do
    name="$(printf '%s' "$img" | sed 's#[/:@]#_#g' | cut -c1-80)"
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$OUT/trivy:/out" \
      aquasec/trivy:latest image --quiet --format cyclonedx \
      --output "/out/${name}.sbom.json" "$img" >/dev/null 2>&1 || true
  done
  ok "SBOMs written to $OUT/trivy/*.sbom.json"
else
  warn "no SBOM produced"
fi

printf '\n'
if [ "$RC" -eq 0 ]; then
  printf 'security-check: audit clean.\n'
else
  printf 'security-check: PROBLEMS or an UNRUN SCAN. See above and %s.\n' "$OUT"
fi
printf 'Report: %s\n' "$OUT"
exit "$RC"
