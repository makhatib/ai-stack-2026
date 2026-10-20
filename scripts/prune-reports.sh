#!/usr/bin/env bash
# AI Stack 2026 — report retention for security-check.sh (NOM-350).
#
# WHY THIS EXISTS.  Every security-check.sh run writes a new
# security-report-<UTC>/ directory holding one Trivy JSON and one SBOM per
# scanned image.  Nothing ever removed them.  On 2026-10-20 nineteen had
# accumulated on AI-Sandbox and the folder was 1.1 GB; free disk on the host
# was falling ~1 GB every five minutes and the root Traefik ingress was about
# to start failing.  Retention is the fix that keeps that from returning.
#
# WHAT IT WILL AND WILL NOT DELETE.
#
#   AUTO dirs  security-report-<8 digits>T<6 digits>Z  — the shape
#              security-check.sh generates.  The newest N (default 3) are
#              kept; older ones are pruned.  This is the runaway set.
#   LABELLED   security-report-<label>-<UTC>  (e.g. -c2-, -bump-, -nom341-).
#              NEVER pruned.  These are created by hand to be cited as
#              evidence: versions.env, security-findings.yaml, gate.json and
#              ci/scan-gate.py all name specific ones, and NOM-310's pending
#              human sign-off rests on them.  An unbounded human action is
#              not the leak this script is for.
#   CITED      Any directory whose name appears in a file under the repo
#              (excluding .git and the report directories themselves) is kept
#              even if it is otherwise prunable.  Belt and braces: it makes
#              widening the shape above safe rather than destructive.
#
# Deletion is by exact name under $ROOT, matched against the shape above.
# There is no glob rm and no `find -delete`.
#
# ROOT-OWNED REPORTS.  A report written by a `sudo security-check.sh` run is
# root:root all the way down, including the trivy/ directory, so an
# unprivileged rm cannot unlink anything inside it.  Measured on
# AI-Sandbox 2026-10-20: four of fourteen reports were in that state.  Those
# are removed through a root container using the same busybox idiom as
# scripts/backup.sh and scripts/restore.sh -- no sudo, no password, no new
# privilege.  If that fails too, the script says so and prints the exact
# command to run by hand; it never reports a failed prune as done.
#
# Usage:  prune-reports.sh [--apply] [--root DIR] [--retain N]
#         Default is a dry run; security-check.sh passes --apply.
#         SECURITY_REPORT_RETAIN=N overrides the default count.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
RETAIN="${SECURITY_REPORT_RETAIN:-3}"
# Same pinned-by-tag reference scripts/backup.sh and restore.sh use.
BUSYBOX="${BUSYBOX_IMAGE:-docker.io/library/busybox:stable}"
APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --root)    ROOT="${2:-}"; shift ;;
    --retain)  RETAIN="${2:-}"; shift ;;
    *) printf 'prune-reports: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# A retain count of 0 (or junk that reads as 0) would delete every report.
# Fail instead of guessing.
case "$RETAIN" in
  ''|*[!0-9]*) printf 'prune-reports: --retain must be a positive integer, got "%s"\n' "$RETAIN" >&2; exit 2 ;;
  0) printf 'prune-reports: --retain 0 would delete every report; refusing\n' >&2; exit 2 ;;
esac
[ -d "$ROOT" ] || { printf 'prune-reports: --root "%s" is not a directory\n' "$ROOT" >&2; exit 2; }

cd "$ROOT" || exit 2

rc=0

# Remove one already-validated report directory.  Returns 0 only if the
# directory is actually gone afterwards -- the check is the filesystem, not
# rm's exit code.
prune_dir() {
  local d="$1"
  rm -rf -- "$ROOT/$d" 2>/dev/null
  if [ ! -e "$ROOT/$d" ]; then
    printf 'retention: pruned %s\n' "$d"
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$ROOT:/work" "$BUSYBOX" rm -rf -- "/work/$d" >/dev/null 2>&1
    if [ ! -e "$ROOT/$d" ]; then
      printf 'retention: pruned %s (root-owned; removed via container)\n' "$d"
      return 0
    fi
  fi
  printf 'retention: COULD NOT prune %s\n' "$d" >&2
  printf 'retention: it is not writable by %s and the container fallback did not remove it.\n' "$(id -un)" >&2
  printf 'retention: remove it by hand:  sudo rm -rf %s\n' "$ROOT/$d" >&2
  return 1
}

auto=()   # the generated shape, newest first
labelled=0
while IFS= read -r d; do
  [ -d "$d" ] || continue          # a stray FILE named security-report-* is not ours
  if printf '%s' "$d" | grep -qE '^security-report-[0-9]{8}T[0-9]{6}Z$'; then
    auto+=("$d")
  else
    labelled=$((labelled + 1))
  fi
done < <(ls -1 2>/dev/null | grep '^security-report-' | sort -r)

[ "$labelled" -gt 0 ] && printf 'retention: keeping %d labelled report dir(s) — evidence, never auto-pruned\n' "$labelled"

if [ "${#auto[@]}" -le "$RETAIN" ]; then
  printf 'retention: %d generated report dir(s), limit %d — nothing to prune\n' "${#auto[@]}" "$RETAIN"
  exit $rc
fi

i=0
for d in "${auto[@]}"; do
  i=$((i + 1))
  [ "$i" -le "$RETAIN" ] && continue
  cited="$(grep -rlF --exclude-dir=.git --exclude-dir='security-report-*' "$d" . 2>/dev/null | head -3 | tr '\n' ' ')"
  if [ -n "$cited" ]; then
    printf 'retention: KEEPING %s — cited by %s\n' "$d" "$cited"
    continue
  fi
  if [ "$APPLY" -eq 1 ]; then
    prune_dir "$d" || rc=1
  else
    printf 'retention: would prune %s\n' "$d"
  fi
done
exit $rc
