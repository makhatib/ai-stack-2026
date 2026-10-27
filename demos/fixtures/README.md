# Demo fixtures — all synthetic

Nothing here comes from a real person, company or customer. The companies
(*Falcon Ridge Logistics*, *Al Waha Trading / شركة الواحة للتجارة*), names,
amounts, dates, codes and phone extensions are invented. Each file says so in
its first lines.

| File | Used by | What it is |
|---|---|---|
| `docs/en-travel-policy.md` | demo 3 | English travel and expense policy (meal allowance 185 SAR, hotel cap 650 SAR, approval above 4,000 SAR, claims within 14 days) |
| `docs/en-q3-operations-note.md` | demo 3 | English operations note (47 trucks, Dammam depot opened 12 August 2026, 93.4 % on time) |
| `docs/ar-leave-policy.md` | demo 3 | Arabic leave policy (30 days annual leave, 10 days carry-over, 7 days notice, 15 days paid sick leave, extension 4417) |
| `../../samples/fixtures/arabic-scan.pdf` | demo 6 | image-only Arabic invoice reminder (invoice 2041, 12,500 SAR, due 15 November 2026); made by `samples/fixtures/make-arabic-scan.py` (NOM-415) |
| `audio/ar-question.wav` | demo 5 | 5.3 s of Arabic speech: «مرحباً، ما هي عاصمة المملكة العربية السعودية؟ أجب بجملة واحدة.» — see `audio/audio.json` |

**The values were chosen to be checkable.** Each question in the checks has one
right value that appears once in the documents, and the documents hold close
wrong values on purpose (240 SAR abroad next to 185 SAR at home; 15 days sick
leave next to 30 days annual leave), so a check can tell *right* from *nearby*.

**The audio is synthetic speech, not a recording of a person.** It was made by
this stack's own `tts-arabic` service — Chatterbox Multilingual (Resemble AI,
**MIT**), its single built-in voice, no voice cloning — and carries Resemble's
watermark that marks it as synthetic. `audio/make_question_audio.py` is how it
was made. TTS is not bit-for-bit repeatable, so the committed file *is* the
fixture; `demos/run.sh 5` refuses to run if its sha256 differs from `audio.json`.

Licences of everything that touches these files are commercial-safe (DoD rule 5):
Docling MIT, Tesseract `ara` model Apache-2.0, bge-m3 MIT, Whisper Arabic
fine-tune Apache-2.0, Chatterbox MIT, Qwen 3.5 Apache-2.0.
