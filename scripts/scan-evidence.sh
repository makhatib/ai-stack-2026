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
# operator, which is how an empty scan once reported CRITICAL=0.  An EMPTY
# list is refused here for the same reason (NOM-372): a loop that iterates
# zero times and then prints DONE is a scan of nothing reported as a scan.
#
# Re-running is cheap and safe: each step SKIPS an output that already exists,
# so an interrupted run resumes instead of re-downloading ~1GB of databases
# and re-extracting a 15GB image.
#
# DISK: A WARNING WITH AN OVERRIDE, NOT A HARD REFUSAL (NOM-372).
# This script used to abort in the loop at a flat `free < 4096 MB`, with no
# way to override it.  Two things were wrong with that:
#   * 4096 MB is BELOW ONE IMAGE.  The largest pin (docling-serve v1.37.0) is
#     4769 MB measured on AI-Sandbox 2026-10-23, so the guard could pass and
#     the scan could still fill the host.  The requirement now comes from
#     scripts/preflight-disk.sh, which derives it from the largest image in
#     the list plus a margin — so it cannot be below one image again.
#   * A HARD REFUSAL WAS THE SHAPE THE TECH LEAD REJECTED on the NOM-350
#     review: it would stop someone regenerating NOM-310 evidence at exactly
#     the wrong moment.  Low disk now WARNS, names --allow-low-disk, and that
#     flag runs it anyway — the same flag, spelled the same way, as
#     scripts/security-check.sh.
#
# WHY THE CHECK IS ALSO INSIDE THE LOOP.  security-check.sh pre-flights once
# because it scans once.  This script pulls, exports and analyses image after
# image, so it can start with room and run out half way through — and a scan
# that fills the disk writes TRUNCATED JSON, which parses as FEWER findings:
# a quieter report for a worse scan.  So the same check runs before every
# image and between the tools, and a run that stops part-way says how far it
# got.  Under --allow-low-disk the mid-run check still stops at
# AISTACK_SCAN_HARD_FLOOR_MB (default 2048, the measured point where this
# host's root Traefik ingress starts failing and takes every unrelated
# *.sandbox.malkhatib.com app down with it).  Set it to 0 to remove even that.
#
# Usage:  scan-evidence.sh [--allow-low-disk]
#
#   OUT=<dir>                       write the evidence set there
#   AISTACK_SCAN_MIN_FREE_MB=N      override the derived disk requirement
#   AISTACK_SCAN_HARD_FLOOR_MB=N    mid-run stop floor (default 2048; 0 = none)
#
# Exit:   0  the evidence set was written
#         1  it was written but is INCOMPLETE (a tool produced nothing — read
#            the NOT RUN markers; this is not a clean result)
#         2  REFUSED before scanning anything: bad argument, no image list, or
#            too little free disk.  NOTHING was measured.
#         3  STOPPED part way on disk.  The images already written are real;
#            the rest were not scanned.  $OUT/NOT-RUN.txt names the STEP that
#            stopped — which is not always an image: the repo config+secret
#            pass is last, and ci/scan-gate.py does not read its report at
#            all, so that marker is the only signal it was skipped.  Free
#            space and re-run — present outputs are skipped, so it resumes,
#            and a run that gets past the refusals clears the old marker.
#
# Rollback: this script only writes into its own $OUT directory and two named
# Docker volumes.  To undo it completely:
#     rm -rf <OUT>  &&  docker volume rm aistack-trivy-cache aistack-grype-cache
# To undo the NOM-372 disk change specifically: `git revert` the commit; it
# touches this file and tests/test-scan-preflight.sh only, and the pre-flight
# it calls (scripts/preflight-disk.sh) is left in place for security-check.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

ALLOW_LOW_DISK=0
# AN ARGUMENT LOOP, NOT "$1", AND UNKNOWN ARGUMENTS ARE REFUSED — same reason
# as security-check.sh: an argument that is silently ignored is a run that
# measured something other than what was asked for.
usage() {
  printf 'usage: scan-evidence.sh [--allow-low-disk]\n\n'
  printf '  --allow-low-disk  start the scan even when free disk is below what it\n'
  printf '                    needs, and keep going if it falls below it mid-run\n'
  printf '                    (see scripts/preflight-disk.sh for the requirement)\n\n'
  printf '  OUT=<dir>                     write the evidence set there\n'
  printf '  AISTACK_SCAN_MIN_FREE_MB=N    override the derived requirement\n'
  printf '  AISTACK_SCAN_HARD_FLOOR_MB=N  mid-run stop floor (default 2048; 0 = none)\n'
}
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-low-disk) ALLOW_LOW_DISK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'scan-evidence: unknown argument %s\n' "$1" >&2
       usage >&2
       exit 2 ;;
  esac
  shift
done

HARD_FLOOR_MB="${AISTACK_SCAN_HARD_FLOOR_MB:-2048}"
case "$HARD_FLOOR_MB" in
  ''|*[!0-9]*) printf 'scan-evidence: AISTACK_SCAN_HARD_FLOOR_MB must be a non-negative integer, got "%s"\n' \
                 "$HARD_FLOOR_MB" >&2; exit 2 ;;
esac

# THE REPORT DIRECTORY IS CREATED AFTER THE ARGUMENTS ARE READ, not before, so
# `scan-evidence.sh --typo` leaves nothing behind for report retention to
# count (the same fix NOM-352 made in security-check.sh).
OUT="${OUT:-$ROOT/security-report-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT/trivy" "$OUT/syft" "$OUT/grype"
LOG="$OUT/driver.log"
say() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }

# Named volumes so a re-run reuses the vulnerability databases rather than
# re-downloading them, and so no database ever lands in the report directory
# (it would then be scanned as part of the repo on the next pass).  Created
# LAZILY, when a tool is actually about to run: a run that refuses on disk, or
# that finds every output already present, adds NO VOLUME to the host.  It does
# still leave its report directory, images.txt, disk.log and the NOT-RUN marker
# — deliberately, because the marker IS the output of a refusal.  Lazy creation
# is about the volumes only.
CACHES_READY=0
ensure_caches() {
  [ "$CACHES_READY" -eq 1 ] && return 0
  docker volume create aistack-trivy-cache >/dev/null
  docker volume create aistack-grype-cache >/dev/null
  CACHES_READY=1
}

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

# AN EMPTY LIST IS REFUSED, NOT SCANNED (NOM-372).  With no images the loop
# below iterates zero times and the script would reach DONE having measured
# nothing — the same false green that `docker compose config --images` once
# produced for an operator who could not read secrets/*.env, and the same
# refusal security-check.sh already makes.
if [ "$IMAGES" -eq 0 ]; then
  say "REFUSED — the image list is EMPTY, so NO IMAGE WOULD BE SCANNED."
  say "This is NOT a clean result. Check that versions.env holds resolved"
  say "sha256: digests, or pass a pre-written $OUT/images.txt."
  echo "scan: NOT RUN (image list empty)" > "$OUT/NOT-RUN.txt"
  exit 2
fi

# --- disk: the requirement, and the two places it is checked ----------------
# A scan that fills the disk produces truncated JSON that parses as "fewer
# findings", so stop while there is still room rather than scanning into a
# corner.  The requirement is DERIVED from the list above by
# scripts/preflight-disk.sh (largest image + margin), not a round number.
NEED_MB=""
DISK_FREE_MB=""
DISK_OUT=""

# Runs the pre-flight and remembers what it said.  Returns its exit status:
#   0 measured and enough   1 LOW   2 could not measure (never "enough").
disk_check() {
  local rc
  DISK_OUT="$(bash "$ROOT/scripts/preflight-disk.sh" "$@" 2>&1)"; rc=$?
  DISK_FREE_MB="$(printf '%s\n' "$DISK_OUT" \
    | sed -n 's/^  .*: \([0-9][0-9]*\) MB free$/\1/p' | sort -n | head -1)"
  {
    printf '%s rc=%s free=%sMB need=%sMB\n' \
      "$(date -u +%H:%M:%S)" "$rc" "${DISK_FREE_MB:-?}" "${NEED_MB:-derive}"
    printf '%s\n' "$DISK_OUT" | sed 's/^/    /'
  } >> "$OUT/disk.log"
  return "$rc"
}

say "pre-flight: free disk for $IMAGES images"
disk_check --images-from "$OUT/images.txt"
PREFLIGHT_RC=$?
printf '%s\n' "$DISK_OUT" | tee -a "$LOG"
# Reuse the SAME requirement for every in-loop re-check, so the number cannot
# drift between the pre-flight an operator read and the check that stops the
# run — and so the re-check does not re-inspect every image each time.
NEED_MB="$(printf '%s\n' "$DISK_OUT" | sed -n 's/^  requirement: \([0-9][0-9]*\) MB.*/\1/p' | head -1)"

if [ "$PREFLIGHT_RC" -eq 0 ]; then
  say "pre-flight OK — ${DISK_FREE_MB}MB free, the scan needs about ${NEED_MB}MB"
elif [ "$ALLOW_LOW_DISK" -eq 1 ]; then
  if [ "$PREFLIGHT_RC" -eq 2 ]; then
    say "WARNING: free disk could NOT BE MEASURED — running anyway because --allow-low-disk was given."
  else
    say "WARNING: LOW DISK (${DISK_FREE_MB}MB free, needs about ${NEED_MB}MB) — running anyway because --allow-low-disk was given."
  fi
  say "If the host fills, these reports will be TRUNCATED JSON that parses as"
  say "FEWER findings, and other services on this host will start failing."
  # SAY WHAT THE FLOOR ACTUALLY DOES, not what it does in the common case.  The
  # floor compares a NUMBER, so there are two ways for it not to stop anything:
  # the floor is 0, or free space could not be measured and there is no number.
  # The flat sentence that used to be here promised a stop in both.
  if [ "$HARD_FLOOR_MB" -eq 0 ]; then
    say "AISTACK_SCAN_HARD_FLOOR_MB=0, so there is NO mid-run floor either:"
    say "nothing will stop this run, whatever happens to free space."
  elif [ "$PREFLIGHT_RC" -eq 2 ]; then
    say "The mid-run floor (${HARD_FLOOR_MB}MB) can only compare a number, and free"
    say "space did not answer here — so it will stop this run only if df starts"
    say "answering mid-run. Watch the host yourself."
  else
    say "The mid-run floor still applies: the scan stops below ${HARD_FLOOR_MB}MB free,"
    say "unless free space stops being measurable at all."
  fi
else
  if [ "$PREFLIGHT_RC" -eq 2 ]; then
    say "SCAN NOT RUN — free disk could NOT BE MEASURED (see above). NO IMAGE WAS SCANNED."
  else
    say "SCAN NOT RUN — only ${DISK_FREE_MB}MB free and the scan needs about ${NEED_MB}MB. NO IMAGE WAS SCANNED."
  fi
  say "This is NOT a clean result. Free some space, or scan anyway with:"
  say "    scripts/scan-evidence.sh --allow-low-disk"
  echo "scan: NOT RUN (low disk: ${DISK_FREE_MB:-unmeasured}MB free, needs ${NEED_MB:-unknown}MB)" > "$OUT/NOT-RUN.txt"
  exit 2
fi

# A RESUME MUST NOT INHERIT THE LAST RUN'S VERDICT (NOM-372).  Resuming is the
# path this script's own header advertises: stop on disk, free some space,
# re-run, present outputs are skipped.  The stopped run left a NOT-RUN marker
# behind, and without this line the successful resume finishes, prints DONE and
# exits 0 with a marker still on disk saying the evidence set is incomplete —
# so a COMPLETE set routinely carried a note that it was not.
# Removed only here, past every refusal above: a run that refuses writes its
# own marker and exits without reaching this line.
rm -f "$OUT/NOT-RUN.txt"

DONE_IMAGES=0
# The in-loop re-check.  Returns 0 to continue, 1 to stop the run.
guard_disk() {
  local where="$1" rc
  # NOT --quiet: the per-filesystem lines are what disk_check reads the free
  # count out of, and with them suppressed the floor below has nothing to
  # compare.  disk_check prints nothing itself — every re-check lands in
  # $OUT/disk.log, and only a WARNING or a STOP reaches the console.
  if [ -n "$NEED_MB" ]; then
    disk_check --need-mb "$NEED_MB"
  else
    disk_check
  fi
  rc=$?
  if [ -n "$DISK_FREE_MB" ] && [ "$HARD_FLOOR_MB" -gt 0 ] \
     && [ "$DISK_FREE_MB" -lt "$HARD_FLOOR_MB" ]; then
    say "STOP at $where — only ${DISK_FREE_MB}MB free, below the ${HARD_FLOOR_MB}MB mid-run floor."
    say "Continuing would write truncated reports and start taking this host's"
    say "other services down with it. --allow-low-disk does NOT override the"
    say "floor; AISTACK_SCAN_HARD_FLOOR_MB=0 removes it."
    return 1
  fi
  [ "$rc" -eq 0 ] && return 0
  if [ "$ALLOW_LOW_DISK" -eq 1 ]; then
    say "LOW DISK at $where (${DISK_FREE_MB:-unmeasured}MB free, needs about ${NEED_MB:-unknown}MB) — continuing because --allow-low-disk was given."
    return 0
  fi
  say "STOP at $where — ${DISK_FREE_MB:-unmeasured}MB free, the scan needs about ${NEED_MB:-unknown}MB."
  say "Stopping rather than writing truncated reports. Re-run to resume"
  say "(present outputs are skipped), or scan anyway with --allow-low-disk."
  return 1
}

# Called when guard_disk says stop.  Takes the SAME step label guard_disk took,
# because the image count alone describes the wrong thing when the stop is not
# in the image loop: a stop at the repo config+secret pass has scanned every
# image, and the old wording then read "STOPPED AFTER 1 of 1 images. The 0
# image(s) not listed above were NOT SCANNED" and never named the step that
# actually did not run.  That step matters more than most: the repo pass is the
# only SECRET scan in the evidence set, and ci/scan-gate.py does not read its
# report at all — this marker is the only signal that it was skipped.
stop_short() {
  local step="$1"
  if [ "$DONE_IMAGES" -lt "$IMAGES" ]; then
    say "STOPPED at $step — $DONE_IMAGES of $IMAGES images scanned."
    say "The other $((IMAGES - DONE_IMAGES)) image(s) were NOT SCANNED — not a clean result."
  else
    say "STOPPED at $step — all $IMAGES images were scanned, but THIS STEP DID NOT RUN."
    say "The image evidence above is real; this step is missing — not a clean result."
  fi
  echo "scan: STOPPED at $step after $DONE_IMAGES of $IMAGES images (disk)" > "$OUT/NOT-RUN.txt"
  exit 3
}

RC=0
while read -r img; do
  [ -n "$img" ] || continue
  name="$(printf '%s' "$img" | sed 's#[/:@]#_#g' | cut -c1-80)"
  # One variable per call site, so the label guard_disk reports and the label
  # stop_short puts in the marker cannot drift apart.
  step="${img%%@*} (before trivy)"
  guard_disk "$step" || stop_short "$step"

  if [ -s "$OUT/trivy/${name}.json" ]; then
    say "trivy  SKIP (present) ${img%%@*}"
  else
    ensure_caches
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
  step="${img%%@*} (before syft)"
  guard_disk "$step" || stop_short "$step"

  if [ -s "$OUT/syft/${name}.syft.json" ]; then
    say "syft   SKIP (present) ${img%%@*}"
  else
    ensure_caches
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
  step="${img%%@*} (before grype)"
  guard_disk "$step" || stop_short "$step"

  # Feeding grype the SBOM rather than the image means the 15GB docling layers
  # are extracted ONCE, by syft, instead of twice.
  if [ -s "$OUT/syft/${name}.syft.json" ]; then
    if [ -s "$OUT/grype/${name}.grype.json" ]; then
      say "grype  SKIP (present) ${img%%@*}"
    else
      ensure_caches
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
  DONE_IMAGES=$((DONE_IMAGES + 1))
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
if [ -s "$OUT/trivy-repo-config-secret.json" ]; then
  say "trivy  SKIP (present) repo config+secret scan"
else
  step="repo config+secret scan"
  guard_disk "$step" || stop_short "$step"
  ensure_caches
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
fi

say "DONE — now run: DISPOSITIONS=security-findings.yaml ci/scan-gate.py versions.env $OUT"
exit "$RC"
