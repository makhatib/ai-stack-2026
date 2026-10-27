# Demo 3 -- chat with my documents in Open WebUI.  Runs INSIDE open-webui,
# after demos/lib/owui_common.py (run.sh joins the two).  argv[1] is a JSON
# object: {"model": ..., "docs": {"<name>": "<utf-8 text>"}, "keep": bool}.
#
# What it proves, through Open WebUI's own API (what its chat box does):
#  1. the three synthetic documents upload and are processed (parsed, chunked,
#     embedded into pgvector) by the stack, not by this script;
#  2. a knowledge base made of them answers questions WITH THE DOCUMENT'S
#     VALUE, and cites the right file;
#  3. it does not invent a value the documents do not contain.
# Each answer is scored match / wrong / absent against values fixed BEFORE the
# run (fluency is not scored: a fluent wrong number is a FAIL).
args = json.loads(sys.argv[1])
MODEL = args["model"]
KB_NAME = "Demo 3 - synthetic company documents"

QUESTIONS = [
    # id, question, expected values (any), known wrong values, expected source, required
    ("Q1-en", "According to the travel policy, how much is the daily meal allowance inside the Kingdom?",
     ["185"], ["240", "650", "480"], "en-travel-policy.md", True),
    ("Q2-ar", "كم يوماً من الإجازة السنوية يحصل عليه الموظف في شركة الواحة للتجارة؟",
     ["30", "ثلاثين", "ثلاثون"], ["15", "خمسة عشر"], "ar-leave-policy.md", True),
    ("Q3-ar-about-en", "متى افتُتح مستودع الدمام الجديد لشركة فالكون ريدج؟",
     ["12 أغسطس", "12 August", "August 12", "2026-08-12", "12/8/2026", "١٢ أغسطس"], ["4 October", "4 أكتوبر"],
     "en-q3-operations-note.md", False),
]
NOT_IN_DOCS = ("Q4-not-in-docs", "What is the monthly salary of the CEO of Falcon Ridge Logistics? Answer only from the documents.")

H, me = signin()
check("signed in as the owner through the trusted header", me.get("role") == "admin", f"{me.get('email')} role={me.get('role')}")
models = [m["id"] for m in req("/api/models", headers=H).get("data", [])]
check(f"model `{MODEL}` is offered by LiteLLM", MODEL in models, ", ".join(models))
emb = req("/api/v1/retrieval/embedding", headers=H)
check("documents are embedded with bge-m3 through LiteLLM (`embed`)",
      emb.get("RAG_EMBEDDING_ENGINE") == "openai" and emb.get("RAG_EMBEDDING_MODEL") == "embed"
      and "litellm" in (emb.get("openai_config") or {}).get("url", ""),
      f"{emb.get('RAG_EMBEDDING_ENGINE') or 'built-in'} / {emb.get('RAG_EMBEDDING_MODEL')}")

# A clean knowledge base every run, so an old upload cannot make a pass.
listing = req("/api/v1/knowledge/", headers=H) or {}
for kb in (listing.get("items", []) if isinstance(listing, dict) else listing):
    if kb.get("name") == KB_NAME:
        req(f"/api/v1/knowledge/{kb['id']}/delete", headers=H, method="DELETE")
kb = req("/api/v1/knowledge/create", {"name": KB_NAME, "description": "Synthetic. NOM-416 demo 3."}, H)

t0 = time.monotonic()
file_ids = {}
for name, text in args["docs"].items():
    f = upload(H, name, text.encode("utf-8"), "text/markdown")
    file_ids[name] = f["id"]
    req(f"/api/v1/knowledge/{kb['id']}/file/add", {"file_id": f["id"]}, H)
TIMES["upload_and_embed_s"] = round(time.monotonic() - t0, 1)
check(f"{len(file_ids)} documents uploaded, parsed and embedded into the knowledge base", len(file_ids) == len(args["docs"]),
      f"{TIMES['upload_and_embed_s']} s")

SYSTEM = ("Answer from the provided documents only. If the documents do not contain the answer, say so. "
          "Answer in the language of the question, in one or two sentences.")
scores = {}
for qid, q, good, bad, src, required in QUESTIONS:
    d, dt = chat(H, MODEL, [{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}],
                 files=[{"type": "collection", "id": kb["id"]}])
    TIMES[qid + "_s"] = round(dt, 1)
    a = strip_think(answer_text(d))
    hit, wrong = has_any(a, good), has_any(a, bad)
    verdict = "match" if hit else ("wrong" if wrong else "absent")
    srcs = d.get("sources") or []
    names = sorted({m.get("name", "") for s in srcs for m in (s.get("metadata") or [])})
    cited = src in names
    # RETRIEVAL and ANSWER are scored apart: "the right passage was handed to
    # the model" and "the model used it" fail for different reasons.
    chunks = [c for s in srcs for c in (s.get("document") or [])]
    retrieved = any(has_any(c, good) for c in chunks)
    scores[qid] = verdict
    note(f"{qid}: {q}")
    note(f"      -> {a[:300]!r}")
    note(f"      sources: {names}; passage with the value retrieved: {retrieved}  ({dt:.1f} s)")
    label = f"{qid}: answer has the document's value ({verdict})" + ("" if required else " [reported, not required]")
    if required:
        check(f"{qid}: the passage with the answer was retrieved", retrieved)
        check(label, verdict == "match", f"expected one of {good}")
        check(f"{qid}: cites {src}", cited)
    else:
        print(f"  [info] {label}; retrieved: {retrieved}; cited {src}: {cited}", flush=True)
    if qid.endswith("-ar") or qid.startswith("Q2"):
        check(f"{qid}: answered in Arabic", arabic_ratio(a) >= 0.5, f"Arabic letters {arabic_ratio(a):.0%}")

qid, q = NOT_IN_DOCS
d, dt = chat(H, MODEL, [{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}],
             files=[{"type": "collection", "id": kb["id"]}])
TIMES[qid + "_s"] = round(dt, 1)
a = strip_think(answer_text(d))
invented = re.findall(r"\d[\d,.\s]{2,}", norm_ar(a))
note(f"{qid}: {q}")
note(f"      -> {a[:300]!r}")
check(f"{qid}: no salary is invented (no number in the answer)", not invented, f"numbers seen: {invented}" if invented else "")

if not args.get("keep"):
    req(f"/api/v1/knowledge/{kb['id']}/delete", headers=H, method="DELETE")
    for fid in file_ids.values():
        try:
            req(f"/api/v1/files/{fid}", headers=H, method="DELETE")
        except urllib.error.HTTPError:
            pass
else:
    note(f"kept the knowledge base '{KB_NAME}' for the camera (DEMO_KEEP=1)")
print("  scores:", json.dumps(scores))
finish("03-chat-with-documents")
