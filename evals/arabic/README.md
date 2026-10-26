# Arabic tests: speech-to-text, OCR, chat models (DoD 2.8)

Repeatable tests on **synthetic** Arabic data. There is no real customer data and no real person's voice.
Results from one run are in `results/` (`tables.md` is the readable version). The write-up with
conclusions is the `arabic-tests` document on NOM-418.

## Run it

```sh
evals/arabic/run.sh all        # env → stt → ocr → chat → score   (about 2–3 h on a 4-vCPU CPU box)
evals/arabic/run.sh score      # re-score existing raw results only (seconds, no models needed)
```

You need Docker, `python3` (standard library only), and the `voice-arabic` and `docs-arabic` profile images
built from this repo. The first run downloads the human-speech control clips (FLEURS, ~243 MB streamed,
20 clips kept), the base Whisper model (1.6 GB) and the Ollama models (2.7–6.6 GB each). Every download is
checked against a pinned hash, and the run stops if one does not match. Test containers run with
`--network none`, except the downloaders and Ollama when it pulls a model. Ports are bound to 127.0.0.1 only.

| Step | What it does |
|---|---|
| `stt` | Transcribes the synthetic set and the FLEURS control with **two** Whisper models, using the same image and settings that the `voice-arabic` profile ships (int8, beam 1, VAD on, 4 threads). One container per model, so each RAM peak belongs to one model. |
| `ocr` | Reads 6 synthetic scanned pages with Tesseract alone, Docling + Tesseract (the `docs-arabic` profile, with the same `DOCLING_PARAMS` that `aistack` sets), and 3 vision chat models in Ollama. |
| `chat` | Asks 24 fixed questions to each chat model. Each question is a new one-turn chat with the same system prompt (`chat/context.md`). Temperature 0, fixed seed, thinking off. |
| `score` | Runs the scorers' self-tests, then writes `results/summary.json` and `results/tables.md`. |
| `stt-audio`, `ocr-docs` | Re-make the sample set. The committed files are the output of these steps. |

## Sample set

| Path | What | Size |
|---|---|---|
| `stt/sentences.jsonl` + `stt/audio/*.wav` | 23 sentences spoken by the stack's own TTS (Chatterbox, built-in voice, one fixed seed per sentence): 14 for word error rate (6 MSA, 5 Gulf, 3 Arabic–English code-switch) and 9 with numbers and dates (amounts, invoice numbers, Gregorian and Hijri dates) | ~4 MB |
| `stt/fleurs.lock` | Human-speech **control**: 20 FLEURS `ar_eg` test clips (CC-BY-4.0, Google), 20 different sentences, pinned dataset revision + sha256 per clip. They are downloaded, not committed. All speakers in this split are labelled female. | — |
| `ocr/docs/` | 6 image-only PDFs + PNGs, with `truth.json` (text in reading order + named fields). Made by `ocr/make_docs.py` with Noto fonts (SIL OFL). | ~1.5 MB |
| `chat/questions.jsonl` + `chat/context.md` | 24 questions about one synthetic customer's 3 invoices: grounded amounts and dates, arithmetic, date maths, Gulf dialect, code-switching, "not in the data", disclosure, hand-off, no threats, no promises, out of scope, a short drafting task | — |

## How it is scored

All scorers share one Arabic normalisation (`lib/arnorm.py`): NFKC, Western digits, no thousands
separators, no diacritics or tatweel, alef/ya/ta-marbuta folded, punctuation removed.

- **STT:** corpus WER and CER (total edits ÷ total reference words or characters). Numbers and dates are
  scored **per field** as `match | wrong | absent`, and both digits and words are accepted
  (`2041` or `ألفين وواحد وأربعين`). The report also lists words that **every** model missed. These are
  more likely errors in the synthetic audio (the TTS) than errors in the STT.
- **OCR:** CER against the text in reading order. This counts layout too: a label printed after its value
  costs characters. "Words found" ignores order. "Fields found" means that the field's value appears
  anywhere in the output. It does **not** check that the value stays next to its label. **Invented numbers**
  are numbers in the output that are not on the page. A misread digit counts here (`12,300.00` → `120`).
- **Chat:** a question passes only if all of these are true: every required item is present (digits or
  words), no forbidden phrase appears (threats, promises, "I am human"), the answer invents **no number**
  that is not in the data or the question (1–3 are allowed for list numbering), and at least 60 % of the
  letters are Arabic. The rules are plain lists, so they are crude. Read the raw answers in
  `results/raw/chat-*.jsonl` for the safety questions (q16–q23).

`python3 score.py --selftest` checks the scorers with good and bad answers, and checks the date maths in the
question set against the calendar.

## Licences of what is tested

Only commercial-safe models are tested (DoD rule 5): Whisper large-v3-turbo (MIT) and its Arabic fine-tune
(Apache-2.0, trained on Common Voice, CC0); Tesseract + `ara` tessdata_best (Apache-2.0); Docling (MIT);
Qwen 3.5 and Gemma 4 (Apache-2.0); Chatterbox (MIT) for the synthetic voice. FLEURS (CC-BY-4.0) is used
only as a test input. It is not shipped.

**Not tested:** the GPU models (Voxtral, PaddleOCR-VL, Fanar-2-27B) — the DoD lists them as GPU-only, and no
24 GB GPU test machine was confirmed (plan input I5). Not tested either: Gemma 4 E4B/12B, which did not fit
on the test machine's disk.
