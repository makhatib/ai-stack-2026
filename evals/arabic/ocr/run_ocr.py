"""Run one OCR engine over ocr/docs and write raw results (JSONL), one line per page.

  python3 run_ocr.py tesseract <container> <out.jsonl>        Tesseract CLI inside the docling-arabic image
  python3 run_ocr.py docling   <base-url>  <out.jsonl> <engine> <lang,lang>
                                                            docling-serve API, the docs-arabic profile path
  python3 run_ocr.py vlm       <ollama-url> <out.jsonl> <model>
                                                            a vision chat model in Ollama, asked to transcribe

Standard library only.  Scoring is separate (score.py), so the raw text stays
inspectable.  Docling gets the image-only PDF (what a user uploads); Tesseract and
the vision models get the PNG of the same page.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
DOCS = sorted(json.load(open(os.path.join(HERE, "docs", "truth.json"), encoding="utf-8"))["docs"])
mode, target, out_path = sys.argv[1:4]
extra = sys.argv[4:]

VLM_PROMPT = ("Transcribe all the text in this image exactly as written, line by line, from top to bottom. "
              "Keep Arabic text in Arabic and English text in English. Keep digits exactly as they appear. "
              "Do not translate, summarise, correct or add anything. Output only the text.")


def post(url, data, headers, timeout=1800):
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), timeout=timeout) as f:
        return json.loads(f.read())


def docling(path, engine, langs):
    b = uuid.uuid4().hex
    parts = [("to_formats", "md"), ("do_ocr", "true"), ("force_ocr", "false"), ("ocr_engine", engine),
             ("image_export_mode", "placeholder")] + [("ocr_lang", x) for x in langs]
    body = b"".join(f"--{b}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode() for k, v in parts)
    body += (f"--{b}\r\nContent-Disposition: form-data; name=\"files\"; filename=\"{os.path.basename(path)}\"\r\n"
             "Content-Type: application/pdf\r\n\r\n").encode() + open(path, "rb").read() + f"\r\n--{b}--\r\n".encode()
    r = post(target.rstrip("/") + "/v1/convert/file", body, {"Content-Type": f"multipart/form-data; boundary={b}"})
    if r.get("status") not in ("success", "partial_success"):
        raise RuntimeError(f"docling status {r.get('status')}: {r.get('errors')}")
    return r["document"]["md_content"] or ""


def vlm(path, model):
    req = {"model": model, "stream": False, "think": False,
           "options": {"temperature": 0, "seed": 418, "num_predict": 700, "num_ctx": 8192},
           "messages": [{"role": "user", "content": VLM_PROMPT,
                         "images": [base64.b64encode(open(path, "rb").read()).decode()]}]}
    r = post(target.rstrip("/") + "/api/chat", json.dumps(req).encode(), {"Content-Type": "application/json"})
    stats = {k: r.get(k) for k in ("prompt_eval_count", "eval_count", "prompt_eval_duration", "eval_duration",
                                   "load_duration")}
    return r["message"]["content"], stats


n = 0
with open(out_path, "w", encoding="utf-8") as out:
    for did in DOCS:
        pdf, png = os.path.join(HERE, "docs", did + ".pdf"), os.path.join(HERE, "docs", did + ".png")
        stats = None
        t0 = time.monotonic()
        if mode == "tesseract":
            text = subprocess.run(["docker", "exec", target, "tesseract", f"/docs/{did}.png", "-", "-l", "ara+eng"],
                                  check=True, capture_output=True, text=True).stdout
            label = "tesseract-4.1.1-ara+eng"
        elif mode == "docling":
            text = docling(pdf, extra[0], extra[1].split(","))
            label = f"docling-{extra[0]}"
        elif mode == "vlm":
            text, stats = vlm(png, extra[0])
            label = f"vlm-{extra[0]}"
        else:
            sys.exit(f"unknown mode {mode}")
        wall = time.monotonic() - t0
        out.write(json.dumps({"engine": label, "doc": did, "wall_s": round(wall, 1), "text": text,
                              "stats": stats, "loadavg": os.getloadavg()}, ensure_ascii=False) + "\n")
        out.flush()
        n += 1
        print(f"{label} {did} {wall:.1f}s {len(text)} chars", flush=True)
if n != len(DOCS) or n == 0:
    sys.exit(f"only {n} of {len(DOCS)} pages processed")
