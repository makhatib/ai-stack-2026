#!/usr/bin/env bash
# NOM-352 — proves scripts/prune-backups.sh bounds backups/ at three archives
# and that each of its refusals actually refuses.
#
# Runs against a FIXTURE directory, not the real backups/.  A test that needed
# real archives would need a 240 MB encrypted backup per case, so it would
# never run -- and deleting a real restore point to prove retention works is
# not a trade this test is willing to make.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PRUNE="$HERE/../scripts/prune-backups.sh"
FAIL=0
pass() { printf '  [ ok ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }
have() { [ -e "$1/$2" ]; }

mkfixture() {
  local r; r="$(mktemp -d)"
  # five generated archives, oldest first by name
  for ts in 20261001T000000Z 20261002T000000Z 20261003T000000Z \
            20261004T000000Z 20261005T000000Z; do
    echo "ciphertext" > "$r/aistack-$ts.tar.gz.enc"
  done
  # things that are NOT the generated shape and must survive
  echo x > "$r/aistack-before-the-odoo-upgrade.tar.gz.enc"   # renamed by hand
  echo x > "$r/aistack-20260101T000000Z.tar.gz"              # not encrypted
  echo x > "$r/notes.txt"
  mkdir -p "$r/aistack-20260102T000000Z.tar.gz.enc"          # a DIRECTORY
  printf '%s' "$r"
}

count_enc() { ls -1 "$1" 2>/dev/null | grep -c '^aistack-.*\.tar\.gz\.enc$'; }

printf '\nNOM-352 backup retention\n'

# --- 1. dry run deletes nothing and names what it would prune --------------
R="$(mkfixture)"
out="$(bash "$PRUNE" --dir "$R" --retain 3 2>&1)"
n=$(ls -1 "$R" | wc -l)
[ "$n" -eq 9 ] && pass "dry run deleted nothing (9 entries still present)" \
               || fail "dry run changed the directory: $n entries left, expected 9"
printf '%s\n' "$out" | grep -q 'would prune aistack-20261002T000000Z.tar.gz.enc' \
  && pass "dry run names what it would prune" || fail "dry run output missing: $out"
rm -rf "$R"

# --- 2. --apply keeps the newest 3 ----------------------------------------
R="$(mkfixture)"
out="$(bash "$PRUNE" --dir "$R" --retain 3 --apply 2>&1)"
for keep in aistack-20261005T000000Z aistack-20261004T000000Z aistack-20261003T000000Z; do
  have "$R" "$keep.tar.gz.enc" && pass "kept newest: $keep" \
    || fail "deleted an archive inside the limit: $keep"
done
for gone in aistack-20261002T000000Z aistack-20261001T000000Z; do
  have "$R" "$gone.tar.gz.enc" && fail "did not prune $gone" || pass "pruned: $gone"
done

# --- 3. nothing outside the generated shape is touched --------------------
have "$R" aistack-before-the-odoo-upgrade.tar.gz.enc \
  && pass "kept a hand-renamed archive — not the generated shape" \
  || fail "deleted a hand-renamed archive"
have "$R" aistack-20260101T000000Z.tar.gz \
  && pass "kept a non-.enc file with an archive-like stamp" \
  || fail "deleted a file that is not a generated archive"
have "$R" notes.txt && pass "kept an unrelated file" || fail "deleted an unrelated file"
have "$R" aistack-20260102T000000Z.tar.gz.enc \
  && pass "kept a DIRECTORY named like an archive" \
  || fail "removed a directory named like an archive"
printf '%s\n' "$out" | grep -q 'leaving 3 file(s) that are not of the generated archive shape' \
  && pass "says how many files it left alone" || fail "did not report the files it left: $out"
rm -rf "$R"

# --- 4. the refusals ------------------------------------------------------
R="$(mkfixture)"
for bad_retain in 0 '' abc -1; do
  out="$(bash "$PRUNE" --dir "$R" --retain "$bad_retain" --apply 2>&1)"; rc=$?
  left=$(count_enc "$R")
  if [ "$rc" -eq 2 ] && [ "$left" -eq 7 ]; then
    pass "refused --retain '$bad_retain' (exit 2) and deleted nothing"
  else
    fail "--retain '$bad_retain' gave rc=$rc and left $left archives (want rc=2, 7)"
  fi
done
out="$(bash "$PRUNE" --dir "$R/nope" --apply 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "refused a --dir that is not a directory (exit 2)" \
               || fail "a missing --dir gave rc=$rc, want 2"
out="$(bash "$PRUNE" --dir "$R" --wipe-everything 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "refused an unknown argument (exit 2)" \
               || fail "an unknown argument gave rc=$rc, want 2"

# --- 5. AISTACK_BACKUP_RETAIN is honoured ---------------------------------
out="$(AISTACK_BACKUP_RETAIN=1 bash "$PRUNE" --dir "$R" --apply 2>&1)"
left=$(count_enc "$R")
[ "$left" -eq 3 ] && pass "AISTACK_BACKUP_RETAIN=1 left 1 generated + 2 non-shape files" \
                  || fail "AISTACK_BACKUP_RETAIN=1 left $left .enc entries, expected 3"
have "$R" aistack-20261005T000000Z.tar.gz.enc \
  && pass "the one it kept is the newest" || fail "kept the wrong archive"
rm -rf "$R"

# --- 6. it never empties a directory that is already inside the limit -----
R="$(mktemp -d)"
echo c > "$R/aistack-20261005T000000Z.tar.gz.enc"
out="$(bash "$PRUNE" --dir "$R" --retain 3 --apply 2>&1)"
have "$R" aistack-20261005T000000Z.tar.gz.enc \
  && pass "a single archive is never pruned (the drill needs one)" \
  || fail "pruned the only archive in the directory"
printf '%s\n' "$out" | grep -q 'nothing to prune' \
  && pass "says there was nothing to prune" || fail "unexpected output: $out"
rm -rf "$R"

printf '\n'
[ "$FAIL" -eq 0 ] && { echo "backup retention: all assertions pass"; exit 0; }
echo "backup retention: FAILURES above"; exit 1
