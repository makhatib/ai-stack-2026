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

SEV_RANK = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3, "NEGLIGIBLE": 4, "UNKNOWN": 5}
BLOCKING = ("CRITICAL", "HIGH")
OS_TYPES = ("rpm", "deb", "apk")


def read_pins(path):
    pins = {}
    for ln in open(path):
        m = re.match(r"([A-Z0-9_]+)_(IMAGE|TAG|DIGEST|KIND)=(.*)", ln.strip())
        if m:
            pins.setdefault(m.group(1), {})[m.group(2)] = m.group(3)
    return {
        n: d for n, d in pins.items()
        if d.get("DIGEST", "").startswith("sha256:")
    }


def index_reports(dirs):
    """digest -> {trivy: path, grype: path}, by reading each report's own metadata."""
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
            by[dig] = {
                "trivy": p,
                "grype": g if os.path.exists(g) else None,
                "report_dir": d,
            }
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
    entries, cur, key, section = [], None, None, ""
    for raw in open(path):
        ln = raw.rstrip("\n")
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"^([a-z_]+):\s*$", ln)
        if m:
            section = m.group(1)
            cur = None
            continue
        m = re.match(r"^  - id:\s*(\S+)", ln)
        if m:
            cur = {"id": m.group(1), "images": [], "packages": [],
                   "approved_by": "", "review_by": "",
                   "approvable": section in APPROVABLE}
            entries.append(cur)
            key = None
            continue
        m = re.match(r"^    (approved_by|review_by):\s*(.*)$", ln)
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
    return claim, entries


def check_approvals(entries):
    """Every entry needs a NAMED human approver and a live review_by.

    An agent cannot satisfy this and must not try: a value of PENDING, or one
    naming an agent, is a failure.  This check is EXPECTED TO FAIL until the
    Tech Lead decides, and that failure is the control working.
    """
    import datetime
    today = datetime.date.today()
    problems, flagged = [], set()
    for e in entries:
        if not e.get("approvable"):
            continue
        ab, rb = e.get("approved_by", ""), e.get("review_by", "")
        if ab in ("n/a", "null"):
            continue
        before = len(problems)
        if not ab or ab == "PENDING" or ab == "null":
            problems.append(f"{e['id']}: approved_by is PENDING — no named human has approved it")
        elif re.search(r"agent|DevOps Engineer|Engineer \(agent\)", ab, re.I):
            problems.append(f"{e['id']}: approved_by names an agent ({ab!r}) — an agent cannot approve a security disposition")
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
        if len(problems) > before:
            flagged.add(e["id"])
    approvable = sum(1 for e in entries if e.get("approvable") and e.get("approved_by") not in ("n/a", "null"))
    return problems, approvable, len(flagged)


def main():
    pins_path, dirs = sys.argv[1], sys.argv[2:]
    disp_path = os.environ.get("DISPOSITIONS")
    claim, entries = load_dispositions(disp_path) if disp_path else (None, None)
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
        for name in sorted(out):
            r = out[name]
            if r["status"] != "SCANNED":
                continue
            for unit, u in sorted(r["units"].items()):
                pkg = unit.rsplit("@", 1)[0]
                ids = claim.get((name, pkg))
                if not ids:
                    unclaimed.append(f"{name} {unit} [{u['worst']}]")
                elif len(ids) > 1:
                    double.append(f"{name} {unit} claimed by {ids}")
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

        approval_problems, n_approvable, n_flagged = check_approvals(entries)
        print(f"\napproval state: {n_approvable - n_flagged}/{n_approvable} "
              f"entries carry a named human approval")
        for p in approval_problems:
            print("    -", p)
        if approval_problems:
            fail.append(f"{n_flagged} disposition(s) without a named human approval "
                        f"— EXPECTED until the Tech Lead decides; this is the control working")

    if fail:
        print("\nGATE FAILURES (coverage):")
        for f in fail:
            print("  -", f)
    else:
        print("\nCOVERAGE COMPLETE: every pin scanned at its exact digest, "
              "every OS layer covered by at least one scanner, grype ran on all.")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
