#!/usr/bin/env bash
# AI Stack 2026 — the backup dump set is the CLUSTER's set, and what it leaves
# out is written down (NOM-378).
#
# WHAT THIS TEST EXISTS TO STOP.
#
# scripts/backup.sh derived its dump set from the key set of
# secrets/app_db_passwords.  That was a deliberate fix for a hardcoded list
# (NOM-307) and it reads as correct, which is why this survived review: the
# comment above it accurately describes a derivation.  The defect was one level
# up -- "the app databases" and "the databases in this cluster" were assumed to
# be the same set.
#
# Measured 2026-10-23: the cluster held SEVEN connectable databases and every
# archive in backups/ contained FOUR.  `aistack` -- the POSTGRES_DB itself,
# holding aistack_slot and action_state_edges -- was in none of them.
#
# And nothing failed.  restore.sh verifies an archive against its own manifest,
# the manifest faithfully lists what backup.sh chose to include, so the check
# and the gap agreed with each other.  THAT is the property under test here:
# not "does the backup work", but "can the backup be wrong about its own scope
# without anything saying so".
#
# IT RUNS THE SHIPPED DERIVATION, NOT A COPY OF IT.  The block between the
# `db-set derivation` markers in scripts/backup.sh is extracted and sourced
# with a STUBBED cluster and a SYNTHETIC password file.  A test that retyped
# the logic would pass forever while backup.sh drifted, which is the same shape
# as the defect.  If the markers are gone the test REFUSES (exit 2) rather than
# reporting on a block it could not find.
#
# No docker, no live stack, no root, no postgres: the cluster is a shell
# function and the secrets are a fixture.
#
# Run:  tests/backup-db-set.sh        (<1s)

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

BACKUP="$ROOT/scripts/backup.sh"
VERIFY="$ROOT/scripts/verify-archive.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { printf '  ok    %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
note() { printf '        %s\n' "$*"; }
refuse() { printf '\n  REFUSED: %s\n\n' "$*" >&2; exit 2; }

printf '\n== backup dump set: the cluster decides, the omissions are recorded ==\n\n'

# --- extract the shipped derivation ----------------------------------------
[ -r "$BACKUP" ] || refuse "cannot read $BACKUP"
[ -r "$VERIFY" ] || refuse "cannot read $VERIFY"

BLOCK="$WORK/derivation.sh"
awk '/^# >>> db-set derivation/{f=1; next} /^# <<< db-set derivation/{f=0} f' \
  "$BACKUP" > "$BLOCK"

# A marker rename, or a refactor that moves the derivation elsewhere, must stop
# this test rather than let it measure an empty file -- "0 failures out of
# nothing" is the cheapest false green there is.
if [ ! -s "$BLOCK" ]; then
  refuse "the 'db-set derivation' markers are not in scripts/backup.sh, or the
  block between them is empty, so the shipped derivation could not be
  extracted and NOTHING WAS MEASURED. Restore the markers around the dump-set
  derivation, or update this test to match the new structure."
fi
# It must be the real thing, not a comment block that happens to sit between
# the markers.
grep -q 'DUMP_DBS' "$BLOCK" \
  || refuse "the extracted block does not assign DUMP_DBS; the markers are
  around the wrong lines and nothing was measured."
ok "extracted the shipped derivation from scripts/backup.sh ($(grep -c '' "$BLOCK") lines)"

# --- the harness: the block, a stubbed cluster, a fixture secrets file ------
# `set -euo pipefail` mirrors scripts/backup.sh exactly, so the block is
# measured under the same shell options it actually runs under.
cat > "$WORK/run.sh" <<'RUNNER'
set -euo pipefail
die() { printf 'DIE: %s\n' "$*"; exit 9; }
cluster_databases() {
  if [ "${CLUSTER_FAIL:-0}" = "1" ]; then return 1; fi
  printf '%s' "$CLUSTER"
}
# shellcheck source=/dev/null
. "$BLOCK"
printf 'DUMP:%s\n'    "$DUMP_DBS"
printf 'APP:%s\n'     "$DUMP_APP"
printf 'OTHER:%s\n'   "$DUMP_CLUSTER"
printf 'SKIPPED:%s\n' "$DB_SKIPPED"
printf 'EXCLUDE:'; for e in "${DB_EXCLUDE[@]}"; do printf ' %s' "${e%%|*}"; done; printf '\n'
RUNNER

# $1 = newline-separated cluster databases, $2 = space-separated app names.
# Sets OUT and RC.
derive() {
  local cluster="$1" apps="$2" app fixture="$WORK/fixture"
  rm -rf "$fixture"; mkdir -p "$fixture/secrets"
  : > "$fixture/secrets/app_db_passwords"
  for app in $apps; do
    printf '%s=synthetic-not-a-real-password\n' "$app" >> "$fixture/secrets/app_db_passwords"
  done
  OUT="$(ROOT="$fixture" BLOCK="$BLOCK" CLUSTER="$cluster" CLUSTER_FAIL="${CLUSTER_FAIL:-0}" \
         bash "$WORK/run.sh" 2>&1)"
  RC=$?
}

field() { printf '%s\n' "$OUT" | sed -n "s/^$1://p"; }

# The cluster as measured on 2026-10-23 -- SEVEN connectable databases, four of
# them apps -- with SYNTHETIC app names.
#
# The app names are deliberately not the real ones.  Two reasons, and they
# agree: CI invariant I15 fails any second literal copy of the app list, and
# scripts/gen-secrets.sh is its single declaration (tests/app-list-coupling.sh
# dodges the same rule with a printf fixture).  Independently, a fixture that
# hardcodes today's four apps would need editing every time the app set
# changes, which is the coupling this repository keeps removing.
#
# What is NOT synthetic is the part under test: `aistack` (the POSTGRES_DB),
# `postgres` and `template1` are the three real databases the ticket is about,
# and they are named exactly.
SEVEN='aistack
app_a
app_b
app_c
app_d
postgres
template1'
FOUR_APPS='app_a app_b app_c app_d'

# --- 1. THE DEFECT: aistack is in the set ----------------------------------
derive "$SEVEN" "$FOUR_APPS"
if [ "$RC" -ne 0 ]; then
  bad "the measured 7-database cluster: derivation exited $RC"
  note "$OUT"
else
  GOT="$(field DUMP)"
  if [ "$GOT" = " aistack app_a app_b app_c app_d" ]; then
    ok "7-database cluster dumps 5:$GOT"
  else
    bad "7-database cluster dumps '$GOT', expected ' aistack app_a app_b app_c app_d'"
  fi
  # Stated as its own assertion because it is the one the ticket is about: a
  # set that merely has the right COUNT could still be the wrong five.
  case "$(field DUMP)" in
    *aistack*) ok "aistack -- the POSTGRES_DB that was in no archive -- is now dumped" ;;
    *) bad "aistack is STILL not in the dump set; this is the NOM-378 defect" ;;
  esac
fi

# --- 2. the omissions are exactly the two that are documented --------------
# This is the assertion that stops silent drift in the other direction.  A
# future edit that adds a third exclusion, or quietly drops aistack back out,
# fails here and has to come and change this line -- which is the point where
# someone has to write down why.
GOT="$(field EXCLUDE)"
if [ "$GOT" = " postgres template1" ]; then
  ok "the exclusion list is exactly postgres and template1, and nothing else"
else
  bad "the exclusion list is '$GOT', expected ' postgres template1'"
  note "If this is a deliberate change, document it in scripts/backup.sh's"
  note "derivation note and update this assertion in the same commit."
fi
GOT="$(field SKIPPED)"
[ "$GOT" = " postgres template1" ] \
  && ok "both are reported as skipped, so the backup says so out loud:$GOT" \
  || bad "skipped set is '$GOT', expected ' postgres template1'"

# --- 3. template0 is never a candidate -------------------------------------
# datallowconn = false, so the cluster query never offers it.  Asserted anyway:
# if someone widens that query to datistemplate, template0 appears and pg_dump
# cannot read it, so the backup would start failing on a database it should
# never have asked about.
case "$(field DUMP)" in
  *template0*) bad "template0 is in the dump set; pg_dump cannot read it" ;;
  *) ok "template0 is not in the set (the query asks for datallowconn)" ;;
esac

# --- 4. app vs cluster kind, which is what the drill asserts over ----------
GOT="$(field APP)"
[ "$GOT" = " app_a app_b app_c app_d" ] \
  && ok "the four apps are classified 'app':$GOT" \
  || bad "app-kind set is '$GOT', expected ' app_a app_b app_c app_d'"
GOT="$(field OTHER)"
[ "$GOT" = " aistack" ] \
  && ok "aistack is classified 'cluster', so the drill asks for no aistack role" \
  || bad "cluster-kind set is '$GOT', expected ' aistack'"

# --- 5. a new app is picked up with no edit here ---------------------------
derive "$(printf '%s\napp_e' "$SEVEN" | sort)" "$FOUR_APPS app_e"
if [ "$RC" -ne 0 ]; then
  bad "fifth app declared and created: derivation exited $RC"; note "$OUT"
else
  case "$(field DUMP)" in
    *app_e*) ok "a fifth app in the cluster and the password file is dumped" ;;
    *) bad "a fifth app is not in the dump set: $(field DUMP)" ;;
  esac
  case "$(field APP)" in
    *app_e*) ok "the fifth app is classified 'app', so its role gets asserted" ;;
    *) bad "the fifth app is not classified 'app': $(field APP)" ;;
  esac
fi

# --- 6. a database created BY HAND is dumped, not silently skipped ---------
# The whole point of deriving from the cluster.  Under the old derivation this
# database was absent from a successful archive and nothing mentioned it.
derive "$(printf '%s\nextradb' "$SEVEN" | sort)" "$FOUR_APPS"
if [ "$RC" -ne 0 ]; then
  bad "hand-made database: derivation exited $RC"; note "$OUT"
else
  case "$(field DUMP)" in
    *extradb*) ok "a database created outside this repo is dumped" ;;
    *) bad "a hand-made database is silently absent from the set: $(field DUMP)" ;;
  esac
  case "$(field OTHER)" in
    *extradb*) ok "and classified 'cluster', since it has no app role" ;;
    *) bad "hand-made database not classified 'cluster': $(field OTHER)" ;;
  esac
fi

# --- 7. a declared app with no database is a FAILURE, not a smaller backup -
# The other half of the NOM-307 coupling, and the reason app_db_passwords is
# still read.  Deriving from the cluster alone would make this app simply
# absent from an archive that reports success.
derive "$SEVEN" "$FOUR_APPS app_e"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'app_e'; then
  ok "a declared app with no database refuses, and NAMES the app"
else
  bad "declared-but-missing app: exit=$RC did not refuse naming app_e"
  note "$OUT"
fi

# --- 8. the vacuous cases all refuse ---------------------------------------
derive "" "$FOUR_APPS"
[ "$RC" -ne 0 ] \
  && ok "a cluster that reports no database refuses rather than dumping nothing" \
  || bad "an empty cluster produced exit 0 and dump set '$(field DUMP)'"

# Set and cleared around the call rather than prefixed onto it: bash keeps a
# `VAR=x func` assignment in effect after the function returns.
CLUSTER_FAIL=1
derive "$SEVEN" "$FOUR_APPS"
CLUSTER_FAIL=0
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'cannot ask postgres'; then
  ok "a failing cluster query refuses instead of falling back to secrets/"
else
  bad "a failing cluster query: exit=$RC"; note "$OUT"
fi

derive "$SEVEN" ""
[ "$RC" -ne 0 ] \
  && ok "an empty app_db_passwords refuses (it is not 'no apps are required')" \
  || bad "an empty password file produced exit 0"

# --- 9. a name that is not a bare identifier is refused, not spliced -------
# $db becomes both a `pg_dump -d` argument and the member path "$db.dump".
derive "$(printf '%s\nweird-name' "$SEVEN" | sort)" "$FOUR_APPS"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'bare identifier'; then
  ok "a database name outside [A-Za-z0-9_] is refused, not built into a path"
else
  bad "non-identifier database name: exit=$RC did not refuse"; note "$OUT"
fi

# --- 10. the restore path can state what an archive cannot return ----------
# Driven through scripts/verify-archive.py's database_statement(), which is the
# one function restore.sh and `aistack verify` both read the set through, so
# they cannot drift in what they say.
printf '\n  -- what the restore path states --\n'
python3 - "$VERIFY" <<'PY'
import importlib.util, json, sys

spec = importlib.util.spec_from_file_location("verify_archive", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

P = F = 0


def ok(m):
    global P
    P += 1
    print("  ok    %s" % m)


def bad(m):
    global F
    F += 1
    print("  FAIL  %s" % m)


MEMBERS = [{"path": n} for n in
           ("aistack.dump", "app_a.dump", "app_b.dump", "app_c.dump",
            "app_d.dump", "globals.sql", "secrets.tar.gz")]
CURRENT = {
    "schema": "aistack.backup.v1",
    "members": MEMBERS,
    "databases": {
        "dumped": [{"name": "aistack", "kind": "cluster"},
                   {"name": "app_a", "kind": "app"},
                   {"name": "app_b", "kind": "app"},
                   {"name": "app_c", "kind": "app"},
                   {"name": "app_d", "kind": "app"}],
        "excluded": [{"name": "postgres", "reason": "the maintenance database"},
                     {"name": "template1", "reason": "the template"}],
    },
}

st = mod.database_statement(CURRENT)
if st["recorded"] and [e["name"] for e in st["returns"]] == [
        "aistack", "app_a", "app_b", "app_c", "app_d"]:
    ok("a current archive states the 5 databases it returns")
else:
    bad("current archive returns %r" % st["returns"])

nores = {e["name"]: e["reason"] for e in st["does_not_return"]}
if sorted(nores) == ["postgres", "template1"] and all(nores.values()):
    ok("and names postgres and template1 as NOT returned, each with a reason")
else:
    bad("does_not_return is %r" % st["does_not_return"])

if [e["name"] for e in st["returns"] if e["kind"] == "app"] == [
        "app_a", "app_b", "app_c", "app_d"]:
    ok("the app kinds it hands the drill exclude aistack")
else:
    bad("app kinds are %r" % st["returns"])

# A LEGACY ARCHIVE MUST NOT CLAIM IT EXCLUDED NOTHING.  Every archive now in
# backups/ is one of these.  "nothing was excluded" and "what was excluded was
# never written down" are different statements and only the second is true.
LEGACY = {"schema": "aistack.backup.v1",
          "members": [{"path": n} for n in
                      ("app_a.dump", "app_b.dump", "app_c.dump",
                       "app_d.dump", "globals.sql")]}
st = mod.database_statement(LEGACY)
if st["recorded"] is False and st["note"] and not st["does_not_return"]:
    ok("a pre-NOM-378 archive reports recorded=False and says what it cannot say")
else:
    bad("legacy archive statement is %r" % st)
if [e["name"] for e in st["returns"]] == ["app_a", "app_b", "app_c", "app_d"]:
    ok("and still lists the four dumps it does carry")
else:
    bad("legacy archive returns %r" % st["returns"])

print("\n  SUBTOTAL %d passed, %d failed" % (P, F))
sys.exit(1 if F else 0)
PY
if [ $? -eq 0 ]; then
  ok "database_statement(): the restore path can state both halves of the set"
else
  bad "database_statement() assertions failed (see SUBTOTAL above)"
fi

# --- 11. the recorded set is load-bearing, not prose in a JSON file --------
# If `databases.dumped` could disagree with the dumps actually present, the
# restore path would print a claim the archive cannot honour -- this ticket's
# defect, moved into the thing that describes it.  verify() must refuse.
printf '\n  -- the recorded set must match the dumps present --\n'
python3 - "$VERIFY" "$WORK" <<'PY'
import hashlib, hmac, importlib.util, json, os, sys

spec = importlib.util.spec_from_file_location("verify_archive", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
work = sys.argv[2]

P = F = 0
SEQ = [0]


def build(payload, databases):
    """A real payload dir with real digests and a real HMAC.

    A FRESH directory per call, numbered rather than hashed: reusing one would
    leave the previous call's dumps behind, verify() would correctly refuse
    them as extra members, and the refusal would read as this assertion
    passing for the wrong reason.
    """
    SEQ[0] += 1
    d = os.path.join(work, "payload-%d" % SEQ[0])
    os.makedirs(d)
    members = []
    for name in sorted(payload):
        p = os.path.join(d, name)
        with open(p, "wb") as fh:
            fh.write(payload[name])
        members.append({"path": name,
                        "sha256": hashlib.sha256(payload[name]).hexdigest(),
                        "bytes": len(payload[name])})
    m = {"schema": "aistack.backup.v1", "created_at": "x",
         "members": members, "databases": databases}
    raw = json.dumps(m, sort_keys=True, separators=(",", ":")).encode()
    with open(os.path.join(d, "MANIFEST.json"), "wb") as fh:
        fh.write(raw)
    key = b"test-only-hmac-key"
    kp = os.path.join(work, "hmac.key")
    with open(kp, "wb") as fh:
        fh.write(key)
    with open(os.path.join(d, "MANIFEST.hmac"), "w") as fh:
        fh.write(hmac.new(key, raw, hashlib.sha256).hexdigest())
    return d, kp


PAYLOAD = {"aistack.dump": b"a", "app_a.dump": b"b", "globals.sql": b"c"}

# Honest: recorded set == dumps present.
d, kp = build(PAYLOAD, {"dumped": [{"name": "aistack", "kind": "cluster"},
                                   {"name": "app_a", "kind": "app"}],
                        "excluded": [{"name": "postgres", "reason": "r"}]})
try:
    mod.verify(d, kp)
    print("  ok    an archive whose recorded set matches its dumps verifies")
    P += 1
except mod.Refuse as e:
    print("  FAIL  honest archive refused: %s" % e)
    F += 1

# Claims a database it does not carry.
d, kp = build(PAYLOAD, {"dumped": [{"name": "aistack", "kind": "cluster"},
                                   {"name": "app_a", "kind": "app"},
                                   {"name": "app_z", "kind": "app"}],
                        "excluded": []})
try:
    mod.verify(d, kp)
    print("  FAIL  a manifest claiming a dump it does not carry VERIFIED")
    F += 1
except mod.Refuse:
    print("  ok    a manifest claiming app_z with no app_z.dump is refused")
    P += 1

# Lists the same database as both dumped and excluded.
d, kp = build(PAYLOAD, {"dumped": [{"name": "aistack", "kind": "cluster"},
                                   {"name": "app_a", "kind": "app"}],
                        "excluded": [{"name": "app_a", "reason": "r"}]})
try:
    mod.verify(d, kp)
    print("  FAIL  a manifest calling app_a both dumped and excluded VERIFIED")
    F += 1
except mod.Refuse:
    print("  ok    a database listed as both dumped and excluded is refused")
    P += 1

print("\n  SUBTOTAL %d passed, %d failed" % (P, F))
sys.exit(1 if F else 0)
PY
if [ $? -eq 0 ]; then
  ok "verify(): a manifest that misdescribes its own database set is refused"
else
  bad "verify() recorded-set assertions failed (see SUBTOTAL above)"
fi

printf '\n== %d passed, %d failed ==\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
