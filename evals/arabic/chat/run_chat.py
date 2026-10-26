"""Ask every question in chat/questions.jsonl to one Ollama model; write raw answers (JSONL).

  python3 run_chat.py <ollama-url> <model> <out.jsonl>

Each question is a fresh one-turn chat with the same system prompt (context.md):
synthetic invoice data for one customer, and the assistant's rules (Arabic only,
use only this data, say when you don't know, automated assistant, no threats or
promises, hand off to a person on request).  temperature 0, fixed seed, thinking
off, so a re-run on the same model and Ollama version gives the same answer.
Standard library only.  Scoring is separate (score.py).
"""
import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
url, model, out_path = sys.argv[1:4]
system = open(os.path.join(HERE, "context.md"), encoding="utf-8").read()
qs = [json.loads(line) for line in open(os.path.join(HERE, "questions.jsonl"), encoding="utf-8") if line.strip()]


def chat(q):
    req = {"model": model, "stream": False, "think": False, "keep_alive": "30m",
           "options": {"temperature": 0, "seed": 418, "num_predict": 400, "num_ctx": 4096},
           "messages": [{"role": "system", "content": system}, {"role": "user", "content": q}]}
    r = urllib.request.Request(url.rstrip("/") + "/api/chat", json.dumps(req).encode(),
                               {"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=1800) as f:
        return json.loads(f.read())


# warm-up (not scored, not timed): loads the model so question 1 doesn't pay the load time
t0 = time.monotonic()
chat("مرحبا")
load_s = time.monotonic() - t0
n = 0
with open(out_path, "w", encoding="utf-8") as out:
    for q in qs:
        t0 = time.monotonic()
        r = chat(q["q"])
        wall = time.monotonic() - t0
        ev, evd = r.get("eval_count") or 0, (r.get("eval_duration") or 0) / 1e9
        pe, ped = r.get("prompt_eval_count") or 0, (r.get("prompt_eval_duration") or 0) / 1e9
        out.write(json.dumps({"model": model, "id": q["id"], "answer": r["message"]["content"],
                              "thinking": bool(r["message"].get("thinking")), "wall_s": round(wall, 1),
                              "gen_tokens": ev, "gen_tps": round(ev / evd, 2) if evd else None,
                              "prompt_tokens": pe, "prompt_tps": round(pe / ped, 1) if ped else None,
                              "loadavg": os.getloadavg()}, ensure_ascii=False) + "\n")
        out.flush()
        n += 1
        print(f"{model} {q['id']} {wall:.1f}s {ev} tok", flush=True)
    out.write(json.dumps({"model": model, "meta": True, "questions": n, "warmup_s": round(load_s, 1)}) + "\n")
if n != len(qs):
    sys.exit(f"only {n} of {len(qs)} questions answered")
