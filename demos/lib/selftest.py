#!/usr/bin/env python3
"""demos/lib/selftest.py -- prove the graders can FAIL.  No docker, no network.

A check that passes everything is not a check.  Every rule the demo checks use
to say PASS is run here on a good input (must pass) AND on a bad input of the
kind the rehearsal actually produced (must fail):
  - an answer with an invented release tag, or a cited URL no tool returned;
  - a document answer with the wrong value, or no value;
  - English text where Arabic was asked for.
Run: python3 demos/lib/selftest.py   (exit 0 = every control behaved)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from grading import grade_research  # noqa: E402
from hermes_run import Run  # noqa: E402

# owui_common.py is written to be concatenated in front of a check; its pure
# helpers are loaded here without its network code running.
ns = {}
exec(compile(open(os.path.join(HERE, "owui_common.py")).read(), "owui_common.py", "exec"), ns)
norm_ar, has_any, arabic_ratio, strip_think = ns["norm_ar"], ns["has_any"], ns["arabic_ratio"], ns["strip_think"]

failures = []


def expect(name, cond):
    print(f"  [{'ok  ' if cond else 'FAIL'}] {name}")
    if not cond:
        failures.append(name)


def run_of(text, calls, results, exit_code=0):
    r = Run()
    r.text, r.calls, r.results, r.exit_code = text, calls, results, exit_code
    return r


SEARCH = ("mcp__aistack__web_web_search", {"query": "gvisor latest release", "limit": 5})
RESULT = ("mcp__aistack__web_web_search",
          '{"results": [{"url": "https://github.com/google/gvisor/releases", "snippet": "release-20261019.0 ..."}]}', False)

print("grade_research (demo 1)")
good = run_of("The newest tag is release-20261019.0 (https://github.com/google/gvisor/releases).", [SEARCH], [RESULT])
expect("a grounded, cited answer passes every rule", all(ok for _, ok, _ in grade_research(good)))
# The rehearsal produced exactly these two (thinking off, 2026-10-27):
invented_url = run_of("The latest tag is v24.0, see https://github.com/gvisor/gvisor/releases/tag/v24.0", [], [])
g = dict((n, ok) for n, ok, _ in grade_research(invented_url))
expect("no search -> FAIL", not g["it searched the web (web_search through the gateway)"])
expect("an invented URL -> FAIL", not g["every cited URL came from a tool result (no invented source)"])
invented_tag = run_of("It is release-20260101.0 (https://github.com/google/gvisor/releases).", [SEARCH], [RESULT])
g = dict((n, ok) for n, ok, _ in grade_research(invented_tag))
expect("a tag no tool returned -> FAIL", not g["the release tag in the answer is one the tools returned (not invented)"])
expect("...while the same answer's real URL still passes its own rule",
       g["every cited URL came from a tool result (no invented source)"])
no_cite = run_of("The newest tag is release-20261019.0.", [SEARCH], [RESULT])
expect("no URL cited -> FAIL", not dict((n, ok) for n, ok, _ in grade_research(no_cite))["it cites at least one source URL"])
failed_run = run_of("", [SEARCH], [RESULT], exit_code=1)
expect("an error exit -> FAIL", not dict((n, ok) for n, ok, _ in grade_research(failed_run))["Hermes answered"])

print("value scoring (demos 3, 5, 6)")
expect("Arabic word with harakat/ta marbuta matches", bool(has_any("يحصل على ثلاثينَ يوماً", ["ثلاثين"])))
expect("Arabic-Indic digits match ASCII", bool(has_any("المبلغ ١٢٥٠٠ ريال", ["12500"])))
expect("the sick-leave value is not the annual-leave value", not has_any("خمسة عشر يوماً", ["30", "ثلاثين"]))
expect("30 is not found inside 300 or 2030", not has_any("300 ريال في 2030", ["30"]))
expect("30 is found as a number in a sentence", bool(has_any("يحصل على 30 يوماً.", ["30"])))
expect("12,500 is found next to Arabic text", bool(has_any("المبلغ 12,500 ريال", ["12,500"])))
expect("an answer with no value scores nothing", not has_any("لا أعرف", ["30", "ثلاثين"]))
expect("Arabic text is Arabic", arabic_ratio("العاصمة هي الرياض") > 0.9)
expect("English text is not Arabic", arabic_ratio("The capital is Riyadh") < 0.1)
expect("a <think> block is not scored", strip_think("<think>maybe 240</think>185 SAR") == "185 SAR")

print(f"selftest: {'all controls behaved' if not failures else str(len(failures)) + ' control(s) misbehaved'}")
sys.exit(1 if failures else 0)
