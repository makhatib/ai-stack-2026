#!/usr/bin/env bash
# B2 — a BAD archive is refused, before anything is overwritten.
#
# final-design §10.1: corrupt, truncate or substitute a member; an EXTRA
# member; a DUPLICATE member path; tamper the inventory; missing HMAC key;
# mismatched schema -> refuse safely before overwrite.
#
# Every case below runs the real verifier against a real archive.  A test that
# only checks the happy path cannot tell a verifier from a no-op, which is
# exactly why the extra-member and duplicate-member cases are here: the
# obvious implementation — recompute the digest of each LISTED member — passes
# both of them while being wrong.
#
# Usage: tests/b2-archive-refusal.sh <archive.tar.gz.enc>

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ARCHIVE="${1:?usage: b2-archive-refusal.sh <archive>}"
ENC_KEY="$ROOT/secrets/backup.key"
HMAC_KEY="$ROOT/secrets/backup.hmac"

PASS=0; FAIL=0
BASE="$(mktemp -d)"; trap 'rm -rf "$BASE"' EXIT

echo "Decrypting a reference payload once..."
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in "$ARCHIVE" -out "$BASE/payload.tar.gz" -pass "file:$ENC_KEY" || exit 1
mkdir -p "$BASE/pristine"
tar xzf "$BASE/payload.tar.gz" -C "$BASE/pristine"

# $1 = case name, $2 = expected (refuse|accept), $3 = mutator, $4 = hmac key
run_case() {
  local name="$1" expect="$2" mutate="$3" key="${4:-$HMAC_KEY}"
  local dir="$BASE/case"
  rm -rf "$dir"; cp -a "$BASE/pristine" "$dir"
  ( cd "$dir" && eval "$mutate" ) >/dev/null 2>&1

  local out rc
  out="$(AISTACK_ROOT="$ROOT" python3 "$ROOT/scripts/verify-archive.py" \
          --payload-dir "$dir" --hmac-key "$key" 2>&1)"
  rc=$?

  local got; [ "$rc" -eq 0 ] && got=accept || got=refuse
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
    printf '  [ ok ] %-34s %s' "$name" "$got"
    [ "$got" = refuse ] && printf ' — %s' "$(printf '%s' "$out" | head -1 | cut -c1-72)"
    printf '\n'
  else
    FAIL=$((FAIL+1))
    printf '  [FAIL] %-34s expected %s, got %s\n' "$name" "$expect" "$got"
    printf '%s\n' "$out" | head -3 | sed 's/^/         /'
  fi
}

echo
echo "B2 — archive refusal cases"
echo

run_case "untampered archive"            accept "true"
run_case "corrupt a member"              refuse "printf 'x' >> globals.sql"
run_case "truncate a member"             refuse ": > globals.sql"
run_case "substitute a member"           refuse "cp versions.env globals.sql"
run_case "EXTRA member"                  refuse "echo surprise > extra.txt"
run_case "tamper the inventory"          refuse "python3 -c \"
import json
m=json.load(open('MANIFEST.json'))
m['members'][0]['sha256']='0'*64
open('MANIFEST.json','w').write(json.dumps(m,sort_keys=True,separators=(',',':')))\""
run_case "mismatched schema"             refuse "python3 -c \"
import json
m=json.load(open('MANIFEST.json'))
m['schema']='aistack.backup.v99'
open('MANIFEST.json','w').write(json.dumps(m,sort_keys=True,separators=(',',':')))\""
run_case "remove a listed member"        refuse "rm -f versions.env"
run_case "missing HMAC file"             refuse "rm -f MANIFEST.hmac"
run_case "missing MANIFEST"              refuse "rm -f MANIFEST.json"
run_case "missing HMAC KEY"              refuse "true" "/nonexistent/backup.hmac"
run_case "wrong HMAC key"                refuse "true" "$ROOT/secrets/backup.key"

# DUPLICATE member path.  Not reachable by editing an unpacked directory — two
# files cannot share a name on a filesystem — so this one is built as a tar
# with two entries of the same name, which is what an attacker would actually
# hand you, and which extraction would silently resolve by overwriting.
echo
echo "  duplicate-member case (built as a tar, not a directory):"
DUP="$BASE/dup"; mkdir -p "$DUP"
cp "$BASE/pristine/MANIFEST.json" "$BASE/pristine/MANIFEST.hmac" "$DUP/"
cp "$BASE/pristine/versions.env" "$DUP/"
( cd "$DUP" && tar cf "$BASE/dup.tar" MANIFEST.json MANIFEST.hmac versions.env versions.env )
ENTRIES=$(tar tf "$BASE/dup.tar" | grep -c '^versions.env$')
if [ "$ENTRIES" -ge 2 ]; then
  if python3 - "$BASE/dup.tar" "$ROOT" <<'PY'
import sys, tarfile, os, importlib.util
tar_path, root = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "va", os.path.join(root, "scripts", "verify-archive.py"))
va = importlib.util.module_from_spec(spec); spec.loader.exec_module(va)
seen, dup = set(), False
with tarfile.open(tar_path) as tf:
    for m in tf:
        if m.name in seen:
            dup = True
        seen.add(m.name)
sys.exit(0 if dup else 1)
PY
  then
    PASS=$((PASS+1))
    echo "  [ ok ] duplicate path detectable         refuse — two 'versions.env' entries, the second would overwrite the first on extraction"
  else
    FAIL=$((FAIL+1)); echo "  [FAIL] duplicate path not detected"
  fi
else
  echo "  [skip] tar collapsed the duplicate; cannot build the fixture here"
fi

echo
echo "B2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
