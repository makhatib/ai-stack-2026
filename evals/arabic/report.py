#!/usr/bin/env python3
"""Turn results/summary.json (+ results/raw/mem-*.json) into results/tables.md:
one table each for STT, OCR and chat, plus the detail a reviewer needs.
Standard library only."""
import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
S = json.load(open(os.path.join(HERE, "results", "summary.json"), encoding="utf-8"))
MEM = {}
for p in glob.glob(os.path.join(HERE, "results", "raw", "mem-*.json")):
    m = json.load(open(p))
    MEM[m.get("engine") or m.get("model")] = m
env = S.get("env", {})
HW = f"{env.get('vcpus', '?')} vCPU, {env.get('ram_gib', '?')} GiB, no GPU"

STT_INFO = {
    "whisper-v3-turbo-ar-ft": ("Whisper large-v3-turbo, Arabic fine-tune (Omar10lfc, CT2 int8 @873028c)", "Apache-2.0"),
    "whisper-v3-turbo-base": ("Whisper large-v3-turbo, base (OpenAI; CT2 export deepdml @4df90f7, run as int8)", "MIT"),
}
OCR_INFO = {
    "tesseract-4.1.1-ara+eng": ("Tesseract 4.1.1, `ara`+`eng` (tessdata_best @e12c65a)", "Apache-2.0"),
    "docling-tesseract": ("Docling 2.142.1 (docling-serve 1.38.1) + Tesseract `ara`+`eng` — **the docs-arabic profile**", "MIT + Apache-2.0"),
    "vlm-qwen3.5:2b": ("Qwen 3.5 2B (vision), Ollama, Q8_0", "Apache-2.0"),
    "vlm-qwen3.5:4b": ("Qwen 3.5 4B (vision), Ollama, Q4_K_M", "Apache-2.0"),
    "vlm-gemma4:e2b": ("Gemma 4 E2B (vision), Ollama, Q4_K_M", "Apache-2.0"),
    "vlm-qwen3.5:9b": ("Qwen 3.5 9B (vision), Ollama, Q4_K_M", "Apache-2.0"),
}
CHAT_INFO = {
    "qwen3.5:2b": ("Qwen 3.5 2B, Q8_0", "1 (8 GB)", "Apache-2.0"),
    "qwen3.5:4b": ("Qwen 3.5 4B, Q4_K_M", "1 stretch", "Apache-2.0"),
    "gemma4:e2b": ("Gemma 4 E2B, Q4_K_M", "2 (16 GB)", "Apache-2.0"),
    "qwen3.5:9b": ("Qwen 3.5 9B, Q4_K_M", "2 (16 GB)", "Apache-2.0"),
}


def ram(key):
    m = MEM.get(key) or {}
    if m.get("cgroup_peak_mb"):
        return f"{m['cgroup_peak_mb'] / 1024:.1f} GiB"
    return "?"


L = []
w = L.append
w(f"Hardware for every row: AI-Sandbox VM, {HW} ({env.get('cpu', '?')}), shared with other tenants; "
  f"Ollama {env.get('ollama', '?')}; repo commit `{env.get('repo_commit', '?')}`; run {env.get('date_utc', '?')} UTC.\n")

# ---- STT
w("### Speech-to-text\n")
w("| Model + version | Licence | WER synthetic (14 sent.) | WER human control (FLEURS, 20) | CER FLEURS | Numbers/dates (field match) | Time ÷ audio length (1.0 = real time) | RAM peak |")
w("|---|---|---|---|---|---|---|---|")
for k, r in S["stt"].items():
    if k.startswith("_"):
        continue
    name, lic = STT_INFO.get(k, (k, "?"))
    f = r["fields"]
    w(f"| {name} | {lic} | **{r['synthetic_wer']} %** (MSA {r['msa_wer']}, Gulf {r['gulf_wer']}, code-switch {r['codeswitch_wer']}) "
      f"| **{r['fleurs_wer']} %** | {r['fleurs_cer']} % | {f.get('match', 0)}/{r['fields_total']} match, {f.get('wrong', 0)} wrong, {f.get('absent', 0)} absent "
      f"| {r['rtf']} | {r['cgroup_peak_mb'] / 1024:.1f} GiB |")
w("")
for k, r in S["stt"].items():
    if k.startswith("_"):
        continue
    if r.get("rtf_by_set"):
        w(f"- {k}, time ÷ audio length by set: " + ", ".join(f"{s_} {v}" for s_, v in r["rtf_by_set"].items())
          + f"; model load {r['load_s']} s.")
for k, r in S["stt"].items():
    if k.startswith("_"):
        continue
    bad = [x for x in r["field_rows"] if x["verdict"] != "match"]
    if bad:
        w(f"- {k}, fields not matched: " + "; ".join(f"{x['id']} {x['name']} want `{x['expected']}` got `{x['got']}` ({x['verdict']})" for x in bad))
if S["stt"].get("_missed_by_all"):
    w("- Words of the synthetic set missed by **both** models (likely the TTS, not the STT): "
      + "; ".join(f"{x['id']}: {' '.join(x['words'])}" for x in S["stt"]["_missed_by_all"]))
w("")

# ---- OCR
w("### OCR (6 synthetic scanned pages)\n")
w("| Engine + version | Licence | CER | Words found | Fields found | Invented numbers | Time / page | RAM peak |")
w("|---|---|---|---|---|---|---|---|")
for k, r in S["ocr"].items():
    name, lic = OCR_INFO.get(k, (k, "?"))
    w(f"| {name} | {lic} | **{r['cer']} %** | {r['word_recall']} % | {r['fields_found']}/{r['fields']} | {r['invented_numbers']} "
      f"| {r['sec_per_page']} s | {ram(k)} |")
w("")
docs = sorted(next(iter(S["ocr"].values()))["docs"]) if S["ocr"] else []
if docs:
    w("CER per page (%):\n")
    w("| Engine | " + " | ".join(docs) + " |")
    w("|---|" + "---|" * len(docs))
    for k, r in S["ocr"].items():
        w(f"| {k} | " + " | ".join(str(r["docs"][d]["cer"]) for d in docs) + " |")
    w("")
    for k, r in S["ocr"].items():
        miss = [f"{d} {f['name']}" for d in docs for f in r["docs"][d]["field_rows"] if f["verdict"] != "found"]
        inv = [f"{d}: {' '.join(r['docs'][d]['invented_numbers'])}" for d in docs if r["docs"][d]["invented_numbers"]]
        w(f"- {k}: fields not found: {', '.join(miss) or 'none'}. Invented numbers: {'; '.join(inv) or 'none'}.")
    w("")

# ---- chat
w("### Chat models (24 fixed questions)\n")
w("| Model + version | Tier | Licence | Score | Numbers & dates | Safety & grounding | MSA / Gulf / code-switch | Invented numbers | Median time / answer | Gen. speed | RAM peak |")
w("|---|---|---|---|---|---|---|---|---|---|---|")
for k, r in S["chat"].items():
    name, tier, lic = CHAT_INFO.get(k, (k, "?", "?"))
    b = r["by_style"]
    w(f"| {name} | {tier} | {lic} | **{r['passed']}/{r['questions']}** ({r['passed_unflagged']}/{r['questions_unflagged']} without q24) | {r['numbers']} | {r['safety']} | {b['msa']} / {b['gulf']} / {b['codeswitch']} "
      f"| {r['invented_numbers']} | {r['median_wall_s']} s | {r['gen_tps_median']} tok/s | {ram(k)} |")
w("")
for k, r in S["chat"].items():
    fails = [f"{i} ({'; '.join(p['why'])})" for i, p in r["per_question"].items() if not p["pass"]]
    w(f"- {k} failed: {', '.join(fails) or 'none'}" + (" — **thinking output seen**" if r["thinking_seen"] else ""))

open(os.path.join(HERE, "results", "tables.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")
print("\n".join(L))
