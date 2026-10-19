-- AI Stack 2026 — the demo schema for W1–W4.
--
-- Applied by `aistack samples setup` into the `aistack_demo` DATABASE, not into
-- any database an application already uses.
--
-- WHY A SEPARATE DATABASE AND ROLE.  The shipped templates write three tables
-- the stack does not otherwise have (`w2_chunks`, `w4_results`) plus the
-- approval envelope.  Three places were available and two are wrong:
--
--   * the `n8n` database — n8n's own operational store.  Demo tables there
--     share a backup, a restore and a migration path with the automation
--     engine's internal state, and `samples teardown` would be deleting
--     tables next to `execution_entity`.
--   * the `aistack` control database — holds `approval_action`, `aistack_slot`
--     and `aistack_fs`.  The `n8n` role has CONNECT but NO TABLE GRANTS there
--     (MEASURED, NOM-302), and granting them so a demo can pass would hand the
--     automation engine write access to the stack's own admission control.
--     That is the wrong trade in the wrong direction.
--   * `aistack_demo`, created here, owned by a role that exists only for the
--     demo and is dropped with it.  `samples teardown` is then DROP DATABASE,
--     which leaves nothing behind to audit.
--
-- The approval envelope in this database is applied FROM THE SHIPPED FILE
-- config/postgres/init/02-approval-envelope.sql, not re-declared here, so the
-- demo exercises the real DDL — the transition-edge table, the append-only
-- transition log and the immutability trigger — rather than a copy of it that
-- could drift.  samples setup applies that file first and this one second.

-- W2's destination, and W1's corpus.  768 dimensions because that is what
-- nomic-embed-text returns (MEASURED, NOM-302); a wrong width here fails at
-- INSERT rather than silently retrieving nonsense.
CREATE TABLE IF NOT EXISTS w2_chunks (
    chunk_id   bigserial PRIMARY KEY,
    source     text        NOT NULL,
    content    text        NOT NULL,
    embedding  vector(768) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- One index, and it is the honest kind for a demo corpus: NONE.  An HNSW index
-- over a few dozen rows is slower than the sequential scan it replaces and
-- would make the demo misreport what pgvector costs at scale.  The query in W1
-- uses the `<->` operator either way, so the operator path is still exercised.
CREATE INDEX IF NOT EXISTS w2_chunks_source_idx ON w2_chunks (source);

-- W4's destination.
CREATE TABLE IF NOT EXISTS w4_results (
    result_id  bigserial PRIMARY KEY,
    prompt     text        NOT NULL,
    answer     text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- W1's evidence.  The demo records the answer NEXT TO the sources it cited,
-- which is the only form in which a citation claim can be re-checked later --
-- and the only form in which `samples run W1` can assert anything about a run
-- a human did in the UI rather than through the harness.
--
-- sources/distances are jsonb rather than text[]/float[] on purpose: they
-- arrive from a Code node as JSON already, and a jsonb round-trip cannot be
-- fooled by a locale that writes decimals with a comma.
CREATE TABLE IF NOT EXISTS w1_runs (
    run_id     bigserial PRIMARY KEY,
    question   text        NOT NULL,
    top_source text        NOT NULL,
    sources    jsonb       NOT NULL,
    distances  jsonb       NOT NULL,
    answer     text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- W3's FINAL PARAMETERS, kept apart from the envelope that hashes them.
--
-- The envelope stores a SHA-256 and nothing else, which is correct: it is the
-- commitment, not the payload.  But a hash can only be re-verified against
-- something, so the text the approver is agreeing to lives here and the
-- delivery step recomputes the digest over THIS ROW inside the same
-- transaction that marks the envelope used.  That is what makes "mutation
-- after approval invalidates the decision" a test rather than a sentence.
CREATE TABLE IF NOT EXISTS w3_pending_summary (
    action_id  uuid PRIMARY KEY REFERENCES approval_action (action_id) ON DELETE CASCADE,
    summary    text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- W3's destination.  A LOCAL TABLE, because nothing in this release sends
-- anything: no mail, no outbound webhook, no message to a person.  "Delivered"
-- means a row landed here.
--
-- UNIQUE (action_id) is the replay defence AT THE DESTINATION, a second one
-- behind the envelope's approved -> executing edge.  One approval cannot
-- become two deliveries even if the state machine is somehow bypassed.
CREATE TABLE IF NOT EXISTS w3_delivered (
    delivery_id  bigserial   PRIMARY KEY,
    action_id    uuid        NOT NULL UNIQUE,
    recipient    text        NOT NULL,
    summary      text        NOT NULL,
    delivered_at timestamptz NOT NULL DEFAULT now()
);

-- THE VALUES THE WORKFLOW IS NOT ALLOWED TO CHOOSE.
--
-- A workflow that can name its own approver can approve itself, so W3 reads
-- the intended approver, the recipient and the config revision from here
-- rather than holding them in a Set node.  In the deployed stack these come
-- from the agentgateway config revision and the decision carries Authelia's
-- Remote-User, which the PROXY sets; `aistack samples setup` writes the demo
-- equivalents and `aistack samples approve` refuses to act for any subject
-- other than the one recorded here.
CREATE TABLE IF NOT EXISTS w3_config (
    key   text PRIMARY KEY,
    value text NOT NULL
);

-- W1's question source.  The template used to open on an HTTP embedding
-- request whose `$json.question` came from an empty manual trigger, so the
-- first node embedded `undefined` (FOUND BY QA, NOM-302).  The question now
-- lives in the workflow itself as a Set node; this table records the ones the
-- harness asserts against, so `docs/samples.md` and the assertions cannot
-- drift apart silently.
CREATE TABLE IF NOT EXISTS w1_expected (
    question       text NOT NULL PRIMARY KEY,
    expect_source  text NOT NULL
);

INSERT INTO w1_expected (question, expect_source) VALUES
    ('How does retrieval-augmented generation find the right chunk of a document?',
     '02-retrieval.md')
ON CONFLICT (question) DO UPDATE SET expect_source = EXCLUDED.expect_source;
