#!/usr/bin/env python3
"""The committed image pins, read once, used by every gate that needs them.

`ci/scan-gate.py` needs them to find the scan of each pinned digest, and
`ci/invariants.py` I9 needs them to bind an exception's recorded `digest:` to
the pin it was measured against.  This module exists so there is ONE reader
rather than two: the lesson ci/approvers.py records — two copies of one rule
that drifted apart and were then held to the weaker of the two — applies to a
parser just as well as to a rule.

NOT the same job as I4's resolver, which substitutes `${VAR:?msg}` out of a
compose reference and is deliberately left where it is.  This reader answers
"what digest is <SERVICE> pinned to", and nothing else.

Stdlib only, on purpose: scan-gate.py is runnable on a machine that has only
python3 and no PyYAML, and importing this must not take that away.
"""

import re

FIELDS = ("IMAGE", "TAG", "DIGEST", "KIND")


def read_pins(path):
    """{PIN_NAME: {IMAGE, TAG, DIGEST, KIND}} for every resolved pin.

    A pin whose DIGEST is not a sha256 is NOT returned.  It is an unresolved
    pin — an image that does not exist yet — and the callers treat it as
    UNSCANNED rather than as absent.  Dropping it here cannot hide it: the
    caller reads the same file.
    """
    pins = {}
    for ln in open(path):
        m = re.match(r"([A-Z0-9_]+)_(IMAGE|TAG|DIGEST|KIND)=(.*)", ln.strip())
        if m:
            pins.setdefault(m.group(1), {})[m.group(2)] = m.group(3)
    return {
        n: d for n, d in pins.items()
        if d.get("DIGEST", "").startswith("sha256:")
    }


def pin_key(service):
    """The versions.env pin name for a compose service name.

    `open-webui` -> `OPEN_WEBUI`, `postgres` -> `POSTGRES`.  Returns the key
    whether or not it exists; the caller reports an unresolvable one, because
    a service whose pin cannot be found is a digest that CANNOT be checked,
    and that must fail rather than pass quietly.
    """
    return re.sub(r"[^A-Z0-9]", "_", str(service).upper())
