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

# --- 12. what the RESTORE hands the drill as its expectation ---------------
#
# WHY THIS IS NOT LEFT TO THE DRILL.  scripts/drill.sh is the real end-to-end
# proof, and it refuses to run alongside serving containers -- by design, since
# a drill beside a live stack is what its lock exists to prevent.  So the only
# way to exercise this decision through the drill is planned downtime, and a
# decision that can only be checked during downtime is one that gets checked
# by hoping.  The classification lives in a function for exactly that reason,
# and the shipped lines are extracted and run here, same as the dump set.
#
# The decision matters in a way that is easy to miss.  The dump set now
# includes `aistack`, which is the POSTGRES_DB and is owned by the superuser:
# there is no non-superuser `aistack` role and there should not be one.  If
# `aistack` reached the drill's expectation list, drill.sh would look for that
# role, not find it, and FAIL A GOOD RESTORE -- the fix for a silent gap
# turning itself into a false alarm.
printf '\n  -- the expectation the restore hands the drill --\n'

RBLOCK="$WORK/classify.sh"
awk '/^# >>> restored-db classification/{f=1; next} /^# <<< restored-db classification/{f=0} f' \
  "$ROOT/scripts/restore.sh" > "$RBLOCK"
if [ ! -s "$RBLOCK" ]; then
  refuse "the 'restored-db classification' markers are not in scripts/restore.sh,
  or the block between them is empty, so NOTHING WAS MEASURED about what the
  restore hands the drill. Restore the markers, or update this test."
fi
for fn in is_app_db restored_db_kind record_restored_db create_database_sql require_database_present; do
  grep -q "^$fn()" "$RBLOCK" \
    || refuse "the extracted block does not define $fn(); the markers are around
  the wrong lines, or the function moved out from between them, and NOTHING WAS
  MEASURED about it."
done
ok "extracted the shipped classification from scripts/restore.sh ($(grep -c '' "$RBLOCK") lines)"

# $1 = RESTORE_DB_RECORDED, $2 = app dbs, $3 = dumps present.  Sets RECORDED.
classify() {
  local out="$WORK/restored.txt"
  : > "$out"
  RECORDED="$(
    RESTORE_DB_RECORDED="$1" RESTORE_APP_DBS="$2" RESTORED_DBS_FILE="$out" \
    DUMPS="$3" bash -c '
      set -uo pipefail
      . "$1"
      for db in $DUMPS; do record_restored_db "$db"; done
      tr "\n" " " < "$RESTORED_DBS_FILE"
    ' _ "$RBLOCK"
  )"
}

# A current archive: five dumps, four of them apps.
classify 1 "authelia litellm n8n openwebui" "aistack authelia litellm n8n openwebui"
if [ "$RECORDED" = "authelia litellm n8n openwebui " ]; then
  ok "a current archive hands the drill the 4 app databases: $RECORDED"
else
  bad "current archive hands the drill '$RECORDED', expected the 4 apps"
fi
case "$RECORDED" in
  *aistack*) bad "aistack reached the drill's expectation; it has no non-superuser role, so this FAILS A GOOD RESTORE" ;;
  *) ok "aistack is NOT in it, so the drill does not demand a role that must not exist" ;;
esac

# A fifth app, with nobody editing the drill.
classify 1 "authelia litellm n8n openwebui app_e" "aistack app_e authelia litellm n8n openwebui"
case "$RECORDED" in
  *app_e*) ok "a fifth app in the archive gets its role asserted with no edit to the drill" ;;
  *) bad "a fifth app did not reach the drill's expectation: $RECORDED" ;;
esac

# A LEGACY archive records no kinds, and every dump in one IS an app database,
# so the fallback must be the old behaviour exactly -- not an empty
# expectation, which drill.sh would have to treat as a vacuous pass.
classify 0 "" "authelia litellm n8n openwebui"
if [ "$RECORDED" = "authelia litellm n8n openwebui " ]; then
  ok "a pre-NOM-378 archive falls back to all 4 dumps, the old behaviour exactly"
else
  bad "legacy fallback hands the drill '$RECORDED', expected the 4 dumps"
fi
classify 0 "" ""
if [ -z "${RECORDED// /}" ]; then
  ok "and an archive with no dump hands over nothing, which drill.sh refuses as vacuous"
else
  bad "an archive with no dump produced '$RECORDED'"
fi

# --- 12a. AND WHAT IT HANDS THE DRILL ABOUT THE DATABASES IT DROPS ---------
#
# The expectation above is app databases only, and it has to be: the drill
# asserts a non-superuser role per entry and a cluster-kind database has none.
# But "not in the role expectation" and "not mentioned at all" were the same
# line, so `aistack` could restore EMPTY and the drill still appended PASS --
# the parent ticket's shape, inside the thing written to catch it (NOM-392).
#
# So record_restored_db() writes a SECOND file, `<kind> <name>` per line, and
# the kind is a recorded fact rather than an absence.  Two properties are under
# test and they are different: that a cluster-kind database reaches the drill
# at all, and that an archive which states NO kinds is distinguishable from one
# whose cluster-kind recording broke.  Both produce an empty cluster set; only
# the first is allowed to be a note instead of a failure.
printf '\n  -- the kinds the restore hands the drill --\n'

# $1 = RESTORE_DB_RECORDED, $2 = app dbs, $3 = dumps present.  Sets KINDS to
# the file contents with newlines turned into ';' so it can be matched whole,
# and APPSIDE to what the same call wrote to the app expectation.
kinds() {
  local kout="$WORK/kinds.txt" aout="$WORK/restored2.txt"
  : > "$kout"; : > "$aout"
  KINDS="$(
    RESTORE_DB_RECORDED="$1" RESTORE_APP_DBS="$2" \
    RESTORED_DB_KINDS_FILE="$kout" RESTORED_DBS_FILE="$aout" \
    DUMPS="$3" bash -c '
      set -uo pipefail
      . "$1"
      for db in $DUMPS; do record_restored_db "$db"; done
      tr "\n" ";" < "$RESTORED_DB_KINDS_FILE"
    ' _ "$RBLOCK"
  )"
  APPSIDE="$(tr '\n' ' ' < "$aout")"
}

# A current archive: the cluster-kind database is named, with its kind.
kinds 1 "app_a app_b" "aistack app_a app_b"
if [ "$KINDS" = "cluster aistack;app app_a;app app_b;" ]; then
  ok "a current archive hands over the kinds: $KINDS"
else
  bad "current archive hands over '$KINDS', expected 'cluster aistack;app app_a;app app_b;'"
fi
# Stated separately because it is the assertion the ticket is about: the drill
# cannot assert over `aistack` if nothing ever tells it `aistack` was restored.
case "$KINDS" in
  *"cluster aistack"*) ok "aistack reaches the drill as cluster-kind, so assertion 5 has something to assert" ;;
  *) bad "aistack does NOT reach the drill; a cluster-kind database can restore empty and pass" ;;
esac
# ...and the app expectation is BYTE-FOR-BYTE what it was before the second
# file existed.  A change that fixed the gap by widening the role expectation
# would fail a good restore, which is the failure NOM-378 wrote the filter for.
if [ "$APPSIDE" = "app_a app_b " ]; then
  ok "and the app-role expectation is unchanged by the second file: $APPSIDE"
else
  bad "the app-role expectation changed to '$APPSIDE', expected 'app_a app_b '"
fi

# A LEGACY archive: every dump is `legacy`, and NOTHING is `cluster`.  This is
# the line that lets drill.sh treat an empty cluster set as a note here and as
# a failure everywhere else.
kinds 0 "" "app_a app_b"
if [ "$KINDS" = "legacy app_a;legacy app_b;" ]; then
  ok "a pre-NOM-378 archive says 'legacy', so the drill knows it was never told"
else
  bad "legacy archive hands over '$KINDS', expected 'legacy app_a;legacy app_b;'"
fi
case "$KINDS" in
  *cluster*) bad "a legacy archive claimed a cluster-kind database; the drill would assert over a database the archive never recorded" ;;
  *) ok "and nothing in a legacy archive is claimed as cluster-kind" ;;
esac

# The kinds file is OPT-IN.  With the variable unset nothing is written and the
# app expectation is exactly what it always was -- `aistack verify` and a
# plain `aistack restore` must not change behaviour because the drill wanted a
# second file.
UNSET_OUT="$(
  RESTORE_DB_RECORDED=1 RESTORE_APP_DBS="app_a app_b" \
  RESTORED_DBS_FILE="$WORK/restored3.txt" DUMPS="aistack app_a app_b" \
  bash -c '
    set -uo pipefail
    : > "$RESTORED_DBS_FILE"
    . "$1"
    for db in $DUMPS; do record_restored_db "$db"; done
    tr "\n" " " < "$RESTORED_DBS_FILE"
  ' _ "$RBLOCK" 2>&1
)"
if [ "$UNSET_OUT" = "app_a app_b " ]; then
  ok "with AISTACK_RESTORED_DB_KINDS_FILE unset, nothing is written and the old path is unchanged"
else
  bad "with the kinds file unset the app expectation became '$UNSET_OUT', expected 'app_a app_b '"
fi

# --- 12b. A NAME THE CHANNEL CANNOT CARRY IS REFUSED, NOT ENCODED (NOM-394) -
#
# Both files 12a measures hold ONE DATABASE PER LINE, and the name comes from a
# filename inside the ARCHIVE.  A name holding a newline is not written
# corrupted -- it is written as TWO entries that both look legitimate and
# neither of which is the database that was in the archive.  That is the
# NOM-393 failure one layer up, and a reader cannot undo it: by the time
# drill.sh opens the file the name is gone.  So the refusal has to be at the
# writer, which is in the block extracted above, which is why it is measured
# here and not in tests/drill-assertion5.sh.
#
# AND IT IS MEASURED AGAINST A CONTROL.  The last two cases strip the guard out
# of the shipped block and require the SAME name to produce the misreport
# there.  A guard whose absence changes nothing is not evidence that the guard
# is what stops this.
printf '\n  -- a name the expectation channel cannot carry (NOM-394) --\n'

# $1 = block to source, $2 = database name.  Sets W_RC, W_OUT, W_KINDS, W_APPS.
write_one() {
  local kout="$WORK/k394.txt" aout="$WORK/a394.txt"
  : > "$kout"; : > "$aout"
  W_OUT="$(
    RESTORE_DB_RECORDED=1 RESTORE_APP_DBS="app_a app_b" \
    RESTORED_DB_KINDS_FILE="$kout" RESTORED_DBS_FILE="$aout" \
    NAME="$2" bash -c '
      set -euo pipefail
      die() { printf "DIE: %s\n" "$*"; exit 9; }
      # shellcheck source=/dev/null
      . "$1"
      record_restored_db "$NAME"
      echo RETURNED-0
    ' _ "$1" 2>&1
  )"
  W_RC=$?
  W_KINDS="$(tr '\n' ';' < "$kout")"
  W_APPS="$(tr '\n' ';' < "$aout")"
}

# THE TICKET'S NAME.  Chosen so that BOTH lines it would produce are themselves
# well-formed `cluster <bare identifier>` entries -- the case the reader cannot
# tell from two real databases.
EVIL="$(printf 'aistack\ncluster evil')"

write_one "$RBLOCK" "$EVIL"
if [ "$W_RC" -ne 0 ] && printf '%s\n' "$W_OUT" | grep -q 'not a bare identifier'; then
  ok "a database name holding a NEWLINE is refused at the writer, with the reason named"
else
  bad "the newline name was not refused: exit=$W_RC"; note "$W_OUT"
fi
if [ -z "$W_KINDS" ] && [ -z "$W_APPS" ]; then
  ok "...and NOTHING was appended to either channel, so no entry of it survives to be read"
else
  bad "the refusal still appended: kinds='$W_KINDS' apps='$W_APPS'"
fi

# THE SAME RULE AS THE READER, not a narrower newline-only one: a space and a
# tab are what NOM-393 fixed downstream, and a hyphen is the ordinary name
# that scripts/backup.sh already refuses to dump.  All three must stop here too
# or the two ends of the channel disagree about what a name may be.
SURVIVED=""
for n in 'my db' "$(printf 'ai\tstack')" 'my-db'; do
  write_one "$RBLOCK" "$n"
  [ "$W_RC" -ne 0 ] || SURVIVED="$SURVIVED '$n'"
  [ -z "$W_KINDS$W_APPS" ] || SURVIVED="$SURVIVED '$n'(wrote)"
done
[ -z "$SURVIVED" ] \
  && ok "a space, a tab and a hyphen are refused by the same rule, so both ends of the channel agree" \
  || bad "these names were not refused at the writer:$SURVIVED"

# A normal name is untouched by the guard -- asserted here and not left to
# 12a's cases, because a guard that refuses everything would pass every
# assertion above about refusals and break every restore.
write_one "$RBLOCK" aistack
if [ "$W_RC" -eq 0 ] && [ "$W_KINDS" = "cluster aistack;" ]; then
  ok "and a bare-identifier name is recorded exactly as before: $W_KINDS"
else
  bad "the guard changed a normal name's handling: exit=$W_RC kinds='$W_KINDS'"; note "$W_OUT"
fi

# --- 12c. teeth: the control, with the guard removed -----------------------
PRE394="$WORK/classify-pre394.sh"
python3 - "$RBLOCK" "$PRE394" <<'PY' || refuse "the NOM-394 bare-identifier guard could not be
  removed from the extracted block (expected exactly one case/esac carrying
  [!A-Za-z0-9_]), so the CONTROL for it was not built and its teeth were NOT
  measured. Update this test to match the guard's new shape."
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
new, n = re.subn(r'\n[ \t]*case "\$db" in\n[ \t]*\*\[!A-Za-z0-9_\]\*\)(?:.*?\n)*?[ \t]*esac\n',
                 "\n", src)
if n != 1:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PY
grep -q '^record_restored_db()' "$PRE394" \
  || refuse "stripping the guard also removed record_restored_db() from the control,
  so the control measures nothing. Update this test."

write_one "$PRE394" "$EVIL"
if [ "$W_RC" -eq 0 ] && [ "$W_KINDS" = "cluster aistack;cluster evil;" ]; then
  ok "teeth: with the guard removed the SAME name writes TWO entries: $W_KINDS"
else
  bad "the pre-NOM-394 control did not reproduce the misreport: exit=$W_RC kinds='$W_KINDS'"
  note "$W_OUT"
fi
# AND READ BACK THE WAY drill.sh READS IT, which is the whole reason the writer
# is the only place this can be fixed: the reader is handed two bare
# identifiers and has nothing left to refuse.
RECOVERED="$(printf '%s' "$W_KINDS" | tr ';' '\n' | sed -n 's/^cluster //p' | tr '\n' ',')"
if [ "$RECOVERED" = "aistack,evil," ]; then
  ok "...which drill.sh's own reader recovers as 'aistack' and 'evil' -- both bare, neither the database in the archive"
else
  bad "reading the control's channel back gave '$RECOVERED', expected 'aistack,evil,'"
fi

# restored_db_kind() and is_app_db() DISAGREE ON PURPOSE for a legacy archive,
# and that disagreement is the whole mechanism: is_app_db() must say "app"
# (the OWNER clause depends on it) while restored_db_kind() must say "we were
# never told".  Asserted together so a later edit that "tidies" one into the
# other has to come here first.
LK="$(RESTORE_DB_RECORDED=0 RESTORE_APP_DBS="" bash -c \
      'set -euo pipefail; . "$1"; restored_db_kind app_a; is_app_db app_a && echo app || echo cluster' \
      _ "$RBLOCK")"
if [ "$LK" = "legacy
app" ]; then
  ok "on a legacy archive restored_db_kind says 'legacy' while is_app_db still says 'app'"
else
  bad "legacy disagreement is gone: got '$(printf '%s' "$LK" | tr '\n' '/')', expected 'legacy/app'"
fi

# --- 12b. WHOSE DATABASE IT IS, which decides the CREATE DATABASE owner -----
#
# The same predicate now has a second caller, and the second one can lose data.
# `CREATE DATABASE %I OWNER %I` with the database name for both holds only
# where role and database share a name -- true of the four app databases,
# FALSE of the kind NOM-378 widened the set to include.  On a restore into a
# FRESH cluster, `CREATE DATABASE metrics OWNER metrics` fails with "role does
# not exist", the failure is swallowed, and pg_restore then reports
# "warnings" -- so a database that IS in the archive does not come back and
# nothing refuses.  That is this ticket's shape in the disaster-recovery path.
printf '\n  -- the owner clause, and the refusal when the database is not there --\n'

# $1 = RESTORE_DB_RECORDED, $2 = app dbs, $3 = db.  Sets APPKIND.
appkind() {
  APPKIND="$(
    RESTORE_DB_RECORDED="$1" RESTORE_APP_DBS="$2" DB="$3" bash -c '
      set -euo pipefail
      . "$1"
      if is_app_db "$DB"; then echo app; else echo cluster; fi
    ' _ "$RBLOCK"
  )"
}

# Same arguments.  Sets SQL_OUT to the shipped CREATE DATABASE statement.
createsql() {
  SQL_OUT="$(
    RESTORE_DB_RECORDED="$1" RESTORE_APP_DBS="$2" DB="$3" bash -c '
      set -euo pipefail
      . "$1"
      create_database_sql "$DB"
    ' _ "$RBLOCK"
  )"
}

# SYNTHETIC app names, same as the dump-set fixture above and for the same two
# reasons: CI invariant I15 fails any second literal copy of the app list, and
# nothing here depends on which apps exist today -- only on whether a database
# has a role of its own.  `aistack` and `metrics` are named exactly, because
# those are the two cases the review is about.
APPS='app_a app_b'

appkind 1 "$APPS" app_a
[ "$APPKIND" = app ] && ok "is_app_db: an app database is 'app'" \
  || bad "is_app_db says app_a is '$APPKIND', expected app"
appkind 1 "$APPS" aistack
[ "$APPKIND" = cluster ] && ok "is_app_db: aistack is 'cluster' (owned by aistack_admin)" \
  || bad "is_app_db says aistack is '$APPKIND', expected cluster"
appkind 0 "" aistack
[ "$APPKIND" = app ] \
  && ok "is_app_db: a legacy archive calls every dump an app, the old behaviour" \
  || bad "legacy is_app_db says '$APPKIND', expected app"

createsql 1 "$APPS" app_a
case "$SQL_OUT" in
  *"CREATE DATABASE %I OWNER %I"*":'db', :'db'"*)
    ok "an app database is created OWNER <its own role>" ;;
  *) bad "app CREATE DATABASE is not the OWNER form:"; note "$SQL_OUT" ;;
esac

# THE DEFECT.  A cluster-kind database must NOT name an owner: omitting the
# clause makes the owner the connecting superuser, which is what the live
# cluster has, and is the only form that works where no same-named role exists.
createsql 1 "$APPS" aistack
case "$SQL_OUT" in
  *OWNER*)
    bad "a cluster-kind database is still created OWNER <db>; on a FRESH cluster"
    note "that fails with 'role \"aistack\" does not exist' and the dump is lost"
    note "$SQL_OUT" ;;
  *"CREATE DATABASE %I"*)
    ok "a cluster-kind database is created with NO owner clause (the superuser owns it)" ;;
  *) bad "cluster CREATE DATABASE is not recognisable:"; note "$SQL_OUT" ;;
esac
# Reached through a hand-made database, which is the case the widening was
# written for and the one that is NOT masked by POSTGRES_DB on the live stack.
createsql 1 "$APPS" metrics
case "$SQL_OUT" in
  *OWNER*) bad "an operator-created 'metrics' would still be CREATE ... OWNER metrics" ;;
  *) ok "and so is an operator-created database with no role of its own" ;;
esac
# A legacy archive keeps the old form exactly: every dump in one is an app.
createsql 0 "" app_a
case "$SQL_OUT" in
  *OWNER*) ok "a legacy archive still uses the OWNER form, unchanged" ;;
  *) bad "legacy CREATE DATABASE lost its OWNER clause:"; note "$SQL_OUT" ;;
esac
# The guard and the quoting are not optional in EITHER form: without
# WHERE NOT EXISTS the create fails on a live stack where the database already
# exists, and without \gexec the format() string is selected and never run.
MISSING=""
for db in app_a aistack; do
  createsql 1 "$APPS" "$db"
  for want in "WHERE NOT EXISTS" '\gexec'; do
    printf '%s' "$SQL_OUT" | grep -qF -- "$want" || MISSING="$MISSING $db:'$want'"
  done
done
[ -z "$MISSING" ] \
  && ok "both forms keep WHERE NOT EXISTS and \\gexec, so the name is quoted by format()" \
  || bad "the generated SQL is missing:$MISSING"

# $1 = db_exists outcome (0 = present, 1 = absent), $2 = db.  Sets P_RC/P_OUT.
# db_exists is overridden AFTER sourcing, so the real one -- which needs docker
# and a running postgres -- is never called.
present() {
  P_OUT="$(
    EXISTS="$1" DB="$2" bash -c '
      set -euo pipefail
      die() { printf "DIE: %s\n" "$*"; exit 9; }
      . "$1"
      db_exists() { return "$EXISTS"; }
      require_database_present "$DB"
      echo RETURNED-0
    ' _ "$RBLOCK" 2>&1
  )"
  P_RC=$?
}

present 1 metrics
if [ "$P_RC" -ne 0 ] && printf '%s' "$P_OUT" | grep -q 'metrics'; then
  ok "a database that is NOT there after the create attempt REFUSES, and names it"
else
  bad "absent database: exit=$P_RC did not refuse naming metrics"; note "$P_OUT"
fi
present 0 metrics
if [ "$P_RC" -eq 0 ] && printf '%s' "$P_OUT" | grep -q 'RETURNED-0'; then
  ok "and a database that IS there passes quietly, so a normal restore is unaffected"
else
  bad "present database: exit=$P_RC"; note "$P_OUT"
fi

# AND BOTH ARE REACHED FROM THE LOOP, in this order.  The two functions above
# can be perfectly correct and never called: that is the same silence with more
# code in it.  The create must come from create_database_sql (not a literal
# statement left behind beside it), the check must sit between the create and
# the load, and pg_restore must be the last of the three -- refusing AFTER
# loading a dump into a database that is not there is not a refusal.
if python3 - "$ROOT/scripts/restore.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
loop = src.find('for dump in "$WORK"/payload/*.dump')
if loop == -1:
    sys.exit(2)                      # the restore loop moved; nothing measured
body = src[loop:]
# Anchored on the COMMANDS, not on the words: the loop's own comments mention
# pg_restore several lines above the call, and matching prose would compare the
# wrong positions and fail a correct loop.
WANT = ('create_database_sql "$db"',
        'require_database_present "$db"',
        'dc exec -T postgres pg_restore')
at = [body.find(s) for s in WANT]
if -1 in at:
    print("        missing from the restore loop: %s" % ", ".join(
        w for w, i in zip(WANT, at) if i == -1))
    sys.exit(1)
if not at[0] < at[1] < at[2]:
    print("        the restore loop calls them out of order: %r"
          % (dict(zip(WANT, at)),))
    sys.exit(1)
sys.exit(0)
PY
then
  ok "the restore loop creates, then REFUSES if absent, then loads -- in that order"
else
  rc=$?
  [ "$rc" = 2 ] && refuse "the per-dump restore loop was not found in
  scripts/restore.sh, so nothing was measured about where the refusal sits."
  bad "the restore loop does not reach the refusal between create and load"
fi

# --- 13. the read-only path the docs promise actually exists ---------------
# docs/backup-restore.md tells an operator to run `aistack verify <archive>`.
# It said so BEFORE the subcommand existed -- a documented capability with no
# code behind it, which is the same shape as a manifest that is internally
# consistent and silent.  Asserted so the doc and the CLI cannot diverge again.
printf '\n  -- the read-only path --\n'
grep -q -- '--verify-only' "$ROOT/scripts/restore.sh" \
  && ok "scripts/restore.sh accepts --verify-only" \
  || bad "scripts/restore.sh has no --verify-only flag, but the docs promise one"
grep -qE '^ *verify\) *shift; *cmd_verify' "$ROOT/bin/aistack" \
  && ok "bin/aistack dispatches 'verify'" \
  || bad "bin/aistack does not dispatch 'verify', but docs/backup-restore.md tells operators to run it"
# READ-ONLY MUST NOT DEPEND ON HOW ARGV LANDS.
#
# cmd_verify was `restore.sh "$@" --verify-only`, with the flag AFTER the
# caller's arguments.  `aistack verify a.enc --into-drill-project` therefore
# let --into-drill-project consume `--verify-only` as its project name,
# VERIFY_ONLY stayed 0, and execution continued past the read-only exit.  The
# request now travels out of band, where another option's argument cannot eat
# it -- so this asserts BOTH that it is set and that no flag is appended.
if python3 - "$ROOT/bin/aistack" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'^cmd_verify\(\)\s*\{(.*?)^\}', src, re.S | re.M) \
    or re.search(r'^cmd_verify\(\)\s*\{([^\n]*)\}', src, re.M)
if not m:
    sys.exit(2)          # nothing measured
body = m.group(1)
problems = []
if "AISTACK_VERIFY_ONLY=1" not in body:
    problems.append("does not set AISTACK_VERIFY_ONLY=1")
if "restore.sh" not in body:
    problems.append("does not delegate to restore.sh")
if "--verify-only" in body:
    problems.append("still appends --verify-only, which another option's "
                    "argument can consume")
if problems:
    print("        cmd_verify() " + "; ".join(problems))
sys.exit(1 if problems else 0)
PY
then
  ok "and does it by running restore.sh with AISTACK_VERIFY_ONLY=1, out of band"
else
  rc=$?
  [ "$rc" = 2 ] && refuse "cmd_verify() was not found in bin/aistack, so nothing
  was measured about how 'aistack verify' requests read-only."
  bad "aistack verify's read-only request is argv-dependent (see above)"
fi

# ...AND THE CHANNEL ACTUALLY REACHES THE CHILD PROCESS.
#
# The check above reads the TEXT of cmd_verify, and text is not a channel.
# Drop the `export` and `AISTACK_VERIFY_ONLY=1` is still in the body, still
# satisfies every assertion above -- while restore.sh, a separate process,
# never sees it, VERIFY_ONLY_FLAG stays 0 and `aistack verify` RESTORES.
# Measured: the same stub child below reports UNSET under that one-word edit.
# So drive the SHIPPED function and ask the child what it got.
VSTUB="$WORK/vstub"
mkdir -p "$VSTUB/scripts"
cat > "$VSTUB/scripts/restore.sh" <<'STUB'
#!/usr/bin/env bash
printf 'SAW=%s ARGV=%s\n' "${AISTACK_VERIFY_ONLY:-UNSET}" "$*"
STUB
chmod +x "$VSTUB/scripts/restore.sh"
if python3 - "$ROOT/bin/aistack" "$WORK/cmd_verify.sh" <<'PY'
import re, sys
m = re.search(r'^cmd_verify\(\)\s*\{(.*?)^\}', open(sys.argv[1]).read(), re.S | re.M) \
    or re.search(r'^cmd_verify\(\)\s*\{[^\n]*\}', open(sys.argv[1]).read(), re.M)
if not m:
    sys.exit(2)                       # nothing measured
open(sys.argv[2], "w").write(m.group(0) + "\n")
PY
then
  # The lifecycle lock is not what is measured here, and taking it would need a
  # live stack; stubbing it drops the mode argument and runs the command.
  SAW="$(env -u AISTACK_VERIFY_ONLY ROOT="$VSTUB" bash -c '
      set -euo pipefail
      with_lifecycle_lock() { shift; "$@"; }
      . "$1"
      cmd_verify fixture.enc
    ' _ "$WORK/cmd_verify.sh" 2>&1)"
  case "$SAW" in
    *"SAW=1 ARGV=fixture.enc"*)
      ok "and the child process receives it, with the archive still in argv" ;;
    *SAW=1*)
      bad "read-only reached the child but the archive did not:"; note "$SAW" ;;
    *)
      bad "the shipped cmd_verify did not deliver read-only to its child, so"
      note "'aistack verify' would reach the write phase. Child reported:"
      note "$SAW" ;;
  esac
else
  refuse "cmd_verify() was not found in bin/aistack, so NOTHING WAS MEASURED
  about whether its read-only request reaches restore.sh at all."
fi

# ...and restore.sh honours that channel.  Driven through the SHIPPED
# resolution, same as the dump set, so a refactor cannot leave this asserting
# a copy.
VBLOCK="$WORK/verifyonly.sh"
awk '/^# >>> verify-only resolution/{f=1; next} /^# <<< verify-only resolution/{f=0} f' \
  "$ROOT/scripts/restore.sh" > "$VBLOCK"
if [ ! -s "$VBLOCK" ]; then
  refuse "the 'verify-only resolution' markers are not in scripts/restore.sh, or
  the block between them is empty, so NOTHING WAS MEASURED about whether
  read-only can be requested out of band. Restore the markers, or update this
  test."
fi
grep -q '^verify_only_requested()' "$VBLOCK" \
  || refuse "the extracted block does not define verify_only_requested(); the
  markers are around the wrong lines and nothing was measured."

# $1 = how to set AISTACK_VERIFY_ONLY (unset|0|1), $2 = the flag's value.
vo() {
  local env=(env)
  case "$1" in
    unset) env=(env -u AISTACK_VERIFY_ONLY) ;;
    *) env=(env "AISTACK_VERIFY_ONLY=$1") ;;
  esac
  VO="$("${env[@]}" FLAG="$2" bash -c '
      set -euo pipefail
      . "$1"
      if verify_only_requested "$FLAG"; then echo READONLY; else echo WRITES; fi
    ' _ "$VBLOCK" 2>&1)"
}

vo unset 0
[ "$VO" = WRITES ] \
  && ok "no flag and no env: a real restore still writes" \
  || bad "an unrequested restore resolved to '$VO', expected WRITES"
vo unset 1
[ "$VO" = READONLY ] \
  && ok "--verify-only alone still works for anyone driving restore.sh directly" \
  || bad "--verify-only resolved to '$VO', expected READONLY"
vo 1 0
[ "$VO" = READONLY ] \
  && ok "AISTACK_VERIFY_ONLY=1 with NO flag is read-only, which is how aistack verify asks" \
  || bad "AISTACK_VERIFY_ONLY=1 resolved to '$VO', expected READONLY"
vo 0 0
[ "$VO" = WRITES ] \
  && ok "and AISTACK_VERIFY_ONLY=0 is not a read-only request" \
  || bad "AISTACK_VERIFY_ONLY=0 resolved to '$VO', expected WRITES"

# The exit must sit ABOVE the first thing that writes, so "read-only" is a
# property of where the code stops rather than a promise in a comment.
if python3 - "$ROOT/scripts/restore.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
exit_at = src.find('if verify_only_requested "$VERIFY_ONLY_FLAG"')
write_at = src.find('echo "4/4  restoring"')
sys.exit(0 if exit_at != -1 and write_at != -1 and exit_at < write_at else 1)
PY
then
  ok "the verify-only exit sits above the restore phase, so it cannot write"
else
  bad "the verify-only exit is missing or BELOW the restore phase"
fi

printf '\n== %d passed, %d failed ==\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
