#!/usr/bin/env bash
# AI Stack 2026 — read one service's MEASURED `runtime_ids` out of
# manifest.yaml, with no interpreter and no library.
#
#   scripts/manifest-runtime-ids.sh postgres   ->  999:999   (exit 0)
#   scripts/manifest-runtime-ids.sh nosuch     ->  (nothing)  exit 1
#
# WHY THIS FILE EXISTS AT ALL.
#
# MEASURED (NOM-307, 2026-10-19), on the isolated QA target that ships only
# what docs/install.md declares.  This lookup used to be a Python heredoc
# inside scripts/gen-secrets.sh that opened with
#
#     try: import yaml
#     except ImportError: sys.exit(0)
#
# PyYAML is not a documented prerequisite and the target does not have it, so
# the import failed, the heredoc printed nothing and EXITED 0, and
# `apply_mode` read that empty answer as "this service declares no ids" and
# wrote every secret 0600 root:root with a WARN it continued past.  Seven
# warnings later Postgres could not read app_db_passwords as uid 999 and the
# first-boot init script died.  The value it needed — `runtime_ids: "999:999"`
# — was in manifest.yaml the whole time and was never read.
#
# The decision is load-bearing, so it does not get to depend on a library
# nobody declared.  `runtime_ids` is a fixed "uid:gid" string on one line per
# entry; awk reads it.  THE ABSENT ANSWER AND THE ZERO ANSWER ARE NOW
# DIFFERENT THINGS: this script exits 1 when it cannot find the entry, and
# every caller must treat that as a failure rather than as a default.
#
# Scope: `services:` and `helpers:`, the two top-level maps whose entries are
# secret consumers.  A nested `runtime_ids` under anything else is not read.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
MANIFEST="${AISTACK_MANIFEST:-$ROOT/manifest.yaml}"

WANT="${1:?usage: manifest-runtime-ids.sh <service-or-helper>}"

[ -f "$MANIFEST" ] || {
  printf 'manifest-runtime-ids: no manifest at %s\n' "$MANIFEST" >&2
  exit 1
}

IDS="$(awk -v want="$WANT" '
  # A line that starts in column 0 is a top-level key: it ends any entry.
  /^[^[:space:]#]/ {
    top = $0; sub(/:.*$/, "", top); inentry = 0; next
  }
  # Two-space indent, then a key with nothing after the colon: a map entry.
  /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ {
    name = $0
    sub(/^  /, "", name)
    sub(/:[[:space:]]*(#.*)?$/, "", name)
    inentry = ((top == "services" || top == "helpers") && name == want)
    next
  }
  # Four-space indent inside the entry we want.
  inentry && /^    runtime_ids:/ {
    v = $0
    sub(/^    runtime_ids:/, "", v)
    sub(/#.*$/, "", v)          # drop the MEASURED comment FIRST: it contains
    gsub(/[^0-9:]/, "", v)      # both digits and colons.
    print v
    exit
  }
' "$MANIFEST")"

case "$IDS" in
  *[0-9]:*[0-9]) ;;   # uid:gid, both numeric
  *)
    printf 'manifest-runtime-ids: no runtime_ids for %s in %s\n' "$WANT" "$MANIFEST" >&2
    exit 1 ;;
esac

printf '%s\n' "$IDS"
