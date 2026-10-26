"""Download model files at one pinned revision and verify each sha256.

Reads models.lock lines `repo revision file sha256 licence`.  A missing or
mismatched hash stops the build: the weights are part of the image's identity,
exactly like a wheel in requirements.lock.  A licence outside the
commercial-safe list stops it too (DoD rule 5); CI checks the same list (I19).
"""
import hashlib
import os
import sys

from huggingface_hub import hf_hub_download

COMMERCIAL_SAFE = {"Apache-2.0", "MIT", "CC0-1.0", "BSD-3-Clause"}

dest = sys.argv[1]
os.makedirs(dest, exist_ok=True)
n = 0
for line in open("models.lock"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    repo, rev, name, want, licence = line.split()
    if licence not in COMMERCIAL_SAFE:
        sys.exit(f"{repo}/{name}: licence {licence} is not on the commercial-safe list")
    path = hf_hub_download(repo, name, revision=rev, local_dir=dest)
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != want:
        sys.exit(f"sha256 mismatch for {repo}@{rev}/{name}: got {h.hexdigest()}, want {want}")
    n += 1
    print(f"ok {repo}@{rev[:8]} {name}")
if n == 0:
    sys.exit("models.lock lists no files; refusing to build an image without weights")

# faster-whisper sizes its mel filterbank from preprocessor_config.json and
# silently falls back to 80 bins without it.  large-v3(-turbo) needs 128, and
# this export ships the same settings as processor_config.json, so the file is
# derived from that one (which is hash-checked above) rather than downloaded.
proc = os.path.join(dest, "processor_config.json")
pre = os.path.join(dest, "preprocessor_config.json")
if os.path.exists(proc) and not os.path.exists(pre):
    import json
    fe = json.load(open(proc))["feature_extractor"]
    if fe.get("feature_size") != 128:
        sys.exit(f"unexpected feature_size {fe.get('feature_size')} in processor_config.json")
    json.dump(fe, open(pre, "w"), indent=2)
    print("derived preprocessor_config.json (feature_size 128)")
