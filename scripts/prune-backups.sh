#!/usr/bin/env bash
# AI Stack 2026 — backup retention (NOM-352).
#
# WHY THIS EXISTS.  backups/ had no retention at all.  Each archive is 240 MB
# measured on AI-Sandbox 2026-10-20, scripts/update.sh takes one on every
# update, and nothing ever removed one -- so the folder grew by 240 MB per
# update and per backup, forever, on a host that NOM-350 had just rescued from
# running out of disk.
#
# HOW MANY TO KEEP, AND WHY THREE.  The bound is justified against what
# actually reads an archive, not against a round number:
#
#   1  scripts/drill.sh (B4, the Tier-A restore drill) defaults to
#      `ls -t backups/*.enc | head -1` -- the NEWEST.  The drill never needs
#      an older one.
#   1  tests/b2-archive-refusal.sh takes an archive as an argument and
#      tampers with a decrypted COPY in a temp dir.  Any archive will do and
#      it writes nothing back here.
#   3  the reverse path.  scripts/update.sh takes a backup immediately before
#      it pulls new digests and ABORTS the update if that backup fails;
#      scripts/rollback.sh says in those words that a major-version rollback
#      means restoring the backup taken before the update.  That archive has
#      to outlive the update long enough for the update to be TRUSTED, which
#      is not the same day.  Keeping three means the pre-update archive
#      survives two further backups.
#
# So three, which bounds the folder at about 720 MB -- 960 MB for the moment
# between writing a new archive and pruning -- against unbounded today.
# AISTACK_BACKUP_RETAIN or --retain overrides it.
#
# WHAT IT WILL NOT TOUCH.
#   * Anything whose name is not exactly the shape backup.sh writes,
#     aistack-<8 digits>T<6 digits>Z.tar.gz.enc.  An archive an operator
#     renamed or copied in by hand is a deliberate act, not the leak this
#     script is for.
#   * The newest N, by name.  The names are UTC stamps, so a lexical sort is
#     a chronological sort.
#   * Anything, when --retain is 0 or junk: that reads as "delete every
#     restore point" and is refused (exit 2) rather than guessed at.
#
# NO "CITED BY A FILE IN THE REPO" KEEP, AND THAT IS DELIBERATE.
# scripts/prune-reports.sh has one, and the same idea here would disable
# retention completely: drill-log.txt appends the FULL PATH of every archive
# it has ever drilled, so every archive is cited by construction and nothing
# would ever be prunable.  A retention rule that can never prune is the leak
# with extra steps.  The protection here is the name shape instead.
#
# ROOT-OWNED ARCHIVES.  backup.sh refuses to run unprivileged (it must read
# root-owned secrets/), so every archive is root:root 0600.  Unlinking one
# needs write permission on the DIRECTORY, not on the file, and backups/ is
# owned by the operator -- so an unprivileged prune normally works.  When the
# directory itself is root-owned it does not, and the removal then goes
# through a root container using the same busybox idiom as scripts/backup.sh
# and scripts/restore.sh -- no sudo, no password, no new privilege.  Either
# way the result is checked against the FILESYSTEM, not against rm's exit
# code, and a prune that did not happen is reported, never reported as done.
#
# Usage:  prune-backups.sh [--apply] [--dir DIR] [--retain N]
#         Default is a dry run; backup.sh passes --apply after a successful
#         archive write.  AISTACK_BACKUP_RETAIN=N overrides the default.
#
# Rollback: delete this file and the call to it at the end of
#           scripts/backup.sh.  Nothing else reads it.  Archives it has
#           already pruned are gone -- a restore point is not recoverable, so
#           read the `--dry-run` output before lowering --retain.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
DIR="${AISTACK_BACKUP_DIR:-$ROOT/backups}"
RETAIN="${AISTACK_BACKUP_RETAIN:-3}"
# Same pinned-by-tag reference scripts/backup.sh, restore.sh and
# prune-reports.sh use.
BUSYBOX="${BUSYBOX_IMAGE:-docker.io/library/busybox:stable}"
APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --dir)     DIR="${2:-}"; shift ;;
    --retain)  RETAIN="${2:-}"; shift ;;
    *) printf 'prune-backups: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

case "$RETAIN" in
  ''|*[!0-9]*) printf 'prune-backups: --retain must be a positive integer, got "%s"\n' "$RETAIN" >&2; exit 2 ;;
  0) printf 'prune-backups: --retain 0 would delete every restore point; refusing\n' >&2; exit 2 ;;
esac
[ -d "$DIR" ] || { printf 'prune-backups: --dir "%s" is not a directory\n' "$DIR" >&2; exit 2; }

DIR="$(cd "$DIR" && pwd)"
rc=0

# Remove one already-validated archive.  Returns 0 only if it is actually gone
# afterwards.
prune_file() {
  local f="$1"
  rm -f -- "$DIR/$f" 2>/dev/null
  if [ ! -e "$DIR/$f" ]; then
    printf 'backup retention: pruned %s\n' "$f"
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$DIR:/work" "$BUSYBOX" rm -f -- "/work/$f" >/dev/null 2>&1
    if [ ! -e "$DIR/$f" ]; then
      printf 'backup retention: pruned %s (root-owned; removed via container)\n' "$f"
      return 0
    fi
  fi
  printf 'backup retention: COULD NOT prune %s\n' "$f" >&2
  printf 'backup retention: %s is not writable by %s and the container fallback did not remove it.\n' \
    "$DIR" "$(id -un)" >&2
  printf 'backup retention: remove it by hand:  sudo rm -f %s/%s\n' "$DIR" "$f" >&2
  return 1
}

auto=()   # the shape backup.sh writes, newest first
other=0
while IFS= read -r f; do
  [ -f "$DIR/$f" ] || continue        # a DIRECTORY named like an archive is not ours
  if printf '%s' "$f" | grep -qE '^aistack-[0-9]{8}T[0-9]{6}Z\.tar\.gz\.enc$'; then
    auto+=("$f")
  else
    other=$((other + 1))
  fi
done < <(ls -1 "$DIR" 2>/dev/null | sort -r)

[ "$other" -gt 0 ] && printf 'backup retention: leaving %d file(s) that are not of the generated archive shape\n' "$other"

if [ "${#auto[@]}" -le "$RETAIN" ]; then
  printf 'backup retention: %d archive(s), limit %d — nothing to prune\n' "${#auto[@]}" "$RETAIN"
  exit $rc
fi

i=0
for f in "${auto[@]}"; do
  i=$((i + 1))
  if [ "$i" -le "$RETAIN" ]; then
    printf 'backup retention: keeping %s\n' "$f"
    continue
  fi
  if [ "$APPLY" -eq 1 ]; then
    prune_file "$f" || rc=1
  else
    printf 'backup retention: would prune %s\n' "$f"
  fi
done
exit $rc
