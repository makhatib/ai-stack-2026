"""demos/lib/report.py -- one way to print and count checks, for host-side checks."""
import json
import sys


class Report:
    def __init__(self, demo):
        self.demo, self.rows, self.times, self.info = demo, [], {}, {}

    def check(self, name, ok, detail=""):
        self.rows.append((name, bool(ok), detail))
        print(f"  [{'ok  ' if ok else 'FAIL'}] {name}{(' -- ' + detail) if detail else ''}", flush=True)
        return ok

    def note(self, text):
        print(f"         {text}", flush=True)

    def finish(self, blocked=None):
        """blocked = a reason string when a precondition the OWNER must supply is
        missing: exit 2, never read as a pass and never as a code failure."""
        ok = all(r[1] for r in self.rows)
        status = "BLOCKED" if blocked else ("PASS" if ok else "FAIL")
        print(json.dumps({"demo": self.demo, "status": status, "checks": len(self.rows),
                          "failed": [r[0] for r in self.rows if not r[1]], "times_s": self.times,
                          "info": self.info, "blocked": blocked}, ensure_ascii=False), flush=True)
        sys.exit(2 if blocked else (0 if ok else 1))
