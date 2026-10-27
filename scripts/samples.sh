#!/usr/bin/env bash
# AI Stack 2026 — the synthetic demo harness (NOM-302).
#
# `samples load` imported four workflow templates and reported success.  QA
# then found that not one of them could run: no model weights, no credentials
# bound, no tables for the SQL to write, no question for W1 to ask, and no
# human decision anywhere in W3's approval path.  An import that succeeds is
# not a demo that works, so this script is the difference between the two.
#
# Four templates are imported; THREE are executable (W1, W3, W4).  W2 is
# deferred by decision — NOM-321 rejected giving Docling a second peer to make
# a demo pass, and NOM-323 fixed the profile at three n8n demos.  setup still
# imports and binds all four, because the deferred one is a template somebody
# may want the day that route is bought by a product requirement.
#
#   setup      preload the named weights, build the demo database, mint the
#              demo credentials, import the workflows (idempotently)
#   run        execute W1/W3/W4 and CHECK THE OUTPUT, negative cases included;
#              report W2 as DEFERRED with the measurement behind it
#   approve    the human decision step in W3, as a separate privilege path
#   teardown   drop everything setup created, except the drill ballast pair
#
# THREE RULES THIS SCRIPT DOES NOT BEND.
#
# 1. Synthetic only.  No real credential, no real document, no outbound
#    message.  Every value either comes from this repo or is generated here.
# 2. Workflows stay INACTIVE.  Nothing here publishes a trigger that fires on
#    its own.  W4 needs a live webhook for the length of its own test; `run`
#    activates it, tests it, and deactivates it again, and then ASSERTS it is
#    inactive — an assertion precisely because "I meant to turn it off" is not
#    a control.
# 3. The PATH, never the VALUE (scripts/gen-secrets.sh's absolute rule).  The
#    generated demo secrets are written 0600 under secrets/ and this script
#    prints where they are.  Nothing here echoes one, and secrets reach
#    containers on stdin rather than argv, where `ps` would show them.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SECRETS="$ROOT/secrets"

# The scratch directory has to live under samples/ because that is the only
# path bind-mounted into n8n (/opt/aistack/samples, read-only), and `n8n
# import:*` reads files from inside the container.  n8n's rootfs is read-only,
# so `docker cp` into it is refused — MEASURED, NOM-302.
RUNDIR="$ROOT/samples/.run"

DEMO_DB="aistack_demo"
DEMO_ROLE="aistack_demo"

# Stable ids, and they are the whole idempotency story.  MEASURED (NOM-302):
# `samples load` imported with no ids, so n8n minted fresh ones every time and
# two runs left EIGHT workflows and FOUR credentials behind.  A demo you cannot
# re-import is a demo nobody re-runs.
CRED_PG="aistackDemoPg001"
CRED_LLM="aistackDemoLlm01"
CRED_W4="aistackDemoHdr01"

W1_ID="aistackDemoW1001"
W2_ID="aistackDemoW2001"
W3_ID="aistackDemoW3001"
W4_ID="aistackDemoW4001"

# The subject the demo envelope names as its approver.  In the deployed stack
# this is Authelia's `Remote-User`, set by the PROXY and never by the workflow.
# Here it is the operator, and `approve` refuses to act for anyone else.
DEMO_APPROVER="local:$(id -un)"

die()  { printf 'samples: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

dc() { ( cd "$ROOT" && docker compose "$@" ); }

CRED_TMP=""
cleanup_rundir() {
  rm -rf "$RUNDIR"
  [ -z "$CRED_TMP" ] || dc exec -T n8n rm -f "$CRED_TMP" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------

need_running() {
  local svc missing=""
  for svc in aistack-postgres aistack-n8n aistack-litellm aistack-ollama; do
    docker ps --format '{{.Names}}' | grep -qx "$svc" || missing="$missing $svc"
  done
  [ -z "$missing" ] || die "these containers are not running:$missing
Run 'aistack up' first.  The demo talks to the live stack; it does not start it."
}

# psql as the SUPERUSER, over the container's local socket.  No password on the
# command line and none in the environment: inside the container the socket
# accepts the local peer, which is why this needs no secret at all.
psql_admin() { docker exec -i aistack-postgres psql -v ON_ERROR_STOP=1 -U aistack_admin -d "$1" "${@:2}"; }
psql_demo()  { docker exec -i aistack-postgres psql -v ON_ERROR_STOP=1 -U "$DEMO_ROLE" -d "$DEMO_DB" "$@"; }

# ---------------------------------------------------------------------------
# secrets
# ---------------------------------------------------------------------------

write_secret() {
  # $1 = basename, $2 = value on stdin.  Reuse over regenerate, for the reason
  # gen-secrets.sh gives: a re-run that rotates a value locks the thing that
  # already holds it out.
  local name="$1" path="$SECRETS/$1"
  if [ -s "$path" ]; then
    info "  reusing existing $path"
    return 0
  fi
  mkdir -p "$SECRETS"; chmod 0700 "$SECRETS" 2>/dev/null || true
  ( umask 077; cat > "$path" )
  chmod 0600 "$path"
  info "  wrote $path (0600)"
}

read_secret() {
  local path="$SECRETS/$1"
  [ -s "$path" ] || die "missing $path — run 'aistack samples setup' first"
  cat "$path"
}

litellm_master_key() {
  # PARSED, never sourced (S06): a master key containing a backtick must not
  # become a command.
  local f="$SECRETS/litellm.env" line
  [ -r "$f" ] || die "cannot read $f.
It is 0640 root:<operator>; run this as the operator who owns the install."
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      LITELLM_MASTER_KEY=*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$f"
  die "no LITELLM_MASTER_KEY in $f"
}

# Run a shell snippet INSIDE a container with secrets on stdin.  argv is
# visible in `ps` to anything that can read /proc on the host; stdin is not.
in_container() { docker exec -i "$1" sh -s; }

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------

cmd_setup() {
  need_running
  trap cleanup_rundir EXIT
  mkdir -p "$RUNDIR"; chmod 0700 "$RUNDIR"

  setup_models
  setup_database
  setup_credentials
  setup_workflows
  setup_corpus

  step "Ready"
  info "Demo database : $DEMO_DB (role $DEMO_ROLE, dropped by 'samples teardown')"
  info "Credentials   : $CRED_PG, $CRED_LLM, $CRED_W4 — bound by id in the workflow JSON"
  info "Workflows     : $W1_ID $W2_ID $W3_ID $W4_ID, all INACTIVE"
  info "Secrets       : $SECRETS/samples_demo_{db_password,litellm_key,w4_token} (0600)"
  info ""
  info "Now run:  aistack samples run all"
}

# alias_models <alias>...: the Ollama model behind each LiteLLM alias, in order.
# awk, not PyYAML: a fresh Ubuntu server is not guaranteed to have PyYAML.
alias_models() {
  local a m out=""
  for a in "$@"; do
    m="$(awk -v a="$a" '
      $1 == "-" && $2 == "model_name:" { cur = ($3 == a) }
      cur && $1 == "model:" { sub(/^[^\/]*\//, "", $2); print $2; exit }
    ' "$ROOT/config/litellm/config.yaml")"
    [ -n "$m" ] || return 1
    out="$out${out:+ }$m"
  done
  printf '%s\n' "$out"
}

# has_model <ollama-list-output> <name>: an EXACT name match (qwen3.5:2b is not
# qwen3.5:9b), with Ollama's implicit :latest.
has_model() {
  local want="$2"; [[ "$want" == *:* ]] || want="$want:latest"
  printf '%s\n' "$1" | awk -v w="$want" '$1 == w { found = 1 } END { exit !found }'
}

setup_models() {
  step "Model weights"
  # NAMED, and checked by name.  QA found an empty `ollama list` after a
  # successful install because `models pull` was passing `sh -c` to an image
  # whose ENTRYPOINT is `ollama` — see bin/aistack.  Nothing here assumes the
  # pull worked; it re-reads the list afterwards.
  # WHAT THE TEMPLATES CALL, not a list kept by hand: W1/W3/W4 ask LiteLLM for
  # `local-chat` and `local-embed`, and config/litellm/config.yaml says which
  # Ollama model each one is.  v2 moved `local-chat` to qwen3.5:2b while this
  # line still pulled the v1 llama3.2:3b, which no template used (NOM-416).
  local want m have
  want="$(alias_models local-embed local-chat)" || die "cannot read the local-embed / local-chat models from config/litellm/config.yaml"
  have="$(docker exec aistack-ollama ollama list 2>/dev/null || true)"
  for m in $want; do
    if has_model "$have" "$m"; then
      info "  present: $m"
      continue
    fi
    info "  pulling: $m  (through the egress helper, not through Ollama)"
    "$ROOT/bin/aistack" models pull "$m" >/dev/null 2>&1 \
      || die "could not pull '$m'.  Run 'aistack models pull $m' to see why."
  done
  have="$(docker exec aistack-ollama ollama list 2>/dev/null || true)"
  for m in $want; do
    has_model "$have" "$m" \
      || die "'$m' is still not in 'ollama list' after a pull that reported success.
That combination is the NOM-302 defect returning; do not treat the demo as runnable."
  done
  info "  both weights present"
}

setup_database() {
  step "Demo database"
  local pw
  if [ -s "$SECRETS/samples_demo_db_password" ]; then
    pw="$(read_secret samples_demo_db_password)"
  else
    pw="$(openssl rand -hex 24)"
    printf '%s' "$pw" | write_secret samples_demo_db_password
  fi

  # Role and database, as the superuser, with the password bound through a psql
  # variable rather than spliced into the SQL text — same pattern as
  # config/postgres/init/01-roles-and-databases.sh.
  printf '%s' "$pw" > "$RUNDIR/pw"; chmod 0600 "$RUNDIR/pw"
  psql_admin postgres -v "pw=$(cat "$RUNDIR/pw")" <<'SQL' >/dev/null
SELECT format('CREATE ROLE aistack_demo LOGIN PASSWORD %L', :'pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aistack_demo')
\gexec
SELECT format('ALTER ROLE aistack_demo PASSWORD %L', :'pw') \gexec
SELECT 'CREATE DATABASE aistack_demo OWNER aistack_demo'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'aistack_demo')
\gexec
SQL
  rm -f "$RUNDIR/pw"

  psql_admin postgres <<'SQL' >/dev/null
REVOKE ALL ON DATABASE aistack_demo FROM PUBLIC;
GRANT CONNECT ON DATABASE aistack_demo TO aistack_demo;
SQL
  info "  role + database ready, PUBLIC revoked"

  # pgvector is NOT a trusted extension in this build (MEASURED, NOM-302:
  # pg_available_extension_versions.trusted = false for 0.8.7), so the database
  # owner cannot create it and the superuser must.  Same reason
  # 01-roles-and-databases.sh creates it for openwebui rather than leaving it
  # to the app.
  psql_admin "$DEMO_DB" -c 'CREATE EXTENSION IF NOT EXISTS vector' >/dev/null
  psql_admin "$DEMO_DB" -c "GRANT ALL ON SCHEMA public TO $DEMO_ROLE" >/dev/null
  info "  pgvector $(psql_admin "$DEMO_DB" -tAc "select extversion from pg_extension where extname='vector'") installed"

  # THE SHIPPED ENVELOPE DDL, not a copy of it.  W3 is supposed to exercise
  # P2's approval envelope; applying this file is what makes the thing under
  # test the real transition-edge table, the real append-only transition log
  # and the real immutability trigger.  The file is idempotent by construction.
  psql_demo < "$ROOT/config/postgres/init/02-approval-envelope.sql" >/dev/null
  info "  approval envelope applied from config/postgres/init/02-approval-envelope.sql"

  psql_demo < "$ROOT/samples/fixtures/schema.sql" >/dev/null
  info "  demo tables applied from samples/fixtures/schema.sql"

  # THE THREE VALUES W3 IS NOT ALLOWED TO CHOOSE FOR ITSELF.  A workflow that
  # can name its own approver can approve itself, so the intended approver, the
  # recipient and the config revision are written HERE, by the operator's
  # command, and W3 reads them.  In the deployed stack they come from the
  # agentgateway config revision and the decision carries Authelia's
  # Remote-User, which the proxy sets.
  #
  # The recipient is a string that is not an address.  `samples run W3` asserts
  # a row in w3_delivered and nothing in this release can send anything, but a
  # demo fixture that looked like a real mailbox would be one copy-paste away
  # from being one.
  psql_demo -v "subject=$DEMO_APPROVER" <<'SQL' >/dev/null
INSERT INTO w3_config (key, value) VALUES
    ('approver_subject', :'subject'),
    ('recipient',        'demo:nobody (nothing is sent in this release)'),
    ('config_revision',  'samples-demo-1')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SQL
  info "  w3_config written: approver is $DEMO_APPROVER"
}

setup_credentials() {
  step "Demo credentials"

  # A LiteLLM VIRTUAL key, scoped to the two demo models with its own budget —
  # not the master key.  The master key has no spend ceiling and revoking it
  # would take the whole stack's inference down; this one can be deleted on its
  # own, which is the entire argument for virtual keys in config/litellm.
  local vkey
  if [ -s "$SECRETS/samples_demo_litellm_key" ]; then
    vkey="$(read_secret samples_demo_litellm_key)"
    info "  reusing existing $SECRETS/samples_demo_litellm_key"
  else
    vkey="$(
      { printf 'MK=%s\n' "$(litellm_master_key)"
        cat <<'SH'
wget -q -O- --header="Content-Type: application/json" \
  --header="Authorization: Bearer $MK" \
  --post-data='{"key_alias":"aistack-samples-demo","models":["local-chat","local-embed"],"max_budget":5.0}' \
  http://litellm:4000/key/generate
SH
      } | in_container aistack-n8n \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])'
    )" || die "could not mint a LiteLLM virtual key"
    printf '%s' "$vkey" | write_secret samples_demo_litellm_key
  fi

  local w4tok
  if [ -s "$SECRETS/samples_demo_w4_token" ]; then
    w4tok="$(read_secret samples_demo_w4_token)"
    info "  reusing existing $SECRETS/samples_demo_w4_token"
  else
    # GENERATED, not committed.  samples/credentials.synthetic.json ships an
    # obviously-fake token because it is only ever decryption ballast for the
    # backup drill.  W4's webhook token is a real control on a path Caddy
    # proxies WITHOUT forward-auth (config/caddy/sites.d/30-n8n.caddy), so a
    # fixed value in git would be a shared secret published with the source.
    w4tok="$(openssl rand -hex 24)"
    printf '%s' "$w4tok" | write_secret samples_demo_w4_token
  fi

  local dbpw; dbpw="$(read_secret samples_demo_db_password)"

  # Streamed over stdin into the n8n container's own tmpfs, imported there and
  # removed there.  NEVER a host file: a root-run install wrote it root:root
  # 0600 under the bind mount and the container's `node` (uid 1000) got
  # EACCES (NOM-400), and a host chown to 1000 would hand the secret to
  # whichever host account owns that uid.  umask 077 keeps it 0600 owned by
  # node; the EXIT trap removes it even when the import fails.
  local ctmp=/home/node/.cache/aistack-credentials.json
  CRED_TMP="$ctmp"
  emit_credentials() {
    python3 - "$CRED_PG" "$DEMO_DB" "$DEMO_ROLE" "$dbpw" "$CRED_LLM" "$vkey" "$CRED_W4" "$w4tok" <<'PY'
import json, sys
pg_id, db, user, pw, llm_id, vkey, w4_id, w4tok = sys.argv[1:9]
print(json.dumps([
    {"id": pg_id, "name": "Demo Postgres (aistack samples)", "type": "postgres",
     "data": {"host": "postgres", "database": db, "user": user, "password": pw,
              "port": 5432, "ssl": "disable"}},
    {"id": llm_id, "name": "Demo LiteLLM virtual key (aistack samples)",
     "type": "httpHeaderAuth",
     "data": {"name": "Authorization", "value": "Bearer " + vkey}},
    {"id": w4_id, "name": "Demo webhook token (aistack samples)",
     "type": "httpHeaderAuth",
     "data": {"name": "X-Aistack-Token", "value": w4tok}},
], indent=2))
PY
  }
  emit_credentials | dc exec -T n8n sh -c 'umask 077; cat > "$1"' _ "$ctmp" >/dev/null 2>&1 \
    || die "staging the demo credentials failed"
  dc exec -T n8n n8n import:credentials --input="$ctmp" >/dev/null 2>&1 \
    || die "importing the demo credentials failed"
  dc exec -T n8n rm -f "$ctmp" >/dev/null 2>&1 || true

  # The drill's ballast pair, bound to nothing.  Imported here too so
  # `aistack drill run` still has ciphertext to decrypt: scripts/drill.sh
  # exports it and greps for the SYNTHETIC marker, and with zero credentials
  # that assertion degrades to a printed note instead of a failure, which is
  # the one failure mode a restore drill must not have.
  #
  # It carries FIXED ids for the same reason the workflows do.  The file
  # shipped without them, so n8n minted a fresh pair on every import: ten
  # setup/load runs left twenty orphaned credentials that nothing deleted.
  dc exec -T n8n n8n import:credentials --input=/opt/aistack/samples/credentials.synthetic.json >/dev/null 2>&1 \
    || die "importing samples/credentials.synthetic.json failed"

  # Two ballast rows, not two per run -- asserted, because the leak this
  # replaces was silent.  The ids are deliberately OUTSIDE teardown's
  # 'aistackDemo%' pattern: this pair is `samples load` state that the drill
  # depends on, so teardown leaves it, and it is the one thing setup creates
  # that teardown does not remove.  See docs/samples.md section 4.
  local nb
  nb="$(psql_admin n8n -tAc "select count(*) from credentials_entity where name in ('Synthetic Postgres (aistack demo)','Synthetic webhook token (aistack demo)')")"
  [ "$nb" = "2" ] || die "expected exactly 2 drill ballast credentials, found $nb -- an id-less import left orphans; delete the rows whose id is neither aistackDrillSyn1 nor aistackDrillSyn2"

  # Assert, rather than trust the exit code: a credential whose id did not
  # survive the import binds to nothing and every Postgres node fails later
  # with a message about a missing credential.
  local id
  for id in "$CRED_PG" "$CRED_LLM" "$CRED_W4"; do
    [ "$(psql_admin n8n -tAc "select count(*) from credentials_entity where id='$id'")" = "1" ] \
      || die "credential $id is not in n8n after an import that reported success"
  done
  info "  three demo credentials imported and bound by id"
}

setup_workflows() {
  step "Workflows"
  dc exec -T n8n n8n import:workflow --separate --input=/opt/aistack/workflows >/dev/null 2>&1 \
    || die "workflow import failed"
  local id n
  for id in "$W1_ID" "$W2_ID" "$W3_ID" "$W4_ID"; do
    n="$(psql_admin n8n -tAc "select count(*) from workflow_entity where id='$id' and active=false")"
    [ "$n" = "1" ] || die "workflow $id is missing or active after import (found $n inactive)"
  done
  # Idempotency, asserted rather than hoped for.  Four workflows, not eight.
  n="$(psql_admin n8n -tAc "select count(*) from workflow_entity where id like 'aistackDemoW%'")"
  [ "$n" = "4" ] || die "expected exactly 4 demo workflows, found $n — the stable-id import is not idempotent"
  info "  4 workflows imported, all inactive, re-import is a no-op"
}

setup_corpus() {
  step "Corpus"
  python3 "$ROOT/samples/fixtures/make-synthetic-pdf.py" "$ROOT/samples/fixtures/synthetic.pdf"
  python3 "$ROOT/scripts/samples_harness.py" load-corpus
}

# ---------------------------------------------------------------------------
# approve — the human decision step in W3
# ---------------------------------------------------------------------------

cmd_approve() {
  need_running
  local action="" decision="approved" assume_yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reject) decision="rejected" ;;
      --yes|-y) assume_yes=1 ;;
      -*) die "unknown flag '$1'" ;;
      *) [ -z "$action" ] || die "one action id at a time"; action="$1" ;;
    esac
    shift
  done
  # NO "approve the latest".  The approver has to name the action, because the
  # thing being approved is a specific envelope and a convenience that picks
  # one for you is how a person approves a row they never read.
  [ -n "$action" ] || die "usage: aistack samples approve <action-id> [--reject] [--yes]
Run 'aistack samples run W3' first; it prints the action id it wrote."

  # THE ACTION ID IS BOUND, NOT PASTED.  It arrives on the command line, and a
  # value spliced into SQL text is a value that can end the statement it is
  # inside.  psql variables quote it as a literal -- and they only work when
  # the SQL arrives on STDIN, because psql does not expand `:'name'` inside a
  # -c string (MEASURED, NOM-302).
  local row
  row="$(psql_demo -tAq -v "a=$action" <<'SQL'
SELECT state, approver_subject, recipient, scope::text, parameter_hash, expires_at,
       (expires_at > now()) AS live
  FROM approval_action WHERE action_id = :'a';
SQL
  )" || die "could not read the envelope.
If the id is not a UUID, that is the error Postgres is reporting."
  [ -n "$row" ] || die "no envelope with action_id '$action' in $DEMO_DB"

  local state subject recipient scope phash expires live
  IFS='|' read -r state subject recipient scope phash expires live <<<"$row"

  info ""
  info "Approval envelope $action"
  info "  state           : $state"
  info "  approver named  : $subject"
  info "  recipient       : $recipient"
  info "  scope           : $scope"
  info "  parameter hash  : $phash"
  info "  expires         : $expires  (still valid: $live)"
  info ""

  # AUTHORISATION, not just authentication.  The envelope names its approver at
  # creation and this refuses to act for anybody else.  In the deployed stack
  # the left-hand side of this comparison is Authelia's Remote-User header,
  # which the proxy sets and neither the workflow nor the model can supply.
  [ "$subject" = "$DEMO_APPROVER" ] \
    || die "this envelope names '$subject' as its approver and you are '$DEMO_APPROVER'.
A decision by the wrong subject is not a decision."
  [ "$state" = "pending" ] \
    || die "the envelope is '$state', not 'pending'.
Only a pending envelope can be decided, and that is enforced by the transition
table in config/postgres/init/02-approval-envelope.sql, not by this check."
  [ "$live" = "t" ] \
    || die "the envelope expired at $expires.  A stale approval is not an approval."

  if [ "$assume_yes" != "1" ]; then
    printf 'Record %s for this envelope? [y/N] ' "$decision"
    local reply; read -r reply
    case "$reply" in y|Y|yes|YES) ;; *) die "no decision recorded" ;; esac
  fi

  # One row or nothing, and the WHERE clause re-checks everything the display
  # above showed: between a human reading the envelope and deciding on it, the
  # envelope can have expired or been decided by somebody else.
  #
  # The result is captured and THEN inspected rather than piped into grep: in a
  # pipeline the exit status is grep's, so a psql that failed outright would be
  # reported as "the envelope changed under you" — a wrong diagnosis for a
  # connection error, and the kind that sends somebody looking in the database
  # for a race that never happened.
  # -q, AND a line match rather than a string equality.  MEASURED (NOM-302):
  # `psql -tA` still prints the command tag, so a successful decision returns
  #
  #     4da7d72e-5bfb-4808-8225-31954d130995
  #     UPDATE 1
  #
  # and comparing that against the action id fails.  The first version did
  # exactly that and told the operator "the envelope changed under you" about a
  # decision it had just recorded correctly — a write check that lies in the
  # safe direction is still a write check that lies.
  local decided
  decided="$(psql_demo -tAq -v "a=$action" -v "d=$decision" <<'SQL'
UPDATE approval_action SET state = :'d'
 WHERE action_id = :'a' AND state = 'pending' AND expires_at > now()
RETURNING action_id;
SQL
  )" || die "the decision could not be written; Postgres reported the error above"
  printf '%s\n' "$decided" | grep -qxF "$action" \
    || die "the transition affected no rows; the envelope changed under you.
Read it again with 'aistack samples approve $action' — it may have expired, or
somebody else may have decided it."
  info "recorded: $action -> $decision"
  info "The transition is in action_transitions, which nothing in this stack can UPDATE or DELETE."
}

# ---------------------------------------------------------------------------
# teardown
# ---------------------------------------------------------------------------

cmd_teardown() {
  need_running
  step "Removing the demo"

  # n8n objects first: a workflow bound to a credential that no longer exists
  # is a confusing artefact to leave behind.
  psql_admin n8n <<'SQL' >/dev/null
DELETE FROM shared_workflow    WHERE "workflowId" IN (SELECT id FROM workflow_entity    WHERE id LIKE 'aistackDemoW%');
DELETE FROM workflow_entity    WHERE id LIKE 'aistackDemoW%';
DELETE FROM shared_credentials WHERE "credentialsId" IN (SELECT id FROM credentials_entity WHERE id LIKE 'aistackDemo%');
DELETE FROM credentials_entity WHERE id LIKE 'aistackDemo%';
SQL
  info "  demo workflows and credentials removed from n8n"

  psql_admin postgres -c "DROP DATABASE IF EXISTS $DEMO_DB" >/dev/null
  psql_admin postgres -c "DROP ROLE IF EXISTS $DEMO_ROLE" >/dev/null
  info "  database and role $DEMO_DB dropped"

  # The LiteLLM virtual key is revoked, not merely forgotten.  A key left live
  # after teardown is a budget nobody is watching.
  if [ -s "$SECRETS/samples_demo_litellm_key" ]; then
    { printf 'MK=%s\nVK=%s\n' "$(litellm_master_key)" "$(read_secret samples_demo_litellm_key)"
      cat <<'SH'
wget -q -O- --header="Content-Type: application/json" \
  --header="Authorization: Bearer $MK" \
  --post-data="{\"keys\":[\"$VK\"]}" \
  http://litellm:4000/key/delete >/dev/null 2>&1 || true
SH
    } | in_container aistack-n8n >/dev/null 2>&1 || true
    info "  LiteLLM virtual key revoked"
  fi

  rm -f "$SECRETS"/samples_demo_db_password "$SECRETS"/samples_demo_litellm_key "$SECRETS"/samples_demo_w4_token
  rm -f "$ROOT/samples/fixtures/synthetic.pdf"
  cleanup_rundir
  info "  generated secrets and fixtures removed"
  info ""
  info "Model weights are NOT removed: they are shared with the rest of the stack."
  info "Remove them deliberately with 'docker volume rm aistack-ollama-models' while the stack is down."
}

# ---------------------------------------------------------------------------

case "${1:-}" in
  setup)    shift; cmd_setup "$@" ;;
  run)      shift; need_running; exec python3 "$ROOT/scripts/samples_harness.py" run "$@" ;;
  approve)  shift; cmd_approve "$@" ;;
  teardown) shift; cmd_teardown "$@" ;;
  *) die "usage: samples.sh {setup|run [W1|W2|W3|W4|all]|approve <action-id>|teardown}" ;;
esac
