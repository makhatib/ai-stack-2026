-- AI Stack 2026 — the approval envelope (final-design §5.9).
--
-- n8n's native approval does not bind parameters, so the shipped template
-- builds one.  The record is a row here, written BEFORE the approver is
-- prompted, and the execute step re-reads it inside the same transaction that
-- marks it used.
--
-- The transition rule is the part that is easy to get wrong.  A CHECK
-- constraint restricts the VALUE, never the TRANSITION: `CHECK (state IN
-- (...))` is perfectly happy with executed -> pending.  So the allowed edges
-- live in a table, a BEFORE UPDATE trigger rejects any pair absent from it,
-- and every transition appends to an append-only log.

CREATE TABLE IF NOT EXISTS action_state_edges (
    from_state text NOT NULL,
    to_state   text NOT NULL,
    PRIMARY KEY (from_state, to_state)
);

INSERT INTO action_state_edges (from_state, to_state) VALUES
    ('pending',   'approved'),
    ('pending',   'rejected'),
    ('pending',   'expired'),
    ('approved',  'executing'),
    ('approved',  'expired'),
    ('executing', 'executed'),
    ('executing', 'failed')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS approval_action (
    action_id        uuid PRIMARY KEY,

    -- The authenticated Authelia subject, taken from the forward-auth header
    -- the PROXY sets.  Never a value the workflow or the model can supply:
    -- an approval has to name a person, and a model that can name the
    -- approver can approve its own action.
    approver_subject text        NOT NULL,

    -- The groups that subject held AT DECISION TIME.  Authorisation, not just
    -- authentication — and a later group change must not retroactively
    -- authorise an action already approved.
    approver_groups  text[]      NOT NULL,

    tool             text        NOT NULL,
    backend_id       text        NOT NULL,

    -- The agentgateway config revision and the workflow template version.  An
    -- approval granted under one configuration is not valid under a different
    -- one; this is the field the stale-configuration case in P2 moves.
    config_revision  text        NOT NULL,

    -- The external counterparty: the single most important thing a human must
    -- see before approving.
    recipient        text        NOT NULL,

    -- The operation and its bounds.  "Approve" must mean approve THIS.
    scope            jsonb       NOT NULL,

    -- SHA-256 over the canonicalised FINAL parameters.  Mutation after
    -- approval invalidates the decision.
    parameter_hash   text        NOT NULL,

    expires_at       timestamptz NOT NULL,
    state            text        NOT NULL DEFAULT 'pending',
    outcome          text,
    created_at       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT approval_action_state_value
        CHECK (state IN ('pending','approved','executing','executed','failed','expired','rejected')),
    CONSTRAINT approval_action_outcome_value
        CHECK (outcome IS NULL OR outcome IN ('ok','unknown','refused'))
);

-- Single-use is a UNIQUE INDEX on the primary key, which it already is; the
-- replay defence is that `executing` can only be entered FROM `approved`, and
-- only by an UPDATE that affects exactly one row.
CREATE INDEX IF NOT EXISTS approval_action_state_idx ON approval_action (state, expires_at);

CREATE TABLE IF NOT EXISTS action_transitions (
    seq        bigserial PRIMARY KEY,
    action_id  uuid        NOT NULL,
    from_state text,
    to_state   text        NOT NULL,
    at         timestamptz NOT NULL DEFAULT now(),
    detail     jsonb
);

-- Append-only in the sense that matters: nothing in the application has UPDATE
-- or DELETE on it.  Enforced by grant, below, and by a trigger so a future
-- grant mistake does not silently make the log editable.
CREATE OR REPLACE FUNCTION action_transitions_append_only() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'action_transitions is append-only (attempted %)', TG_OP;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS action_transitions_no_update ON action_transitions;
CREATE TRIGGER action_transitions_no_update
    BEFORE UPDATE OR DELETE ON action_transitions
    FOR EACH ROW EXECUTE FUNCTION action_transitions_append_only();

CREATE OR REPLACE FUNCTION approval_action_guard() RETURNS trigger AS $$
BEGIN
    IF NEW.state IS DISTINCT FROM OLD.state THEN
        IF NOT EXISTS (
            SELECT 1 FROM action_state_edges
            WHERE from_state = OLD.state AND to_state = NEW.state
        ) THEN
            RAISE EXCEPTION 'illegal approval transition % -> %', OLD.state, NEW.state;
        END IF;
        INSERT INTO action_transitions (action_id, from_state, to_state)
        VALUES (NEW.action_id, OLD.state, NEW.state);
    END IF;

    -- The envelope is immutable once written.  Rewriting the recipient or the
    -- parameter hash of a pending approval is how one approval becomes an
    -- approval of something else.
    IF NEW.approver_subject IS DISTINCT FROM OLD.approver_subject
       OR NEW.parameter_hash  IS DISTINCT FROM OLD.parameter_hash
       OR NEW.recipient       IS DISTINCT FROM OLD.recipient
       OR NEW.scope           IS DISTINCT FROM OLD.scope
       OR NEW.config_revision IS DISTINCT FROM OLD.config_revision
       OR NEW.tool            IS DISTINCT FROM OLD.tool
       OR NEW.backend_id      IS DISTINCT FROM OLD.backend_id
       OR NEW.expires_at      IS DISTINCT FROM OLD.expires_at THEN
        RAISE EXCEPTION 'approval envelope fields are immutable after creation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS approval_action_transition_guard ON approval_action;
CREATE TRIGGER approval_action_transition_guard
    BEFORE UPDATE ON approval_action
    FOR EACH ROW EXECUTE FUNCTION approval_action_guard();

-- The execute step's one permitted move.  Two concurrent executes cannot both
-- win: the second affects zero rows because the first already left 'approved'.
--
--   UPDATE approval_action
--      SET state = 'executing'
--    WHERE action_id = $1 AND state = 'approved' AND expires_at > now();
--
-- ...and it proceeds ONLY IF one row was affected.
