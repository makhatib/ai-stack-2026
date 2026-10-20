#!/usr/bin/env bash
# AI Stack 2026 — pre-flight disk assertion for the scan half (NOM-352).
#
# WHY THIS EXISTS.  NOM-350 cleared AI-Sandbox from 8.5 GB free to 29 GB and
# capped the report COUNT at 3, but the thing that burned ~1 GB every five
# minutes was the scan itself: every image it reads is exported to disk before
# it is analysed, and the vulnerability database is downloaded alongside it.
# That run stopped because it EXITED, not because anything held it back.  At
# roughly 2 GB free the host's root Traefik ingress starts failing and every
# *.sandbox.malkhatib.com app goes down with it, so a scan that runs the host
# out of disk takes unrelated services with it.
#
# A WARNING, NOT A GATE.  This script only MEASURES and REPORTS; the exit
# status is advice.  security-check.sh turns a low-disk answer into a skipped
# scan that reports NOT RUN and names --allow-low-disk, which overrides it.
# A hard refusal was considered and rejected (Tech Lead, NOM-350 review): it
# would stop someone regenerating NOM-310 evidence at exactly the wrong
# moment.
#
# THE REQUIREMENT IS DERIVED, AND SAYS WHEN IT COULD NOT BE.
#   derived   largest image in the list + --margin-mb (default 2048 MB for the
#             vulnerability database, the report JSON, and filesystem slack).
#             The largest image decides it because the scan handles one image
#             at a time and frees each before the next.  Measured 2026-10-20
#             on AI-Sandbox: nine pinned images total 10.6 GB, the largest
#             (docling-serve v1.37.0) is 4.66 GB, so the derived requirement
#             is about 6.8 GB.
#   floor     when the list cannot be resolved, or an image in it is not
#             present locally so its size is unknown, the answer falls back to
#             --floor-mb (default 8192) and the output SAYS it is a floor and
#             not a measurement.  `docker compose config --images` returns an
#             EMPTY list for an operator who cannot read secrets/*.env, and a
#             requirement derived from an empty list would be 0 MB — "plenty
#             of room" for a scan nothing measured.  Same trap, same rule, as
#             the scan half's own image-list guard.
#
# WHICH FILESYSTEM.  Both the Docker data root (the image export and the
# database land there) and the report directory (the JSON and SBOMs land
# there).  They are the same filesystem on AI-Sandbox and are reported once
# when they are; on a host where /var/lib/docker is its own volume they are
# two separate answers and the smaller one decides.
#
# Usage:  preflight-disk.sh [--path DIR]... [--need-mb N] [--margin-mb N]
#                           [--floor-mb N] [--images-from FILE|-] [--quiet]
#         AISTACK_SCAN_MIN_FREE_MB=N is the same override as --need-mb.
#
# Exit:   0  enough free disk, and it was actually measured
#         1  LOW — less free than the requirement
#         2  could not measure, or bad arguments.  NOT "enough": a caller must
#            treat anything non-zero as unproven.
#
# Rollback: delete this file and the call to it in scripts/security-check.sh.
#           Nothing else reads it and it writes nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

NEED_MB="${AISTACK_SCAN_MIN_FREE_MB:-}"
MARGIN_MB=2048
FLOOR_MB=8192
IMAGES_FROM=""
QUIET=0
PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --path)        PATHS+=("${2:-}"); shift ;;
    --need-mb)     NEED_MB="${2:-}"; shift ;;
    --margin-mb)   MARGIN_MB="${2:-}"; shift ;;
    --floor-mb)    FLOOR_MB="${2:-}"; shift ;;
    --images-from) IMAGES_FROM="${2:-}"; shift ;;
    --quiet)       QUIET=1 ;;
    *) printf 'preflight-disk: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

for v in NEED_MB MARGIN_MB FLOOR_MB; do
  val="${!v}"
  [ -z "$val" ] && continue
  case "$val" in
    ''|*[!0-9]*) printf 'preflight-disk: --%s must be a non-negative integer, got "%s"\n' \
                   "$(printf '%s' "$v" | tr 'A-Z_' 'a-z-')" "$val" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

# --- what the scan will need ------------------------------------------------
NEED_KIND="derived"
if [ -n "$NEED_MB" ]; then
  NEED_KIND="override"
else
  IMAGES=""
  if [ "$IMAGES_FROM" = "-" ]; then
    IMAGES="$(cat)"
  elif [ -n "$IMAGES_FROM" ]; then
    [ -r "$IMAGES_FROM" ] || { printf 'preflight-disk: cannot read %s\n' "$IMAGES_FROM" >&2; exit 2; }
    IMAGES="$(cat "$IMAGES_FROM")"
  elif command -v docker >/dev/null 2>&1; then
    IMAGES="$( (cd "$ROOT" && docker compose config --images 2>/dev/null) || true )"
  fi

  NIMAGES=0
  LARGEST_MB=0
  LARGEST_NAME=""
  UNKNOWN=0
  for img in $IMAGES; do
    [ -n "$img" ] || continue
    NIMAGES=$((NIMAGES + 1))
    bytes="$(docker image inspect -f '{{.Size}}' "$img" 2>/dev/null)"
    case "$bytes" in
      ''|*[!0-9]*) UNKNOWN=$((UNKNOWN + 1)); continue ;;
    esac
    mb=$((bytes / 1048576))
    if [ "$mb" -gt "$LARGEST_MB" ]; then LARGEST_MB="$mb"; LARGEST_NAME="${img%%@*}"; fi
  done

  if [ "$NIMAGES" -eq 0 ]; then
    NEED_KIND="floor-no-list"
    NEED_MB="$FLOOR_MB"
  elif [ "$UNKNOWN" -gt 0 ]; then
    # An image that is not present locally will be pulled, and its size is not
    # knowable without asking the registry -- which the audit half is designed
    # to run without.  So the derived number is a LOWER BOUND here; take the
    # larger of it and the floor, and say which.
    NEED_KIND="floor-unknown-sizes"
    NEED_MB=$((LARGEST_MB + MARGIN_MB))
    [ "$NEED_MB" -lt "$FLOOR_MB" ] && NEED_MB="$FLOOR_MB"
  else
    NEED_MB=$((LARGEST_MB + MARGIN_MB))
  fi
fi

# --- how much there is -----------------------------------------------------
if [ "${#PATHS[@]}" -eq 0 ]; then
  PATHS=("$ROOT")
  if command -v docker >/dev/null 2>&1; then
    dr="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
    [ -n "$dr" ] && [ -d "$dr" ] && PATHS+=("$dr")
  fi
fi

MEASURED=0
FREE_MB=""
LOW=0
seen_fs=""
for p in "${PATHS[@]}"; do
  [ -n "$p" ] || continue
  line="$(df -Pm -- "$p" 2>/dev/null | awk 'NR==2{print $1" "$4" "$6}')"
  [ -n "$line" ] || { say "  [warn] cannot measure free space on $p"; continue; }
  src="${line%% *}"; rest="${line#* }"; free="${rest%% *}"; mount="${rest#* }"
  case "$free" in ''|*[!0-9]*) say "  [warn] df gave no usable free count for $p"; continue ;; esac
  # One answer per filesystem: the Docker data root and the report directory
  # are the same volume on AI-Sandbox, and reporting it twice reads as two
  # independent checks when it is one.
  case " $seen_fs " in *" $src|$mount "*) continue ;; esac
  seen_fs="$seen_fs $src|$mount"
  MEASURED=$((MEASURED + 1))
  say "  $mount ($src): ${free} MB free"
  if [ -z "$FREE_MB" ] || [ "$free" -lt "$FREE_MB" ]; then FREE_MB="$free"; fi
  [ "$free" -lt "$NEED_MB" ] && LOW=1
done

case "$NEED_KIND" in
  override) say "  requirement: ${NEED_MB} MB (override)" ;;
  derived)  say "  requirement: ${NEED_MB} MB = largest image ${LARGEST_MB} MB (${LARGEST_NAME}) + ${MARGIN_MB} MB margin" ;;
  floor-no-list)
    say "  requirement: ${NEED_MB} MB (FLOOR, not a measurement — the image list"
    say "               could not be resolved, so no image size was read)" ;;
  floor-unknown-sizes)
    say "  requirement: ${NEED_MB} MB (FLOOR — ${UNKNOWN} of ${NIMAGES} images are not"
    say "               present locally, so their size is unknown until pulled)" ;;
esac

if [ "$MEASURED" -eq 0 ]; then
  printf 'preflight-disk: NOT MEASURED — no filesystem answered df.\n' >&2
  printf 'preflight-disk: this is not a report of enough free disk.\n' >&2
  exit 2
fi

if [ "$LOW" -eq 1 ]; then
  say "  LOW: ${FREE_MB} MB free, the scan needs about ${NEED_MB} MB"
  exit 1
fi
say "  OK: ${FREE_MB} MB free, the scan needs about ${NEED_MB} MB"
exit 0
