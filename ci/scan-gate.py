#!/usr/bin/env python3
"""NOM-301 — the C2 release gate, computed from exact-digest evidence only.

Takes the candidate pin set (versions.env) and a list of report directories,
and for EACH PIN looks for a scan of EXACTLY that digest.  The rules that make
this a gate rather than a summary:

  * A pin with no exact-digest scan is UNSCANNED.  It is reported as UNKNOWN
    and fails the gate.  It is never silently omitted from the totals and
    never counted as zero.
  * An image whose OS was identified but for which NO scanner produced an
    OS-layer result is OS-UNKNOWN and fails the gate.  trivy alone is not
    enough here: it has no data source for CentOS Stream and returns no
    os-pkgs result at all, so grype's rpm/deb/apk matches are what close that
    layer.  "Scanner returned nothing" and "nothing is wrong" are different
    answers and this keeps them apart.
  * SEV_SOURCE picks the severity convention, and the two are NOT
    interchangeable, so the gate reports under whichever it was told to use
    rather than mixing them:
      vendor  trivy's severity, i.e. what the distro's own security team
              assigned after accounting for its compile flags and defaults.
      worst   the worse of trivy's and grype's.  grype scores from NVD, which
              does not know the distro's build, so this is the conservative
              reading and it runs higher.
    A finding only one scanner sees is still a finding under both.  Where only
    grype reads a unit as blocking, the reason is recorded, because the two
    reasons mean opposite things:
      no-vendor-data  trivy produced no os-pkgs result for this image at all,
                      so there is no distro verdict to compare against and
                      grype's is the ONLY verdict.  grype resolves CentOS
                      Stream 9 onto the Red Hat feed, whose severities are
                      that vendor's own (it emits NEGLIGIBLE, an NVD-absent
                      term, which is how we know).  These are vendor findings.
      disagrees-up    trivy DID assess this package and scored it lower.
                      Here grype's NVD-derived score is the harsher reading of
                      a package the distro already judged.

The unit of account is the (image, package, installed-version) triple, not the
CVE, because one bump or one accepted exception disposes of every CVE a triple
carries.  CVE instance counts are reported alongside so nothing is hidden.
"""
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import approvers  # noqa: E402  — the approval-authority rule, shared with I9
from pins import read_pins  # noqa: E402  — the committed pins, shared with I9

SEV_RANK = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3, "NEGLIGIBLE": 4, "UNKNOWN": 5}
BLOCKING = ("CRITICAL", "HIGH")
OS_TYPES = ("rpm", "deb", "apk")

# The header block the per-entry `units` must add up to.
HEADER_TOTALS = "totals_after_V0_bump"


def index_reports(dirs):
    """digest -> {trivy: path, grype: path}, by reading each report's own metadata.

    WHEN TWO DIRECTORIES HOLD A SCAN OF THE SAME DIGEST, THE MORE COMPLETE ONE
    WINS — not the last one listed [NOM-341].  This was last-writer-wins, and
    the ordering is whatever the caller's shell glob produced, so
    `ci/scan-gate.py versions.env security-report-*/` let
    security-report-docling-recheck-20261018T194157Z — a trivy-only recheck
    with no SBOM and no grype — shadow the full c2 scan of the same docling
    digest.  Measured: DOCLING reported 3 units instead of 75 and the gate's
    total read 131 against the register's 203, while the gate still called
    every unit claimed.  A silent DOWNGRADE of evidence is worse than a
    missing scan, because a missing scan is reported as UNSCANNED.

    "More complete" is: has a grype second opinion, then has an OS-layer
    result, then the later directory name.  All three are properties of the
    evidence, so the answer does not depend on argument order.
    """
    by = {}
    for d in dirs:
        tdir, gdir = os.path.join(d, "trivy"), os.path.join(d, "grype")
        if not os.path.isdir(tdir):
            continue
        for f in sorted(os.listdir(tdir)):
            if not f.endswith(".json"):
                continue
            p = os.path.join(tdir, f)
            try:
                doc = json.load(open(p))
            except Exception:
                continue
            # the digest the scan actually read, from the report, not the filename
            name = doc.get("ArtifactName") or ""
            dig = name.partition("@")[2]
            if not dig:
                for rd in (doc.get("Metadata") or {}).get("RepoDigests") or []:
                    dig = rd.partition("@")[2]
                    break
            if not dig:
                continue
            g = os.path.join(gdir, f[:-5] + ".grype.json")
            has_grype = os.path.exists(g)
            has_os = any((r.get("Class") == "os-pkgs")
                         for r in (doc.get("Results") or []))
            cand = {
                "trivy": p,
                "grype": g if has_grype else None,
                "report_dir": d,
                "_rank": (1 if has_grype else 0, 1 if has_os else 0, d),
            }
            prev = by.get(dig)
            if prev is None or cand["_rank"] > prev["_rank"]:
                by[dig] = cand
    return by


SEV_SOURCE = os.environ.get("SEV_SOURCE", "vendor")


def collect(trivy_path, grype_path):
    units = collections.defaultdict(lambda: {
        "cves": {}, "vendor_cves": {}, "class": set(), "scanners": set(), "fix": "",
    })
    osfam, trivy_os = "", False
    tdoc = json.load(open(trivy_path))
    osfam = ((tdoc.get("Metadata") or {}).get("OS") or {}).get("Family") or ""
    for r in tdoc.get("Results") or []:
        if r.get("Class") == "os-pkgs":
            trivy_os = True
        for v in r.get("Vulnerabilities") or []:
            u = units[(v.get("PkgName"), v.get("InstalledVersion"))]
            sev = v.get("Severity") or "UNKNOWN"
            cur = u["cves"].get(v.get("VulnerabilityID"))
            if cur is None or SEV_RANK.get(sev, 9) < SEV_RANK.get(cur, 9):
                u["cves"][v.get("VulnerabilityID")] = sev
            u["vendor_cves"][v.get("VulnerabilityID")] = sev
            u["class"].add(r.get("Class"))
            u["scanners"].add("trivy")
            if v.get("FixedVersion"):
                u["fix"] = u["fix"] or v["FixedVersion"]

    grype_os = 0
    if grype_path:
        gdoc = json.load(open(grype_path))
        for m in gdoc.get("matches") or []:
            a, v = m.get("artifact") or {}, m.get("vulnerability") or {}
            if (a.get("type") or "") in OS_TYPES:
                grype_os += 1
            u = units[(a.get("name"), a.get("version"))]
            sev = (v.get("severity") or "UNKNOWN").upper()
            cur = u["cves"].get(v.get("id"))
            if cur is None or SEV_RANK.get(sev, 9) < SEV_RANK.get(cur, 9):
                u["cves"][v.get("id")] = sev
            u["class"].add("os-pkgs" if (a.get("type") or "") in OS_TYPES else "lang-pkgs")
            u["scanners"].add("grype")
            fx = (v.get("fix") or {}).get("versions") or []
            if fx:
                u["fix"] = u["fix"] or ",".join(fx)

    blocking, counts = {}, collections.Counter()
    for (pkg, ver), u in units.items():
        is_os = "os-pkgs" in u["class"]
        # No distro verdict exists for an OS package when trivy returned no
        # os-pkgs result for the image.  Fall back to grype's, which for this
        # case IS the vendor feed, rather than reading trivy's silence as "not
        # blocking" — that is the bug commit 9042e0c fixed one level up.
        no_vendor_data = is_os and not trivy_os
        sevs = u["cves"] if (SEV_SOURCE != "vendor" or no_vendor_data) else u["vendor_cves"]
        bl = sorted(c for c, s in sevs.items() if s in BLOCKING)
        vendor_bl = [c for c, s in u["vendor_cves"].items() if s in BLOCKING]
        worst_bl = [c for c, s in u["cves"].items() if s in BLOCKING]
        reason = ""
        if worst_bl and not vendor_bl:
            reason = "no-vendor-data" if no_vendor_data else "disagrees-up"
            counts[reason] += 1
        if not bl:
            continue
        worst = min(sevs.values(), key=lambda s: SEV_RANK.get(s, 9))
        blocking[f"{pkg}@{ver}"] = {
            "worst": worst,
            "blocking_cves": bl,
            "n_blocking": len(bl),
            "class": sorted(u["class"]),
            "fix": u["fix"],
            "scanners": sorted(u["scanners"]),
            "grype_only_reason": reason,
        }
    return osfam, trivy_os, grype_os, blocking, counts


def load_dispositions(path):
    """(image, package) -> entry id, from security-findings.yaml.

    Parsed without PyYAML so the gate has no dependency the sandbox might not
    have.  Only the shape this file actually uses is supported: top-level
    `dispositions:` / `non_vulnerability_findings:` lists whose entries carry
    `id`, an `images` inline list, and one or more `packages*` block lists.
    """
    # Only these sections carry decisions that need approving.  `coverage_limits`
    # entries are statements about what the evidence does NOT establish — there
    # is nothing to approve in "we did not run cosign", and sweeping them into
    # the approval check would invent three findings that do not exist.
    APPROVABLE = ("dispositions", "non_vulnerability_findings")
    # The scalar fields the arithmetic and approval checks read.  `units` and
    # `critical_units` were present in the register and read by NOBODY before
    # NOM-341 — which is exactly how V6 could declare 62 against 77 measured
    # and V10 21 against 22 for a day with a green coverage check.
    SCALARS = ("approved_by", "approved_at", "review_by", "units", "critical_units")
    entries, cur, key, section = [], None, None, ""
    header, hblock = {}, None
    for raw in open(path):
        ln = raw.rstrip("\n")
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        # the `candidate: / totals_after_V0_bump:` header block, which is the
        # figure the per-entry sum has to equal
        if hblock is not None:
            m = re.match(r"^    ([a-z_]+):\s*(\d+)\s*$", ln)
            if m:
                header[m.group(1)] = int(m.group(2))
                continue
            if re.match(r"^ {0,3}\S", ln):
                hblock = None
        m = re.match(r"^([a-z_]+):\s*$", ln)
        if m:
            section = m.group(1)
            cur = None
            continue
        if section == "candidate" and re.match(rf"^  {HEADER_TOTALS}:\s*$", ln):
            hblock = HEADER_TOTALS
            continue
        m = re.match(r"^  - id:\s*(\S+)", ln)
        if m:
            cur = {"id": m.group(1), "images": [], "packages": [],
                   "approved_by": "", "review_by": "",
                   "approvable": section in APPROVABLE}
            entries.append(cur)
            key = None
            continue
        m = re.match(rf"^    ({'|'.join(SCALARS)}):\s*(.*)$", ln)
        if m and cur is not None:
            cur[m.group(1)] = m.group(2).strip().strip('"').strip("'")
            key = None
            continue
        if cur is None:
            continue
        # both the inline `key: [a, b]` and the `key:` + `  - a` block forms,
        # because the register uses whichever reads better per entry and a
        # parser that silently ignores one of them produces a FALSE "claimed"
        # verdict — which is the one failure mode this check must not have.
        m = re.match(r"^    (images|packages[a-z_]*):\s*\[(.*)\]\s*$", ln)
        if m:
            vals = [x.strip().strip('"').strip("'") for x in m.group(2).split(",") if x.strip()]
            cur["images" if m.group(1) == "images" else "packages"].extend(vals)
            key = None
            continue
        m = re.match(r"^    (images|packages[a-z_]*):\s*$", ln)
        if m:
            key = "images" if m.group(1) == "images" else "packages"
            continue
        m = re.match(r"^      - (.*)$", ln)
        if m and key in ("packages", "images"):
            cur[key].append(m.group(1).strip().strip('"').strip("'"))
            continue
        if re.match(r"^    \S", ln):
            key = None
    claim = {}
    for e in entries:
        for img in e["images"]:
            for pkg in e["packages"]:
                claim.setdefault((img, pkg), []).append(e["id"])
    return claim, entries, header


def check_unit_arithmetic(entries, measured, header, totals):
    """An approval may not certify an entry whose own arithmetic is wrong.

    THE DEFECT THIS EXISTS FOR [NOM-309/NOM-341].  The coverage check above
    asks only "is every measured unit claimed by SOME entry".  It never asked
    whether the number an entry DECLARES is the number it claims.  So V6 could
    declare `units: 62` while claiming 77, V10 `units: 21` while claiming 22,
    and the per-entry column could sum to 187 against a header total of 203 —
    with the gate green on coverage the whole time.  The only thing that
    caught it was a human reading the file, and a control that is a human
    reading the file is not a control.

    Three assertions, because each catches something the others do not:

      1. PER ENTRY, declared `units` == measured units for that entry's
         (image, package) set, and the same for `critical_units`.
      2. EVERY approvable entry must DECLARE both, including the ones that
         measure zero.  An undeclared figure is not a passing figure; without
         this, an entry dodges assertion 1 by saying nothing, and assertion 3
         silently loses a term.
      3. The per-entry sum == the register header's own totals.  Assertion 1
         alone passes a register whose entries are each right and whose header
         is wrong, which is the figure a reader quotes.

    `measured` is {entry id: (units, critical_units)} counted from the SAME
    claim map the coverage check used, so the two cannot disagree about which
    unit belongs to which entry.
    """
    problems = []
    dsum = dcrit = 0
    for e in entries:
        if not e.get("approvable"):
            continue
        eid = e["id"]
        mu, mc = measured.get(eid, (0, 0))
        for field, meas in (("units", mu), ("critical_units", mc)):
            raw = str(e.get(field, "")).strip()
            if raw == "":
                problems.append(
                    f"{eid}: declares no {field}, and measures {meas} — every "
                    f"approvable entry must state both, or the header total "
                    f"below is a sum with a missing term")
                continue
            try:
                decl = int(raw)
            except ValueError:
                problems.append(f"{eid}: {field} {raw!r} is not a number")
                continue
            if field == "units":
                dsum += decl
            else:
                dcrit += decl
            if decl != meas:
                problems.append(
                    f"{eid}: declares {field}: {decl} but the scan measures "
                    f"{meas} for its own (image, package) set — an approval "
                    f"would certify a figure the evidence does not support")
    want_u = header.get("blocking_units")
    want_c = header.get("critical_units")
    if want_u is None:
        problems.append(
            f"the register header has no {HEADER_TOTALS}.blocking_units, so "
            f"the per-entry sum ({dsum}) has nothing to be checked against")
    elif dsum != want_u:
        problems.append(
            f"the per-entry units sum to {dsum} but the header "
            f"{HEADER_TOTALS}.blocking_units says {want_u} — correct the "
            f"per-entry declarations from the scan first; the header is what "
            f"moves to meet them")
    if want_c is not None and dcrit != want_c:
        problems.append(
            f"the per-entry critical_units sum to {dcrit} but the header "
            f"{HEADER_TOTALS}.critical_units says {want_c}")
    # and both must still equal what the scan actually measured
    if dsum != totals["units"]:
        problems.append(
            f"the per-entry units sum to {dsum} but the scan measured "
            f"{totals['units']} blocking units in total")
    if dcrit != totals["crit"]:
        problems.append(
            f"the per-entry critical_units sum to {dcrit} but the scan "
            f"measured {totals['crit']} CRITICAL units in total")
    hh = header.get("high_units")
    if hh is not None and hh != totals["units"] - totals["crit"]:
        problems.append(
            f"the header {HEADER_TOTALS}.high_units says {hh} but the scan "
            f"measured {totals['units'] - totals['crit']}")
    hc = header.get("blocking_cve_instances")
    if hc is not None and hc != totals["cves"]:
        problems.append(
            f"the header {HEADER_TOTALS}.blocking_cve_instances says {hc} but "
            f"the scan measured {totals['cves']}")
    return problems


def check_approvals(entries, root):
    """Every entry needs a NAMED HUMAN approver and a live review_by.

    The rule itself lives in ci/approvers.py and is shared with
    `ci/invariants.py` I9, because this check and that one are the same rule
    applied to two registers and two copies of it drifted apart once already:
    both rejected `PENDING` and the string "DevOps Engineer", and NEITHER
    rejected "Tech Lead" — an agent of this company, and the one the registers
    named as reviewer.  See that module's header.

    An agent cannot satisfy this and must not try.  It failed for the whole
    life of the register and that failure WAS the control working; a named
    human approved on 2026-10-20 (NOM-310) and it passes from that date.

    Read a failure here against that.  While NO entry is signed, a failure is
    the pre-signature state.  Once ANY entry is signed, a failure is a
    REGRESSION -- a tampered name, an agent signing, a PENDING value put back,
    or a review_by window widened past the register's own 180-day promise.
    Those need different fixes, so the caller must not collapse them into
    "go and get an approval".
    """
    import datetime
    today = datetime.date.today()
    approvers_list, problems = approvers.load_approvers(root)
    flagged = set()
    for e in entries:
        if not e.get("approvable"):
            continue
        ab, rb = e.get("approved_by", ""), e.get("review_by", "")
        if ab in ("n/a", "null"):
            continue
        before = len(problems)
        if not ab:
            problems.append(f"{e['id']}: approved_by is empty — no named human has approved it")
        else:
            problems.extend(approvers.check_approved_by(
                e["id"], ab, approvers_list, "security disposition"))
        if rb and rb not in ("null", "n/a"):
            try:
                d = datetime.date.fromisoformat(rb)
            except ValueError:
                problems.append(f"{e['id']}: review_by {rb!r} is not a date")
            else:
                if (d - today).days < 0:
                    problems.append(f"{e['id']}: {(today - d).days} days PAST its review_by")
        elif ab not in ("n/a",):
            problems.append(f"{e['id']}: missing review_by")
        # the <= 180-day cap, from the shared rule, so this register is held
        # to the same window as security-exceptions.yaml.  Vacuous today only
        # because every `approved_at` here is null; it goes live per entry the
        # moment a human writes one.  See approvers.check_review_window.
        problems.extend(approvers.check_review_window(
            e["id"], e.get("approved_at"), rb))
        if len(problems) > before:
            flagged.add(e["id"])
    approvable = sum(1 for e in entries if e.get("approvable") and e.get("approved_by") not in ("n/a", "null"))
    return problems, approvable, len(flagged)


USAGE = ("usage: ci/scan-gate.py --dispositions REGISTER versions.env REPORT_DIR...\n"
         "       ci/scan-gate.py --coverage-only       versions.env REPORT_DIR...\n")


def parse_args(argv):
    """Pin set, report dirs and the register, off the command line.

    THE REGISTER HALF OF THIS GATE IS NOT SKIPPABLE IN SILENCE [NOM-341].
    security-findings.yaml's own header documents the invocation as
    `ci/scan-gate.py --dispositions security-findings.yaml`, and that flag did
    not exist: the register arrived only through the DISPOSITIONS environment
    variable.  So running the DOCUMENTED command ran the coverage half, skipped
    the claim / arithmetic / approval half entirely, printed COVERAGE COMPLETE
    and exited 0 — a gate reporting success for three checks it never made.
    That is the same defect one level up as the declared figure nobody checked.

    The flag is real now, the environment variable still works for callers that
    already use it, and asking for NEITHER is an error rather than a quieter
    gate.  --coverage-only keeps the narrower run available to whoever wants
    it, and makes them say so out loud.
    """
    disp, coverage_only, rest = os.environ.get("DISPOSITIONS"), False, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--dispositions" and i + 1 < len(argv):
            disp, i = argv[i + 1], i + 2
        elif a.startswith("--dispositions="):
            disp, i = a.split("=", 1)[1], i + 1
        elif a == "--coverage-only":
            coverage_only, i = True, i + 1
        elif a.startswith("-"):
            sys.exit(f"unknown option {a}\n{USAGE}")
        else:
            rest.append(a)
            i += 1
    if len(rest) < 2:
        sys.exit(USAGE)
    if disp and coverage_only:
        sys.exit("--coverage-only and a register contradict each other; pick one.\n"
                 + USAGE)
    if not coverage_only and not disp:
        sys.exit("REGISTER CHECKS DID NOT RUN — and a gate that did not look is not a\n"
                 "gate that found nothing.  Name the register:\n"
                 "    ci/scan-gate.py --dispositions security-findings.yaml "
                 "versions.env REPORT_DIR\n"
                 "or ask for the narrower run explicitly with --coverage-only.\n")
    return rest[0], rest[1:], (None if coverage_only else disp)


def main():
    pins_path, dirs, disp_path = parse_args(sys.argv[1:])
    claim, entries, header = (load_dispositions(disp_path) if disp_path
                              else (None, None, {}))
    pins = read_pins(pins_path)
    reports = index_reports(dirs)

    out, fail = {}, []
    for name in sorted(pins):
        d = pins[name]
        dig = d["DIGEST"]
        ev = reports.get(dig)
        if ev is None:
            out[name] = {"status": "UNSCANNED", "pin": f"{d['IMAGE']}:{d['TAG']}@{dig}"}
            fail.append(f"{name}: no scan of the pinned digest — UNKNOWN, not clean")
            continue
        osfam, t_os, g_os, blocking, gonly = collect(ev["trivy"], ev["grype"])
        os_covered = t_os or g_os > 0
        if osfam and not os_covered:
            fail.append(f"{name}: OS {osfam} identified but no scanner produced an OS-layer result")
        if ev["grype"] is None:
            fail.append(f"{name}: no grype second opinion")
        out[name] = {
            "status": "SCANNED",
            "pin": f"{d['IMAGE']}:{d['TAG']}@{dig}",
            "os_family": osfam,
            "os_covered_by": ([] if not t_os else ["trivy"]) + ([] if not g_os else ["grype"]),
            "os_covered": os_covered,
            "grype_os_matches": g_os,
            "evidence_dir": ev["report_dir"],
            "sev_source": SEV_SOURCE,
            "grype_only_no_vendor_data": gonly["no-vendor-data"],
            "grype_only_disagrees_up": gonly["disagrees-up"],
            "units": blocking,
        }

    print(f"severity convention: {SEV_SOURCE}"
          f"{'  (trivy / distro security team)' if SEV_SOURCE == 'vendor' else '  (worse of trivy and grype)'}\n")
    print(f"{'image':16} {'OS':15} {'OS-layer by':14} {'units':6} {'CRIT':5} {'HIGH':5} {'CVEs':6} {'no-data':8} {'dis-up':6}")
    tot = collections.Counter()
    for name in sorted(out):
        r = out[name]
        if r["status"] != "SCANNED":
            print(f"{name:16} {'':15} {'':14} {'UNSCANNED — UNKNOWN, NOT CLEAN'}")
            continue
        c = sum(1 for u in r["units"].values() if u["worst"] == "CRITICAL")
        h = sum(1 for u in r["units"].values() if u["worst"] == "HIGH")
        n = sum(u["n_blocking"] for u in r["units"].values())
        tot["units"] += len(r["units"]); tot["crit"] += c; tot["high"] += h; tot["cves"] += n
        tot["nodata"] += r["grype_only_no_vendor_data"]
        tot["disup"] += r["grype_only_disagrees_up"]
        cov = ",".join(r["os_covered_by"]) or "NONE"
        print(f"{name:16} {r['os_family'] or '-':15} {cov:14} {len(r['units']):6} {c:5} {h:5} {n:6} "
              f"{r['grype_only_no_vendor_data']:8} {r['grype_only_disagrees_up']:6}")
    print(f"{'TOTAL':16} {'':15} {'':14} {tot['units']:6} {tot['crit']:5} {tot['high']:5} {tot['cves']:6} "
          f"{tot['nodata']:8} {tot['disup']:6}")
    print("\nno-data = OS units with NO distro verdict to compare against (trivy "
          "produced no os-pkgs\n          result for that image); grype's Red Hat-feed "
          "severity is the only verdict, and is used.\n"
          "dis-up  = units the distro DID assess and scored lower than grype's NVD "
          "score.\n          Counted, not adopted, under the vendor convention.")

    dest = os.environ.get("GATE_JSON", "gate.json")
    json.dump(out, open(dest, "w"), indent=1, sort_keys=True)
    print(f"\nwrote {dest}")

    # --- every blocking unit must be claimed by exactly one disposition -----
    if claim is not None:
        unclaimed, double = [], []
        # counted off the SAME claim map the coverage check uses, so the
        # arithmetic check below cannot disagree with it about which unit
        # belongs to which entry
        measured = collections.defaultdict(lambda: [0, 0])
        for name in sorted(out):
            r = out[name]
            if r["status"] != "SCANNED":
                continue
            for unit, u in sorted(r["units"].items()):
                pkg = unit.rsplit("@", 1)[0]
                ids = claim.get((name, pkg))
                if not ids:
                    unclaimed.append(f"{name} {unit} [{u['worst']}]")
                    continue
                if len(ids) > 1:
                    double.append(f"{name} {unit} claimed by {ids}")
                for i in ids:
                    measured[i][0] += 1
                    if u["worst"] == "CRITICAL":
                        measured[i][1] += 1
        print(f"\ndisposition coverage: {disp_path}")
        if unclaimed:
            print(f"  UNCLAIMED blocking units: {len(unclaimed)} — each is an "
                  f"UNDISPOSITIONED finding and fails the gate")
            for x in unclaimed[:40]:
                print("    -", x)
            if len(unclaimed) > 40:
                print(f"    ... and {len(unclaimed) - 40} more")
            fail.append(f"{len(unclaimed)} blocking unit(s) claimed by no disposition")
        else:
            print("  every blocking unit is claimed by a disposition entry")
        if double:
            print(f"  AMBIGUOUS: {len(double)} unit(s) claimed by more than one entry")
            for x in double[:20]:
                print("    -", x)
            fail.append(f"{len(double)} blocking unit(s) claimed by more than one disposition")

        # --- an approval may not certify an entry whose arithmetic is wrong --
        arith = check_unit_arithmetic(
            entries, {k: tuple(v) for k, v in measured.items()}, header,
            {"units": tot["units"], "crit": tot["crit"], "cves": tot["cves"]})
        print(f"\nunit arithmetic: per-entry declarations vs this scan")
        if arith:
            for p in arith:
                print("    -", p)
            fail.append(f"{len(arith)} unit-arithmetic error(s) — a declared "
                        f"figure does not equal what the scan measures, so no "
                        f"approval of it would mean anything")
        else:
            print("  every approvable entry's declared units and critical_units "
                  "equal what this scan\n  measures for its own packages, and "
                  "the per-entry sum equals the header total.")

        approval_problems, n_approvable, n_flagged = check_approvals(
            entries, os.path.dirname(os.path.abspath(disp_path)) or ".")
        print(f"\napproval state: {n_approvable - n_flagged}/{n_approvable} "
              f"entries carry a named human approval")
        for p in approval_problems:
            print("    -", p)
        if approval_problems:
            # The pre-signature state and a regression on a SIGNED register are
            # the same failure to this check, but not the same event to the
            # person reading the output.  Saying "EXPECTED ... this is the
            # control working" about an already-signed register tells an
            # operator to ignore a real red light, and asserts a cause (no
            # approval) that may not be the one the per-entry lines above gave.
            if n_flagged == n_approvable:
                fail.append(f"{n_flagged}/{n_approvable} disposition(s) carry no "
                            f"valid named-human approval — EXPECTED while the "
                            f"register is unsigned, until the named human approver "
                            f"in security-approvers.yaml approves; this is the "
                            f"control working")
            else:
                fail.append(f"{n_flagged} of {n_approvable} disposition(s) FAIL the "
                            f"approval check while {n_approvable - n_flagged} are "
                            f"signed — a REGRESSION on a signed register, NOT the "
                            f"pre-signature state. The cause is in the per-entry "
                            f"line(s) above and may be the approver name, a PENDING "
                            f"value, or an expired review_by window; those need "
                            f"different fixes, and re-approving fixes only the first")

    if fail:
        print("\nGATE FAILURES (coverage):")
        for f in fail:
            print("  -", f)
    else:
        print("\nCOVERAGE COMPLETE: every pin scanned at its exact digest, "
              "every OS layer covered by at least one scanner, grype ran on all.")
    if disp_path is None:
        # --coverage-only was asked for explicitly, so say in the output what
        # this run does NOT cover.  "The gate passed" must not be sayable
        # about a run that never opened the register.
        print("\nREGISTER NOT CHECKED (--coverage-only): the claim, arithmetic and\n"
              "approval checks did not run.  This output is about the scans only.")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
