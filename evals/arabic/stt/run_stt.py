"""Transcribe the STT sample set with one model and write raw results (JSONL).

Runs INSIDE the voice-arabic STT image (faster-whisper 1.2.1, CTranslate2 4.8.3),
offline, one container per model so the container's memory peak belongs to
that model alone (see run.sh stt).  Decoding settings are the ones the
voice-arabic profile ships (build/stt-arabic/server.py): language ar, int8,
beam 1, VAD on, no conditioning on previous text, 4 threads.

  python run_stt.py <model_dir> <label> <out.jsonl> <set_dir>=<name> ...
Each set dir holds audio/<id>.wav and a refs file (sentences.jsonl or refs.jsonl).
Scoring is separate (score.py), so raw transcripts stay inspectable.
"""
import json
import os
import resource
import sys
import time

from faster_whisper import WhisperModel, decode_audio

model_dir, label, out_path = sys.argv[1:4]
sets = [a.split("=", 1) for a in sys.argv[4:]]


def cgroup_peak():
    for p in ("/sys/fs/cgroup/memory.peak", "/sys/fs/cgroup/memory/memory.max_usage_in_bytes"):
        try:
            return int(open(p).read())
        except OSError:
            pass
    return None


t0 = time.monotonic()
model = WhisperModel(model_dir, device="cpu", compute_type="int8", cpu_threads=4, local_files_only=True)
load_s = time.monotonic() - t0
first = True
n = 0
with open(out_path, "w", encoding="utf-8") as out:
    for set_dir, set_name in sets:
        refs = os.path.join(set_dir, "sentences.jsonl")
        if not os.path.exists(refs):
            refs = os.path.join(set_dir, "refs.jsonl")
        for line in open(refs, encoding="utf-8"):
            if not line.strip():
                continue
            r = json.loads(line)
            wav = os.path.join(set_dir, "audio", r.get("file", r["id"] + ".wav"))
            dur = len(decode_audio(wav, sampling_rate=16000)) / 16000  # FLEURS is float WAV; decode, don't parse
            if first:  # warm-up, not timed: the first call pays one-off allocation costs
                list(model.transcribe(wav, language="ar", beam_size=1, vad_filter=True,
                                      condition_on_previous_text=False)[0])
                first = False
            t1 = time.monotonic()
            segs, _ = model.transcribe(wav, language="ar", beam_size=1, vad_filter=True,
                                       condition_on_previous_text=False)
            text = " ".join(s.text.strip() for s in segs).strip()
            wall = time.monotonic() - t1
            out.write(json.dumps({"model": label, "set": set_name, "id": r["id"], "audio_s": round(dur, 2),
                                  "wall_s": round(wall, 2), "hyp": text}, ensure_ascii=False) + "\n")
            n += 1
            print(f"{label} {set_name} {r['id']} {dur:.1f}s audio in {wall:.1f}s", flush=True)
    rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
    peak = cgroup_peak()
    out.write(json.dumps({"model": label, "meta": True, "clips": n, "load_s": round(load_s, 1),
                          "max_rss_mb": round(rss_mb), "cgroup_peak_mb": round(peak / 2**20) if peak else None,
                          "loadavg": os.getloadavg()}) + "\n")
print(f"{label}: {n} clips, load {load_s:.1f}s, max RSS {rss_mb:.0f} MB")
if n == 0:
    sys.exit("no clips transcribed")
