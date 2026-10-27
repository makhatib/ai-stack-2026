#!/bin/sh
# Runs INSIDE the fixture's n8n container before it starts: import the three
# credentials W4 is bound to (ids from the shipped workflow), import the SHIPPED
# W4 workflow unchanged, publish it, then start n8n.  Secrets arrive as env vars
# and are written 0600 to the container's own tmpfs, never to a mounted path.
set -eu
umask 077
node -e '
const e = process.env;
console.log(JSON.stringify([
 {id:"aistackDemoPg001", name:"Demo Postgres (aistack samples)", type:"postgres",
  data:{host:"nom-417-db", database:"proof", user:"proof", password:e.PROOF_DB_PW, port:5432, ssl:"disable"}},
 {id:"aistackDemoLlm01", name:"Demo LiteLLM virtual key (aistack samples)", type:"httpHeaderAuth",
  data:{name:"Authorization", value:"Bearer stub"}},
 {id:"aistackDemoHdr01", name:"Demo webhook token (aistack samples)", type:"httpHeaderAuth",
  data:{name:"X-Aistack-Token", value:e.PROOF_W4_TOKEN}}]));' > /tmp/creds.json
n8n import:credentials --input=/tmp/creds.json >/dev/null
rm -f /tmp/creds.json
# W4 posts to http://litellm:4000 ; the stub answers to that name on the fixture network.
n8n import:workflow --input=/shipped/W4-webhook-to-model.json >/dev/null
n8n publish:workflow --id=aistackDemoW4001 >/dev/null
exec n8n start
