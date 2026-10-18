#!/usr/bin/env bash
# AI Stack 2026 — render the frozen local-mode copy into every surface.
#
# The sentence lives in exactly ONE file. This writes it into the single
# AISTACK-LOCAL-MODE region of each surface named in release-manifest.txt.
# CI invariant I12 then asserts each surface has exactly one region and that
# its bytes EQUAL the file in full.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; cd "$ROOT"
python3 - <<'PY'
import re
canon = open("strings/local-mode.txt").read().strip()
surfaces = [l.strip() for l in open("release-manifest.txt")
            if l.strip() and not l.startswith("#")]
leaders = {".md": ("<!-- ", " -->"), ".yaml": ("# ", ""), ".yml": ("# ", ""),
           ".example": ("# ", ""), ".txt": ("", "")}
changed = 0
for f in surfaces:
    try:
        text = open(f).read()
    except OSError:
        continue
    if "AISTACK-LOCAL-MODE:BEGIN" not in text:
        continue
    import os
    pre, post = leaders.get(os.path.splitext(f)[1], ("# ", ""))
    body = f"{pre}{canon}{post}" if pre or post else canon
    new = re.sub(
        r"(AISTACK-LOCAL-MODE:BEGIN.*?\n).*?(\n[^\n]*AISTACK-LOCAL-MODE:END)",
        lambda m: m.group(1) + body + m.group(2), text, flags=re.S)
    if new != text:
        open(f, "w").write(new)
        print(f"  rendered into {f}")
        changed += 1
print(f"  {changed} surface(s) updated" if changed else "  all surfaces already match")
PY
