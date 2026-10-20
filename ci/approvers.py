#!/usr/bin/env python3
"""Who may sign a security disposition — ONE rule, shared by both registers.

`ci/scan-gate.py` guards security-findings.yaml and `ci/invariants.py` I9 guards
security-exceptions.yaml.  Before NOM-310 each carried its own copy of the
"no agent may approve" rule, and the two copies were not the same rule:

  * Both rejected `PENDING` and both rejected a value matching
    `agent|DevOps Engineer|Engineer \\(agent\\)`.
  * NEITHER REJECTED THE LITERAL STRING "Tech Lead" — an agent in this company.
    So the one agent the registers actually named as reviewer could have signed
    18 entries and passed a control built to stop an agent signing.  That was a
    gap in the check, not a permission.  Found by the DevOps Engineer on
    NOM-301, decided by the board user on NOM-310: KEEP THE RULE, CLOSE THE GAP.
  * A denylist of two role names also accepted any other string at all.
    `approved_by: "the team"` or `"approved"` or `"ok"` passed both checks.

So the rule is now stated once, here, and it has TWO INDEPENDENT HALVES that
must BOTH pass.  Either half alone is defeatable by the party it exists to stop:

  1. NEGATIVE (`agent_identity_hit`) — the value must not name an agent of this
     company.  The roster below is in CODE, so an agent cannot widen it by
     editing a register.  This is the floor.
  2. POSITIVE (`load_approvers` + exact match) — the value must exactly equal a
     name on the `approvers:` list in security-approvers.yaml, and that entry
     must declare `human: true` and cite the issue where a human named them.
     This is what turns "not obviously an agent" into "a specific person".

WHAT THIS MECHANISM DOES NOT ESTABLISH — stated plainly, because a check whose
limits are not written down gets cited for more than it proves:

  * It CANNOT prove the named person consented.  Nothing in a repository can.
    The evidence of consent is the `authority_record` issue each approver entry
    cites, which a human reads.  The check asserts the citation exists, not
    that it says yes.
  * An agent with write access to security-approvers.yaml CAN invent a
    human-looking name and add it.  Half 2 is therefore a consistency control,
    not an authentication control.  What stops that specific move is half 1
    plus the fact that the allowlist is a four-line diff a reviewer sees.  Any
    agent trying it has to put a forged human's name in a tracked file under
    its own commit, which is the kind of evidence this register exists to leave.
  * It says nothing about whether a disposition is CORRECT.  It is a check on
    authority only.

Imported by both gates; has no third-party dependency, because scan-gate.py is
deliberately runnable without PyYAML and this file must not take that away.
"""

import os
import re

# ---------------------------------------------------------------------------
# Half 1 — the agents of this company, which is the set that may NOT approve.
# ---------------------------------------------------------------------------
# Source: GET /api/companies/<Nomad AI>/agents, read 2026-10-20 (NOM-310).
# Names AND titles, because `approved_by` is free text and either form would be
# recognised by a reader as the agent that wrote it.
#
# Add a row when an agent is added.  A roster that silently goes stale is the
# one failure mode of half 1: a NEW agent, not listed here, is caught only by
# the generic markers below and by half 2's allowlist.  That is why half 2 is
# not optional.
AGENT_NAMES = (
    "Tech Lead",
    "Senior Engineer",
    "Full-Stack 1",
    "Full-Stack 2",
    "Full-Stack Engineer",
    "Advisor",
    "CTO Advisor",
    "Skill Scout",
    "Skill Research Specialist",
    "Research Scout",
    "Research and Verification Specialist",
    "QA Engineer",
    "Automation Engineer",
    "AI Engineer",
    "UI/UX Designer",
    "UI/UX Product Designer",
    "Video Editor",
    "Motion Designer",
    "DevOps Engineer",
    "Platform Engineer",
    "Graphic Designer",
    "Modeer",
    "Digital Marketing Manager",
    "Head of Digital",
)

# Generic markers, for an agent this roster has not caught yet.  Deliberately
# NOT in this list: "CEO", "founder", "owner".  The CEO of this company is an
# AGENT named Modeer — but a human founder is also legitimately described as
# CEO, and banning the word would reject the real approver while the roster
# already rejects "Modeer" by name.  Half 2 is what separates those two cases.
AGENT_MARKERS = (
    r"\bagent\b",
    r"\bagents\b",
    r"\bbot\b",
    r"\bassistant\b",
    r"\bclaude\b",
    r"\bllm\b",
    r"\bheartbeat\b",
)

# A string that asks for approval is not an approval [NOM-301].
PENDING_MARKERS = (r"\bpending\b", r"\btbd\b", r"\bunapproved\b", r"\bto be decided\b")

NOT_APPLICABLE = ("n/a", "null", "none", "")

APPROVERS_FILE = "security-approvers.yaml"

# Both registers' headers promise a review window no longer than this.
# security-exceptions.yaml says a "`review_by` date <= 180 days EVEN WHEN THE
# ENTRY IS PERMANENT".  Until NOM-341 nothing asserted it, so the promise was
# prose: both gates checked only whether `review_by` was already PAST, which
# a `review_by: 2099-01-01` passes for the next seventy years.
REVIEW_WINDOW_DAYS = 180


def _norm(s):
    return re.sub(r"\s+", " ", str(s or "")).strip().strip('"').strip("'")


def agent_identity_hit(value):
    """The agent name or marker this value matches, or None.  Half 1."""
    v = _norm(value)
    if not v:
        return None
    for name in AGENT_NAMES:
        if re.search(rf"(?<![A-Za-z]){re.escape(name)}(?![A-Za-z])", v, re.I):
            return name
    for pat in AGENT_MARKERS:
        if re.search(pat, v, re.I):
            return pat
    return None


def pending_hit(value):
    """The pending marker this value matches, or None."""
    v = _norm(value)
    for pat in PENDING_MARKERS:
        if re.search(pat, v, re.I):
            return pat
    return None


def _as_date(value):
    """A `datetime.date` from a register field, or None if it is not one."""
    import datetime
    if isinstance(value, datetime.date):
        return value
    v = _norm(value)
    if v.lower() in NOT_APPLICABLE:
        return None
    try:
        return datetime.date.fromisoformat(v)
    except ValueError:
        return None


def check_review_window(entry_id, approved_at, review_by,
                        max_days=REVIEW_WINDOW_DAYS):
    """The <= 180-day cap, asserted FROM `approved_at`.  Shared by both gates.

    Fails an entry whose window is TOO LONG, which is the half neither gate
    had: a `review_by` far in the future is not "a live review date", it is
    an entry that will never come back for review.  Past-due is a different
    failure and stays with each caller, which already reported it.

    WHAT THIS DOES NOT ESTABLISH, stated because a check whose limits are not
    written down gets cited for more than it proves: with no `approved_at`
    there is no window to measure, so an UNSIGNED entry is not checked here.
    That is not a hole to route around — it is the definition.  The window is
    a property of an approval, and the moment a human writes `approved_at`
    this check goes live on that entry.  Every entry in
    security-findings.yaml is in exactly that state today.
    """
    problems = []
    rb = _as_date(review_by)
    aa = _as_date(approved_at)
    if rb is None:
        return problems               # the caller owns "missing / not a date"
    if aa is None:
        return problems               # unsigned: no window exists yet
    window = (rb - aa).days
    if window > max_days:
        problems.append(
            f"{entry_id}: review_by {rb.isoformat()} is {window} days after "
            f"approved_at {aa.isoformat()} — the register's own header promises "
            f"a window of {max_days} days or less, even for a permanent entry")
    if window < 0:
        problems.append(
            f"{entry_id}: review_by {rb.isoformat()} is BEFORE approved_at "
            f"{aa.isoformat()} — the entry was born past its own review date")
    return problems


def load_approvers(root):
    """(approvers, problems) from security-approvers.yaml.  Half 2.

    Parsed line-wise rather than with PyYAML for the same reason
    `load_dispositions` is: the gate must run on a machine that has only
    python3.  The shape accepted is the one the file uses and no other —
    `approvers:` holding `- name:` entries with `key: value` fields, plus the
    `key: >-` block scalars the prose fields need.  An entry shape this parser
    does not understand is reported as a problem, never skipped: a silently
    dropped approver would make half 2 vacuous, which is the one thing it must
    not be.
    """
    path = os.path.join(root, APPROVERS_FILE)
    if not os.path.isfile(path):
        return [], [f"{APPROVERS_FILE} is missing — no approver is authorised and "
                    f"NO entry in either register can carry an approval"]
    problems, approvers, cur, section, block = [], [], None, "", None
    for lineno, raw in enumerate(open(path, encoding="utf-8"), 1):
        ln = raw.rstrip("\n")
        s = ln.strip()
        # A continuation line of a `key: >-` block scalar, which is indented
        # deeper than the field itself.  Tested BEFORE the comment skip, so a
        # '#' inside prose stays prose.
        if block is not None and (not s or re.match(r"^      \S", ln)):
            if s:
                cur[block] = _norm(cur.get(block, "") + " " + s)
            continue
        block = None
        if not s or s.startswith("#"):
            continue
        m = re.match(r"^([a-z_]+):\s*(.*)$", ln)
        if m:
            section = m.group(1)
            cur = None
            continue
        if section != "approvers":
            continue
        m = re.match(r"^  - ([a-z_]+):\s*(.*)$", ln)
        if m:
            cur = {m.group(1): _norm(m.group(2))}
            approvers.append(cur)
            continue
        m = re.match(r"^    ([a-z_]+):\s*(.*)$", ln)
        if m and cur is not None:
            key, val = m.group(1), _norm(m.group(2))
            if val in (">-", ">", "|", "|-", ""):
                cur[key], block = "", key
            else:
                cur[key] = val
            continue
        problems.append(f"{APPROVERS_FILE}:{lineno}: this line is not a shape the "
                        f"approver parser understands ({s!r}); an approver list "
                        f"that is parsed loosely is not a control")
    for i, a in enumerate(approvers, 1):
        who = a.get("name") or f"entry {i}"
        if not a.get("name"):
            problems.append(f"{APPROVERS_FILE}: approver {i} has no name")
        if _norm(a.get("human")).lower() != "true":
            problems.append(f"{APPROVERS_FILE}: approver {who!r} does not declare "
                            f"human: true — only a human may be on this list")
        if not re.match(r"^NOM-\d+$", _norm(a.get("authority_record"))):
            problems.append(f"{APPROVERS_FILE}: approver {who!r} cites no "
                            f"authority_record issue (NOM-nnn) for who named them")
        hit = agent_identity_hit(a.get("name"))
        if hit:
            problems.append(f"{APPROVERS_FILE}: approver {who!r} matches the agent "
                            f"identity {hit!r} — an agent cannot be authorised to "
                            f"approve by being added to this list")
    return approvers, problems


def authorised_names(approvers):
    return [a["name"] for a in approvers if a.get("name")]


def check_approved_by(entry_id, value, approvers, what="security disposition"):
    """Every problem with this `approved_by`, in the order a reader wants them.

    Returns [] only when the value names a human on the allowlist AND matches
    no agent identity.  `n/a`/`null` is the caller's business, not this check's.
    """
    v = _norm(value)
    if v.lower() in NOT_APPLICABLE:
        return []
    problems = []
    hit = pending_hit(v)
    if hit:
        problems.append(f"{entry_id}: approved_by is still pending ({v!r}) — "
                        f"a request for approval is not an approval")
    hit = agent_identity_hit(v)
    if hit:
        problems.append(f"{entry_id}: approved_by names an agent of this company "
                        f"({v!r} matches {hit!r}) — an agent cannot approve a {what}")
    names = authorised_names(approvers)
    if not any(v.lower() == n.lower() for n in names):
        problems.append(f"{entry_id}: approved_by {v!r} is not an authorised approver "
                        f"in {APPROVERS_FILE} (authorised: {names or 'NOBODY'}) — "
                        f"the value must be exactly the name on that list")
    return problems
