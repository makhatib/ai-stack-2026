#!/usr/bin/env python3
"""AI Stack 2026 — the CI invariants (final-design §5.10).

Computed statically from `docker compose config --no-interpolate` and from
manifest.yaml, so they fail the PR rather than the viewer's install.

Run:  python3 ci/invariants.py [--root .]
Exit: 0 all pass, 1 one or more fail.

An invariant that CI cannot pass is not a control; it is a note.  Every check
below runs against this repository as it stands.
"""

import argparse
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import approvers  # noqa: E402  — the approval-authority rule, shared with the scan gate
import pins as pinfile  # noqa: E402  — the committed pins, shared with the scan gate

try:
    import yaml
except ImportError:
    print("FATAL: PyYAML is required to run the invariants.", file=sys.stderr)
    sys.exit(2)

FAILURES = []
RESULTS = []

SHIPPED_SCOPES = ("mvp", "v2")


def check(ident, title):
    def deco(fn):
        def run(ctx):
            try:
                problems = fn(ctx) or []
            except Exception as e:  # a check that errors is a check that failed
                problems = [f"the check itself raised {e!r}"]
            if problems:
                FAILURES.append(ident)
                RESULTS.append((ident, "FAIL", title, problems))
            else:
                RESULTS.append((ident, "pass", title, []))
        run.ident = ident
        return run
    return deco


# ---------------------------------------------------------------------------
# Context
# ---------------------------------------------------------------------------

class Ctx:
    def __init__(self, root):
        self.root = root
        with open(os.path.join(root, "manifest.yaml")) as fh:
            self.manifest = yaml.safe_load(fh)
        # --no-interpolate so a missing .env cannot make an invariant vacuous.
        out = subprocess.run(
            ["docker", "compose", "config", "--no-interpolate", "--format", "json"],
            cwd=root, capture_output=True, text=True,
        )
        if out.returncode != 0:
            raise SystemExit("docker compose config failed:\n" + out.stderr)
        self.compose = json.loads(out.stdout)
        self.services = self.compose.get("services") or {}
        self.networks = self.compose.get("networks") or {}

    def mvp_services(self):
        """Every SHIPPED service: the MVP's and v2's.

        The name is historical — the checks below were written for `scope: mvp`
        and v2 (NOM-413) adds `scope: v2` to the same set rather than forking
        every predicate.  `later` and `1.0` stay out, exactly as before.
        """
        return {k: v for k, v in (self.manifest.get("services") or {}).items()
                if v.get("scope") in SHIPPED_SCOPES}

    def bridge(self, name):
        return (self.manifest.get("bridges") or {}).get(name) or {}

    def release_surfaces(self):
        """The copy surfaces I12 scans, read from release-manifest.txt.

        DERIVED from the manifest file and scanned regardless of path; that
        scan takes precedence over every path exclusion.
        """
        path = os.path.join(self.root, "release-manifest.txt")
        out = []
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#"):
                out.append(line)
        return out

    def shipped_files(self):
        """The release manifest's surfaces (I6, I12).

        Derived, not listed: everything git tracks, minus the directories the
        release manifest excludes.  `docs/decisions/**` must appear nowhere.
        """
        out = subprocess.run(["git", "ls-files"], cwd=self.root,
                             capture_output=True, text=True)
        files = [f for f in out.stdout.splitlines() if f.strip()]
        return [f for f in files if not f.startswith("docs/decisions/")]


# ---------------------------------------------------------------------------
# The invariants
# ---------------------------------------------------------------------------

@check("I1", "confinement: every `confined: true` service is pairwise and class-pure")
def i1(ctx):
    bad = []
    for name, svc in ctx.mvp_services().items():
        if not svc.get("confined"):
            continue
        nets = svc.get("networks") or []
        classes = {ctx.bridge(n).get("class") for n in nets}
        if len(classes) != 1:
            bad.append(f"{name} spans bridge classes {sorted(classes)}; confined services must be class-pure")
        csvc = ctx.services.get(name) or {}
        if csvc.get("ports"):
            bad.append(f"{name} declares ports and is confined")
        for n in nets:
            b = ctx.bridge(n)
            if b.get("class") == "egress":
                bad.append(f"{name} attaches to the egress-class bridge {n}")
            members = b.get("members") or []
            if len(members) != 2:
                bad.append(f"{name} sits on bridge {n} with {len(members)} members; confined services need exactly two")
            if b.get("zone_policy") != "contained" and svc.get("class") != "untrusted-fetch":
                bad.append(f"{name} sits on {n} whose zone_policy is {b.get('zone_policy')}, and its own class is not untrusted-fetch")
    return bad


@check("I1b", "trust_bridges is an EQUALITY, not a lookup")
def i1b(ctx):
    computed = set()
    for name, svc in ctx.mvp_services().items():
        classes = {ctx.bridge(n).get("class") for n in (svc.get("networks") or [])}
        classes.discard(None)
        if len(classes) > 1:
            computed.add(name)
    registered = {e["service"] for e in (ctx.manifest.get("trust_bridges") or [])}
    # Only compare over MVP services: the register also carries entries whose
    # services are deferred, and those are checked by scope, not by this set.
    registered_mvp = {s for s in registered if s in ctx.mvp_services()}
    bad = []
    for s in sorted(computed - registered_mvp):
        bad.append(f"{s} crosses trust classes but is NOT in trust_bridges (unlisted crosser)")
    for s in sorted(registered_mvp - computed):
        bad.append(f"{s} is in trust_bridges but no longer crosses a class (stale entry)")
    for e in (ctx.manifest.get("trust_bridges") or []):
        for field in ("reason", "controls", "reviewer"):
            if not e.get(field):
                bad.append(f"trust_bridges entry {e.get('service')} is missing '{field}'")
    return bad


@check("I2", "no service except caddy declares a `ports:` key")
def i2(ctx):
    bad = []
    for name, svc in ctx.services.items():
        if svc.get("ports") and name != "caddy":
            bad.append(f"{name} declares ports")
    # And caddy's must not be a wildcard bind.
    #
    # Under --no-interpolate a port is still a STRING ("${VAR}:443:443"), not
    # the parsed mapping compose produces once variables are resolved, so this
    # handles both shapes rather than assuming the richer one.
    for p in (ctx.services.get("caddy") or {}).get("ports") or []:
        if isinstance(p, dict):
            host_ip = p.get("host_ip")
            published = p.get("published")
        else:
            parts = str(p).split(":")
            host_ip = parts[0] if len(parts) >= 3 else None
            published = parts[-2] if len(parts) >= 2 else None
        if host_ip in (None, "", "0.0.0.0", "::"):
            bad.append(f"caddy publishes {published} on a WILDCARD address ({host_ip!r})")
        elif "${" in str(host_ip) and "AISTACK_BIND_ADDR" not in str(host_ip):
            bad.append(f"caddy's bind address comes from an unexpected variable: {host_ip}")
    return bad


@check("I3", "service count per profile matches the manifest; no helper restarts")
def i3(ctx):
    bad = []
    declared = (ctx.manifest.get("counts") or {}).get("steady_state", {}).get("v2")
    actual = len(ctx.mvp_services())
    if declared != actual:
        bad.append(f"manifest declares steady_state.v2={declared} but lists {actual} shipped services")

    # Rendered compose: core has no profile key; every other group is a profile.
    # Each manifest profile is checked against ITS OWN groups, so a service in
    # the wrong group — or a group whose profile key is not what compose
    # declares — fails here rather than at somebody's install.
    core = [n for n, s in ctx.services.items() if not s.get("profiles")]
    by_profile = {}
    for n, s in ctx.services.items():
        for p in s.get("profiles") or []:
            by_profile.setdefault(p, set()).add(n)
    groups = ctx.manifest.get("groups") or {}
    for pname, prof in (ctx.manifest.get("profiles") or {}).items():
        if prof.get("scope") == "1.0":
            continue
        want = len(core)
        for g in prof.get("groups") or []:
            key = (groups.get(g) or {}).get("profile_key", g)
            if key is None:
                continue
            want += len(by_profile.get(key, ()))
        if prof.get("containers") != want:
            bad.append(f"profile {pname!r} declares {prof.get('containers')} containers; "
                       f"compose renders {want} for groups {prof.get('groups')}")
    # And the manifest's group membership must be what compose says.
    for g, grp in groups.items():
        if grp.get("scope") not in SHIPPED_SCOPES:
            continue
        key = grp.get("profile_key", g)
        for svc in grp.get("services") or []:
            cs = ctx.services.get(svc)
            if cs is None:
                bad.append(f"group {g} lists {svc}, which compose does not define")
                continue
            have = cs.get("profiles") or []
            if key is None and have:
                bad.append(f"{svc} is in core but compose gives it profiles {have}")
            if key is not None and key not in have:
                bad.append(f"{svc} is in group {g} (profile {key}) but compose gives it profiles {have}")

    for h in (ctx.manifest.get("helpers") or {}):
        svc = ctx.services.get(h)
        if svc and svc.get("restart") == "unless-stopped":
            bad.append(f"helper {h} declares restart: unless-stopped, which would let it be counted as steady state")

    peak = (ctx.manifest.get("counts") or {}).get("peak", {}).get("v2")
    if peak != actual + 1:
        bad.append(f"peak ({peak}) must equal steady_state ({actual}) + the helper lock's ceiling of 1")
    return bad


@check("I4", "every image carries a tag AND a digest, resolvable from committed versions.env")
def i4(ctx):
    """Two assertions, because one of them can pass vacuously.

    STATICALLY (--no-interpolate) the reference must have the fail-closed
    SHAPE: a tag variable, an `@`, a digest variable, and a `:?` guard on each
    so a missing pin fails rather than silently resolving to :latest.

    RESOLVED against the COMMITTED `versions.env` every reference must end in a
    real sha256.  The shape check alone would pass a repo whose versions.env is
    empty, and the resolved check alone would pass a repo that hard-codes
    digests with no guard, so neither is sufficient by itself.

    Resolution deliberately does NOT go through `docker compose config
    --images`.  Measured 2026-10-18: on a clean clone of the tip that command
    exits non-zero with

        required variable AISTACK_HOSTNAME is missing a value

    because --images interpolates the OPERATOR's `.env`, which a fresh
    checkout does not have.  So CI was red on a clean clone and green on the
    build host -- the one place its answer did not matter.  And when it did
    run it proved the local machine's pins, not the committed ones.  Reading
    versions.env is both clone-clean and the stronger claim: it is the file a
    reviewer actually diffs when a pin moves.
    """
    bad = []
    vpath = os.path.join(ctx.root, "versions.env")
    if not os.path.isfile(vpath):
        return ["versions.env is absent, so no committed pin could be resolved"]
    pins = {}
    with open(vpath) as fh:
        for line in fh:
            m = re.match(r"^([A-Z0-9_]+)=(.*)$", line.strip())
            if m:
                pins[m.group(1)] = m.group(2)

    def resolve(name, img):
        """Substitute ${VAR}, ${VAR:?msg} and ${VAR:-default} from versions.env."""
        missing = []

        def sub(m):
            var, op, arg = m.group(1), m.group(2), m.group(3)
            if pins.get(var):
                return pins[var]
            if op == ":-":
                return arg
            missing.append(var)
            return "<unset:%s>" % var

        out = re.sub(r"\$\{([A-Z0-9_]+)(:\?|:-)?([^}]*)\}", sub, img)
        for var in missing:
            bad.append(f"{name}: {var} has no value in the committed versions.env")
        return out

    for name, svc in ctx.services.items():
        # A service this repository BUILDS (mem0, mcp-web) has no registry
        # digest of its own: its identity is a function of its build context.
        # What must be pinned is everything the build starts from, so the
        # assertion moves there: the BASE arg is tag AND digest, guarded, and
        # resolves to a sha256; the Python deps carry a hash for every wheel.
        if svc.get("build"):
            b = svc["build"]
            base = ((b.get("args") or {}) if isinstance(b, dict) else {}).get("BASE") or ""
            if "@" not in base or ":?" not in base or "DIGEST" not in base:
                bad.append(f"{name}: build BASE is not a guarded tag@digest reference: {base!r}")
            else:
                rb = resolve(name, base)
                if not re.search(r"@sha256:[0-9a-f]{64}$", rb):
                    bad.append(f"{name}: build BASE does not resolve to a sha256: {rb}")
            ctxdir = b.get("context") if isinstance(b, dict) else b
            lock = os.path.join(ctx.root, ctxdir or "", "requirements.lock")
            # A build that installs nothing with pip has no wheels to hash
            # (build/docling-arabic adds one checksummed file; I19 checks it).
            dfile = os.path.join(ctx.root, ctxdir or "", "Dockerfile")
            uses_pip = os.path.isfile(dfile) and "pip install" in open(dfile).read()
            if not uses_pip:
                pass
            elif not os.path.isfile(lock):
                bad.append(f"{name}: {ctxdir}/requirements.lock is missing")
            else:
                text = open(lock).read()
                n_req = len(re.findall(r"(?m)^[A-Za-z0-9_.\-\[\]]+==", text))
                n_hash = len(re.findall(r"--hash=sha256:[0-9a-f]{64}", text))
                if n_req == 0 or n_hash < n_req:
                    bad.append(f"{name}: requirements.lock has {n_req} pins but {n_hash} hashes")
            if (svc.get("pull_policy") or "") != "never":
                bad.append(f"{name}: a locally built image must say pull_policy: never, or compose may pull a same-named image from a registry")
            continue
        img = svc.get("image") or ""
        if "@" not in img:
            bad.append(f"{name}: image reference has no digest component: {img}")
        if ":?" not in img:
            bad.append(f"{name}: image reference has no `:?` fail-closed guard: {img}")
        if "${" in img and "DIGEST" not in img:
            bad.append(f"{name}: templated reference does not interpolate a DIGEST variable: {img}")
        resolved = resolve(name, img)
        if not re.search(r"@sha256:[0-9a-f]{64}$", resolved):
            bad.append(f"resolved image is not digest-pinned: {resolved}")
    return bad


@check("I5", "no sites.d/ template for any never-publishable service; no wildcard n8n route")
def i5(ctx):
    bad = []
    sites = os.path.join(ctx.root, "config", "caddy", "sites.d")
    never = set((ctx.manifest.get("publish") or {}).get("never") or [])
    blob = ""
    for f in sorted(os.listdir(sites)) if os.path.isdir(sites) else []:
        blob += open(os.path.join(sites, f)).read()
    # A reverse_proxy to a never-publishable service name is the failure.
    for target in never:
        base = target.replace("-admin-ui", "").replace("-admin-endpoint", "")
        base = base.replace("n8n-editor", "n8n").replace("n8n-rest-api", "n8n")
        if re.search(rf"reverse_proxy\s+{re.escape(base)}:", blob) and base not in ("n8n",):
            bad.append(f"a sites.d/ route proxies to never-publishable service '{base}'")
    for pattern in ("/n8n/rest/", "/n8n/webhook-test/", "/n8n/form/"):
        if f"handle {pattern}" in blob:
            bad.append(f"a sites.d/ route HANDLES {pattern}, which must only ever be denied")
    if "@n8n_forbidden" not in blob:
        bad.append("no explicit deny matcher for n8n's editor/REST/webhook-test/form routes")
    return bad


@check("I6", "no docker.sock, privileged, host namespace, --no-sandbox, set -x, or banned string")
def i6(ctx):
    bad = []
    for name, svc in ctx.services.items():
        for v in svc.get("volumes") or []:
            src = v.get("source") if isinstance(v, dict) else str(v)
            if src and "docker.sock" in str(src):
                bad.append(f"{name} mounts the Docker socket")
        if svc.get("privileged"):
            bad.append(f"{name} is privileged")
        for key in ("network_mode", "pid", "ipc"):
            val = svc.get(key)
            if val and str(val).startswith("host"):
                bad.append(f"{name} shares the host {key}")

    banned = [l.strip() for l in open(os.path.join(ctx.root, "strings", "banned.txt"))
              if l.strip() and not l.startswith("#")]
    # The checker and its data files necessarily CONTAIN the strings they
    # search for.  Excluding exactly those two, by name, is not a loophole —
    # any other file that mentions them still fails, and a new exclusion would
    # have to be added here in a reviewed diff.
    SELF = {"ci/invariants.py", "strings/banned.txt"}
    for f in ctx.shipped_files():
        if f in SELF:
            continue
        path = os.path.join(ctx.root, f)
        if not os.path.isfile(path):
            continue
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except Exception:
            continue
        if "--no-sandbox" in text:
            bad.append(f"{f} contains --no-sandbox")
        for phrase in banned:
            if re.search(rf"\b{re.escape(phrase)}\b", text, re.I):
                bad.append(f"{f} contains the banned assurance string {phrase!r}")

    # THE GATE MUST NOT BE ABLE TO COMMIT ITS OWN OUTPUT [NOM-301].  The
    # .gitignore entry for gate.json was added in 4345e96 and silently removed
    # in f98b0c6, which rewrote the tail of that file for an unrelated change.
    # Nothing noticed, because the entry was a line in a file rather than a
    # condition anything checked.  I6 is the right home: committing scan output
    # is what turned I6 red on a clean clone once already.
    ign = subprocess.run(["git", "check-ignore", "-q", "gate.json"], cwd=ctx.root,
                         capture_output=True, text=True)
    if ign.returncode == 1:
        bad.append("gate.json is not git-ignored — `ci/scan-gate.py` writes it into "
                   "the repo root by default, so running the gate dirties the tree "
                   "and any `git add -A` can commit scan output")
    elif ign.returncode != 0:
        bad.append(f"could not ask git whether gate.json is ignored "
                   f"(git check-ignore exited {ign.returncode}); this check is "
                   f"UNKNOWN, not passing")
    return bad


def _exceptions_exist(ctx, ids):
    path = os.path.join(ctx.root, "security-exceptions.yaml")
    if not os.path.exists(path):
        return False
    have = {e.get("id") for e in (yaml.safe_load(open(path)) or {}).get("exceptions") or []}
    return all(i in have for i in ids)


@check("I7", "no untrusted_input service on egress, or on ANY bridge with internal: false")
def i7(ctx):
    bad = []
    # UNQUALIFIED ACROSS PROFILES (rev 10): every SHIPPED profile, not only the
    # Tier-A-installable ones.  The old form was qualified "in any
    # Tier-A-installable profile"; that qualifier is deleted.
    #
    # `later` entries are excluded, and that is the faithful reading rather
    # than a weakening.  The deferred `web` services sit on nat_egress bridges
    # BY DESCRIPTION — that topology is precisely why they were deferred — and
    # they are in NO PROFILE, so "in any profile at all" does not reach them.
    # Including them would make this invariant unpassable while the manifest
    # keeps the deferred rows that I8 and I11 deliberately retain at full
    # width.  The day `web` returns, its scope changes to 1.0 and this check
    # starts failing until its bridges are redesigned — which is the
    # reintroduction gate working, not a hole.
    for name, svc in (ctx.manifest.get("services") or {}).items():
        if svc.get("scope") == "later":
            continue
        if svc.get("untrusted_input") != True and svc.get("untrusted_input") != "yes":
            continue
        for n in svc.get("networks") or []:
            b = ctx.bridge(n)
            if b.get("class") == "egress":
                bad.append(f"{name} has untrusted_input and attaches to egress-class bridge {n}")
            if b.get("internal") is False:
                # THE ONE SANCTIONED SHAPE (v2, NOM-413): a web fetcher must reach
                # the internet to do its job, so it sits on an untrusted-fetch
                # bridge that is PAIRWISE with its single caller.  Allowed only
                # when ALL of: the bridge class is untrusted-fetch; it has exactly
                # two members; it has a fixed subnet and no IPv6; the service is
                # in that bridge's member list; and the service cites an exception
                # id that exists in security-exceptions.yaml.  Anything else on a
                # NAT'd bridge still fails.
                ok = (b.get("class") == "untrusted-fetch"
                      and b.get("pairwise") is True
                      and len(b.get("members") or []) == 2
                      and name in (b.get("members") or [])
                      and b.get("subnet") and b.get("ipv6") is False
                      and bool(svc.get("exception_ids"))
                      and _exceptions_exist(ctx, svc.get("exception_ids")))
                if not ok:
                    bad.append(f"{name} has untrusted_input and attaches to {n}, which is internal: false "
                               f"(and is not a pairwise untrusted-fetch bridge backed by a registered exception)")
    return bad


@check("I8", "parse/untrusted-*/egress bridges declare a fixed subnet and ipv6: false")
def i8(ctx):
    bad = []
    # The class list is deliberately NOT shortened: untrusted-fetch and
    # untrusted-exec have no members here, and the predicate must already be in
    # force on the day a deferred bridge returns.
    classes = {"parse", "untrusted-fetch", "untrusted-exec", "egress"}
    for name, b in (ctx.manifest.get("bridges") or {}).items():
        if b.get("class") not in classes:
            continue
        if b.get("scope") == "later":
            if not b.get("subnet"):
                bad.append(f"deferred bridge {name} has no reserved subnet; it must return at the same address")
            continue
        if not b.get("subnet"):
            bad.append(f"{name} (class {b.get('class')}) declares no fixed subnet")
        if b.get("ipv6") is not False:
            bad.append(f"{name} does not declare ipv6: false")
    return bad


def _exception_digest_binding(ctx, e):
    """An exception's recorded `digest:` must still be the pinned digest.

    security-exceptions.yaml's header promises CI fails an entry "that records
    a digest that no longer matches the pin — a change invalidates its own
    evidence rather than inheriting it".  Until NOM-341 NO CODE DID THAT, and
    the claim was load-bearing: E7's capability set was bisected against a
    Debian 12 pgvector digest, and NOM-341 moves that pin to Debian 13.  With
    no binding, the swap would have left a Debian 12 bisection sitting under a
    Debian 13 image, reading as approved evidence.

    An entry with no `digest:` records no evidence to invalidate and is not
    checked.  An entry WITH one whose service does not resolve to a pin is a
    digest that CANNOT be checked, and that fails — a binding that silently
    skips what it cannot resolve is not a binding.
    """
    bad = []
    dig = str(e.get("digest") or "").strip()
    if not dig:
        return bad
    eid = f"exception {e.get('id')}"
    if not re.match(r"^sha256:[0-9a-f]{64}$", dig):
        return [f"{eid}: digest {dig!r} is not a sha256 digest"]
    svcs = e.get("service")
    svcs = svcs if isinstance(svcs, list) else [svcs]
    try:
        pins = pinfile.read_pins(os.path.join(ctx.root, "versions.env"))
    except OSError as exc:
        return [f"{eid}: cannot read versions.env to bind the digest ({exc})"]
    resolved, unresolved = {}, []
    for s in svcs:
        key = pinfile.pin_key(s)
        if key in pins:
            resolved[key] = pins[key]["DIGEST"]
        else:
            unresolved.append(f"{s!r} (looked for {key}_DIGEST)")
    if unresolved:
        bad.append(f"{eid}: records a digest but its service(s) "
                   f"{', '.join(unresolved)} resolve to no pin in versions.env "
                   f"— the digest cannot be bound, so the evidence cannot be "
                   f"confirmed to still apply")
    if resolved and dig not in resolved.values():
        bad.append(f"{eid}: records digest {dig} which is NOT the pinned digest "
                   f"for its service(s) " +
                   ", ".join(f"{k}={v}" for k, v in sorted(resolved.items())) +
                   " — the pin moved, so this entry's evidence was measured "
                   f"against a different image and does NOT carry over")
    return bad


@check("I9", "web-search flags false in EVERY profile; exceptions register complete")
def i9(ctx):
    bad = []
    owui = (ctx.services.get("open-webui") or {}).get("environment") or {}
    for flag in ("ENABLE_WEB_SEARCH", "ENABLE_RAG_WEB_SEARCH"):
        if str(owui.get(flag)).lower() not in ("false", "0"):
            bad.append(f"open-webui {flag} is {owui.get(flag)!r}, must be false in every shipped profile")
    exc = os.path.join(ctx.root, "security-exceptions.yaml")
    if not os.path.exists(exc):
        bad.append("security-exceptions.yaml is missing")
        return bad
    reg = yaml.safe_load(open(exc)) or {}
    APPROVERS, approver_problems = approvers.load_approvers(ctx.root)
    bad.extend(approver_problems)
    import datetime
    today = datetime.date.today()
    for e in reg.get("exceptions") or []:
        if e.get("scope") == "deferred":
            continue
        for field in ("approved_by", "approved_at", "review_by"):
            if not e.get(field):
                bad.append(f"exception {e.get('id')} is missing {field}")
        # PRESENCE IS NOT APPROVAL.  This check used to accept any non-empty
        # `approved_by`, so the agent-authored string
        #   "DevOps Engineer (NOM-258), pending Tech Lead review"
        # satisfied it — the register recorded its own author as the approver
        # and CI called that complete [NOM-301].  It was then tightened to
        # reject `pending` and two agent role names, and STILL accepted the
        # literal "Tech Lead" [NOM-310].  The rule now lives in one place,
        # ci/approvers.py, shared with ci/scan-gate.py, so the two registers
        # are held to one standard instead of the weaker of two — and it has a
        # positive half: the value must be a name on security-approvers.yaml,
        # not merely a string that fails to look like an agent.
        bad.extend(approvers.check_approved_by(
            f"exception {e.get('id')}", e.get("approved_by"),
            APPROVERS, "security exception"))
        rb = e.get("review_by")
        if rb:
            d = rb if isinstance(rb, datetime.date) else datetime.date.fromisoformat(str(rb))
            if d < today:
                bad.append(f"exception {e.get('id')} is past its review_by ({rb})")
        # THE <= 180-DAY CAP, which this file's header promises and nothing
        # asserted before NOM-341.  The past-due check above is not it: a
        # `review_by: 2099-01-01` is not past due and never will be, so an
        # entry could promise a review window it had no intention of keeping.
        # Measured from `approved_at`, in the shared rule, so the findings
        # register is held to the same cap the moment it is signed.
        bad.extend(approvers.check_review_window(
            f"exception {e.get('id')}", e.get("approved_at"), rb))
        # THE DIGEST BINDING, likewise promised in this file's header and
        # likewise unenforced before NOM-341.
        bad.extend(_exception_digest_binding(ctx, e))
    return bad


@check("I10", "the gating machinery is ABSENT (inverted invariant)")
def i10(ctx):
    bad = []
    forbidden_units = ["aistack-enforce.service", "aistack-enforce.timer",
                       "aistack-stop-gated.service"]
    for f in ctx.shipped_files():
        base = os.path.basename(f)
        if base in forbidden_units:
            bad.append(f"{f} exists; revision 10 withdrew the policy-loss contract")
        if re.match(r"aistack-group@.*\.service$", base):
            bad.append(f"{f} is an aistack-group@*.service unit")
        path = os.path.join(ctx.root, f)
        if os.path.isfile(path):
            try:
                text = open(path, encoding="utf-8", errors="replace").read()
            except Exception:
                continue
            if "/run/aistack/firewall.deadline" in text and "ci/invariants.py" not in f:
                bad.append(f"{f} references /run/aistack/firewall.deadline")

    for name, svc in ctx.services.items():
        r = svc.get("restart")
        if r != "unless-stopped":
            bad.append(f"{name} declares restart: {r!r}; only the restore-drill project may differ")
        labels = svc.get("labels") or {}
        keys = labels.keys() if isinstance(labels, dict) else labels
        for k in keys:
            if "aistack.gated" in str(k):
                bad.append(f"{name} carries the aistack.gated label")
    return bad


@check("I11", "every bridge's internal: flag equals what its own zone_policy mandates")
def i11(ctx):
    mandate = {"contained": True, "published": False, "nat_egress": False, "forwarding": False}
    bad = []
    for name, b in (ctx.manifest.get("bridges") or {}).items():
        zp = b.get("zone_policy")
        if zp not in mandate:
            bad.append(f"{name} has unknown zone_policy {zp!r}")
            continue
        if b.get("internal") is not mandate[zp]:
            bad.append(f"{name}: zone_policy {zp} mandates internal: {mandate[zp]}, manifest says {b.get('internal')}")

    # And the RENDERED compose must agree with the manifest.
    for name, net in ctx.networks.items():
        b = ctx.bridge(name)
        if not b:
            continue
        want = mandate.get(b.get("zone_policy"))
        got = net.get("internal", False)
        if want is not None and bool(got) != want:
            bad.append(f"compose network {name}: internal is {got}, zone_policy {b.get('zone_policy')} mandates {want}")
    return bad


@check("I12", "canonical local-mode copy: one region per surface, byte-equal, token scan outside")
def i12(ctx):
    bad = []
    canon = open(os.path.join(ctx.root, "strings", "local-mode.txt")).read().strip()
    tokens = [l.strip() for l in open(os.path.join(ctx.root, "strings", "exposure-tokens.txt"))
              if l.strip() and not l.startswith("#")]
    allow = set()
    for l in open(os.path.join(ctx.root, "strings", "exposure-allowlist.txt")):
        if l.strip() and not l.startswith("#") and "|" in l:
            allow.add(l.split("|", 2)[-1].strip())

    surfaces = ctx.release_surfaces()

    for f in surfaces:
        path = os.path.join(ctx.root, f)
        if not os.path.isfile(path):
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        begins = text.count("AISTACK-LOCAL-MODE:BEGIN")
        ends = text.count("AISTACK-LOCAL-MODE:END")
        if begins != ends:
            bad.append(f"{f}: unbalanced local-mode region markers")
            continue
        if begins == 0:
            continue
        if begins != 1:
            bad.append(f"{f}: {begins} local-mode regions; exactly one is allowed")
            continue
        m = re.search(r"AISTACK-LOCAL-MODE:BEGIN(.*?)AISTACK-LOCAL-MODE:END", text, re.S)
        inner = m.group(1)
        # Strip the comment leader each surface uses, then compare bytes.
        stripped = "\n".join(
            re.sub(r"^\s*(#|<!--|-->|//)\s?", "", ln).rstrip()
            for ln in inner.splitlines()
        ).strip()
        stripped = stripped.replace("-->", "").strip()
        if stripped != canon:
            bad.append(f"{f}: the local-mode region does not equal strings/local-mode.txt")

    # Token scan OUTSIDE any region, over the declared copy surfaces.
    for f in surfaces:
        path = os.path.join(ctx.root, f)
        if not os.path.isfile(path):
            continue
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except Exception:
            continue
        outside = re.sub(r"AISTACK-LOCAL-MODE:BEGIN.*?AISTACK-LOCAL-MODE:END", "", text, flags=re.S)
        for i, line in enumerate(outside.splitlines(), 1):
            s = line.strip()
            if not s or s in allow:
                continue
            for t in tokens:
                # A trailing `*` is a PREFIX token; anything else must match
                # as a whole word.  Without that distinction `LAN` reports
                # `$$ LANGUAGE plpgsql;` and "language models" as exposure
                # claims — measured, not hypothetical — and a token list that
                # cries wolf gets allowlisted into uselessness, which is the
                # failure mode F23 already warns about.
                if t.endswith("*"):
                    pat = rf"\b{re.escape(t[:-1])}\w*"
                else:
                    pat = rf"\b{re.escape(t)}\b"
                if re.search(pat, s, re.I):
                    bad.append(f"{f}:{i} matches exposure token {t!r} outside a region and is not allowlisted: {s[:90]}")
                    break
    return bad


@check("I12e", "docs/decisions/** appears nowhere in the release manifest")
def i12e(ctx):
    """What makes docs/decisions/ non-shipping a CHECKED FACT, not an intention.

    A shipped file placed there fails this assertion rather than escaping the
    string check by sitting under an excluded path.
    """
    bad = [f"{f} is listed in release-manifest.txt but lives under docs/decisions/"
           for f in ctx.release_surfaces() if f.startswith("docs/decisions/")]
    # Every declared surface must actually exist, or the scan is vacuous for it.
    for f in ctx.release_surfaces():
        if not os.path.isfile(os.path.join(ctx.root, f)):
            bad.append(f"release-manifest.txt lists {f}, which does not exist — "
                       f"I12 would pass vacuously for it")
    return bad


@check("I13", "writer-scope containment over every byte-accepting ingress")
def i13(ctx):
    bad = []
    limits_path = os.path.join(ctx.root, "limits.yaml")
    if not os.path.exists(limits_path):
        bad.append("limits.yaml is missing; I13 quantifies over its ingress list")
        return bad
    limits = yaml.safe_load(open(limits_path)) or {}
    ingress = set(limits.get("ingress_services") or [])

    covered = set()
    for name in ingress:
        svc = ctx.services.get(name)
        if svc is None:
            # A helper may be listed; it has no compose service.
            if name in (ctx.manifest.get("helpers") or {}):
                covered.add(name)
                continue
            bad.append(f"limits.yaml lists ingress service {name!r} which is not in compose")
            continue
        covered.add(name)
        for v in svc.get("volumes") or []:
            tgt = v.get("target") if isinstance(v, dict) else str(v)
            if tgt and "/sys/fs/cgroup" in str(tgt):
                bad.append(f"{name} mounts /sys/fs/cgroup")
        caps_add = [c.upper() for c in (svc.get("cap_add") or [])]
        if "SYS_ADMIN" in caps_add:
            bad.append(f"{name} has cap_add SYS_ADMIN")
        if "ALL" not in [c.upper() for c in (svc.get("cap_drop") or [])]:
            bad.append(f"{name} does not cap_drop ALL")
        opts = svc.get("security_opt") or []
        if not any("no-new-privileges:true" in str(o) for o in opts):
            bad.append(f"{name} lacks no-new-privileges:true")
        if svc.get("privileged"):
            bad.append(f"{name} is privileged")
        if svc.get("cgroup") == "host":
            bad.append(f"{name} shares the host cgroup namespace")

    # SET EQUALITY: a new ingress on a service outside the list fails the PR.
    declared_ingress = {n for n, s in (ctx.manifest.get("services") or {}).items()
                        if s.get("scope") in SHIPPED_SCOPES and s.get("untrusted_input") in (True, "yes")}
    missing = declared_ingress - ingress
    for m in sorted(missing):
        bad.append(f"{m} accepts untrusted bytes but is not in limits.yaml ingress_services")
    extra = {i for i in ingress if i in ctx.services} - declared_ingress
    for e in sorted(extra):
        bad.append(f"limits.yaml lists {e} as ingress but the manifest does not mark it untrusted_input")
    return bad


@check("I14", "lock order: every path takes lifecycle before helper")
def i14(ctx):
    # A CI grep over the command implementations, as the design specifies.
    path = os.path.join(ctx.root, "bin", "aistack")
    text = open(path).read()
    bad = []
    if re.search(r"with_helper_lock\s+with_lifecycle_lock", text):
        bad.append("bin/aistack takes the helper lock before the lifecycle lock")
    # The wrapper must skip acquisition when the fd is already held, or a
    # nested invocation deadlocks against itself.
    for var in ("AISTACK_LOCK_FD_LIFECYCLE", "AISTACK_LOCK_FD_HELPER"):
        if var not in text:
            bad.append(f"bin/aistack never consults {var}; a nested helper would deadlock")
    return bad


@check("I15", "one declaration of the app list; named consumers derive it; no literal copy in the 3 gated shapes")
def i15(ctx):
    """One declaration, N derivations — checked, not promised in a comment.

    NOM-307's review found the app list written out literally in SIX files
    under a comment in healthcheck.sh asserting that two of them "cannot
    drift".  Nothing coupled them: no invariant, no test.  Declaring the set
    in gen-secrets.sh and deriving it everywhere else is only a fix while
    something fails the build when another literal copy appears.

    WHAT THIS CHECK ACTUALLY COVERS, stated exactly, because the first cut of
    it claimed more than it did.  A literal that names EVERY declared app, in
    one of three SHAPES, fails the build (<app> stands for an app name — real
    names here would make this file the second copy and fail the check):

        for x in <app> <app> <app> <app>                 (a loop)
        APPS="<app> <app> <app> <app>"                   (an assignment)
        ... WHERE rolname IN ('<app>','<app>', ...)       (a SQL set)

    The first version matched only the loop, so `drill.sh`'s SQL `IN (...)`
    list and count sat outside the gate while gen-secrets.sh's comment claimed
    "a second literal copy anywhere" would fail the build.  It is a tripwire
    for the shapes that have actually appeared in this repository, NOT a proof
    that no literal copy can exist: a list assembled by `printf`, spread down
    a heredoc, or built one `grep -q` at a time would still slip past it.
    tests/app-list-coupling.sh deliberately contains such a `printf` fixture.

    IT TAKES THE WHOLE SET, not two tokens.  Both weaker thresholds were
    measured: a substring scan returns the legitimate per-app VOLUME lists in
    backup.sh, restore.sh and remove.sh, and "any two app tokens" additionally
    returns doctor.sh's `service:secret-path` pair list, which names postgres,
    n8n and authelia and is a list of services, not of databases.  Both are
    different lists with different blast radii.  A copy of THIS list names all
    of it, because it is copied from the declaration the day it is written —
    which is the day this check has to catch it.

    FOUR WAYS THIS CHECK COULD HAVE BEEN FAKE, all measured while writing it:

      * Scanning raw text matched the COMMENTS that describe the defect being
        removed, so the fix failed its own invariant and the only repair would
        have been to allowlist the prose.  Full-line comments are stripped
        first.
      * `\bn8n\b` matches inside `aistack-n8n-data`, so every volume loop in
        backup.sh, restore.sh and remove.sh looked like an app list.  Tokens
        are split on characters that are neither alphanumeric nor `_.-`, so
        `aistack-n8n-data` stays ONE token and matches no app EXACTLY.
      * Writing the app names here, in the checker, made this file the second
        literal copy and I15 failed itself.  So the names are DERIVED from the
        declaration in gen-secrets.sh, which also means a checker that cannot
        find that declaration fails instead of quietly looking for nothing.
      * Deleting a derivation would have made the check pass vacuously, so
        every consumer is listed by name with the token that proves it reads
        the derived source.
    """
    DECLARER = os.path.join("scripts", "gen-secrets.sh")
    # Every consumer, and the token(s) that prove it derives rather than
    # declares.  Listed explicitly so that DELETING a derivation cannot make
    # this check pass: an absent derivation is a failure, exactly like the
    # absent runtime_ids entry this ticket started from.
    DERIVERS = {
        os.path.join("config", "postgres", "init", "01-roles-and-databases.sh"): ("app_db_passwords",),
        os.path.join("config", "postgres", "healthcheck.sh"): ("app_db_passwords",),
        os.path.join("scripts", "backup.sh"): ("app_db_passwords",),
        # restore.sh reads the ARCHIVE, then hands that set to the drill.
        os.path.join("scripts", "restore.sh"): ("payload/*.dump", "AISTACK_RESTORED_DBS_FILE"),
        os.path.join("scripts", "drill.sh"): ("AISTACK_RESTORED_DBS_FILE",),
    }
    SHAPES = (
        ("a `for ... in` loop", re.compile(r"\bfor\s+\w+\s+in\s+([^\n;]*)")),
        ("an assignment", re.compile(r"(?m)^[ \t]*(?:export[ \t]+|local[ \t]+|readonly[ \t]+)?"
                                    r"[A-Za-z_][A-Za-z0-9_]*\+?=(.*)$")),
        ("a SQL `IN (...)` set", re.compile(r"(?is)\bIN\s*\(([^)]*)\)")),
    )
    # Keeps `aistack-n8n-data` and `n8n-data` whole; splits quotes, commas,
    # parentheses, whitespace and `$`.
    SPLIT = re.compile(r"[^A-Za-z0-9_.-]+")

    def code_of(path):
        raw = open(path, encoding="utf-8", errors="replace").read()
        # Full-line comments only.  Stripping from any '#' would eat
        # ${line#*=} and ${ANSWER#checked:} and could invent a match.
        code = "\n".join("" if ln.lstrip().startswith("#") else ln
                          for ln in raw.splitlines())
        return code.replace("\\\n", " ")  # join continuations before matching

    def tokens(words):
        return [t for t in SPLIT.split(words.strip()) if t]

    bad = []
    # --- the app names, DERIVED from the declaration ------------------------
    declarer_full = os.path.join(ctx.root, DECLARER)
    if not os.path.exists(declarer_full):
        return [f"{DECLARER} is missing, so the app list has no declaration and "
                f"I15 has nothing to check against"]
    bare = re.compile(r"[a-z][a-z0-9_]*\Z")
    found = []
    for words in SHAPES[0][1].findall(code_of(declarer_full)):
        toks = tokens(words)
        if len(toks) >= 2 and all(bare.match(t) for t in toks):
            found.append(toks)
    if len(found) != 1:
        return [f"{DECLARER} holds {len(found)} loops that look like the app-list "
                f"declaration; I15 needs exactly one to derive the app names "
                f"from, and cannot check a list it cannot find"]
    APPS = set(found[0])

    # --- no second literal copy, in any of the gated shapes -----------------
    for dirpath, dirnames, filenames in os.walk(ctx.root):
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", "__pycache__", "node_modules", "backups", ".runtime")]
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, ctx.root)
            if not (name.endswith((".sh", ".py")) or rel == os.path.join("bin", "aistack")):
                continue
            try:
                code = code_of(full)
            except OSError as e:
                bad.append(f"{rel} could not be read ({e}); I15 cannot be checked over it")
                continue
            for shape, rx in SHAPES:
                for words in rx.findall(code):
                    named = APPS.intersection(tokens(words))
                    if named != APPS:
                        continue
                    if rel == DECLARER and shape == SHAPES[0][0]:
                        continue  # the one declaration
                    bad.append(f"{rel} writes the app list out literally in {shape} "
                               f"({' '.join(sorted(named))}); {DECLARER} is the single "
                               f"declaration and every other consumer must derive it")

    # --- and every consumer still derives -----------------------------------
    for rel, want in sorted(DERIVERS.items()):
        full = os.path.join(ctx.root, rel)
        if not os.path.exists(full):
            bad.append(f"{rel} is missing; it is one of the consumers I15 quantifies over")
            continue
        text = open(full, encoding="utf-8", errors="replace").read()
        for token in want:
            if token not in text:
                bad.append(f"{rel} does not mention {token}, so it cannot be deriving "
                           f"the app list; a consumer that derives nothing is how the "
                           f"list drifts back apart")
    return bad


@check("I16", "the drill's capability sets equal the shipped ones (no privileged second copy)")
def i16(ctx):
    """compose.drill.yaml may not grant a service MORE than compose.yaml does.

    ADDED BY NOM-341, and it is a fourth control beyond the three that ticket
    asked for — see the handoff.  The reason it is here: NOM-341 narrowed
    postgres from five capabilities to four, and found the five-capability
    list ALSO written out in compose.drill.yaml under a `# E7` comment with
    nothing holding the two equal.

    The drill is the worst possible place for a divergent copy.  Its whole
    purpose is to prove a restore works, so if it grants MORE than the shipped
    service, it proves a restore works for a container the operator will never
    run — and the failure mode of that divergence is a GREEN DRILL, which
    nobody investigates.  This repository has already been here once: commit
    e0ccc04 ("the sixth copy was in the drill, where the failure mode is
    PASS").  I15 holds the app list together for the same reason.

    Equality, not a subset: a drill that grants LESS would fail for a reason
    the real service does not have, which is a false red and wastes the drill
    just as thoroughly as a false green.
    """
    import yaml as _yaml
    bad = []
    path = os.path.join(ctx.root, "compose.drill.yaml")
    if not os.path.isfile(path):
        return ["compose.drill.yaml is absent, so the restore drill has no definition"]
    with open(path) as fh:
        drill = (_yaml.safe_load(fh) or {}).get("services") or {}
    for name, dsvc in sorted(drill.items()):
        dcaps = sorted(c.upper() for c in ((dsvc or {}).get("cap_add") or []))
        shipped = ctx.services.get(name)
        if shipped is None:
            if dcaps:
                bad.append(f"drill service {name} adds {dcaps} but no such service "
                           f"exists in compose.yaml to compare against")
            continue
        scaps = sorted(c.upper() for c in (shipped.get("cap_add") or []))
        if dcaps != scaps:
            extra = [c for c in dcaps if c not in scaps]
            short = [c for c in scaps if c not in dcaps]
            bad.append(
                f"drill service {name} cap_add {dcaps} != shipped {scaps}"
                + (f"; drill grants MORE: {extra} — the drill would pass against a "
                   f"container that is not the one shipped" if extra else "")
                + (f"; drill grants LESS: {short} — the drill would fail for a "
                   f"reason the shipped service does not have" if short else ""))
        if "ALL" not in [c.upper() for c in ((dsvc or {}).get("cap_drop") or [])]:
            bad.append(f"drill service {name} does not cap_drop ALL")
    return bad


@check("I17", "one MCP allowlist: no stdio, an argument allowlist for every tool, the agent runtimes are gVisor")
def i17(ctx):
    """The three properties NOM-412 §4 says the build must enforce itself.

    1. No stdio MCP server anywhere: not in LiteLLM's mcp_servers, and not in
       the config Hermes ships.
    2. EVERY allowed tool has an `allowed_params` entry (`[]` for a tool with no
       arguments).  LiteLLM applies the argument check only to tools that HAVE
       an entry (NOM-412 limit 2), so a missing entry is a tool whose arguments
       are not checked at all — fail-open by omission.
    3. Hermes, n8n and Open WebUI reach tools through that one allowlist and no
       other: neither Hermes' nor Open WebUI's shipped config may name an MCP
       server that is not LiteLLM's /mcp.  Hermes and Crawl4AI run under runsc.
    """
    bad = []
    cfg = yaml.safe_load(open(os.path.join(ctx.root, "config", "litellm", "config.yaml"))) or {}
    if (cfg.get("general_settings") or {}).get("enable_mcp") is not True:
        bad.append("config/litellm/config.yaml: general_settings.enable_mcp must be true (it is the one MCP gateway)")
    servers = cfg.get("mcp_servers") or {}
    if not servers:
        bad.append("config/litellm/config.yaml declares no mcp_servers")
    for name, srv in servers.items():
        if srv.get("command") or srv.get("args") or str(srv.get("transport", "http")).lower() == "stdio":
            bad.append(f"mcp_servers.{name} is a stdio server; stdio MCP is not allowed")
        if not str(srv.get("url", "")).startswith("http://"):
            bad.append(f"mcp_servers.{name} has no http:// url (internal bridges only)")
        tools = srv.get("allowed_tools")
        params = srv.get("allowed_params")
        if not tools:
            bad.append(f"mcp_servers.{name} has no allowed_tools: an unlisted server would expose every tool")
            continue
        if not isinstance(params, dict):
            bad.append(f"mcp_servers.{name} has no allowed_params")
            continue
        for t in tools:
            if t not in params or not isinstance(params[t], list):
                bad.append(f"mcp_servers.{name}: tool {t!r} is allowed but has no allowed_params entry "
                           f"(use [] for no arguments), so its arguments would not be checked")
        for t in params:
            if t not in tools:
                bad.append(f"mcp_servers.{name}: allowed_params names {t!r}, which is not in allowed_tools")

    # The committed lock must name exactly the allowed tools and keys.
    lockp = os.path.join(ctx.root, "config", "mcp", "tools.lock.json")
    if not os.path.isfile(lockp):
        bad.append("config/mcp/tools.lock.json is missing")
    else:
        lock = json.load(open(lockp)).get("tools") or {}
        want = {f"{n}-{t}": sorted(srv.get("allowed_params", {}).get(t, []))
                for n, srv in servers.items() for t in (srv.get("allowed_tools") or [])}
        got = {k: sorted(v.get("arguments", [])) for k, v in lock.items()}
        for k in sorted(set(want) | set(got)):
            if k not in got:
                bad.append(f"tools.lock.json is missing {k}")
            elif k not in want:
                bad.append(f"tools.lock.json lists {k}, which the allowlist does not")
            elif got[k] != want[k]:
                bad.append(f"tools.lock.json {k} arguments {got[k]} != allowlist {want[k]}")

    # Hermes config: stdio is refused; the only MCP server is the gateway.
    hp = os.path.join(ctx.root, "config", "hermes", "config.yaml")
    if os.path.isfile(hp):
        hcfg = yaml.safe_load(open(hp)) or {}
        for name, srv in (hcfg.get("mcp_servers") or {}).items():
            if srv.get("command") or srv.get("args"):
                bad.append(f"config/hermes/config.yaml mcp_servers.{name} is stdio")
            if "litellm:4000/mcp" not in str(srv.get("url", "")):
                bad.append(f"config/hermes/config.yaml mcp_servers.{name} bypasses the gateway: {srv.get('url')!r}")
    else:
        bad.append("config/hermes/config.yaml is missing")
    # Open WebUI's one tool connection is the gateway too.
    ow = (ctx.services.get("open-webui") or {}).get("environment") or {}
    if "TOOL_SERVER_CONNECTIONS" in ow:
        bad.append("open-webui declares TOOL_SERVER_CONNECTIONS in compose; it is generated into secrets/open-webui.env with the app's own key")

    for name in ("hermes", "crawl4ai", "openclaw", "openclaw-sandbox"):
        if name not in ctx.services and name.startswith("openclaw"):
            bad.append(f"{name} is missing from the rendered compose, so its runtime cannot be checked")
            continue
        if (ctx.services.get(name) or {}).get("runtime") != "runsc":
            bad.append(f"{name} must declare runtime: runsc (gVisor); a missing runtime falls back to runc silently")
    return bad


# Licences rule 5 of the DoD accepts for model weights and voices.  Anything
# else — CC-BY-NC, "research only", a custom licence nobody has read — fails.
COMMERCIAL_SAFE_LICENCES = {"Apache-2.0", "MIT", "CC0-1.0", "BSD-3-Clause"}
OPENCLAW_MIN = (2026, 4, 22)


@check("I19", "optional profiles: OpenClaw locked down, pinned commercial-safe weights, no GPU path")
def i19(ctx):
    """What DoD 2.4 asks of each optional profile, as properties of the repo.

    openclaw — OpenClaw >= 2026.4.22; sandbox ON for every session (`mode: all`)
    on the SSH backend, which needs no Docker socket; ClawHub and every other
    skill/plugin install FAIL CLOSED (`security.installPolicy` enabled with no
    `exec` command — OpenClaw's documented fail-closed state — for skills and
    plugins; no bundled skills; skill-workshop learning off); gateway on loopback inside its container with the Control UI off;
    elevated tools off; private network only (its bridges are checked by I7,
    I8, I11 like every other).
    voice-arabic / docs-arabic — every weight file a build fetches is pinned by
    sha256 in that build's models.lock WITH a licence from the commercial-safe
    list; a Dockerfile `ADD --checksum` must name a row of its models.lock; the
    TTS server offers no voice cloning.
    gpu — Later (no 24 GB GPU test machine): nothing may request a GPU.
    """
    bad = []
    # --- openclaw: version ---------------------------------------------------
    pins = {}
    for line in open(os.path.join(ctx.root, "versions.env")):
        m = re.match(r"^([A-Z0-9_]+)=(.*)$", line.strip())
        if m:
            pins[m.group(1)] = m.group(2)
    tag = pins.get("OPENCLAW_TAG", "")
    m = re.match(r"^v?(\d{4})\.(\d+)\.(\d+)", tag)
    if not m:
        bad.append(f"OPENCLAW_TAG {tag!r} is not a YYYY.M.D release tag")
    elif tuple(int(x) for x in m.groups()) < OPENCLAW_MIN:
        bad.append(f"OPENCLAW_TAG {tag} is older than 2026.4.22 (DoD section 1)")
    # --- openclaw: config ----------------------------------------------------
    cp = os.path.join(ctx.root, "config", "openclaw", "openclaw.json")
    if not os.path.isfile(cp):
        bad.append("config/openclaw/openclaw.json is missing")
    else:
        oc = json.load(open(cp))
        g = lambda *ks: _dig(oc, ks)
        want = [
            (("agents", "defaults", "sandbox", "mode"), "all", "sandbox must be on for every session"),
            (("agents", "defaults", "sandbox", "backend"), "ssh", "the only backend that needs no Docker socket"),
            (("agents", "defaults", "sandbox", "ssh", "strictHostKeyChecking"), True, "the sandbox host key must be pinned"),
            (("gateway", "bind"), "loopback", "the gateway must not listen on a bridge"),
            (("gateway", "controlUi", "enabled"), False, "no web UI is routed to it"),
            (("tools", "elevated", "enabled"), False, "elevated exec escapes the sandbox"),
            (("security", "installPolicy", "enabled"), True, "installs must go through the policy"),
            # An EMPTY list is read by OpenClaw as "no allowlist" -- measured on
            # 2026.10.7: 13 bundled skills stayed eligible.  One name that
            # matches no skill blocks all 49 (NOM-415 profiles doc).
            (("skills", "allowBundled"), ["__none__"], "no bundled skills"),
            (("skills", "workshop", "autonomous", "mode"), "off", "the agent must not write its own skills"),
            (("security", "installPolicy", "targets"), ["skill", "plugin"], "the policy must cover plugins as well as skills"),
            (("skills", "install", "allowUploadedArchives"), False, "no uploaded skill archives"),
            (("browser", "enabled"), False, "no browser"),
            (("update", "auto", "enabled"), False, "no self-update (pin every version)"),
        ]
        for path, value, why in want:
            if g(*path) != value:
                bad.append(f"openclaw.json {'.'.join(path)} is {g(*path)!r}, must be {value!r}: {why}")
        if g("security", "installPolicy", "exec") is not None:
            bad.append("openclaw.json security.installPolicy.exec is set: with a command the policy can ALLOW "
                       "installs; with none, every ClawHub/skill/plugin install fails closed, which is the requirement")
        for name, ent in (g("agents", "entries") or {}).items():
            if _dig(ent, ("sandbox", "mode")) not in (None, "all"):
                bad.append(f"openclaw.json agents.entries.{name} overrides sandbox.mode")
        if g("channels"):
            bad.append("openclaw.json configures channels; a channel is an inbound path this profile does not ship")
    # --- weights: pinned, hashed, licensed ------------------------------------
    bdir = os.path.join(ctx.root, "build")
    n_rows = 0
    for d in sorted(os.listdir(bdir)) if os.path.isdir(bdir) else []:
        lockp = os.path.join(bdir, d, "models.lock")
        dfile = os.path.join(bdir, d, "Dockerfile")
        shas = set()
        if os.path.isfile(lockp):
            for ln in open(lockp):
                ln = ln.strip()
                if not ln or ln.startswith("#"):
                    continue
                f = ln.split()
                if len(f) != 5:
                    bad.append(f"build/{d}/models.lock row has {len(f)} fields, needs repo revision file sha256 licence: {ln[:80]}")
                    continue
                n_rows += 1
                repo, rev, fname, sha, lic = f
                if not re.fullmatch(r"[0-9a-f]{40}", rev):
                    bad.append(f"build/{d}/models.lock {fname}: revision {rev!r} is not a commit hash")
                if not re.fullmatch(r"[0-9a-f]{64}", sha):
                    bad.append(f"build/{d}/models.lock {fname}: {sha!r} is not a sha256")
                if lic not in COMMERCIAL_SAFE_LICENCES:
                    bad.append(f"build/{d}/models.lock {repo}/{fname}: licence {lic} is not commercial-safe")
                shas.add(sha)
        if os.path.isfile(dfile):
            text = open(dfile).read()
            for sha in re.findall(r"ADD\s+--checksum=sha256:([0-9a-f]{64})", text):
                if sha not in shas:
                    bad.append(f"build/{d}/Dockerfile ADDs sha256:{sha[:12]}… which build/{d}/models.lock does not list")
            if "fetch_models.py" in text and not shas:
                bad.append(f"build/{d}/Dockerfile fetches models but build/{d}/models.lock lists none")
    for d in ("stt-arabic", "tts-arabic", "docling-arabic"):
        if not os.path.isfile(os.path.join(bdir, d, "models.lock")):
            bad.append(f"build/{d}/models.lock is missing")
    if n_rows == 0:
        bad.append("no models.lock rows were read at all; this check would be vacuous")
    tts = os.path.join(bdir, "tts-arabic", "server.py")
    if os.path.isfile(tts) and re.search(r"audio_prompt|prepare_conditionals", open(tts).read()):
        bad.append("build/tts-arabic/server.py references a voice-cloning input; only the built-in voice ships")
    # --- gpu is Later ----------------------------------------------------------
    for name, svc in ctx.services.items():
        devs = (((svc.get("deploy") or {}).get("resources") or {}).get("reservations") or {}).get("devices")
        if svc.get("gpus") or devs:
            bad.append(f"{name} requests a GPU; the gpu profile is Later (no 24 GB GPU test machine)")
    return bad


def _dig(obj, keys):
    for k in keys:
        if not isinstance(obj, dict) or k not in obj:
            return None
        obj = obj[k]
    return obj


@check("I18", "VPS mode: real ACME certificates, MFA on every route, one bypass, firewall allows only 22/80/443")
def i18(ctx):
    """NOM-414.  The properties DoD 2.3 names, asserted over the VPS files.

    1. Caddyfile.vps: admin off, an ACME CA, and neither `local_certs` nor
       `tls internal` (a self-made certificate on a public name is the failure).
    2. Every site block imports `strip_identity`, and every `handle` that proxies
       to an app imports `require_mfa`.  The only handles without it are all of
       auth.{domain} (it IS the login) and n8n's /webhook/* (a header-token
       machine caller, same exception as home mode).
    3. Authelia VPS policy: default deny, no `one_factor`, a `two_factor` rule
       on the wildcard domain, and exactly ONE bypass rule, for /webhook/.
    4. The firewall script opens only the SSH port(s), 80 and 443.
    5. compose actually mounts these files through the AISTACK_* knobs, so the
       files checked here are the files that run.
    """
    bad = []
    caddy = os.path.join(ctx.root, "config", "caddy")
    main_path = os.path.join(caddy, "Caddyfile.vps")
    sites_dir = os.path.join(caddy, "sites-vps.d")
    if not os.path.isfile(main_path):
        return ["config/caddy/Caddyfile.vps is missing"]
    main = open(main_path).read()
    code = "\n".join(l.split("#", 1)[0] for l in main.splitlines())
    if not re.search(r"^\s*admin\s+off\s*$", code, re.M):
        bad.append("Caddyfile.vps does not set `admin off`")
    if re.search(r"^\s*local_certs\b", code, re.M) or re.search(r"\btls\s+internal\b", code):
        bad.append("Caddyfile.vps uses local_certs / tls internal: VPS mode must get real ACME certificates")
    if not re.search(r"^\s*acme_ca\s+\S+", code, re.M):
        bad.append("Caddyfile.vps sets no acme_ca")
    if not os.path.isdir(sites_dir) or not [f for f in os.listdir(sites_dir) if f.endswith(".caddy")]:
        return bad + ["config/caddy/sites-vps.d/ has no *.caddy files"]

    def strip(s):
        return "\n".join(l.split("#", 1)[0].rstrip() for l in s.splitlines())

    def blocks(text):
        """[(header, body)] for each top-level `header {` ... `}`."""
        out, depth, head, start = [], 0, None, 0
        for m in re.finditer(r"[{}]|\n", text):
            ch = m.group(0)
            if ch == "{":
                if depth == 0:
                    head = text[text.rfind("\n", 0, m.start()) + 1:m.start()].strip()
                    start = m.end()
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0 and head is not None:
                    out.append((head, text[start:m.start()]))
                    head = None
        return out

    sites = []
    for f in sorted(os.listdir(sites_dir)):
        if f.endswith(".caddy"):
            sites += [(f, h, b) for h, b in blocks(strip(open(os.path.join(sites_dir, f)).read()))]
    sites += [("Caddyfile.vps", h, b) for h, b in blocks(code) if not h.startswith("(") and h]
    served = set()
    for f, head, body in sites:
        if head.startswith("(") or "AISTACK_DOMAIN" not in head:
            continue
        host = head.replace("{$AISTACK_DOMAIN}", "{domain}")
        served.add(host)
        if "{domain}" == host and "redir" in body and "reverse_proxy" not in body:
            continue  # the bare domain only redirects
        if "import strip_identity" not in body:
            bad.append(f"{f}: site {host} does not import strip_identity")
        for hh, hb in blocks(body):
            if not hh.startswith("handle"):
                continue
            proxies = re.findall(r"reverse_proxy\s+(\S+)", hb)
            if not proxies:
                continue
            gated = "import require_mfa" in hb or "forward_auth authelia" in hb
            if host == "auth.{domain}":
                continue
            if host == "n8n.{domain}" and hh == "handle /webhook/*":
                if gated:
                    bad.append(f"{f}: n8n's webhook handle is behind forward-auth; machine callers cannot pass it")
                continue
            if not gated:
                bad.append(f"{f}: `{hh}` on {host} proxies to {proxies} with NO forward-auth")
            for target in proxies:
                if not re.match(r"(open-webui:8080|homepage:3000|n8n:5678|authelia:9091)$", target):
                    bad.append(f"{f}: `{hh}` on {host} proxies to unexpected target {target}")
    for need in ("auth.{domain}", "chat.{domain}", "dash.{domain}", "n8n.{domain}"):
        if need not in served:
            bad.append(f"no site block for {need}")
    if "(require_mfa)" not in code or "forward_auth authelia:9091" not in code:
        bad.append("Caddyfile.vps does not define the require_mfa snippet over forward_auth authelia:9091")

    # Authelia policy.
    apath = os.path.join(ctx.root, "config", "authelia", "configuration.vps.yml")
    if not os.path.isfile(apath):
        bad.append("config/authelia/configuration.vps.yml is missing")
    else:
        raw = open(apath).read()
        cfg = yaml.safe_load(raw) or {}
        ac = cfg.get("access_control") or {}
        rules = ac.get("rules") or []
        if ac.get("default_policy") != "deny":
            bad.append("configuration.vps.yml: access_control.default_policy must be deny")
        if any(r.get("policy") == "one_factor" for r in rules):
            bad.append("configuration.vps.yml: one_factor is used; every app route is two_factor")
        bypass = [r for r in rules if r.get("policy") == "bypass"]
        if len(bypass) != 1 or (bypass[0].get("resources") or []) != ["^/webhook/.*$"] \
                or "n8n." not in str(bypass[0].get("domain")):
            bad.append(f"configuration.vps.yml: expected exactly one bypass (n8n /webhook/), found {bypass}")
        if not any(r.get("policy") == "two_factor" and str(r.get("domain", "")).startswith("*.") for r in rules):
            bad.append("configuration.vps.yml: no two_factor rule on the wildcard domain")
        ck = (cfg.get("session") or {}).get("cookies") or []
        if not ck or "AISTACK_DOMAIN" not in str(ck[0].get("domain")) or "auth." not in str(ck[0].get("authelia_url")):
            bad.append("configuration.vps.yml: session cookie must sit on {{ env AISTACK_DOMAIN }} with authelia_url on auth.")

    # Firewall: only ssh, 80, 443.
    hostsh = os.path.join(ctx.root, "scripts", "vps-host.sh")
    if os.path.isfile(hostsh):
        allows = re.findall(r"^\s*(?:for p in .*; do )?ufw allow ([^ ;]+)", open(hostsh).read(), re.M)
        for a in allows:
            if a not in ("80/tcp", "443/tcp", "\"$p/tcp\"", "in"):
                bad.append(f"scripts/vps-host.sh opens {a}; VPS mode allows only ssh, 80/tcp and 443/tcp")
        if not re.search(r"ufw default deny incoming", open(hostsh).read()):
            bad.append("scripts/vps-host.sh does not set default deny incoming")
    else:
        bad.append("scripts/vps-host.sh is missing")

    # compose mounts exactly these files.
    cv = " ".join(str(v.get("source") if isinstance(v, dict) else v)
                  for v in (ctx.services.get("caddy") or {}).get("volumes") or [])
    for need in ("AISTACK_CADDYFILE", "AISTACK_CADDY_SITES"):
        if need not in cv:
            bad.append(f"compose caddy volumes do not use {need}, so the VPS Caddy files would never be mounted")
    av = " ".join(str(v.get("source") if isinstance(v, dict) else v)
                  for v in (ctx.services.get("authelia") or {}).get("volumes") or [])
    if "AISTACK_AUTHELIA_CONFIG" not in av:
        bad.append("compose authelia volumes do not use AISTACK_AUTHELIA_CONFIG")
    return bad


ALL = [i1, i1b, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i12e, i13, i14,
       i15, i16, i17, i18, i19]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = ap.parse_args()

    ctx = Ctx(args.root)
    for c in ALL:
        c(ctx)

    width = max(len(t) for _, _, t, _ in RESULTS)
    print()
    for ident, status, title, problems in RESULTS:
        mark = "ok  " if status == "pass" else "FAIL"
        print(f"  [{mark}] {ident:<5} {title}")
        for p in problems:
            print(f"           - {p}")
    print()
    if FAILURES:
        print(f"{len(FAILURES)} invariant(s) FAILED: {', '.join(FAILURES)}")
        return 1
    print(f"All {len(RESULTS)} invariants pass.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
