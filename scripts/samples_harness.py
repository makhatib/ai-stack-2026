#!/usr/bin/env python3
"""AI Stack 2026 — run the n8n demos and CHECK WHAT THEY PRODUCED (NOM-302).

`aistack samples load` used to import four workflows and report success.  QA
then found that none of them could run, and that is the distinction this file
exists to hold: an import is a file landing in a database, a demo is a run with
an output somebody checked.

FOUR TEMPLATES ARE IMPORTED; THREE ARE EXECUTABLE.  W1, W3 and W4 run and are
graded here.  W2 is DEFERRED by decision -- n8n has no route to Docling and
NOM-321 rejected adding one to make a demo pass -- so this file reports it as a
deferral with the measurement, and never as a pass.  P2 (the approval envelope)
is exercised on its own, against the shipped DDL.

HOW IT CHECKS, AND WHY NOT THE OBVIOUS WAY.  Every assertion reads the
DATABASE, not the n8n CLI's stdout.  Three reasons, in order of how much they
cost when ignored:

  * stdout shape is an n8n implementation detail.  `n8n execute --rawOutput`
    prints the last node's data, which changes when a template gains a node,
    and a harness that parses it goes red on an edit that broke nothing.
  * a run a human did in the UI leaves the same rows as a run this harness
    did, so the same assertions grade both.
  * a row survives the run.  When a case fails, the evidence is still there to
    look at afterwards -- which is not true of a captured stream nobody kept.

NO NETWORK OF ITS OWN.  Every HTTP call is made from INSIDE a container that
is already on the right bridge, because the host cannot reach LiteLLM, Postgres
or n8n directly -- `apps`, `gateway`, `data` and `inference` are all internal
and only Caddy publishes a port.  A harness that needed a host route would have
to widen the topology to test it, which is the opposite of testing it.

SYNTHETIC ONLY.  No real credential, no real document, no outbound message of
any kind.  "Delivered" in W3 means a row in w3_delivered; there is no mail, no
chat and no webhook out of this stack in this release.

EXIT CODES, because a harness that only prints is a harness people skim:
  0  nothing failed.  Every executable case passed; a DEFERRED case may be
     reported and counted (today that is W2 -- a decision, not a defect, so it
     does not colour the exit code.  See w2() below.)
  1  at least one case FAILED
  2  no failures, but at least one case is BLOCKED -- an OPEN question, where
     the demo cannot reach something and nobody has decided about it yet.
     Nothing in this release is in that state; the code stays because the
     difference between "undecided" and "decided no" is the point.
"""

import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECRETS = os.path.join(ROOT, "secrets")
CORPUS = os.path.join(ROOT, "samples", "corpus")
FIXTURES = os.path.join(ROOT, "samples", "fixtures")

DEMO_DB = "aistack_demo"
DEMO_ROLE = "aistack_demo"
ADMIN_ROLE = "aistack_admin"

W1_ID = "aistackDemoW1001"
W2_ID = "aistackDemoW2001"
W3_ID = "aistackDemoW3001"
W4_ID = "aistackDemoW4001"

W4_PATH = "/webhook/w4-demo"

EMBED_DIMS = 768
PDF_SENTINEL = "AISTACK-SYNTHETIC-PDF-SENTINEL-7F3A"


# ---------------------------------------------------------------------------
# plumbing
# ---------------------------------------------------------------------------

class Fail(Exception):
    """An assertion inside a case failed.  Caught per case, never per run."""


def sh(argv, stdin=None, timeout=900, cwd=None):
    """Run a command, return (rc, stdout, stderr).  Never raises on rc != 0."""
    p = subprocess.run(argv, input=stdin, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, timeout=timeout, text=True,
                       cwd=cwd)
    return p.returncode, p.stdout, p.stderr


def docker(*args, **kw):
    return sh(["docker", *args], **kw)


def compose(*args, **kw):
    """`docker compose` with ROOT as the working directory, and no -f flags.

    Deliberately the same invocation bin/aistack's dc() uses.  Naming
    compose.yaml explicitly would silently ignore a compose.override.yaml an
    operator relies on, and then the helper container in w4() would run with a
    different configuration from the stack it is testing.
    """
    return sh(["docker", "compose", *args], cwd=ROOT, **kw)


def in_container(container, script, timeout=900):
    """Run a shell script inside a container with the script on STDIN.

    On stdin rather than in argv: anything that can read /proc on the host can
    read another process's argv, and some of these scripts carry a token.  The
    scripts therefore must not `cat` without a filename either -- that would
    eat the rest of the script from the same descriptor.
    """
    return sh(["docker", "exec", "-i", container, "sh", "-s"], stdin=script,
              timeout=timeout)


def psql(db, sql, user=ADMIN_ROLE, vars=None, timeout=300):
    """One statement, with every value bound through a psql variable.

    THE SQL GOES IN ON STDIN, NOT IN -c.  MEASURED (NOM-302): psql does not
    interpolate `:'name'` variables into a -c command string -- the server gets
    the literal colon and answers `syntax error at or near ":"`.  Which is a
    good failure, because the alternative to variables is string-pasting demo
    text into SQL, and the demo text includes model output.

    `:'name'` quotes the value as a literal, so a chunk containing a quote or a
    backslash cannot end the string it is inside.
    """
    argv = ["docker", "exec", "-i", "aistack-postgres", "psql",
            "-v", "ON_ERROR_STOP=1", "-U", user, "-d", db]
    for key, value in (vars or {}).items():
        argv += ["-v", "%s=%s" % (key, value)]
    argv += ["-tAq", "-f", "-"]
    body = sql.strip()
    if not body.endswith(";"):
        body += ";"
    return sh(argv, stdin=body + "\n", timeout=timeout)


def rows(db, sql, user=DEMO_ROLE, vars=None):
    """Run a statement and return its result rows as a list of dicts.

    Two things are deliberate here.

    The result is wrapped in json_agg so the transport is JSON rather than
    psql's pipe-separated text: a prompt or an answer containing a `|` or a
    newline is ordinary demo data, and splitting on a delimiter that can appear
    inside a value is how a harness starts reporting fictional rows.

    The wrapper is a CTE and not a sub-SELECT, because half the statements this
    grades are `UPDATE ... RETURNING` -- the envelope's atomic claim is the
    single most important one -- and a data-modifying statement is not legal
    inside a FROM.  A CTE takes both.
    """
    wrapped = ("WITH q AS (%s) SELECT coalesce(json_agg(row_to_json(q)), "
               "'[]'::json)::text FROM q" % sql.rstrip().rstrip(";"))
    rc, out, err = psql(db, wrapped, user=user, vars=vars)
    if rc != 0:
        raise Fail("SQL failed: %s" % (err.strip() or out.strip()))
    return json.loads(out.strip() or "[]")


def one(db, sql, user=DEMO_ROLE, vars=None):
    got = rows(db, sql, user=user, vars=vars)
    return got[0] if got else None


def scalar(db, sql, user=DEMO_ROLE, vars=None):
    rc, out, err = psql(db, sql, user=user, vars=vars)
    if rc != 0:
        raise Fail("SQL failed: %s" % (err.strip() or out.strip()))
    return out.strip()


def read_secret(name):
    path = os.path.join(SECRETS, name)
    if not os.path.isfile(path):
        raise Fail("missing %s -- run 'aistack samples setup' first" % path)
    with open(path) as fh:
        return fh.read().strip()


# ---------------------------------------------------------------------------
# HTTP from inside a container, with an exact status code
# ---------------------------------------------------------------------------

# node, not wget.  busybox wget reports a non-2xx as a message on stderr and
# gives no clean way to read the status code or the error body, and both are
# exactly what the W4 negative cases assert on.  node is present in the n8n
# image by definition -- it is what n8n runs on.
_NODE_POST = r"""
cat <<'AISTACK_NODE_EOF' > /tmp/aistack-post.js
const http = require('http');
const req = JSON.parse(process.env.AISTACK_REQ);
const body = req.body === null ? null : Buffer.from(req.body, 'utf8');
const headers = Object.assign({}, req.headers);
if (body) { headers['Content-Length'] = body.length; }
const r = http.request({ host: req.host, port: req.port, path: req.path,
                         method: req.method, headers, timeout: req.timeout_ms },
  (res) => {
    const parts = [];
    res.on('data', (c) => parts.push(c));
    res.on('end', () => process.stdout.write(JSON.stringify({
      status: res.statusCode,
      body: Buffer.concat(parts).toString('utf8').slice(0, req.max_body),
    }) + '\n'));
  });
r.on('timeout', () => { r.destroy(new Error('timeout after ' + req.timeout_ms + 'ms')); });
r.on('error', (e) => process.stdout.write(JSON.stringify({ status: 0, body: 'ERROR ' + e.message }) + '\n'));
if (body) { r.write(body); }
r.end();
AISTACK_NODE_EOF
AISTACK_REQ=%s node /tmp/aistack-post.js
rc=$?
rm -f /tmp/aistack-post.js
exit $rc
"""


def http_in(container, host, port, path, method="POST", body=None,
            headers=None, timeout_ms=180000, max_body=4000):
    """Make one HTTP request from inside `container`; return (status, body).

    The request -- including any token -- travels in the script on stdin and
    then in the helper process's ENVIRONMENT, not in its argv.  `ps` inside the
    container shows `node /tmp/aistack-post.js` and nothing else.
    """
    req = {"host": host, "port": port, "path": path, "method": method,
           "body": body, "headers": headers or {}, "timeout_ms": timeout_ms,
           # An embedding response is ~16 KB of floats, an error body is a
           # sentence.  The default keeps a failure's detail readable; the
           # caller raises it when it actually needs the payload.
           "max_body": max_body}
    # Single-quoted for the shell, with no embedded single quote possible:
    # json.dumps escapes nothing into a quote, and the value is JSON text.
    quoted = "'" + json.dumps(req).replace("'", "'\"'\"'") + "'"
    rc, out, err = in_container(container, _NODE_POST % quoted,
                                timeout=timeout_ms / 1000.0 + 60)
    line = out.strip().splitlines()[-1] if out.strip() else ""
    if not line:
        raise Fail("no response from the in-container HTTP helper (rc=%d): %s"
                   % (rc, (err or "").strip()[:300]))
    try:
        got = json.loads(line)
    except ValueError:
        raise Fail("unparseable helper output: %s" % line[:300])
    return got["status"], got["body"]


def embed(text):
    """Embed one string through LiteLLM, from inside n8n, with the demo key."""
    key = read_secret("samples_demo_litellm_key")
    status, body = http_in(
        "aistack-n8n", "litellm", 4000, "/v1/embeddings",
        body=json.dumps({"model": "local-embed", "input": text}),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + key},
        max_body=4_000_000)
    if status != 200:
        raise Fail("LiteLLM /v1/embeddings returned %s: %s" % (status, body[:300]))
    data = json.loads(body)["data"][0]["embedding"]
    if len(data) != EMBED_DIMS:
        raise Fail("local-embed returned %d dimensions, expected %d"
                   % (len(data), EMBED_DIMS))
    return data


# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------

RESULTS = []


def record(case, title, status, detail=""):
    RESULTS.append((case, title, status, detail))
    mark = {"PASS": "PASS    ", "FAIL": "FAIL    ", "BLOCKED": "BLOCKED ",
            "DEFERRED": "DEFERRED", "INFO": "info    "}[status]
    print("  %s %-6s %s" % (mark, case, title))
    for line in str(detail).splitlines():
        if line.strip():
            print("            %s" % line)
    sys.stdout.flush()


def case(case_id, title):
    """Decorator-free case runner: returns a function that grades a callable."""
    def run(fn):
        try:
            detail = fn() or ""
            record(case_id, title, "PASS", detail)
            return True
        except Fail as exc:
            record(case_id, title, "FAIL", str(exc))
            return False
    return run


def banner(text):
    print("\n== %s" % text)


# ---------------------------------------------------------------------------
# corpus loading (called by `samples setup`)
# ---------------------------------------------------------------------------

def chunk_markdown(text, limit=400):
    """Paragraph-aligned chunks, never mid-sentence.

    A fixed character window would cut "the nearest chunks are fetched" in
    half and then the demo's retrieval quality would be a property of the
    window size rather than of the embedding.

    400 characters, which for this corpus is 2-3 chunks per file.  The first
    version used 900 and produced ONE chunk per file: a nearest-neighbour
    search over two rows that both match is not a retrieval demo, it is a
    coin toss that W1 would pass either way.
    """
    out, current = [], []
    for para in [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]:
        candidate = ("\n\n".join(current + [para])).strip()
        if current and len(candidate) > limit:
            out.append("\n\n".join(current))
            current = [para]
        else:
            current.append(para)
    if current:
        out.append("\n\n".join(current))
    return out


def cmd_load_corpus():
    banner("Corpus")
    files = sorted(f for f in os.listdir(CORPUS) if f.endswith(".md"))
    if not files:
        raise SystemExit("samples: no corpus files in %s" % CORPUS)
    total = 0
    for name in files:
        with open(os.path.join(CORPUS, name)) as fh:
            text = fh.read()
        chunks = chunk_markdown(text)
        # Idempotent per source: a second setup replaces this file's chunks
        # rather than adding a second copy of them, which would quietly change
        # what W1's nearest-neighbour search is searching.
        rc, out, err = psql(DEMO_DB,
                            "DELETE FROM w2_chunks WHERE source = :'src'",
                            user=DEMO_ROLE, vars={"src": name})
        if rc != 0:
            raise SystemExit("samples: %s" % (err.strip() or out.strip()))
        for body in chunks:
            vec = embed(body)
            rc, out, err = psql(
                DEMO_DB,
                "INSERT INTO w2_chunks (source, content, embedding) "
                "VALUES (:'src', :'body', :'vec'::vector)",
                user=DEMO_ROLE,
                vars={"src": name, "body": body,
                      "vec": "[" + ",".join(repr(float(x)) for x in vec) + "]"})
            if rc != 0:
                raise SystemExit("samples: %s" % (err.strip() or out.strip()))
            total += 1
        print("  %s -> %d chunk(s)" % (name, len(chunks)))
    print("  %d chunk(s) embedded with local-embed and stored in w2_chunks" % total)

    # The one document W2 would parse.  Generated here rather than committed;
    # the generator's own docstring says why.
    pdf = os.path.join(FIXTURES, "synthetic.pdf")
    if not os.path.isfile(pdf):
        raise SystemExit("samples: %s is missing" % pdf)
    with open(pdf, "rb") as fh:
        blob = fh.read()
    if PDF_SENTINEL.encode() not in blob:
        raise SystemExit("samples: %s does not contain its own sentinel" % pdf)
    print("  synthetic.pdf present (%d bytes, sentinel in the content stream)"
          % len(blob))


# ---------------------------------------------------------------------------
# workflow execution
# ---------------------------------------------------------------------------

def execute_workflow(workflow_id, timeout=1200):
    """Run one workflow by id in the LIVE n8n and return its CLI output.

    `n8n execute` runs the trigger's downstream chain once, in process, with no
    timer registered and no webhook served.  That is the whole reason the
    templates can stay inactive: a demo nobody has switched on should not start
    firing at 08:00 on a machine nobody is watching.

    N8N_RUNNERS_BROKER_PORT IS NOT OPTIONAL.  MEASURED (NOM-302): `n8n execute`
    starts its own task broker, and inside the live container port 5679 is
    already taken by the running main -- so the obvious invocation dies with
    "Do you have another instance of n8n running already?" before executing
    anything.  A second port is the whole fix; the broker is in-process and
    reachable only on loopback.
    """
    rc, out, err = sh(["docker", "exec",
                       "-e", "N8N_RUNNERS_BROKER_PORT=15679",
                       "-i", "aistack-n8n",
                       "n8n", "execute", "--id", workflow_id],
                      timeout=timeout)
    blob = (out or "") + (err or "")
    return rc, blob


def assert_execution_ok(workflow_id, rc, blob):
    """Did the run finish, or did a node throw?

    THE EXIT CODE IS NOT THE SIGNAL AND NEITHER IS THE OUTPUT TEXT.  MEASURED
    (NOM-302): `n8n execute` exits 0 for a workflow whose HTTP node aborted,
    printing a NodeApiError stack and nothing a grep for "failed" would match.
    A harness reading rc alone reports that run green -- which is the exact
    class of false pass this ticket exists to remove.

    n8n writes a row to execution_entity with a `status` for every run,
    including CLI runs, so that row is what gets read.  It also carries which
    node the run stopped at, which is the first thing anybody debugging wants.
    """
    if rc != 0:
        raise Fail("n8n execute --id %s exited %d:\n%s"
                   % (workflow_id, rc, tail(blob)))
    got = one("n8n", "SELECT e.id, e.status, d.data::text AS data "
                     "FROM execution_entity e "
                     "LEFT JOIN execution_data d ON d.\"executionId\" = e.id "
                     "WHERE e.\"workflowId\" = :'wid' ORDER BY e.id DESC LIMIT 1",
              user=ADMIN_ROLE, vars={"wid": workflow_id})
    if not got:
        raise Fail("n8n recorded no execution for %s at all:\n%s"
                   % (workflow_id, tail(blob)))
    if got["status"] != "success":
        raise Fail("n8n execution %s of %s is %r%s\n%s"
                   % (got["id"], workflow_id, got["status"],
                      last_node(got["data"]), tail(blob)))
    return ""


def last_node(data):
    """Which node the run stopped at, out of n8n's FLATTED execution data.

    `execution_data.data` is flatted JSON: one array where every nested value
    is replaced by the string index of its own slot.  So `lastNodeExecuted` is
    not a node name, it is "7" -- MEASURED, NOM-302, after an error message
    helpfully reported that the run "stopped at node '7'".  Resolving one hop
    is all this needs, and it falls back to saying nothing rather than
    inventing a name.
    """
    try:
        arr = json.loads(data or "[]")
        for slot in arr:
            if isinstance(slot, dict) and "lastNodeExecuted" in slot:
                ref = slot["lastNodeExecuted"]
                name = arr[int(ref)] if str(ref).isdigit() else ref
                if isinstance(name, str) and name:
                    return " and stopped at node %r" % name
    except Exception:
        pass
    return ""


def tail(blob, lines=14):
    kept = [l for l in (blob or "").splitlines() if l.strip()]
    return "\n".join(kept[-lines:])


def workflow_node_credentials(workflow_id):
    """Which credential id each node of an IMPORTED workflow is bound to.

    Read from n8n's own database rather than from the JSON on disk: the file is
    what we wrote, the row is what n8n accepted.  QA's original finding was
    exactly this gap -- the files looked fine and the import had dropped the
    binding.
    """
    got = one("n8n", "SELECT nodes::text AS nodes FROM workflow_entity "
                     "WHERE id = :'wid'", user=ADMIN_ROLE,
              vars={"wid": workflow_id})
    if not got:
        raise Fail("workflow %s is not imported" % workflow_id)
    bound = {}
    for node in json.loads(got["nodes"]):
        for kind, cred in (node.get("credentials") or {}).items():
            bound.setdefault(node["name"], []).append((kind, cred.get("id")))
    return bound


def assert_inactive(workflow_id):
    got = one("n8n", "SELECT active, \"activeVersionId\" AS av "
                     "FROM workflow_entity WHERE id = :'wid'",
              user=ADMIN_ROLE, vars={"wid": workflow_id})
    if not got:
        raise Fail("workflow %s is not imported" % workflow_id)
    if got["active"] or got["av"]:
        raise Fail("workflow %s is ACTIVE (active=%r, activeVersionId=%r) and "
                   "every demo in this release must stay inactive"
                   % (workflow_id, got["active"], got["av"]))


# ---------------------------------------------------------------------------
# W1
# ---------------------------------------------------------------------------

def w1():
    banner("W1 - research over a local corpus")
    ok = True

    def all_inactive():
        for workflow in (W1_ID, W2_ID, W3_ID, W4_ID):
            assert_inactive(workflow)
        return "active=false and activeVersionId=null for all four"
    ok &= case("W1.0", "all four demo workflows are imported and INACTIVE")(
        all_inactive)

    def bindings():
        bound = workflow_node_credentials(W1_ID)
        want = {"Embed the question": "aistackDemoLlm01",
                "Nearest chunks (pgvector)": "aistackDemoPg001",
                "Answer with citations": "aistackDemoLlm01",
                "Record the run (answer + citations)": "aistackDemoPg001"}
        for node, cred in want.items():
            got = [v for _, v in bound.get(node, [])]
            if cred not in got:
                raise Fail("node %r is bound to %r, expected %s"
                           % (node, got, cred))
        return "4 nodes bound by credential id"
    ok &= case("W1.1", "every W1 node that needs a credential has one")(bindings)

    def unauthenticated_litellm():
        status, body = http_in("aistack-n8n", "litellm", 4000, "/v1/embeddings",
                               body=json.dumps({"model": "local-embed",
                                                "input": "probe"}),
                               headers={"Content-Type": "application/json"},
                               timeout_ms=30000)
        if status != 401:
            raise Fail("expected 401 without a key, got %s: %s"
                       % (status, body[:200]))
        return "LiteLLM answers 401 without a key, so the bound key is load-bearing"
    ok &= case("W1.2", "NEGATIVE: LiteLLM refuses an unauthenticated embedding")(
        unauthenticated_litellm)

    def corpus_present():
        n = int(scalar(DEMO_DB, "SELECT count(*) FROM w2_chunks"))
        if n < 2:
            raise Fail("w2_chunks holds %d row(s); run 'aistack samples setup'" % n)
        dims = int(scalar(DEMO_DB, "SELECT vector_dims(embedding) FROM w2_chunks LIMIT 1"))
        if dims != EMBED_DIMS:
            raise Fail("stored embeddings are %d-dimensional, expected %d"
                       % (dims, EMBED_DIMS))
        return "%d chunk(s) of %d dimensions in w2_chunks" % (n, dims)
    ok &= case("W1.3", "the local corpus is loaded and embedded")(corpus_present)

    def run_and_check():
        before = int(scalar(DEMO_DB, "SELECT count(*) FROM w1_runs"))
        rc, blob = execute_workflow(W1_ID)
        assert_execution_ok(W1_ID, rc, blob)
        after = int(scalar(DEMO_DB, "SELECT count(*) FROM w1_runs"))
        if after != before + 1:
            raise Fail("w1_runs went from %d to %d rows; the workflow ran but "
                       "recorded nothing:\n%s" % (before, after, tail(blob)))
        row = one(DEMO_DB, "SELECT question, top_source, sources::text AS sources, "
                           "distances::text AS distances, answer FROM w1_runs "
                           "ORDER BY run_id DESC LIMIT 1")
        expect = one(DEMO_DB, "SELECT expect_source FROM w1_expected "
                              "WHERE question = :'q'", vars={"q": row["question"]})
        if not expect:
            raise Fail("no w1_expected row for the question the workflow asked: "
                       "%r" % row["question"])
        if row["top_source"] != expect["expect_source"]:
            raise Fail("nearest chunk came from %r, expected %r (sources: %s)"
                       % (row["top_source"], expect["expect_source"], row["sources"]))
        dists = json.loads(row["distances"])
        if len(dists) < 2:
            raise Fail("only %d neighbour(s) returned" % len(dists))
        if dists != sorted(dists):
            raise Fail("distances are not ascending: %s -- the ORDER BY did not "
                       "run, so row order is luck" % dists)
        if len(row["answer"].strip()) < 20:
            raise Fail("the recorded answer is %d characters: %r"
                       % (len(row["answer"].strip()), row["answer"][:80]))
        return ("asked %r\n  nearest: %s (distance %.4f), %d neighbours ascending\n"
                "  answer: %d characters, recorded in w1_runs"
                % (row["question"], row["top_source"], dists[0], len(dists),
                   len(row["answer"])))
    ok &= case("W1.4", "W1 runs end to end and retrieves the right source")(
        run_and_check)
    return bool(ok)


# ---------------------------------------------------------------------------
# W2
# ---------------------------------------------------------------------------

def w2():
    banner("W2 - chat with your PDF")
    ok = True

    def fixture():
        pdf = os.path.join(FIXTURES, "synthetic.pdf")
        if not os.path.isfile(pdf):
            raise Fail("%s is missing; run 'aistack samples setup'" % pdf)
        with open(pdf, "rb") as fh:
            blob = fh.read()
        if not blob.startswith(b"%PDF-1.4"):
            raise Fail("the fixture is not a PDF 1.4 file")
        if PDF_SENTINEL.encode() not in blob:
            raise Fail("the fixture does not contain its own sentinel")
        return "%d bytes, sentinel present" % len(blob)
    ok &= case("W2.1", "the synthetic document exists and carries its sentinel")(
        fixture)

    def bindings():
        bound = workflow_node_credentials(W2_ID)
        for node, cred in (("Embed via LiteLLM", "aistackDemoLlm01"),
                           ("Store chunk + embedding", "aistackDemoPg001")):
            got = [v for _, v in bound.get(node, [])]
            if cred not in got:
                raise Fail("node %r is bound to %r, expected %s"
                           % (node, got, cred))
        return "the embed and store nodes are bound; the parse node needs no credential"
    ok &= case("W2.2", "W2's credential-bearing nodes are bound")(bindings)

    # The one case in this harness that cannot pass, and it reports DEFERRED
    # rather than FAIL because nothing is broken -- the demo asks for a route
    # the release decided not to have (NOM-321, NOM-323).
    #
    # PROBED WITH A CONTROL, because the first version of this gate was the
    # `ollama sh` bug again.  It ran `getent hosts docling-serve` inside the
    # n8n image, which has no `getent`: the exec fails with rc=127 on stderr,
    # stdout is empty, and "empty stdout" was then read as "the name does not
    # resolve" -- the same answer whatever the topology, which made the
    # routable branch below unreachable.  A probe that cannot report success
    # is not a measurement.  So: the harness's own in-container HTTP helper
    # (node, which n8n is built on, not busybox), fired twice -- once at a
    # service n8n is SUPPOSED to reach, once at Docling.  The control is what
    # makes Docling's answer mean something.
    def probe(host, port, path):
        try:
            return http_in("aistack-n8n", host, port, path,
                           method="GET", timeout_ms=10000)
        except Fail as exc:
            return 0, "probe helper failed: %s" % exc

    ctrl_status, ctrl_body = probe("litellm", 4000, "/health/liveliness")
    doc_status, doc_body = probe("docling-serve", 5001, "/health")
    measured = ("from aistack-n8n, same HTTP helper for both:\n"
                "  litellm:4000/health/liveliness       -> status %s, %s\n"
                "  docling-serve:5001/health            -> status %s, %s"
                % (ctrl_status, (ctrl_body or "").strip()[:80] or "(empty)",
                   doc_status, (doc_body or "").strip()[:80] or "(empty)"))

    if ctrl_status != 200:
        # The control did not answer either, so this run measured nothing about
        # Docling.  That is a FAIL of the probe, not a deferral of the demo:
        # reporting a deferral here would be inventing the finding again.
        ok = False
        record("W2.3", "the reachability probe itself could not report success",
               "FAIL",
               measured + "\nThe control probe is supposed to return 200 from a "
               "healthy stack.\nNo conclusion about Docling can be drawn from "
               "this run.  Check that\nthe stack is up ('bin/aistack doctor') "
               "and re-run.")
    elif doc_status == 200:
        record("W2.3", "n8n can reach Docling", "INFO",
               measured + "\nDocling answers /health from n8n -- the topology "
               "changed since NOM-302.\nW2 is executed and graded like W1 "
               "below.  If that route was added on\npurpose, NOM-321's decision "
               "needs re-reading; it rejected a parser peer\nadded to make this "
               "demo pass.")
        ok &= case("W2.4", "W2 runs end to end (Docling -> LiteLLM -> pgvector)")(
            _w2_execute)
    else:
        record("W2.3", "W2 is DEFERRED by decision: n8n has no route to Docling",
               "DEFERRED",
               measured + "\n"
               "docling-serve is confined on the pairwise parse-owui /29 with "
               "Open WebUI as\nits only peer; n8n is on apps+gateway+data.  W2's "
               "parse step therefore\ncannot complete, so this harness does not "
               "execute W2 and does not report\nit as a pass.  Everything else "
               "in the template is bound and ready.\n"
               "\n"
               "This is DECIDED, not open.  NOM-321: no new Docling peer to make "
               "a demo\npass -- parse-n8n rejected, and the n8n -> Open WebUI -> "
               "Docling route\nrejected with it.  A parser peer returns only via "
               "the reserved parse-agw\nwith a passed G-AGENTS or its own named "
               "gate, bought by a product\nrequirement.  NOM-323: the profile "
               "ships three executable n8n demos --\nW1, W3, W4 -- and W2 defers "
               "with the agents group, like W6.\n"
               "See docs/samples.md section 3.")
    return bool(ok)


def _w2_execute():
    before = int(scalar(DEMO_DB, "SELECT count(*) FROM w2_chunks "
                                 "WHERE source = 'synthetic.pdf'"))
    rc, blob = execute_workflow(W2_ID)
    assert_execution_ok(W2_ID, rc, blob)
    after = int(scalar(DEMO_DB, "SELECT count(*) FROM w2_chunks "
                                "WHERE source = 'synthetic.pdf'"))
    if after <= before:
        raise Fail("no new synthetic.pdf chunk was stored:\n%s" % tail(blob))
    got = one(DEMO_DB, "SELECT content FROM w2_chunks WHERE source='synthetic.pdf' "
                       "ORDER BY chunk_id DESC LIMIT 1")
    if PDF_SENTINEL not in got["content"]:
        raise Fail("the stored chunk does not contain the PDF's sentinel, so "
                   "the bytes did not survive the parse")
    return "sentinel recovered from the parsed document and stored with its embedding"


# ---------------------------------------------------------------
# W4
# ---------------------------------------------------------------------------

# The short-lived n8n that SERVES W4's webhook for the length of its own test.
# Same idiom as the model-puller helper: a container that exists for one job
# and is gone when the job is done, rather than a setting left switched on.
#
# WHY THE LIVE INSTANCE IS NOT THE ONE UNDER TEST.  n8n registers production
# webhooks when a main process STARTS, and in regular mode (EXECUTIONS_MODE
# regular, C3) a running main never re-reads the database for newly published
# workflows -- `publish:workflow` says so itself: "changes will not take effect
# if n8n is running".  The dedicated `n8n webhook` process is not an option
# either; it refuses outside queue mode.  So something has to start.  A
# throwaway main costs one container and leaves the long-running instance
# unrestarted and unreconfigured, which is the whole of what it buys.
#
# IT DOES NOT CONTAIN THE ROUTE.  An earlier version of this comment claimed
# that while the demo is served here, the instance behind the reverse proxy
# still has no route for it.  W4.6 measured the opposite and now asserts it:
# registration is shared state in webhook_entity, so a published webhook
# answers on EVERY running main.  The container boundary is an operational
# convenience, not a containment boundary -- see live_serves_it_too().
W4_HELPER = "aistack-samples-w4"


def w4_helper_up():
    docker("rm", "-f", W4_HELPER)
    rc, out, err = compose("run", "-d", "--no-deps", "--name", W4_HELPER,
                           "n8n", "start", timeout=300)
    if rc != 0:
        raise Fail("could not start the W4 helper container: %s"
                   % (err.strip() or out.strip())[:400])
    deadline = time.time() + 240
    while time.time() < deadline:
        rc, _, _ = docker("exec", W4_HELPER, "wget", "-q", "-T", "3", "-O",
                          "/dev/null", "http://127.0.0.1:5678/healthz")
        if rc == 0:
            return
        time.sleep(5)
    raise Fail("the W4 helper never became healthy:\n%s"
               % tail(docker("logs", "--tail", "20", W4_HELPER)[1]))


def w4_helper_down():
    # STOP, then remove.  A SIGKILL leaves n8n's webhook registration row
    # behind; a graceful stop lets it deregister.  30 seconds is generous for a
    # process whose only registered route is this demo.
    docker("stop", "-t", "30", W4_HELPER)
    docker("rm", "-f", W4_HELPER)


def webhook_registered(expect, timeout=120):
    """Wait until the demo webhook is (or is not) in n8n's registration table."""
    deadline = time.time() + timeout
    while True:
        n = int(scalar("n8n", "SELECT count(*) FROM webhook_entity "
                              "WHERE \"workflowId\" = :'wid'",
                       user=ADMIN_ROLE, vars={"wid": W4_ID}))
        if (n > 0) == expect:
            return n
        if time.time() > deadline:
            raise Fail("webhook_entity holds %d row(s) for %s after %ds; "
                       "expected %s" % (n, W4_ID, timeout,
                                        "a registration" if expect else "none"))
        time.sleep(3)


def webhook_answers(container, timeout=240):
    """Wait until the demo webhook is actually being SERVED, not merely rowed.

    NEITHER THE DATABASE ROW NOR /healthz IS THE READINESS SIGNAL.  MEASURED
    (NOM-302): the helper answers /healthz several seconds before
    ActiveWorkflowManager has attached the route, and the registration row
    appears on its own schedule -- so a harness that waits for either POSTs
    into a 404 and reports the demo broken.  The signal is the route answering:
    a request with a deliberately wrong token, which a registered webhook
    refuses with 403 and an unregistered path cannot distinguish from any other
    404.
    """
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        status, _ = http_in(container, "127.0.0.1", 5678, W4_PATH,
                            body=json.dumps({"prompt": "readiness probe"}),
                            headers={"Content-Type": "application/json",
                                     "X-Aistack-Token": "deliberately-wrong"},
                            timeout_ms=20000)
        last = status
        if status in (401, 403):
            return status
        time.sleep(5)
    raise Fail("the demo webhook never started answering in %s (last status "
               "%s after %ds)" % (container, last, timeout))


def w4():
    banner("W4 - webhook to model to stored result")
    ok = True

    def bindings():
        bound = workflow_node_credentials(W4_ID)
        got = [v for _, v in bound.get("Webhook (header token)", [])]
        if "aistackDemoHdr01" not in got:
            raise Fail("the webhook node is bound to %r, expected "
                       "aistackDemoHdr01 -- QA's original finding was this "
                       "exact gap: headerAuth with no credential" % got)
        got = [v for _, v in bound.get("Ask the model via LiteLLM", [])]
        if "aistackDemoLlm01" not in got:
            raise Fail("the model node is bound to %r" % got)
        return "the webhook's header-token credential and the model key are both bound"
    ok &= case("W4.1", "the webhook's header-token credential is bound")(bindings)

    token = read_secret("samples_demo_w4_token")
    prompt = "Reply with the single word OK."

    def publish():
        rc, out, err = sh(["docker", "exec", "-i", "aistack-n8n",
                           "n8n", "publish:workflow", "--id", W4_ID], timeout=300)
        if rc != 0:
            raise Fail((err.strip() or out.strip())[:400])
        w4_helper_up()
        refused = webhook_answers(W4_HELPER)
        rows_now = webhook_registered(True)
        path = one("n8n", "SELECT \"webhookPath\" AS p, method FROM webhook_entity "
                          "WHERE \"workflowId\" = :'wid'", user=ADMIN_ROLE,
                   vars={"wid": W4_ID})
        if path["p"] != "w4-demo":
            raise Fail("n8n registered the demo on %r, not on 'w4-demo'. A "
                       "webhook node with no webhookId registers under "
                       "<workflowId>/<node name>/<path>, which then does not "
                       "resolve (MEASURED, NOM-302)." % path["p"])
        return ("published, served by a throwaway n8n on the internal bridges, "
                "%d registration row (%s %s), and the route answers %s to a "
                "wrong token" % (rows_now, path["method"], path["p"], refused))
    if not case("W4.2", "the demo webhook is served for the length of its test")(
            publish):
        w4_helper_down()
        sh(["docker", "exec", "-i", "aistack-n8n", "n8n", "unpublish:workflow",
            "--id", W4_ID], timeout=300)
        return False

    try:
        def good():
            before = int(scalar(DEMO_DB, "SELECT count(*) FROM w4_results"))
            # 14 minutes: the answer is generated by a 3B model on a CPU while
            # the request is held open.  MEASURED at 90s for 256 tokens on an
            # idle sandbox box and over five minutes on a loaded one, which is
            # why the template asks for 160.  The ceiling above this is n8n's
            # own EXECUTIONS_TIMEOUT_MAX (900s, limits.yaml).
            status, body = http_in(W4_HELPER, "127.0.0.1", 5678, W4_PATH,
                                   body=json.dumps({"prompt": prompt}),
                                   headers={"Content-Type": "application/json",
                                            "X-Aistack-Token": token},
                                   timeout_ms=840000)
            if status != 200:
                raise Fail("a POST with the right token returned %s: %s"
                           % (status, body[:300]))
            after = int(scalar(DEMO_DB, "SELECT count(*) FROM w4_results"))
            if after != before + 1:
                raise Fail("w4_results went from %d to %d rows" % (before, after))
            row = one(DEMO_DB, "SELECT prompt, answer FROM w4_results "
                               "ORDER BY result_id DESC LIMIT 1")
            if row["prompt"] != prompt:
                raise Fail("the stored prompt is %r, not what was posted"
                           % row["prompt"][:80])
            if not row["answer"].strip():
                raise Fail("the stored answer is empty")
            if "result_id" not in body:
                raise Fail("responseMode=lastNode should return the stored row, "
                           "got: %s" % body[:200])
            return ("200, the model answered %r, and the row is in w4_results"
                    % row["answer"].strip()[:60])
        ok &= case("W4.3", "a POST with the right token runs the demo end to end")(good)

        def negatives():
            before = int(scalar(DEMO_DB, "SELECT count(*) FROM w4_results"))
            checks = []
            for label, headers in (
                    ("no token", {"Content-Type": "application/json"}),
                    ("wrong token", {"Content-Type": "application/json",
                                     "X-Aistack-Token": "not-the-token"}),
                    ("right header name, empty value",
                     {"Content-Type": "application/json",
                      "X-Aistack-Token": ""}),
                    ("the token in the WRONG header",
                     {"Content-Type": "application/json",
                      "Authorization": "Bearer " + token})):
                status, body = http_in(W4_HELPER, "127.0.0.1", 5678, W4_PATH,
                                       body=json.dumps({"prompt": prompt}),
                                       headers=headers, timeout_ms=60000)
                if status not in (401, 403):
                    raise Fail("%s: expected 401/403, got %s: %s"
                               % (label, status, body[:200]))
                checks.append("%s -> %s %s" % (label, status, body[:60].strip()))
            after = int(scalar(DEMO_DB, "SELECT count(*) FROM w4_results"))
            if after != before:
                raise Fail("a rejected request still stored %d row(s)"
                           % (after - before))
            return ("\n".join(checks) +
                    "\nand w4_results is unchanged, so no inference was bought")
        ok &= case("W4.4", "NEGATIVE: four ways of not having the token are refused")(
            negatives)

        def bad_body():
            before = int(scalar(DEMO_DB, "SELECT count(*) FROM w4_results"))
            status, body = http_in(W4_HELPER, "127.0.0.1", 5678, W4_PATH,
                                   body=json.dumps({"nope": 1}),
                                   headers={"Content-Type": "application/json",
                                            "X-Aistack-Token": token},
                                   timeout_ms=120000)
            if status == 200:
                raise Fail("a body with no prompt was accepted: %s" % body[:200])
            after = int(scalar(DEMO_DB, "SELECT count(*) FROM w4_results"))
            if after != before:
                raise Fail("a refused body still stored a row")
            return ("an authenticated POST with no prompt -> %s, nothing stored, "
                    "no inference bought" % status)
        ok &= case("W4.5", "NEGATIVE: an authenticated POST with no prompt is refused")(
            bad_body)

        def live_serves_it_too():
            """A property of the stack, written down because it surprised me.

            I expected the live instance to answer 404 here: nothing restarted
            it, and n8n registers webhooks at startup.  It answered 200 --
            MEASURED, NOM-302, and it is this harness that caught my own wrong
            assumption, which is the argument for assertions over narration.

            WEBHOOK REGISTRATION IS SHARED STATE IN POSTGRES.  The throwaway
            container writes webhook_entity on startup, and every running main
            resolves an unknown path through that table.  So while the demo is
            published, it answers on EVERY main, including the one the reverse
            proxy talks to.

            Which relocates the whole safety claim.  The demo is not kept off
            the proxy by this harness's choice of container; it is kept off by
            the fact that Caddy forwards /n8n/webhook/* WITHOUT stripping the
            prefix, so n8n has no route for what arrives (W4.7).  That is a BUG
            standing in for a control, and the edit that fixes webhooks is the
            same edit that exposes this route -- which is exactly why it is a
            Tech Lead decision and not mine.

            A wrong token on purpose: this case is about whether the route is
            LIVE here, and 403-from-the-auth-check answers that without buying
            ninety seconds of inference or storing a row.
            """
            status, body = http_in("aistack-n8n", "127.0.0.1", 5678, W4_PATH,
                                   body=json.dumps({"prompt": prompt}),
                                   headers={"Content-Type": "application/json",
                                            "X-Aistack-Token": "deliberately-wrong"},
                                   timeout_ms=30000)
            if status == 404:
                raise Fail("the live n8n answered 404 where it answered 403 "
                           "when this was written (NOM-302). If registration "
                           "is no longer shared through webhook_entity that is "
                           "GOOD news, but the exposure note on NOM-302 and in "
                           "docs/samples.md is now stale and must be re-read.")
            if status not in (401, 403):
                raise Fail("the live n8n answered %s: %s" % (status, body[:200]))
            return ("the live n8n -- the instance behind the reverse proxy -- "
                    "serves this route too (%s to a wrong token) while the demo "
                    "is published.\n  Registration is shared state in "
                    "webhook_entity, not per-process. What keeps the demo off "
                    "the proxy is W4.7's path mismatch, which is a bug, not a "
                    "control." % status)
        ok &= case("W4.6", "while published, the demo answers on EVERY running main")(
            live_serves_it_too)

        # Reported, not asserted, and deliberately not called a guarantee.
        record("W4.7", "the same request through the reverse proxy", "INFO",
               proxy_probe(token, prompt))
    finally:
        def cleanup():
            w4_helper_down()
            rc, out, err = sh(["docker", "exec", "-i", "aistack-n8n",
                               "n8n", "unpublish:workflow", "--id", W4_ID],
                              timeout=300)
            if rc != 0:
                raise Fail((err.strip() or out.strip())[:300])
            left = webhook_registered(False)
            assert_inactive(W4_ID)
            published = int(scalar("n8n", "SELECT count(*) FROM "
                                          "workflow_published_version "
                                          "WHERE \"workflowId\" = :'wid'",
                                  user=ADMIN_ROLE, vars={"wid": W4_ID}))
            if published:
                raise Fail("%s is still in workflow_published_version" % W4_ID)
            # THE PROPERTY THAT ACTUALLY MATTERS, asserted where it is true.
            # W4.6 establishes that a published demo answers on every main, so
            # "put away" has to mean the live instance stops answering -- not
            # merely that a row is gone and a flag is false.
            status, body = http_in("aistack-n8n", "127.0.0.1", 5678, W4_PATH,
                                   body=json.dumps({"prompt": "after cleanup"}),
                                   headers={"Content-Type": "application/json",
                                            "X-Aistack-Token": token},
                                   timeout_ms=30000)
            if status != 404:
                raise Fail("the live n8n still answers %s on %s after the demo "
                           "was unpublished" % (status, W4_PATH))
            return ("helper removed, unpublished, %d registration row(s) left, "
                    "active=false, no published version, and the live n8n "
                    "answers 404 again: %s" % (left, body.strip()[:90]))
        ok &= case("W4.8", "the demo webhook is put away again")(cleanup)
    return bool(ok)


def proxy_probe(token, prompt):
    """What the SAME request does through Caddy, measured rather than assumed.

    MEASURED (NOM-302, 2026-10-19): it answers 404, and NOT because anything is
    guarding it.  config/caddy/sites.d/30-n8n.caddy proxies /n8n/webhook/* to
    n8n without stripping the /n8n prefix, so n8n receives a path it has no
    route for:

        POST https://aistack.localhost/n8n/webhook/w4-demo
        404  Cannot POST /n8n/webhook/w4-demo

    That is reported here as a FINDING, not as a control and not as a pass.  A
    404 that comes from a path mismatch disappears the moment somebody adds a
    `uri strip_prefix /n8n` to make webhooks work -- and that same edit would
    put this route, which has no forward-auth in front of it, into service with
    nothing but n8n's own header check.  Whether to make it work, and what has
    to be true first, is a Tech Lead call tracked on NOM-302.
    """
    try:
        import ssl
        import urllib.error
        import urllib.request
        host = bind = None
        with open(os.path.join(ROOT, ".env")) as fh:
            for line in fh:
                if line.startswith("AISTACK_HOSTNAME="):
                    host = line.split("=", 1)[1].strip()
                if line.startswith("AISTACK_BIND_ADDR="):
                    bind = line.split("=", 1)[1].strip()
        if not host:
            return "skipped: no AISTACK_HOSTNAME in .env"
        req = urllib.request.Request(
            "https://%s/n8n%s" % (host, W4_PATH),
            data=json.dumps({"prompt": prompt}).encode(),
            headers={"Content-Type": "application/json",
                     "X-Aistack-Token": token},
            method="POST")
        ctx = ssl._create_unverified_context()   # Caddy's internal CA
        try:
            with urllib.request.urlopen(req, timeout=30, context=ctx) as res:
                status, body = res.status, res.read(300).decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            status, body = exc.code, exc.read(300).decode("utf-8", "replace")
        detail = "POST https://%s/n8n%s -> %s" % (host, W4_PATH, status)
        if status == 404 and "Cannot POST /n8n" in body:
            detail += ("\nThe 404 is a PATH MISMATCH, not a control: Caddy "
                       "forwards /n8n/webhook/* without stripping the prefix, "
                       "so n8n has no route for what it receives.\nFiled and "
                       "routed on NOM-321: that route is also the one Caddy "
                       "proxies WITHOUT forward-auth, so the edit that makes "
                       "webhooks work is also an exposure decision.")
        elif status == 200:
            detail += ("\nThe demo webhook IS answerable through the proxy "
                       "while published. That is wider than the release "
                       "describes; re-read 30-n8n.caddy before shipping.")
        return detail + ("\n(bind address %s)" % bind if bind else "")
    except Exception as exc:                     # a probe, never a gate
        return "skipped: %s: %s" % (type(exc).__name__, exc)


# ---------------------------------------------------------------------------
# P2 - the approval envelope, exercised on its own
# ---------------------------------------------------------------------------

P2_PROBE_SQL = """
INSERT INTO approval_action (action_id, approver_subject, approver_groups, tool,
        backend_id, config_revision, recipient, scope, parameter_hash,
        expires_at, state)
VALUES (gen_random_uuid(), 'local:p2-probe', ARRAY['admins'], :'tool',
        'n8n-local', 'rev-p2', 'demo:nobody', '{"probe":true}'::jsonb,
        encode(sha256('probe'::bytea), 'hex'), now() + :'ttl'::interval, :'state')
RETURNING action_id
"""


def p2_probe(tool, state="pending", ttl="5 minutes"):
    got = one(DEMO_DB, P2_PROBE_SQL, vars={"tool": tool, "state": state, "ttl": ttl})
    return got["action_id"]


def expect_sql_error(sql, needle, vars=None):
    rc, out, err = psql(DEMO_DB, sql, user=DEMO_ROLE, vars=vars)
    if rc == 0:
        raise Fail("the statement SUCCEEDED and should have been refused: %s"
                   % sql.strip()[:160])
    blob = (err or "") + (out or "")
    if needle.lower() not in blob.lower():
        raise Fail("refused, but not for the expected reason (%r):\n%s"
                   % (needle, blob.strip()[:300]))
    return blob.strip().splitlines()[0][:200]


def w3_quiesce():
    """Retire every live send_summary envelope, through LEGAL transitions only.

    WHY A TEST NEEDS THIS, and it is not tidiness.  MEASURED (NOM-302): P2.6
    creates an approved envelope, tampers with its summary and expects W3 to
    refuse it -- but W3's claim takes the OLDEST approved envelope, which is
    the correct behaviour for a queue and the wrong one for a test that assumes
    it will get its own row.  A leftover approved envelope from an earlier run
    was claimed and refused instead, and P2.6 then read its own row, found it
    untouched, and reported a failure that was really a fixture problem.  A
    test that silently grades a different row than the one it created is worse
    than no test.

    Nothing here bypasses the state machine: pending -> expired and
    approved -> expired are declared edges, and an envelope stranded in
    `executing` goes to `failed` with outcome `unknown`, which is precisely
    what that outcome value is for -- we do not know whether the action
    happened, and recording `refused` would be a claim we cannot make.
    """
    expired = rows(DEMO_DB,
                   "UPDATE approval_action SET state='expired' "
                   "WHERE tool='send_summary' AND state IN ('pending','approved') "
                   "RETURNING action_id")
    stranded = rows(DEMO_DB,
                    "UPDATE approval_action SET state='failed', outcome='unknown' "
                    "WHERE tool='send_summary' AND state='executing' "
                    "RETURNING action_id")
    return len(expired), len(stranded)


def p2():
    banner("P2 - the approval envelope (exercised independently of W3)")
    ok = True

    ok &= case("P2.1", "NEGATIVE: an illegal state transition is refused")(
        lambda: expect_sql_error(
            "UPDATE approval_action SET state='executed' WHERE action_id=:'a'",
            "illegal approval transition",
            vars={"a": p2_probe("p2_illegal")}))

    def immutable():
        action = p2_probe("p2_immutable")
        first = expect_sql_error(
            "UPDATE approval_action SET recipient='someone-else' "
            "WHERE action_id=:'a'", "immutable", vars={"a": action})
        second = expect_sql_error(
            "UPDATE approval_action SET parameter_hash='00' WHERE action_id=:'a'",
            "immutable", vars={"a": action})
        return first + "\n" + second
    ok &= case("P2.2", "NEGATIVE: the envelope is immutable after creation")(immutable)

    def append_only():
        action = p2_probe("p2_log")
        scalar(DEMO_DB, "UPDATE approval_action SET state='approved' "
                        "WHERE action_id=:'a'", vars={"a": action})
        n = int(scalar(DEMO_DB, "SELECT count(*) FROM action_transitions "
                                "WHERE action_id=:'a'", vars={"a": action}))
        if n != 1:
            raise Fail("the transition log holds %d row(s) for one transition" % n)
        first = expect_sql_error(
            "UPDATE action_transitions SET to_state='nonsense' "
            "WHERE action_id=:'a'", "append-only", vars={"a": action})
        second = expect_sql_error(
            "DELETE FROM action_transitions WHERE action_id=:'a'",
            "append-only", vars={"a": action})
        return "transition logged, then: " + first + "\n" + second
    ok &= case("P2.3", "every transition is logged and the log cannot be edited")(
        append_only)

    def replay():
        action = p2_probe("p2_replay")
        scalar(DEMO_DB, "UPDATE approval_action SET state='approved' "
                        "WHERE action_id=:'a'", vars={"a": action})
        claim = ("UPDATE approval_action SET state='executing' WHERE action_id = "
                 "(SELECT action_id FROM approval_action WHERE action_id=:'a' "
                 "AND state='approved' AND expires_at > now() "
                 "ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED) "
                 "RETURNING action_id")
        first = rows(DEMO_DB, claim, vars={"a": action})
        second = rows(DEMO_DB, claim, vars={"a": action})
        if len(first) != 1:
            raise Fail("the first claim affected %d row(s)" % len(first))
        if len(second) != 0:
            raise Fail("the SECOND claim of one approval affected %d row(s) -- "
                       "that is a replay" % len(second))
        return "first claim: 1 row, second claim of the same approval: 0 rows"
    ok &= case("P2.4", "NEGATIVE: one approval cannot be claimed twice")(replay)

    def expiry():
        action = p2_probe("p2_expired", state="approved", ttl="-1 minutes")
        claim = ("UPDATE approval_action SET state='executing' WHERE action_id = "
                 "(SELECT action_id FROM approval_action WHERE action_id=:'a' "
                 "AND state='approved' AND expires_at > now() LIMIT 1) "
                 "RETURNING action_id")
        got = rows(DEMO_DB, claim, vars={"a": action})
        if got:
            raise Fail("an EXPIRED approval was claimed")
        state = scalar(DEMO_DB, "SELECT state FROM approval_action "
                                "WHERE action_id=:'a'", vars={"a": action})
        return "an approved-but-expired envelope cannot be claimed (still %r)" % state
    ok &= case("P2.5", "NEGATIVE: an expired approval cannot be claimed")(expiry)

    def tamper():
        # The case under test is what happens AFTER a decision, so the harness
        # records the decision itself here instead of waiting for a human.  The
        # human path is `aistack samples approve`, exercised by W3 below; this
        # is the machine-checkable half.
        #
        # Retire anything already queued first, so the claim inside W3 can only
        # pick the envelope this case created -- see w3_quiesce().
        retired, stranded = w3_quiesce()
        action = scalar(DEMO_DB,
                        "INSERT INTO approval_action (action_id, approver_subject, "
                        "approver_groups, tool, backend_id, config_revision, "
                        "recipient, scope, parameter_hash, expires_at, state) "
                        "SELECT gen_random_uuid(), "
                        "(SELECT value FROM w3_config WHERE key='approver_subject'), "
                        "ARRAY['admins'], 'send_summary', 'n8n-local', 'rev-p2', "
                        "'demo:nobody', '{\"tamper\":true}'::jsonb, "
                        "encode(sha256(convert_to('the approved text','UTF8')),'hex'), "
                        "now() + interval '10 minutes', 'pending' "
                        "RETURNING action_id")
        scalar(DEMO_DB, "INSERT INTO w3_pending_summary (action_id, summary) "
                        "VALUES (:'a', 'the approved text')", vars={"a": action})
        scalar(DEMO_DB, "UPDATE approval_action SET state='approved' "
                        "WHERE action_id=:'a'", vars={"a": action})
        # ...and now somebody changes what was approved.
        scalar(DEMO_DB, "UPDATE w3_pending_summary SET summary='something else' "
                        "WHERE action_id=:'a'", vars={"a": action})
        rc, blob = execute_workflow(W3_ID)
        assert_execution_ok(W3_ID, rc, blob)
        row = one(DEMO_DB, "SELECT state, outcome FROM approval_action "
                           "WHERE action_id=:'a'", vars={"a": action})
        delivered = int(scalar(DEMO_DB, "SELECT count(*) FROM w3_delivered "
                                        "WHERE action_id=:'a'", vars={"a": action}))
        if delivered:
            raise Fail("the tampered summary WAS delivered")
        if (row["state"], row["outcome"]) != ("failed", "refused"):
            raise Fail("the envelope is %r/%r, expected failed/refused"
                       % (row["state"], row["outcome"]))
        path = [r["to_state"] for r in rows(
            DEMO_DB, "SELECT to_state FROM action_transitions WHERE action_id=:'a' "
                     "ORDER BY seq", vars={"a": action})]
        if path != ["approved", "executing", "failed"]:
            raise Fail("transition log reads %s" % path)
        return ("W3 claimed the approval, recomputed the hash over the CHANGED "
                "text, delivered nothing and marked the envelope failed/refused\n"
                "  transition log: pending -> %s\n"
                "  (retired %d queued and %d stranded envelope(s) first so the "
                "claim could only pick this one)"
                % (" -> ".join(path), retired, stranded))
    ok &= case("P2.6", "NEGATIVE: changing the parameters after approval refuses the send")(
        tamper)
    return bool(ok)


# ---------------------------------------------------------------------------
# W3
# ---------------------------------------------------------------------------

def w3_live_envelope():
    return one(DEMO_DB,
               "SELECT action_id, state, expires_at FROM approval_action "
               "WHERE tool='send_summary' AND state IN ('pending','approved','executing') "
               "AND expires_at > now() ORDER BY created_at LIMIT 1")


def w3():
    banner("W3 - scheduled summary behind the approval envelope")
    ok = True

    def bindings():
        bound = workflow_node_credentials(W3_ID)
        missing = [n for n in ("Claim an approved envelope (one row, or nothing)",
                               "Re-read, re-hash, then deliver or refuse",
                               "Yesterday's results",
                               "Request approval (write the envelope FIRST)",
                               "Summarise")
                   if not bound.get(n)]
        if missing:
            raise Fail("these nodes carry no credential: %s" % missing)
        return "%d nodes bound by credential id" % len(bound)
    ok &= case("W3.1", "every W3 node that needs a credential has one")(bindings)

    live = w3_live_envelope()
    if live and live["state"] == "executing":
        # Not a state any code path here leaves behind: the claim and the
        # delivery are one statement each, and the delivery always moves the
        # envelope on.  If one is sitting in `executing` something was killed
        # mid-flight, and the honest outcome is `failed`/`unknown` -- recorded
        # by a person who has decided whether the action happened, not guessed
        # by this harness.
        record("W3.0", "an envelope is stranded in 'executing'", "FAIL",
               "action_id %s is 'executing' with no delivery row. Decide what "
               "actually happened, then record it:\n"
               "  UPDATE approval_action SET state='failed', outcome='unknown' "
               "WHERE action_id='%s';\n"
               "Re-running 'samples run P2' also retires it."
               % (live["action_id"], live["action_id"]))
        return False
    phase = ("dispatch" if live and live["state"] == "approved"
             else "await" if live and live["state"] == "pending"
             else "request")
    recent = int(scalar(DEMO_DB, "SELECT count(*) FROM w3_delivered "
                                 "WHERE delivered_at > now() - interval '20 hours'"))
    if phase == "request" and recent:
        phase = "idle"

    if phase == "request":
        def request():
            rc, blob = execute_workflow(W3_ID)
            assert_execution_ok(W3_ID, rc, blob)
            got = one(DEMO_DB, "SELECT action_id, approver_subject, recipient, "
                               "state, parameter_hash, expires_at "
                               "FROM approval_action WHERE tool='send_summary' "
                               "AND state='pending' ORDER BY created_at DESC LIMIT 1")
            if not got:
                raise Fail("no pending envelope was written:\n%s" % tail(blob))
            summary = one(DEMO_DB, "SELECT summary, "
                                   "encode(sha256(convert_to(summary,'UTF8')),'hex') AS h "
                                   "FROM w3_pending_summary WHERE action_id=:'a'",
                          vars={"a": got["action_id"]})
            if not summary:
                raise Fail("the envelope has no final parameters to hash")
            if summary["h"] != got["parameter_hash"]:
                raise Fail("the stored hash does not cover the stored summary")
            if int(scalar(DEMO_DB, "SELECT count(*) FROM w3_delivered "
                                   "WHERE action_id=:'a'",
                          vars={"a": got["action_id"]})):
                raise Fail("something was DELIVERED without an approval")
            return ("envelope %s is pending for %s (expires %s)\n"
                    "  summary: %d characters, hash verified over exactly that text\n"
                    "  nothing delivered, because nobody has approved anything\n"
                    "  decide it with: aistack samples approve %s"
                    % (got["action_id"], got["approver_subject"],
                       got["expires_at"], len(summary["summary"]),
                       got["action_id"]))
        ok &= case("W3.2", "a run with nothing approved REQUESTS approval and stops")(
            request)
        phase = "await"

    if phase == "await":
        def idempotent():
            before = int(scalar(DEMO_DB, "SELECT count(*) FROM approval_action "
                                         "WHERE tool='send_summary'"))
            rc, blob = execute_workflow(W3_ID)
            assert_execution_ok(W3_ID, rc, blob)
            after = int(scalar(DEMO_DB, "SELECT count(*) FROM approval_action "
                                        "WHERE tool='send_summary'"))
            if after != before:
                raise Fail("a second run while one approval was pending created "
                           "%d more envelope(s)" % (after - before))
            delivered = int(scalar(DEMO_DB, "SELECT count(*) FROM w3_delivered"))
            pending = w3_live_envelope()
            return ("ran again with an approval pending: still %d envelope(s), "
                    "%d delivery row(s)\n  waiting on: aistack samples approve %s"
                    % (after, delivered, pending["action_id"] if pending else "?"))
        ok &= case("W3.3", "a second run does NOT stack a second approval request")(
            idempotent)
        pending = w3_live_envelope()
        record("W3.4", "the human decision is the next step", "INFO",
               "This is where the demo stops without a person.  Approve or "
               "reject it:\n"
               "    bin/aistack samples approve %s\n"
               "    bin/aistack samples approve %s --reject\n"
               "then run 'bin/aistack samples run W3' again to grade the "
               "dispatch." % (pending["action_id"] if pending else "<action-id>",
                              pending["action_id"] if pending else "<action-id>"))

    elif phase == "dispatch":
        def dispatch():
            action = live["action_id"]
            approved = one(DEMO_DB, "SELECT summary FROM w3_pending_summary "
                                    "WHERE action_id=:'a'", vars={"a": action})
            rc, blob = execute_workflow(W3_ID)
            assert_execution_ok(W3_ID, rc, blob)
            row = one(DEMO_DB, "SELECT state, outcome FROM approval_action "
                               "WHERE action_id=:'a'", vars={"a": action})
            if (row["state"], row["outcome"]) != ("executed", "ok"):
                raise Fail("the envelope is %r/%r after dispatch, expected "
                           "executed/ok:\n%s" % (row["state"], row["outcome"],
                                                 tail(blob)))
            got = one(DEMO_DB, "SELECT recipient, summary FROM w3_delivered "
                               "WHERE action_id=:'a'", vars={"a": action})
            if not got:
                raise Fail("the envelope says executed but nothing was delivered")
            if approved and got["summary"] != approved["summary"]:
                raise Fail("what was delivered is not what was approved")
            path = [r["to_state"] for r in rows(
                DEMO_DB, "SELECT to_state FROM action_transitions "
                         "WHERE action_id=:'a' ORDER BY seq", vars={"a": action})]
            if path != ["approved", "executing", "executed"]:
                raise Fail("transition log reads %s" % path)
            second = rows(DEMO_DB,
                          "UPDATE approval_action SET state='executing' "
                          "WHERE action_id=:'a' AND state='approved' "
                          "AND expires_at > now() RETURNING action_id",
                          vars={"a": action})
            if second:
                raise Fail("the executed approval could be claimed again")
            return ("delivered to %r the exact text that was approved\n"
                    "  envelope %s: pending -> %s\n"
                    "  a replay claim after execution affects 0 rows"
                    % (got["recipient"], action, " -> ".join(path)))
        ok &= case("W3.5", "after a human approval the summary is delivered once")(
            dispatch)

    elif phase == "idle":
        def idle():
            before = int(scalar(DEMO_DB, "SELECT count(*) FROM approval_action "
                                         "WHERE tool='send_summary'"))
            rc, blob = execute_workflow(W3_ID)
            assert_execution_ok(W3_ID, rc, blob)
            after = int(scalar(DEMO_DB, "SELECT count(*) FROM approval_action "
                                        "WHERE tool='send_summary'"))
            if after != before:
                raise Fail("a run within 20 hours of a delivery created %d "
                           "envelope(s)" % (after - before))
            return ("today's summary has already been delivered, so the run asks "
                    "for nothing and delivers nothing")
        ok &= case("W3.6", "a run after a delivery neither re-requests nor re-sends")(
            idle)
    return bool(ok)


# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

TARGETS = {"W1": w1, "W2": w2, "W3": w3, "W4": w4, "P2": p2}
ALL_ORDER = ["W1", "W2", "W4", "P2", "W3"]


def cmd_run(argv):
    wanted = [a.upper() for a in argv] or ["ALL"]
    if "ALL" in wanted:
        wanted = list(ALL_ORDER)
    unknown = [w for w in wanted if w not in TARGETS]
    if unknown:
        raise SystemExit("samples: unknown target(s) %s (pick from %s or all)"
                         % (unknown, "/".join(ALL_ORDER)))
    print("AI Stack 2026 - synthetic demo harness")
    print("Every value is synthetic.  Nothing here sends a message to anybody.")
    for name in wanted:
        TARGETS[name]()

    passed = [r for r in RESULTS if r[2] == "PASS"]
    failed = [r for r in RESULTS if r[2] == "FAIL"]
    blocked = [r for r in RESULTS if r[2] == "BLOCKED"]
    deferred = [r for r in RESULTS if r[2] == "DEFERRED"]
    banner("Summary")
    print("  %d passed, %d failed, %d blocked, %d deferred"
          % (len(passed), len(failed), len(blocked), len(deferred)))
    for cid, title, _, _ in failed:
        print("  FAIL     %-6s %s" % (cid, title))
    for cid, title, _, _ in blocked:
        print("  BLOCKED  %-6s %s" % (cid, title))
    for cid, title, _, _ in deferred:
        print("  DEFERRED %-6s %s" % (cid, title))
    if failed:
        return 1
    if blocked:
        print("\n  Nothing FAILED.  A BLOCKED case is an OPEN question: something")
        print("  the demo cannot reach and nobody has yet decided about.")
        return 2
    if deferred:
        # Exit 0, deliberately.  A DEFERRED case is not an open question and
        # not a defect: somebody with the authority to decide looked at it and
        # said no (W2 -> NOM-321, NOM-323).  A release check that goes red for
        # a decision is a release check people start passing with `|| true`.
        # The deferral is still printed, and still counted, on every run.
        print("\n  Complete, with a deferral.  Nothing failed and nothing is")
        print("  blocked; a DEFERRED case is one this release decided not to")
        print("  ship -- the decision and its reason are printed above it.")
        return 0
    return 0


def main():
    argv = sys.argv[1:]
    if not argv:
        raise SystemExit("usage: samples_harness.py {load-corpus|run [W1|W2|W3|W4|P2|all]}")
    if argv[0] == "load-corpus":
        cmd_load_corpus()
        return 0
    if argv[0] == "run":
        return cmd_run(argv[1:])
    raise SystemExit("samples: unknown subcommand %r" % argv[0])


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Fail as exc:          # a setup-time failure, outside any case
        sys.stderr.write("samples: %s\n" % exc)
        sys.exit(1)
    except KeyboardInterrupt:
        # Two things an interrupt inside W4 can leave behind: the throwaway
        # container, and W4's published flag.  The container is removed here
        # because it holds a port and a database connection; the flag is left
        # alone deliberately, since clearing it needs the n8n CLI and racing
        # that against a Ctrl-C is how a half-finished cleanup gets written.
        # `aistack samples run W4` repairs both; so does teardown.
        w4_helper_down()
        sys.stderr.write("samples: interrupted.  If this stopped inside W4, run "
                         "'aistack samples run W4' again to put the demo "
                         "webhook away.\n")
        sys.exit(130)
