"""demos/lib/grading.py -- the grading rules, apart from the code that runs a
demo, so demos/lib/selftest.py can prove each rule FAILS a bad answer as well
as passing a good one (a check that cannot fail proves nothing)."""
import re

TAG_RE = re.compile(r"release-\d{8}\.\d+")


def grade_research(run):
    """Demo 1.  `run` is a hermes_run.Run (or anything with the same fields).
    Returns [(check name, ok, detail)]."""
    out = []
    out.append(("Hermes answered", run.exit_code == 0 and bool(run.text), run.error or ""))
    searched = [i for n, i in run.calls if n.endswith("web_web_search")]
    out.append(("it searched the web (web_search through the gateway)", bool(searched),
                f"{len(searched)} search(es)" if searched else "no web_search call"))
    seen = run.tool_output_text() + "\n" + "\n".join(str(i) for _, i in run.calls)
    tags = sorted(set(TAG_RE.findall(run.text)))
    grounded = [t for t in tags if t in seen]
    out.append(("the release tag in the answer is one the tools returned (not invented)",
                bool(tags) and grounded == tags, f"answer: {tags or 'no tag'}; found in tool output: {grounded}"))
    cited = run.cited_urls()
    unseen = [u for u in cited if u not in seen and u.rstrip("/") not in seen]
    out.append(("it cites at least one source URL", bool(cited), ", ".join(cited)))
    out.append(("every cited URL came from a tool result (no invented source)", bool(cited) and not unseen,
                f"not in any tool result: {unseen}" if unseen else ""))
    return out
