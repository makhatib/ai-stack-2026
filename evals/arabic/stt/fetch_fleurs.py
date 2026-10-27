"""Fetch the human-speech CONTROL set for the STT test: 20 clips of Google FLEURS
Arabic (ar_eg, test split), 20 different sentences.  Every speaker in this split
is labelled FEMALE (428/428 rows; only the train split has male speakers), so
the control has no male voice.

Why a control: our own sample set is synthetic speech from our TTS.  If both STT
models miss a word there, the TTS may have said it wrong.  FLEURS is real people
reading Wikipedia sentences (MSA, Egyptian speakers), so it shows how the models
hear humans.  It is NOT our data and NOT customer data.

Licence: FLEURS is CC-BY-4.0 (Conneau et al., 2022, https://huggingface.co/datasets/google/fleurs).
The clips are not committed to this repo; this script downloads them at one
pinned dataset revision and checks every clip against fleurs.lock.

  python3 fetch_fleurs.py <dest-dir>            # download + verify (writes <dest>/audio, <dest>/refs.jsonl)
  python3 fetch_fleurs.py <dest-dir> --pick     # re-derive the pick and print a new lock (maintainer only)
Standard library only; streams the 243 MB archive and stops after the last pick.
"""
import csv
import hashlib
import json
import os
import sys
import tarfile
import urllib.request

REV = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
BASE = f"https://huggingface.co/datasets/google/fleurs/resolve/{REV}/data/ar_eg"
HERE = os.path.dirname(os.path.abspath(__file__))
N = 20

dest = sys.argv[1]
pick_mode = "--pick" in sys.argv
os.makedirs(os.path.join(dest, "audio"), exist_ok=True)
csv.field_size_limit(1 << 24)

with urllib.request.urlopen(f"{BASE}/test.tsv") as f:
    tsv = f.read().decode("utf-8")
# columns: sentence id, file, raw transcription, normalised transcription, chars, samples, gender
rows = {r[1]: r for r in csv.reader(tsv.splitlines(), delimiter="\t", quoting=csv.QUOTE_NONE)}

lock = {}
if not pick_mode:
    for line in open(os.path.join(HERE, "fleurs.lock"), encoding="utf-8"):
        if line.strip() and not line.startswith("#"):
            name, sid, sha, gender = line.rstrip("\n").split("\t")
            lock[name] = (sid, sha, gender)
    if len(lock) != N:
        sys.exit(f"fleurs.lock lists {len(lock)} clips, expected {N}")

got, seen = {}, set()
with urllib.request.urlopen(f"{BASE}/audio/test.tar.gz") as resp, tarfile.open(fileobj=resp, mode="r|gz") as t:
    for m in t:
        if not m.isfile():
            continue
        name = m.name.rsplit("/", 1)[-1]
        r = rows.get(name)
        if r is None:
            continue
        if pick_mode:
            if r[0] in seen:
                continue
        elif name not in lock:
            continue
        data = t.extractfile(m).read()
        sha = hashlib.sha256(data).hexdigest()
        if not pick_mode and sha != lock[name][1]:
            sys.exit(f"sha256 mismatch for {name}: got {sha}, want {lock[name][1]}")
        with open(os.path.join(dest, "audio", name), "wb") as out:
            out.write(data)
        got[name] = (r[0], sha, r[6], r[2])
        if pick_mode:
            seen.add(r[0])
        if len(got) == N:
            break

if len(got) != N:
    sys.exit(f"only {len(got)} of {N} clips found in the archive")
with open(os.path.join(dest, "refs.jsonl"), "w", encoding="utf-8") as out:
    for name in sorted(got):
        sid, sha, gender, text = got[name]
        out.write(json.dumps({"id": name[:-4], "file": name, "sentence_id": sid, "gender": gender,
                              "text": text}, ensure_ascii=False) + "\n")
if pick_mode:
    print(f"# FLEURS ar_eg test @ {REV}: file, sentence id, sha256, gender")
    for name in sorted(got):
        sid, sha, gender, _ = got[name]
        print(f"{name}\t{sid}\t{sha}\t{gender}")
else:
    print(f"fleurs: {len(got)} clips verified -> {dest}")
