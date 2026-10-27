# Demo 6 -- Arabic scanned document -> text -> question answered.  Runs INSIDE
# open-webui after demos/lib/owui_common.py.  argv[1] = JSON
# {"model": ..., "expected": <make-arabic-scan.py --expected>}; the PDF is on
# the container's /tmp/demo6-arabic-scan.pdf (run.sh copies it in).
#
# The fixture is samples/fixtures/arabic-scan.pdf: an IMAGE-ONLY synthetic
# invoice reminder (no text layer), so only OCR can read it.  Two stages, scored
# apart, because they fail for different reasons:
#   A. text  -- Open WebUI's own upload sends it to its parser (docling-arabic,
#               Tesseract `ara`); every expected word and number must come back;
#   B. answer -- three Arabic questions about the page, each scored per FIELD as
#               match / wrong / absent.  The invoice number is required.  The
#               amount and the due date are REPORTED: NOM-415 measured that
#               Docling emits the value before its label on RTL "label: value"
#               lines, which can pair a value with the wrong label.
args = json.loads(sys.argv[1])
MODEL, EXP = args["model"], args["expected"]

H, me = signin()
check("signed in as the owner through the trusted header", me.get("role") == "admin", f"{me.get('email')}")
cfg = req("/api/v1/retrieval/config", headers=H)
check("Open WebUI's parser is Docling -> docling-arabic (profile docs-arabic)",
      cfg.get("CONTENT_EXTRACTION_ENGINE") == "docling" and "docling-arabic" in (cfg.get("DOCLING_SERVER_URL") or ""),
      f"{cfg.get('CONTENT_EXTRACTION_ENGINE')} {cfg.get('DOCLING_SERVER_URL')}")

pdf = open("/tmp/demo6-arabic-scan.pdf", "rb").read()
t0 = time.monotonic()
f = upload(H, "arabic-scan.pdf", pdf, "application/pdf")
TIMES["ocr_s"] = round(time.monotonic() - t0, 1)
text = (req(f"/api/v1/files/{f['id']}/data/content", headers=H) or {}).get("content", "")
print("  OCR text:")
for line in text.strip().splitlines()[:12]:
    print("    | " + line)
nt = norm_ar(text)
words = [w for w in EXP["words"] if norm_ar(w) in nt]
nums = [n for n in EXP["numbers"] if n in nt]
check(f"A. OCR text has every expected word ({len(words)}/{len(EXP['words'])})", len(words) == len(EXP["words"]),
      f"missing: {[w for w in EXP['words'] if w not in words]}" if len(words) < len(EXP["words"]) else f"{TIMES['ocr_s']} s")
check(f"A. OCR text has every expected number ({len(nums)}/{len(EXP['numbers'])})", len(nums) == len(EXP["numbers"]),
      f"missing: {[n for n in EXP['numbers'] if n not in nums]}" if len(nums) < len(EXP["numbers"]) else "")

SYSTEM = "أجب من المستند المرفق فقط. إذا لم يحتوِ المستند على الجواب فقل ذلك. أجب بالعربية في جملة واحدة."
FIELDS = [
    ("invoice_no", "ما رقم الفاتورة في هذا المستند؟", ["2041"], ["12,500", "12500"], True),
    ("amount", "ما المبلغ المستحق في هذا المستند؟", ["12,500", "12500", "12.500", "اثني عشر ألفا وخمسمائة"], ["2041"], False),
    ("due_date", "ما تاريخ الاستحقاق في هذا المستند؟", ["15 نوفمبر 2026", "15 نوفمبر", "١٥ نوفمبر"], ["12,500"], False),
]
fields = {}
for key, q, good, bad, required in FIELDS:
    d, dt = chat(H, MODEL, [{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}],
                 files=[{"type": "file", "id": f["id"]}])
    TIMES[key + "_s"] = round(dt, 1)
    a = strip_think(answer_text(d))
    v = "match" if has_any(a, good) else ("wrong" if has_any(a, bad) else "absent")
    fields[key] = v
    note(f"{key}: {q}")
    note(f"      -> {a[:240]!r}  ({dt:.1f} s)")
    if required:
        check(f"B. {key}: {v}", v == "match", f"expected {good[0]}")
        check(f"B. {key}: answered in Arabic", arabic_ratio(a) >= 0.5, f"{arabic_ratio(a):.0%}")
    else:
        print(f"  [info] B. {key}: {v} [reported, not required: RTL label/value pairing, NOM-415 §4]", flush=True)

try:
    req(f"/api/v1/files/{f['id']}", headers=H, method="DELETE")
except urllib.error.HTTPError:
    pass
print("  fields:", json.dumps(fields))
finish("06-arabic-scan-to-answer")
