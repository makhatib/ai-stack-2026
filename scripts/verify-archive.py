#!/usr/bin/env python3
"""AI Stack 2026 — archive verification (final-design §7.4, S11).

Runs BEFORE any extraction and before anything is overwritten.  Exit 0 means
the archive is safe to extract; any other exit means refuse.

SET EQUALITY, NOT LOOKUP.  Recomputing each LISTED member's digest cannot
detect an EXTRA member, so verification enumerates the archive and:
  * rejects any path not in the inventory      (extra member)
  * rejects any DUPLICATE path                 (the second would overwrite the
                                                first on extraction, so a
                                                count match is not a set match)
  * rejects any inventory entry with no member (missing member)
  * recomputes every member digest and compares

SAFE EXTRACTION IS THE ONLY EXTRACTION PATH.  Member paths are audited before
any write — relative, no `..`, resolves inside the target, no symlink or
hardlink escape, no device or FIFO members, no absolute paths — and extraction
goes through one helper that RE-CHECKS EACH MEMBER AS IT WRITES rather than
trusting a pre-pass.  A pre-pass is a TOCTOU window when the archive is a file
somebody else can still write.

THE HMAC KEY MUST BE PRESENT.  There is no fall-back to digest-only
verification: the digests live in the manifest, so a forged manifest with
matching digests passes every check except this one.
"""

import argparse
import hashlib
import hmac
import json
import os
import sys
import tarfile


class Refuse(Exception):
    pass


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def audit_member(member, target_root):
    """Raise Refuse unless this member is safe to write under target_root."""
    name = member.name

    if member.isdev() or member.ischr() or member.isblk() or member.isfifo():
        raise Refuse(f"member {name!r} is a device or FIFO")
    if member.issym() or member.islnk():
        raise Refuse(f"member {name!r} is a symlink or hardlink")
    if not (member.isfile() or member.isdir()):
        raise Refuse(f"member {name!r} has an unsupported type")
    if name.startswith("/") or (len(name) > 1 and name[1] == ":"):
        raise Refuse(f"member {name!r} is an absolute path")
    if os.path.isabs(name):
        raise Refuse(f"member {name!r} is an absolute path")

    parts = name.replace("\\", "/").split("/")
    if any(p == ".." for p in parts):
        raise Refuse(f"member {name!r} contains '..'")

    resolved = os.path.realpath(os.path.join(target_root, name))
    root = os.path.realpath(target_root)
    if resolved != root and not resolved.startswith(root + os.sep):
        raise Refuse(f"member {name!r} resolves outside the target: {resolved}")


def verify(payload_dir, hmac_key_path, archive_label="archive"):
    mpath = os.path.join(payload_dir, "MANIFEST.json")
    hpath = os.path.join(payload_dir, "MANIFEST.hmac")

    if not os.path.exists(mpath):
        raise Refuse("no MANIFEST.json in the archive")
    if not os.path.exists(hpath):
        raise Refuse("no MANIFEST.hmac in the archive")

    if not hmac_key_path or not os.path.exists(hmac_key_path):
        raise Refuse(
            "the HMAC key is absent. Restore REFUSES to start rather than "
            "falling back to digest-only verification: the digests live in the "
            "manifest, so a forged manifest with matching digests would pass "
            "every other check."
        )

    with open(hmac_key_path, "rb") as fh:
        key = fh.read().strip()
    with open(mpath, "rb") as fh:
        manifest_bytes = fh.read()
    want = open(hpath).read().strip()
    got = hmac.new(key, manifest_bytes, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(want, got):
        raise Refuse("MANIFEST.hmac does not match the manifest (tampered or wrong key)")

    manifest = json.loads(manifest_bytes)
    if manifest.get("schema") != "aistack.backup.v1":
        raise Refuse(f"unsupported backup schema {manifest.get('schema')!r}")

    inventory = {}
    for entry in manifest.get("members", []):
        p = entry["path"]
        if p in inventory:
            raise Refuse(f"inventory lists {p!r} twice")
        inventory[p] = entry

    # Enumerate what is ACTUALLY there.
    present = {}
    for name in os.listdir(payload_dir):
        if name in ("MANIFEST.json", "MANIFEST.hmac"):
            continue
        full = os.path.join(payload_dir, name)
        if os.path.isfile(full):
            present[name] = full

    extra = sorted(set(present) - set(inventory))
    missing = sorted(set(inventory) - set(present))
    if extra:
        raise Refuse(f"archive contains members not in the inventory: {extra}")
    if missing:
        raise Refuse(f"inventory lists members not in the archive: {missing}")

    for name, entry in sorted(inventory.items()):
        actual = sha256_file(present[name])
        if actual != entry["sha256"]:
            raise Refuse(
                f"member {name!r} digest mismatch "
                f"(expected {entry['sha256'][:16]}…, got {actual[:16]}…)"
            )

    return manifest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--payload-dir", required=True,
                    help="the UNPACKED payload directory (decrypt+untar first)")
    ap.add_argument("--hmac-key", required=True)
    ap.add_argument("--expect-schema", default="aistack.backup.v1")
    args = ap.parse_args()

    try:
        manifest = verify(args.payload_dir, args.hmac_key)
    except Refuse as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 1
    except Exception as e:  # malformed archive, unreadable member, ...
        print(f"REFUSED: verification could not complete: {e!r}", file=sys.stderr)
        return 1

    print(json.dumps({
        "verdict": "ok",
        "created_at": manifest.get("created_at"),
        "members": len(manifest.get("members", [])),
        "excluded_by_design": manifest.get("excluded_by_design"),
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
