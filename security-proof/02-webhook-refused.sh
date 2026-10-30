#!/usr/bin/env bash
# Security proof 2 of 3 (DoD 2.6): a malicious payload sent to a webhook is refused.
#
#   ./02-webhook-refused.sh --fixture                         the sandbox rig (see fixture/up.sh)
#   ./02-webhook-refused.sh --url https://n8n.<domain>/webhook/w4-demo --token-file F \
#         --counter 'docker exec aistack-postgres psql -U ... -tAc "select count(*) from w4_results"'
#
# THE TARGET is the shipped W4 workflow ("webhook to model to stored result") behind
# the shipped VPS-mode Caddy route.  Its defences, in the order a request meets them:
#   Caddy      body capped at 1 MB                      -> 413
#   n8n        header-token credential                  -> 403
#   workflow   "Validate the request": prompt must be a non-empty string <= 2000 chars
# The proof is not "the status was an error".  It is that a refused request left NO
# TRACE: no row stored and no model call paid for.  So the script reads a counter
# (rows stored + model calls) before and after every hostile request.
#
# A positive control runs first: a correct request MUST be accepted and MUST move the
# counter.  Without it, "everything was refused" could just mean the webhook is down.
#
# Exit 0 PASS, 1 FAIL, 2 NOT MEASURED.
set -uo pipefail
NAME=02-webhook-refused
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
URL=""; TOKEN_FILE=""; HEADER="X-Aistack-Token"; COUNTER=""; RESOLVE=""; INSECURE=""; CONTROL=1; FIX=0
while [ $# -gt 0 ]; do case "$1" in
  --fixture) FIX=1 ;;
  --url) URL="$2"; shift ;;
  --token-file) TOKEN_FILE="$2"; shift ;;
  --header) HEADER="$2"; shift ;;
  --counter) COUNTER="$2"; shift ;;
  --insecure) INSECURE="-k" ;;
  --no-control) CONTROL=0 ;;
  *) sed -n 2,24p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac; shift; done
if [ $FIX = 1 ]; then
  S="$HERE/fixture/.state"; [ -s "$S/w4_token" ] || { echo "fixture is not up: run security-proof/fixture/up.sh" >&2; exit 2; }
  URL="https://n8n.fixture.test:18443/webhook/w4-demo"; TOKEN_FILE="$S/w4_token"; INSECURE="-k"
  RESOLVE="--resolve n8n.fixture.test:18443:127.0.0.1"
  COUNTER='echo $(( $(docker exec nom-417-db psql -U proof -d proof -tAc "select count(*) from w4_results") + $(wc -l < '"$S"'/llm/llm-calls.log) ))'
fi
[ -n "$URL" ] && [ -s "$TOKEN_FILE" ] || { sed -n 2,24p "$0" | sed 's/^# \{0,1\}//'; exit 2; }
command -v curl >/dev/null && command -v python3 >/dev/null || { echo "needs curl and python3" >&2; exit 2; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; umask 077
printf '%s: %s\n' "$HEADER" "$(cat "$TOKEN_FILE")" > "$W/good.hdr"      # never on argv
printf '%s: %s\n' "$HEADER" "not-the-token" > "$W/bad.hdr"
python3 - "$W" <<'PY'
import json, sys
w = sys.argv[1]
open(w + "/ok.json", "w").write(json.dumps({"prompt": "hello"}))
open(w + "/huge.json", "w").write(json.dumps({"prompt": "A" * (2 * 1024 * 1024)}))      # 2 MB > Caddy's 1 MB
open(w + "/long.json", "w").write(json.dumps({"prompt": "A" * 5000}))                    # > the workflow's 2000
open(w + "/obj.json", "w").write(json.dumps({"prompt": {"$ne": ""}}))                    # operator-injection shape
open(w + "/arr.json", "w").write(json.dumps({"prompt": ["a", "b"]}))
open(w + "/trunc.json", "w").write('{"prompt": "cut off')                                # malformed JSON
open(w + "/empty.json", "w").write(json.dumps({"prompt": "   "}))
PY

count() { bash -c "$COUNTER" 2>/dev/null | tr -d ' \n'; }
post() { # $1 header file, $2 body file  -> HTTP status
  curl -s $INSECURE $RESOLVE -m 40 -o /dev/null -w '%{http_code}' -X POST -H @"$1" \
       -H 'Content-Type: application/json' --data-binary @"$2" "$URL"; }

title "Webhook under test" "$URL   (header token: $HEADER; the token itself is never printed)"
BASE="$(count)"
[[ "$BASE" =~ ^[0-9]+$ ]] || { skip "no counter: cannot tell a refused request from an accepted one"; verdict "webhook refusals"; }
info "counter before (rows stored + model calls): $BASE"

if [ $CONTROL = 1 ]; then
  title "Control: a correct request must be ACCEPTED" "so that 'refused' below means something"
  c="$(post "$W/good.hdr" "$W/ok.json")"; a="$(count)"
  if [ "$c" = 200 ] && [ "$a" -gt "$BASE" ] 2>/dev/null; then ok "valid token + valid prompt -> HTTP 200, counter $BASE -> $a (the webhook works)"; BASE="$a"
  else bad "control failed: HTTP $c, counter $BASE -> $a. The webhook is not working, so no refusal below proves anything"; fi
fi

title "Hostile payloads: each must be REFUSED and leave NO trace"
refuse() { # $1 label, $2 status, $3 expected-class description
  local label="$1" code="$2" after; after="$(count)"
  if [[ "$code" =~ ^[45][0-9][0-9]$ ]] && [ "$after" = "$BASE" ]; then ok "$label -> HTTP $code, nothing stored, no model call"
  else bad "$label -> HTTP $code, counter $BASE -> $after (it was accepted or left a trace)"; BASE="$after"; fi
}
refuse "no token                                    " "$(curl -s $INSECURE $RESOLVE -m 40 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @"$W/ok.json" "$URL")"
refuse "wrong token                                 " "$(post "$W/bad.hdr" "$W/ok.json")"
refuse "2 MB body (valid token)                     " "$(post "$W/good.hdr" "$W/huge.json")"
refuse "5000-character prompt (valid token)         " "$(post "$W/good.hdr" "$W/long.json")"
refuse "prompt is an object {\"\$ne\":\"\"} (valid token)" "$(post "$W/good.hdr" "$W/obj.json")"
refuse "prompt is an array (valid token)            " "$(post "$W/good.hdr" "$W/arr.json")"
refuse "blank prompt (valid token)                  " "$(post "$W/good.hdr" "$W/empty.json")"
refuse "malformed JSON (valid token)                " "$(post "$W/good.hdr" "$W/trunc.json")"
refuse "GET instead of POST (valid token)           " "$(curl -s $INSECURE $RESOLVE -m 40 -o /dev/null -w '%{http_code}' -H @"$W/good.hdr" "$URL")"
# The editor's test URL must not be open to the internet even though /webhook/* is.
test_url="${URL/\/webhook\//\/webhook-test\/}"
# A redirect counts as refused only when it goes to the login portal: Authelia
# answers a POST with 303, a GET with 302 (NOM-430: 303 used to print FAIL).
read -r c loc <<<"$(curl -s $INSECURE $RESOLVE -m 40 -o /dev/null -w '%{http_code} %{redirect_url}' -X POST -H @"$W/good.hdr" -H 'Content-Type: application/json' --data-binary @"$W/ok.json" "$test_url")"
to_login=0
[[ "${loc:-}" =~ ^https?://auth\. || "${loc:-}" =~ ^https?://[^/]+/authelia(/|\?|$) ]] && to_login=1
case "$c" in
  401|403|404) ok "the editor's /webhook-test/ URL is not open (HTTP $c: refused or no route)" ;;
  30[1-8]) if [ $to_login = 1 ]; then ok "the editor's /webhook-test/ URL is not open (HTTP $c: redirect to the login portal)"
           else bad "/webhook-test/ answered HTTP $c to ${loc:-nowhere}, which is not the login portal"; fi ;;
  *) bad "/webhook-test/ answered HTTP $c" ;;
esac
[ "$(count)" = "$BASE" ] && ok "after all hostile requests the counter is still $BASE: no row, no model call" || bad "counter moved to $(count) during the hostile requests"

verdict "malicious webhook payloads are refused and leave no trace" "a webhook payload was accepted, or a refusal left a trace, or the control failed"
