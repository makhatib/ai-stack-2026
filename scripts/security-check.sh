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

# THIS SCRIPT REQUIRES PyYAML AND SAYS SO HERE, LOUDLY.
#
# Not a prerequisite of the stack: nothing in install.sh or bin/aistack
# imports yaml (NOM-307 removed the last one).  But the audit half below reads
# security-exceptions.yaml with `import yaml` to learn which services hold an
# E6 environment-variable secret, and those services are held to a STRICTER
# assertion than everything else.  Without the module that read produces an
# empty list, this script has `set -u` but not `set -e`, and the strict half
# of the audit would then cover nothing while still printing its result lines.
# A check that quietly examines fewer things than it claims is worse than no
# check, so it stops instead.
python3 -c 'import yaml' 2>/dev/null || {
  printf '\nsecurity-check: CANNOT RUN — PyYAML is missing.\n\n' >&2
  printf 'The audit reads security-exceptions.yaml to find the E6 services, and\n' >&2
  printf 'without it that list would be empty and the strict half of the audit\n' >&2
  printf 'would silently check nothing.  Install it and re-run:\n\n' >&2
  printf '    apt install python3-yaml      # or: pip install PyYAML\n\n' >&2
  printf 'This is a developer/operator tool.  The INSTALLER does not need it.\n' >&2
  exit 2
}
OUT="$ROOT/security-report-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"

ok()   { printf '  [ ok ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; RC=1; }
warn() { printf '  [warn] %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

# A failed scan has to say WHY.  Trivy writes one FATAL line to stderr; keep
# its tail so "scan failed" is a diagnosis (timeout? auth? disk?) and not a
# shrug.  An absent or empty stderr file must never print as an empty reason.
scan_err() {
  local f="$1" line=""
  if [ -s "$f" ]; then
    line="$(grep -a FATAL "$f" | tail -n 1)"
    [ -n "$line" ] || line="$(tail -n 1 "$f")"
  fi
  [ -n "$line" ] || line="no stderr captured"
  printf '%s' "$line" | sed 's/.*FATAL[[:space:]]*//; s/^Fatal error[[:space:]]*//' | cut -c1-140
}

SKIP_SCAN=0
# Trivy's own default is --timeout 5m.  Measured 2026-10-18: docling-serve
# (15.1GB) dies on that with context-deadline-exceeded, and ollama (9.4GB)
# dies the same way on the SBOM pass, so the two biggest images were
# silently unscanned.  Image size decides this, not content -- raise it
# on a slow disk.
TRIVY_TIMEOUT="${TRIVY_TIMEOUT:-45m}"
[ "${1:-}" = "--audit-only" ] && SKIP_SCAN=1

printf '\nAI Stack 2026 — security check\n'
printf 'Report directory: %s\n' "$OUT"

# REPORT RETENTION (NOM-350).  Placed here on purpose:
#   * AFTER the new directory exists, so the limit counts this run
#     (3 = this report plus the two before it);
#   * BEFORE the scan writes anything, so space is freed before it is
#     needed;
#   * AFTER warn() is defined, so a prune it could not do is a visible
#     [warn] line in this script's own output and not just stderr noise.
# Nothing used to remove these: nineteen had accumulated on AI-Sandbox at
# 1.1 GB while the host's free disk fell ~1 GB every five minutes
# (NOM-350).  Hand-labelled and cited report dirs are never pruned - see
# scripts/prune-reports.sh for exactly what it refuses to touch.
"$ROOT/scripts/prune-reports.sh" --apply \
  || warn "report retention could not prune every old report - see the lines above"

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

hdr "Audit: release gate over the exact-digest scan evidence"
# ci/scan-gate.py EXISTED, WORKED, AND RAN FOR NOBODY [NOM-353].
#
# This script ran ci/invariants.py only, so every control that lives in the
# GATE rather than in the invariants fired exactly when a human typed the
# command -- which, for a standing audit, is never.  Three of them: every
# blocking unit must be claimed by exactly one disposition entry; each
# entry's declared `units`/`critical_units` must EQUAL what the scan
# measures for its own packages; and each approvable entry must carry a
# named-human approval from security-approvers.yaml.  The register's own
# header promises all three.  Prose in a control file is not a control.
#
# IT IS IN PART 1, NOT PART 2, ON PURPOSE.  The gate reads committed YAML
# and already-written JSON -- no network, no download, no daemon -- so it
# belongs in the half that still works on a machine that cannot reach a
# vulnerability database, and it therefore also runs under --audit-only.
# Running it AFTER the Trivy half would gain nothing: the gate requires a
# grype second opinion per pin and this script never produces one (that is
# scripts/scan-evidence.sh), so a pin whose evidence is missing fails the
# gate either way, and fails it for the right reason.
#
# IT IS GIVEN EVERY REPORT DIRECTORY, NOT THE NEWEST ONE.  The evidence for
# a pin is wherever it was scanned, and the grype half only ever exists in
# a hand-labelled scan-evidence dir.  Handing over the whole pool used to be
# unsafe -- index_reports was last-writer-wins on digest, so shell glob
# order could let a trivy-only recheck SHADOW a full scan of the same digest
# (measured NOM-341: docling 3 units instead of 75, total 131 against the
# register's 203, and the gate still called every unit claimed).  NOM-341
# made the winner the more COMPLETE scan -- has grype, then has an OS-layer
# result -- which is a property of the evidence and not of argument order.
# That fix is what makes this invocation legitimate; tests/test-scan-gate.sh
# asserts it still holds, because this call site is the thing that depends
# on it.
#
# A directory with no trivy/ is dropped HERE rather than inside the gate, so
# that "no evidence at all" is reported as NOT RUN instead of arriving as
# ten identical UNSCANNED lines.  The count of dirs actually read is printed
# either way: a gate that examined nothing must not print a pass.
GATE_DIRS=()
for d in "$ROOT"/security-report-*/; do
  [ -d "$d/trivy" ] && GATE_DIRS+=("${d%/}")
done
# GATE_JSON goes in THIS RUN's report dir, not the repo root where the gate
# defaults it.  Two reasons.  The root copy would be rewritten on every audit,
# so the machine-readable verdict would stop belonging to any particular scan;
# and gate.json records each pin's winning `evidence_dir` by name, which makes
# every directory it names CITED to scripts/prune-reports.sh -- so a root
# gate.json that happened to name a generated security-report-<UTC>/ dir would
# pin it against retention forever, which is the NOM-350 disk leak coming back
# through the audit that is supposed to prevent it.
if [ "${#GATE_DIRS[@]}" -eq 0 ]; then
  warn "NOT RUN — no security-report-*/ directory holds a trivy/ subdirectory,"
  warn "so the gate had nothing to read and every pin would report UNSCANNED."
  warn "Produce evidence with scripts/scan-evidence.sh. NOT a clean result."
  RC=1
elif GATE_JSON="$OUT/gate.json" python3 ci/scan-gate.py \
       --dispositions security-findings.yaml versions.env "${GATE_DIRS[@]}" \
       > "$OUT/scan-gate.txt" 2>&1; then
  ok "release gate passes (${#GATE_DIRS[@]} evidence dir(s) read, verdict in $OUT/scan-gate.txt)"
  sed -n 's/^severity convention: /         convention: /p; s/^approval state: /         approvals: /p' \
    "$OUT/scan-gate.txt"
  awk '/^TOTAL/{printf "         measured: units=%s CRITICAL=%s HIGH=%s CVEs=%s\n",$2,$3,$4,$5}' \
    "$OUT/scan-gate.txt"
elif grep -q '^GATE FAILURES' "$OUT/scan-gate.txt"; then
  # The gate reached a verdict and the verdict is NO.
  bad "RELEASE GATE FAILED — see $OUT/scan-gate.txt"
  sed -n '/^GATE FAILURES/,$p' "$OUT/scan-gate.txt" | head -12 | sed 's/^/         /'
else
  # It never got as far as a verdict -- a missing register, an unparseable
  # versions.env, a traceback.  "The gate failed" and "the gate could not
  # run" are different facts and this script does not blur them anywhere
  # else, so it does not blur them here.
  bad "RELEASE GATE COULD NOT RUN — it exited without reaching a verdict."
  bad "This is NOT a gate failure and NOT a pass. Last lines of $OUT/scan-gate.txt:"
  tail -5 "$OUT/scan-gate.txt" | sed 's/^/         /'
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
# A value that IS a secret must not survive into any place a viewer might copy
# from.  Three corrections over the obvious version of this check:
#
#  1. IT ONLY PROVES ANYTHING FOR SECRETS IT COULD READ.  The files are
#     root-owned on purpose, so unprivileged this loop reads nothing, compares
#     nothing, and still printed "no secret value found" — a clean line for a
#     check that never ran.  Count what was read; report NOT RUN at zero.
#     Same rule the scan half already follows.
#  2. An `.env` file is a LIST of secrets, not one secret, and the old version
#     skipped those files whole — which is exactly where litellm's and
#     open-webui's keys live.  Take the values.
#  3. The comparison goes through `grep -Ff <file>`, never `grep -F "$value"`,
#     so no secret is ever an argv entry visible to `ps` on a shared host.
#  4. MEASURED (NOM-258, 2026-10-18).  The blanket form of this check FAILED
#     on a correct stack, and that is worse than it sounds.  E6 in the
#     register declares that open-webui and litellm receive their secret as
#     an ENVIRONMENT VARIABLE because neither upstream supports a _FILE
#     indirection, so LITELLM_MASTER_KEY, LITELLM_SALT_KEY and
#     WEBUI_SECRET_KEY are PRESENT in `compose config` by design.  Reporting
#     the stack's one declared residual as an undetected leak means
#     security-check can never go green, which trains the operator to ignore
#     it -- the check would then be producing the outcome it exists to
#     prevent.
#
#     So the E6 values are split out and held to a DIFFERENT, STRICTER
#     assertion than "absent": they must appear at
#     services.<e6-service>.environment.<KEY> and NOWHERE else in the
#     rendered config, and they must never appear in `compose ps`, which is
#     what a viewer actually copies from.  Everything else must still be
#     absent everywhere.  The E6 service list is READ FROM THE REGISTER, not
#     hardcoded: the register is the artefact a reviewer greps, and a second
#     copy of that list in a script is a copy that drifts.
LEAK=0; READ=0; TOTAL=0
RAW="$(mktemp)"; PATS="$(mktemp)"
RAW6="$(mktemp)"; PATS6="$(mktemp)"
trap 'rm -f "$RAW" "$PATS" "$RAW6" "$PATS6"' EXIT

E6_FILES="$(python3 - <<'PY'
import yaml
reg = yaml.safe_load(open("security-exceptions.yaml")) or {}
for e in reg.get("exceptions") or []:
    if e.get("scope") == "deferred":
        continue
    if "ENVIRONMENT VARIABLE" not in (e.get("exception") or "").upper():
        continue
    svc = e.get("service")
    for s in ([svc] if isinstance(svc, str) else (svc or [])):
        print(f"{s}.env")
PY
)"

for f in secrets/*; do
  [ -f "$f" ] || continue
  TOTAL=$((TOTAL + 1))
  body="$(sudo -n cat "$f" 2>/dev/null || cat "$f" 2>/dev/null || true)"
  [ -n "$body" ] || continue
  READ=$((READ + 1))
  base="$(basename "$f")"
  dest="$RAW"
  printf '%s\n' "$E6_FILES" | grep -qxF "$base" && dest="$RAW6"
  case "$base" in
    *.env) printf '%s\n' "$body" | sed -n 's/^[A-Za-z_][A-Za-z0-9_]*=//p' ;;
    *)     printf '%s\n' "$body" ;;
  esac >> "$dest"
done
# Strip optional quoting, drop anything too short to be distinguishable from
# ordinary text, and de-duplicate.
sed 's/^"//; s/"$//' "$RAW"  | awk 'length($0) >= 16' | sort -u > "$PATS"
sed 's/^"//; s/"$//' "$RAW6" | awk 'length($0) >= 16' | sort -u > "$PATS6"
NCHECKED=$(wc -l < "$PATS")
N6=$(wc -l < "$PATS6")

if [ "$NCHECKED" -gt 0 ]; then
  docker compose ps -a 2>/dev/null | grep -qFf "$PATS" \
    && { bad "a secret value appears in 'compose ps'"; LEAK=1; }
  docker compose config 2>/dev/null | grep -qFf "$PATS" \
    && { bad "a secret value appears in 'compose config'"; LEAK=1; }
fi

if [ "$N6" -gt 0 ]; then
  docker compose ps -a 2>/dev/null | grep -qFf "$PATS6" \
    && { bad "an E6 environment secret appears in 'compose ps' — E6 does NOT cover that"; LEAK=1; }
  # Containment, not absence.  Paths only are printed; no value is ever echoed
  # and the pattern file is passed as a PATH, so no secret is in argv either.
  E6OUT="$(python3 - "$PATS6" <<'PY'
import json, subprocess, sys, yaml
pats = [l.rstrip("\n") for l in open(sys.argv[1]) if l.strip()]
r = subprocess.run(["docker", "compose", "config", "--format", "json"],
                   capture_output=True, text=True)
if r.returncode != 0:
    print("UNRESOLVED"); raise SystemExit(0)
cfg = json.loads(r.stdout)
reg = yaml.safe_load(open("security-exceptions.yaml")) or {}
allowed = set()
for e in reg.get("exceptions") or []:
    if e.get("scope") == "deferred":
        continue
    if "ENVIRONMENT VARIABLE" not in (e.get("exception") or "").upper():
        continue
    svc = e.get("service")
    allowed.update([svc] if isinstance(svc, str) else (svc or []))

hits = []
def walk(node, path):
    if isinstance(node, dict):
        for k, v in node.items():
            walk(v, path + [str(k)])
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, path + [str(i)])
    else:
        s = str(node)
        if any(p in s for p in pats):
            hits.append(path)
walk(cfg, [])

ok_paths, stray = [], []
for h in hits:
    if len(h) >= 4 and h[0] == "services" and h[1] in allowed and h[2] == "environment":
        ok_paths.append(f"{h[1]}.{h[3]}")
    else:
        stray.append(".".join(h))
for p in sorted(set(stray)):
    print("STRAY " + p)
for p in sorted(set(ok_paths)):
    print("OK " + p)
PY
)"
  if printf '%s\n' "$E6OUT" | grep -q '^UNRESOLVED$'; then
    warn "could not render compose config as JSON, so E6 containment was NOT checked"
    RC=1
  elif printf '%s\n' "$E6OUT" | grep -q '^STRAY '; then
    bad "an E6 environment secret appears OUTSIDE its own service's environment:"
    printf '%s\n' "$E6OUT" | sed -n 's/^STRAY /         /p'
    LEAK=1
  else
    NE6=$(printf '%s\n' "$E6OUT" | grep -c '^OK ' || true)
    ok "E6 residual is confined to its own services ($NE6 env keys, $N6 values)"
    printf '%s\n' "$E6OUT" | sed -n 's/^OK /         declared by E6: /p'
  fi
fi
if [ "$TOTAL" -eq 0 ]; then
  warn "NOT RUN — no file under secrets/ was even visible to $(id -un)."
  warn "An empty or unreadable secrets/ is not a stack with no secrets."
  RC=1
elif [ "$READ" -eq 0 ]; then
  warn "NOT RUN — none of the $TOTAL secret files is readable by $(id -un), so"
  warn "nothing was compared.  Re-run with sudo.  This is NOT a clean result."
  RC=1
elif [ "$NCHECKED" -eq 0 ]; then
  warn "NOT RUN — $READ/$TOTAL file(s) read, but no value in them was long"
  warn "enough to search for.  Nothing was compared."
  RC=1
elif [ "$LEAK" -eq 0 ]; then
  # Worded to match what was actually proved.  "No secret in compose output"
  # would be false: the E6 values are in there by design, and the claim this
  # check can make is that every OTHER secret is absent and the E6 ones are
  # confined to where the register says.
  ok "no undeclared secret in compose output ($NCHECKED values from $READ/$TOTAL files)"
  if [ "$READ" -lt "$TOTAL" ]; then
    warn "PARTIAL: $((TOTAL - READ)) of $TOTAL secret files were unreadable by $(id -un)"
    warn "and were therefore never compared.  Re-run with sudo for full coverage."
  fi
fi

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
# RESOLVE THE IMAGE LIST ONCE, AND PROVE IT IS NOT EMPTY.
#
# MEASURED, not hypothesised — this is what the script did before this guard.
# `docker compose config --images` exits 1 and prints NOTHING when the
# invoking user cannot read secrets/*.env, and the Docker CLI reads an
# env_file as the invoking user (E6).  So for an ordinary operator the `for`
# loop below iterated an EMPTY list: it scanned no image, left both counters
# at zero, wrote no JSON, and printed
#
#     TOTAL across all images: CRITICAL=0 HIGH=0
#
# A clean bill of health for a scan that never happened — in the one script
# whose own header says an unrun scan must never be summarised as clean.
# The SBOM half did the same, reporting "[ ok ] SBOMs written" over an empty
# directory.  Both now count what they actually did and compare it to what
# they were asked to do.
if IMAGES="$(docker compose config --images 2>/dev/null)" && [ -n "$IMAGES" ]; then
  NIMAGES=$(printf '%s\n' "$IMAGES" | grep -c .)
else
  IMAGES=""; NIMAGES=0
fi

if [ "$SKIP_SCAN" -eq 1 ]; then
  warn "SKIPPED (--audit-only). NOT a clean result — nothing was scanned."
elif [ "$NIMAGES" -eq 0 ]; then
  warn "NOT RUN — the image list could not be resolved as $(id -un), so NO"
  warn "IMAGE WAS SCANNED. secrets/*.env is root-owned and the Docker CLI"
  warn "reads env_file as the invoking user; run: sudo bin/aistack security-check"
  warn "This is NOT a clean result and must not be summarised as one."
  echo "scan: NOT RUN (image list empty as $(id -un))" > "$OUT/trivy-NOT-RUN.txt"
  RC=1
elif ! docker image inspect aquasec/trivy:latest >/dev/null 2>&1 && ! docker pull -q aquasec/trivy:latest >/dev/null 2>&1; then
  warn "TRIVY COULD NOT BE OBTAINED, SO NO IMAGE WAS SCANNED."
  warn "This is reported as NOT RUN. It is NOT a clean result, and it must"
  warn "not be summarised as one."
  echo "scan: NOT RUN (trivy unavailable)" > "$OUT/trivy-NOT-RUN.txt"
  RC=1
else
  mkdir -p "$OUT/trivy"
  TOTAL_CRIT=0; TOTAL_HIGH=0; SCANNED=0; LAYER_GAPS=0
  for img in $IMAGES; do
    name="$(printf '%s' "$img" | sed 's#[/:@]#_#g' | cut -c1-80)"
    printf '  scanning %s\n' "${img%%@*}"
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$OUT/trivy:/out" \
      aquasec/trivy:latest image --quiet --scanners vuln \
        --severity CRITICAL,HIGH --timeout "$TRIVY_TIMEOUT" \
        --format json --output "/out/${name}.json" \
        "$img" >/dev/null 2>"$OUT/trivy/${name}.err" \
      || warn "    scan failed for $img: $(scan_err "$OUT/trivy/${name}.err")"
    if [ -f "$OUT/trivy/${name}.json" ]; then
      SCANNED=$((SCANNED + 1))
      # trivy exits 0 and writes a valid report even when it skipped a whole
      # layer.  Measured on docling-serve v1.37.0: its base is CentOS Stream 9,
      # trivy logs `WARN Unsupported os family="centos-stream"`, returns no
      # os-pkgs result at all, and a naive count then reads 0 CRITICAL for an
      # OS layer nothing ever looked at.  --quiet hides that warning, so the
      # gap is detected from the report instead: an OS was identified but no
      # os-pkgs result came back.  trivy's own legend separates '-' (not
      # scanned) from '0' (clean); this summary has to separate them too.
      read -r c h osgap osfam < <(python3 - "$OUT/trivy/${name}.json" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("0 0 unreadable -"); raise SystemExit
c=h=0
results=d.get("Results") or []
for r in results:
    for v in r.get("Vulnerabilities") or []:
        if v.get("Severity")=="CRITICAL": c+=1
        elif v.get("Severity")=="HIGH": h+=1
fam=((d.get("Metadata") or {}).get("OS") or {}).get("Family") or ""
gap="none"
if fam and not any(r.get("Class")=="os-pkgs" for r in results): gap="os"
print(c,h,gap,fam or "-")
PY
)
      TOTAL_CRIT=$((TOTAL_CRIT + c)); TOTAL_HIGH=$((TOTAL_HIGH + h))
      printf '    CRITICAL=%s HIGH=%s\n' "$c" "$h"
      if [ "$osgap" = "os" ]; then
        LAYER_GAPS=$((LAYER_GAPS + 1))
        warn "    OS LAYER NOT SCANNED for ${img%%@*}: trivy has no data"
        warn "    source for os=$osfam, so it returned no OS package result."
        warn "    The counts above cover language packages ONLY. The OS layer"
        warn "    is an UNKNOWN here, and must not be summarised as clean."
        RC=1
      elif [ "$osgap" = "unreadable" ]; then
        LAYER_GAPS=$((LAYER_GAPS + 1))
        warn "    REPORT UNREADABLE for ${img%%@*}. Counted as 0/0, which"
        warn "    proves nothing. NOT a clean result."
        RC=1
      fi
    fi
  done
  # The count is part of the result.  A total without it is unreadable.
  printf '\n  SCANNED %s of %s images: CRITICAL=%s HIGH=%s\n' \
    "$SCANNED" "$NIMAGES" "$TOTAL_CRIT" "$TOTAL_HIGH"
  if [ "$SCANNED" -eq 0 ]; then
    warn "NOT RUN — every scan failed. The totals above describe nothing."
    RC=1
  elif [ "$SCANNED" -ne "$NIMAGES" ]; then
    warn "PARTIAL — $((NIMAGES - SCANNED)) image(s) were not scanned. The"
    warn "totals cover only the $SCANNED that were. NOT a clean result."
    RC=1
  elif [ "$LAYER_GAPS" -gt 0 ]; then
    warn "PARTIAL — all $SCANNED images were scanned, but $LAYER_GAPS had a"
    warn "layer trivy could not cover (see above). NOT a clean result."
  else
    ok "every pinned image was scanned, every layer covered"
  fi
  if [ "$TOTAL_CRIT" -gt 0 ]; then
    warn "Critical findings exist. These are UPSTREAM images; the action is"
    warn "to check each finding's fixed-version and bump the pin, not to"
    warn "suppress it. Full JSON is in $OUT/trivy/."
  fi
fi

hdr "Scan: SBOM"
if [ "$SKIP_SCAN" -eq 1 ]; then
  warn "SKIPPED (--audit-only)."
elif [ "$NIMAGES" -eq 0 ]; then
  warn "NOT RUN — no image list (see above). No SBOM was produced."
elif docker image inspect aquasec/trivy:latest >/dev/null 2>&1; then
  mkdir -p "$OUT/trivy"
  for img in $IMAGES; do
    name="$(printf '%s' "$img" | sed 's#[/:@]#_#g' | cut -c1-80)"
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$OUT/trivy:/out" \
      aquasec/trivy:latest image --quiet --format cyclonedx --timeout "$TRIVY_TIMEOUT" \
      --output "/out/${name}.sbom.json" "$img" >/dev/null 2>"$OUT/trivy/${name}.sbom.err" \
      || warn "    SBOM failed for ${img%%@*}: $(scan_err "$OUT/trivy/${name}.sbom.err")"
  done
  NSBOM=$(find "$OUT/trivy" -name '*.sbom.json' -size +1c | wc -l)
  if [ "$NSBOM" -eq "$NIMAGES" ]; then
    ok "$NSBOM SBOMs written to $OUT/trivy/*.sbom.json"
  elif [ "$NSBOM" -eq 0 ]; then
    warn "NO SBOM WAS WRITTEN. Reported as NOT RUN, not as done."
    RC=1
  else
    warn "only $NSBOM of $NIMAGES SBOMs were written — PARTIAL."
    RC=1
  fi
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
