#!/usr/bin/env bash
# NOM-350 — proves scripts/prune-reports.sh caps generated report dirs at 3
# and that each of its three refusals actually refuses.
#
# Runs against a FIXTURE root, not the repo: the real thing is only exercised
# by a 45-minute scan, and a retention test that needs a scan would never run.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PRUNE="$HERE/../scripts/prune-reports.sh"
FAIL=0
pass() { printf '  [ ok ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }
have() { [ -e "$1/$2" ]; }

mkfixture() {
  local r; r="$(mktemp -d)"
  # six generated dirs, oldest first by name
  for ts in 20261001T000000Z 20261002T000000Z 20261003T000000Z \
            20261004T000000Z 20261005T000000Z 20261006T000000Z; do
    mkdir -p "$r/security-report-$ts"; echo x > "$r/security-report-$ts/trivy.json"
  done
  # a hand-labelled evidence dir, and a file that merely looks like one
  mkdir -p "$r/security-report-nom999-20260101T000000Z"
  echo 'not a directory' > "$r/security-report-20260102T000000Z.txt"
  # a config file citing the OLDEST generated dir by name
  echo 'EVIDENCE=security-report-20261001T000000Z' > "$r/versions.env"
  printf '%s' "$r"
}

printf '\nNOM-350 report retention\n'

# --- 1. dry run deletes nothing -------------------------------------------
R="$(mkfixture)"
out="$(bash "$PRUNE" --root "$R" --retain 3 2>&1)"
n=$(ls -1d "$R"/security-report-*/ 2>/dev/null | wc -l)
[ "$n" -eq 7 ] && pass "dry run deleted nothing (7 dirs still present)" \
                || fail "dry run changed the tree: $n dirs left, expected 7"
printf '%s\n' "$out" | grep -q 'would prune security-report-20261002T000000Z' \
  && pass "dry run names what it would prune" || fail "dry run output missing: $out"
rm -rf "$R"

# --- 2. --apply keeps the newest 3, prunes the rest ------------------------
R="$(mkfixture)"
out="$(bash "$PRUNE" --root "$R" --retain 3 --apply 2>&1)"
for keep in security-report-20261006T000000Z security-report-20261005T000000Z \
            security-report-20261004T000000Z; do
  have "$R" "$keep" && pass "kept newest: $keep" || fail "deleted a dir inside the limit: $keep"
done
for gone in security-report-20261003T000000Z security-report-20261002T000000Z; do
  have "$R" "$gone" && fail "did not prune $gone" || pass "pruned: $gone"
done

# --- 3. the three refusals ------------------------------------------------
have "$R" security-report-20261001T000000Z \
  && pass "refusal 1: kept the CITED dir (named in versions.env) even though it is oldest" \
  || fail "refusal 1 broken: deleted a dir cited by versions.env"
printf '%s\n' "$out" | grep -q 'KEEPING security-report-20261001T000000Z' \
  && pass "refusal 1 is reported, not silent" || fail "citation keep was silent: $out"
have "$R" security-report-nom999-20260101T000000Z \
  && pass "refusal 2: kept the hand-LABELLED evidence dir" \
  || fail "refusal 2 broken: pruned a labelled evidence dir"
have "$R" security-report-20260102T000000Z.txt \
  && pass "refusal 3: kept the stray FILE that matches the prefix" \
  || fail "refusal 3 broken: deleted a non-directory"

# --- 4. idempotent --------------------------------------------------------
before="$(ls -1 "$R" | sort)"
bash "$PRUNE" --root "$R" --retain 3 --apply >/dev/null 2>&1
[ "$before" = "$(ls -1 "$R" | sort)" ] && pass "second run is a no-op" || fail "second run changed the tree"
rm -rf "$R"

# --- 5. retain 0 / junk must refuse, not empty the folder ------------------
for bad in 0 "" abc -1; do
  R="$(mkfixture)"
  bash "$PRUNE" --root "$R" --retain "$bad" --apply >/dev/null 2>&1
  rc=$?
  n=$(ls -1d "$R"/security-report-*/ 2>/dev/null | wc -l)
  if [ "$rc" -eq 2 ] && [ "$n" -eq 7 ]; then pass "refused --retain '$bad' (exit 2, tree untouched)"
  else fail "--retain '$bad' exited $rc leaving $n dirs — expected exit 2 and 7"; fi
  rm -rf "$R"
done

# --- 6. default retain is 3 ----------------------------------------------
R="$(mkfixture)"
bash "$PRUNE" --root "$R" --apply >/dev/null 2>&1
n=$(ls -1d "$R"/security-report-2026[01]*/ 2>/dev/null | grep -cE 'security-report-[0-9]{8}T[0-9]{6}Z/$')
[ "$n" -eq 4 ] && pass "default retain is 3 (3 newest + 1 cited survive)" \
               || fail "default retain wrong: $n generated dirs survive, expected 4"
rm -rf "$R"

# --- 7. a ROOT-OWNED report dir (what a `sudo security-check.sh` leaves) ---
# This is the case that made the first version of retention useless: it
# printed FAILED and the reports kept accumulating.  Four of the fourteen
# real ones on AI-Sandbox were in this state.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  R="$(mkfixture)"
  victim=security-report-20261002T000000Z
  docker run --rm -v "$R:/work" docker.io/library/busybox:stable \
    sh -c "chown -R 0:0 /work/$victim" >/dev/null 2>&1
  owner="$(stat -c %U "$R/$victim")"
  [ "$owner" = root ] && pass "fixture: $victim is root-owned" \
                      || fail "fixture setup failed: $victim is owned by $owner, expected root"
  out="$(bash "$PRUNE" --root "$R" --retain 3 --apply 2>&1)"
  have "$R" "$victim" && fail "root-owned dir survived: retention still cannot bound disk" \
                      || pass "pruned the ROOT-OWNED dir via the container fallback"
  printf '%s\n' "$out" | grep -q 'removed via container' \
    && pass "says which path removed it" || fail "container fallback was not reported: $out"
  rm -rf "$R" 2>/dev/null
else
  printf '  [SKIP] root-owned case needs a working docker; not exercised here\n'
  FAIL=1
fi

printf '\n'
[ "$FAIL" -eq 0 ] && { printf 'report retention: PASS\n\n'; exit 0; }
printf 'report retention: FAIL\n\n'; exit 1
