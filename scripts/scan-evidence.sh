#!/usr/bin/env bash
# AI Stack 2026 — produce the full C2 scan evidence set (NOM-301).
#
# THREE TOOLS, BECAUSE ONE IS NOT ENOUGH AND WE CAN NAME THE GAP:
#
#   trivy   vuln + secret + misconfig, per image, at the exact pinned digest.
#   syft    SBOM per image (syft-json to feed grype, spdx-json for humans).
#   grype   the second opinion, fed from the syft SBOM.
#
# WHY GRYPE IS NOT OPTIONAL HERE.  trivy has NO DATA SOURCE for CentOS Stream.
# On docling-serve v1.37.0 it identifies the OS, logs
#   INFO  Detected OS      family="centos-stream" version="9"
#   WARN  Unsupported os   family="centos-stream"
# returns NO os-pkgs result at all, and still exits 0 with a valid report.
# grype resolves ID=centos VERSION_ID=9 onto the Red Hat feed and returns the
# 2133 rpm findings trivy cannot see.  Running both is what turns that layer
# from an UNKNOWN into an answer.
#
# WHY THE IMAGE LIST COMES FROM versions.env.  NOM-258 scanned a hand-written
# images.txt, which silently omitted agentgateway — a pinned image that was
# therefore unmeasured rather than clean.  Deriving the list from the pin file
# means a pin cannot be left out without the gate noticing.  Compare with
# `docker compose config --images`, which this deliberately does NOT use:
# that needs secrets/*.env readable and returns an EMPTY list for an ordinary
# operator, which is how an empty scan once reported CRITICAL=0.
#
# Re-running is cheap and safe: each step SKIPS an output that already exists,
# so an interrupted run resumes instead of re-downloading ~1GB of databases
# and re-extracting a 15GB image.
#
# Rollback: this script only writes into its own $OUT directory and two named
# Docker volumes.  To undo it completely:
#     rm -rf <OUT>  &&  docker volume rm aistack-trivy-cache aistack-grype-cache
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

OUT="${OUT:-$ROOT/security-report-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT/trivy" "$OUT/syft" "$OUT/grype"
LOG="$OUT/driver.log"
say() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }

# Named volumes so a re-run reuses the vulnerability databases rather than
# re-downloading them, and so no database ever lands in the report directory
# (it would then be scanned as part of the repo on the next pass).
docker volume create aistack-trivy-cache >/dev/null
docker volume create aistack-grype-cache >/dev/null

# --- the image list, derived from the pins ----------------------------------
if [ ! -f "$OUT/images.txt" ]; then
  python3 - "$ROOT/versions.env" > "$OUT/images.txt" <<'PY'
import re, sys
pins = {}
for ln in open(sys.argv[1]):
    m = re.match(r"([A-Z0-9_]+)_(IMAGE|TAG|DIGEST)=(.*)", ln.strip())
    if m:
        pins.setdefault(m.group(1), {})[m.group(2)] = m.group(3)
for name in sorted(pins):
    d = pins[name]
    # An UNRESOLVED pin is a pin that does not exist yet, not an image to scan.
    # It is skipped HERE and reported as UNSCANNED by ci/scan-gate.py, which
    # reads the same file — so skipping it cannot hide it.
    if d.get("DIGEST", "").startswith("sha256:"):
        print(f"{d['IMAGE']}:{d['TAG']}@{d['DIGEST']}")
PY
fi

IMAGES="$(grep -c . "$OUT/images.txt")"
say "candidate set: $IMAGES images, derived from versions.env"

# A scan that fills the disk produces truncated JSON that parses as "fewer
# findings", so stop while there is still room rather than scanning into a
# corner.  Measured: the docling SBOM pass alone needs several GB.
guard_disk() {
  local free
  free=$(df -Pm "$ROOT" | awk 'NR==2{print $4}')
  printf '%s free=%sMB\n' "$(date -u +%H:%M:%S)" "$free" >> "$OUT/disk.log"
  if [ "$free" -lt 4096 ]; then
    say "ABORT: only ${free}MB free; refusing to continue rather than write truncated reports"
    return 1
  fi
  return 0
}

RC=0
while read -r img; do
  [ -n "$img" ] || continue
  name="$(printf '%s' "$img" | sed 's#[/:@]#_#g' | cut -c1-80)"
  guard_disk || exit 1

  if [ -s "$OUT/trivy/${name}.json" ]; then
    say "trivy  SKIP (present) ${img%%@*}"
  else
    say "trivy  START ${img%%@*}"
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v aistack-trivy-cache:/root/.cache \
      -v "$OUT/trivy:/out" \
      aquasec/trivy:latest image \
        --scanners vuln,secret,misconfig \
        --severity CRITICAL,HIGH,MEDIUM,LOW,UNKNOWN \
        --timeout 90m --format json --output "/out/${name}.json" \
        "$img" >"$OUT/trivy/${name}.out" 2>"$OUT/trivy/${name}.err"
    say "trivy  END   ${img%%@*} rc=$?"
  fi
  guard_disk || exit 1

  if [ -s "$OUT/syft/${name}.syft.json" ]; then
    say "syft   SKIP (present) ${img%%@*}"
  else
    say "syft   START ${img%%@*}"
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$OUT/syft:/out" \
      -e SYFT_FILE_METADATA_CATALOGER_ENABLED=false \
      anchore/syft:latest \
        "docker:$img" -o "syft-json=/out/${name}.syft.json" \
                      -o "spdx-json=/out/${name}.spdx.json" \
        >"$OUT/syft/${name}.out" 2>"$OUT/syft/${name}.err"
    say "syft   END   ${img%%@*} rc=$?"
  fi
  guard_disk || exit 1

  # Feeding grype the SBOM rather than the image means the 15GB docling layers
  # are extracted ONCE, by syft, instead of twice.
  if [ -s "$OUT/syft/${name}.syft.json" ]; then
    if [ -s "$OUT/grype/${name}.grype.json" ]; then
      say "grype  SKIP (present) ${img%%@*}"
    else
      say "grype  START ${img%%@*}"
      docker run --rm \
        -v aistack-grype-cache:/.cache \
        -v "$OUT/syft:/in:ro" -v "$OUT/grype:/out" \
        anchore/grype:latest \
          "sbom:/in/${name}.syft.json" -o json --file "/out/${name}.grype.json" \
          >"$OUT/grype/${name}.out" 2>"$OUT/grype/${name}.err"
      say "grype  END   ${img%%@*} rc=$?"
    fi
  else
    # NOT RUN is written to disk so the gate sees an explicit marker rather
    # than an absent file it might read as "nothing found".
    say "grype  NOT RUN ${img%%@*} — no SBOM to read. NOT a clean result."
    echo "NOT RUN: syft produced no SBOM for $img" > "$OUT/grype/${name}.NOT-RUN"
    RC=1
  fi
done < "$OUT/images.txt"

# --- repo-level config and secret scan --------------------------------------
# READ THE COVERAGE LIMIT BEFORE TRUSTING A ZERO HERE (security-findings.yaml
# L1): trivy's misconfig scanner analyses Dockerfiles, Kubernetes manifests,
# Terraform, CloudFormation and Helm.  This repo ships NONE of those, so it
# reports `Detected config files num=0` and no misconfigurations — which means
# it examined nothing, not that the configuration is clean.  `ci/invariants.py`
# is the actual control for compose.yaml, the Caddyfile and the authelia
# config.  The SECRET half of this pass IS meaningful: it is content-based and
# does read every file.
say "trivy  START repo config+secret scan (see L1 — misconfig coverage is NONE here)"
docker run --rm \
  -v aistack-trivy-cache:/root/.cache \
  -v "$ROOT:/src:ro" -v "$OUT:/out" \
  aquasec/trivy:latest fs --scanners misconfig,secret \
    --severity CRITICAL,HIGH,MEDIUM,LOW,UNKNOWN \
    --skip-dirs "/src/security-report-*" \
    --timeout 30m --format json --output /out/trivy-repo-config-secret.json \
    /src >"$OUT/trivy-repo.out" 2>"$OUT/trivy-repo.err"
say "trivy  END   repo config+secret scan rc=$?"

say "DONE — now run: DISPOSITIONS=security-findings.yaml ci/scan-gate.py versions.env $OUT"
exit "$RC"
