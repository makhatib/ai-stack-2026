#!/usr/bin/env bash
# AI Stack 2026 — install gVisor (runsc) and register it as a Docker runtime.
#
# Hermes and Crawl4AI declare `runtime: runsc` (invariant I17).  This script is
# what makes that runtime exist on a machine that does not have it.  It is
# idempotent and it is the only thing in the installer that restarts dockerd,
# and it does so only when /etc/docker/daemon.json actually changed.
#
#   sudo scripts/install-gvisor.sh          install + register (no-op if present)
#   scripts/install-gvisor.sh --check       exit 0 if Docker lists runsc, else 1
#
# The release and its sha512 come from versions.env (GVISOR_URL,
# GVISOR_SHA512_X86_64).  A download whose sha512 does not match is deleted and
# nothing is installed.  x86_64 only: that is the only digest we pin.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
BIN_DIR="${AISTACK_GVISOR_BIN_DIR:-/usr/local/bin}"
DAEMON_JSON="${AISTACK_DAEMON_JSON:-/etc/docker/daemon.json}"

die() { printf 'install-gvisor: %s\n' "$*" >&2; exit 1; }

have_runtime() { docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"runsc"'; }

if [ "${1:-}" = "--check" ]; then have_runtime; exit $?; fi

[ "$(id -u)" -eq 0 ] || die "must run as root (it writes $BIN_DIR and $DAEMON_JSON). Re-run: sudo $0"
[ "$(uname -m)" = x86_64 ] || die "only x86_64 is pinned (found $(uname -m))."
command -v docker >/dev/null || die "docker is not installed."

# shellcheck disable=SC1091
. "$ROOT/versions.env"
: "${GVISOR_URL:?versions.env has no GVISOR_URL}" "${GVISOR_SHA512_X86_64:?versions.env has no GVISOR_SHA512_X86_64}"

if [ -x "$BIN_DIR/runsc" ] && have_runtime; then
  echo "gVisor: runsc is already installed and registered ($("$BIN_DIR/runsc" --version 2>/dev/null | head -1))."
  exit 0
fi

command -v zstd >/dev/null || die "zstd is not installed (apt-get install -y zstd)."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "gVisor: downloading $GVISOR_URL"
curl -fsSL --retry 3 -o "$TMP/gvisor.tar.zstd" "$GVISOR_URL" || die "download failed."
GOT="$(sha512sum "$TMP/gvisor.tar.zstd" | awk '{print $1}')"
[ "$GOT" = "$GVISOR_SHA512_X86_64" ] || die "sha512 mismatch: expected $GVISOR_SHA512_X86_64, got $GOT. Nothing installed."

mkdir -p "$TMP/x" && tar --zstd -xf "$TMP/gvisor.tar.zstd" -C "$TMP/x"
install -d -m0755 "$BIN_DIR" "$BIN_DIR/gvisor-bin"
install -m0755 "$TMP/x/runsc" "$TMP/x/containerd-shim-runsc-v1" "$BIN_DIR/"
[ -d "$TMP/x/gvisor-bin" ] && install -m0755 "$TMP/x/gvisor-bin/"* "$BIN_DIR/gvisor-bin/"

# Merge, never overwrite: an operator's existing daemon.json keeps its keys.
mkdir -p "$(dirname "$DAEMON_JSON")"
CHANGED="$(python3 - "$DAEMON_JSON" "$BIN_DIR/runsc" <<'PY'
import json, os, sys
path, runsc = sys.argv[1], sys.argv[2]
cfg = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
want = {"path": runsc, "runtimeArgs": ["--platform=systrap"]}
rt = cfg.setdefault("runtimes", {})
if rt.get("runsc") == want:
    print("no"); sys.exit(0)
if os.path.exists(path):
    open(path + ".pre-gvisor.bak", "w").write(open(path).read())
rt["runsc"] = want
tmp = path + ".new"
open(tmp, "w").write(json.dumps(cfg, indent=2) + "\n")
os.replace(tmp, path)
print("yes")
PY
)"
if [ "$CHANGED" = yes ]; then
  echo "gVisor: registered runsc in $DAEMON_JSON; restarting Docker (containers with a restart policy come back)."
  systemctl restart docker || die "docker did not restart. Previous config: $DAEMON_JSON.pre-gvisor.bak"
  for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
fi
have_runtime || die "Docker does not list the runsc runtime after install."
echo "gVisor: runsc installed and registered ($("$BIN_DIR/runsc" --version 2>/dev/null | head -1))."
