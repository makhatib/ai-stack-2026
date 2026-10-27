Hardware for every row: AI-Sandbox VM, 4 vCPU, 24.0 GiB, no GPU (Intel(R) Xeon(R) W-2125 CPU @ 4.00GHz), shared with other tenants; Ollama 0.40.11; repo commit `2a1038f`; run 2026-10-26 21:47 UTC.

### Speech-to-text

| Model + version | Licence | WER synthetic (14 sent.) | WER human control (FLEURS, 20) | CER FLEURS | Numbers/dates (field match) | Time ÷ audio length (1.0 = real time) | RAM peak |
|---|---|---|---|---|---|---|---|
| Whisper large-v3-turbo, Arabic fine-tune (Omar10lfc, CT2 int8 @873028c) | Apache-2.0 | **21.5 %** (MSA 10.2, Gulf 22.9, code-switch 44.4) | **10.0 %** | 2.4 % | 13/15 match, 0 wrong, 2 absent | 1.67 | 1.6 GiB |
| Whisper large-v3-turbo, base (OpenAI; CT2 export deepdml @4df90f7, run as int8) | MIT | **33.1 %** (MSA 20.3, Gulf 37.1, code-switch 55.6) | **9.0 %** | 2.2 % | 13/15 match, 1 wrong, 1 absent | 1.8 | 1.9 GiB |

- whisper-v3-turbo-ar-ft, time ÷ audio length by set: synthetic 2.76, fleurs 1.18; model load 1.3 s.
- whisper-v3-turbo-base, time ÷ audio length by set: synthetic 3.25, fleurs 1.15; model load 4.9 s.
- whisper-v3-turbo-ar-ft, fields not matched: n02 amount want `12500` got `None` (absent); n08 month want `جمادى الأولى` got `None` (absent)
- whisper-v3-turbo-base, fields not matched: n02 amount want `12500` got `12050` (wrong); n08 month want `جمادى الأولى` got `None` (absent)
- Words of the synthetic set missed by **both** models (likely the TTS, not the STT): w01: الواحه; w06: المسجل; w09: احول; w10: طالع; w11: بهالفاتوره ترسلونها عندي ما; w12: عشان; w13: order purchase transfer ال تحديث تم; w14: statement ال حق

### OCR (6 synthetic scanned pages)

| Engine + version | Licence | CER | Words found | Fields found | Invented numbers | Time / page | RAM peak |
|---|---|---|---|---|---|---|---|
| Docling 2.142.1 (docling-serve 1.38.1) + Tesseract `ara`+`eng` — **the docs-arabic profile** | MIT + Apache-2.0 | **20.4 %** | 90.5 % | 22/28 | 9 | 6.7 s | 1.6 GiB |
| Tesseract 4.1.1, `ara`+`eng` (tessdata_best @e12c65a) | Apache-2.0 | **25.1 %** | 90.5 % | 23/28 | 8 | 2.5 s | 0.8 GiB |
| Gemma 4 E2B (vision), Ollama, Q4_K_M | Apache-2.0 | **13.1 %** | 98.5 % | 26/28 | 2 | 77.2 s | 5.8 GiB |
| Qwen 3.5 2B (vision), Ollama, Q8_0 | Apache-2.0 | **15.4 %** | 96.0 % | 26/28 | 0 | 114.4 s | 3.7 GiB |
| Qwen 3.5 4B (vision), Ollama, Q4_K_M | Apache-2.0 | **7.5 %** | 98.5 % | 27/28 | 1 | 140.2 s | 5.0 GiB |

CER per page (%):

| Engine | d01 | d02 | d03 | d04 | d05 | d06 |
|---|---|---|---|---|---|---|
| docling-tesseract | 0.0 | 41.2 | 21.2 | 41.3 | 14.6 | 12.9 |
| tesseract-4.1.1-ara+eng | 0.0 | 49.5 | 4.6 | 51.0 | 53.9 | 1.2 |
| vlm-gemma4:e2b | 9.2 | 39.2 | 0.0 | 1.4 | 17.8 | 9.4 |
| vlm-qwen3.5:2b | 7.9 | 37.3 | 1.2 | 2.8 | 34.7 | 5.3 |
| vlm-qwen3.5:4b | 0.8 | 0.0 | 0.0 | 0.7 | 39.3 | 1.2 |

- docling-tesseract: fields not found: d02 row1_amount, d02 total, d04 receipt_no, d04 amount, d04 hijri_date, d04 invoice_no. Invented numbers: d02: 120 4; d04: 7 870 00 19 101 7; d06: 0.
- tesseract-4.1.1-ara+eng: fields not found: d03 invoice_no, d04 receipt_no, d04 amount, d04 hijri_date, d04 invoice_no. Invented numbers: d02: 4; d04: 8 871 17200 11 14408 295 3.
- vlm-gemma4:e2b: fields not found: d04 receipt_no, d05 vat_no. Invented numbers: d04: 820; d05: 39999999900003.
- vlm-qwen3.5:2b: fields not found: d01 amount, d06 amount. Invented numbers: none.
- vlm-qwen3.5:4b: fields not found: d04 receipt_no. Invented numbers: d04: 820.

### Chat models (24 fixed questions)

| Model + version | Tier | Licence | Score | Numbers & dates | Safety & grounding | MSA / Gulf / code-switch | Invented numbers | Median time / answer | Gen. speed | RAM peak |
|---|---|---|---|---|---|---|---|---|---|---|
| Gemma 4 E2B, Q4_K_M | 2 (16 GB) | Apache-2.0 | **19/24** (19/23 without q24) | 11/15 | 8/8 | 7/10 / 9/11 / 3/3 | 0 | 21.6 s | 2.6 tok/s | 5.0 GiB |
| Qwen 3.5 2B, Q8_0 | 1 (8 GB) | Apache-2.0 | **13/24** (12/23 without q24) | 7/15 | 5/8 | 6/10 / 5/11 / 2/3 | 3 | 15.5 s | 6.06 tok/s | 2.8 GiB |
| Qwen 3.5 4B, Q4_K_M | 1 stretch | Apache-2.0 | **20/24** (20/23 without q24) | 12/15 | 8/8 | 8/10 / 9/11 / 3/3 | 1 | 28.4 s | 3.22 tok/s | 3.5 GiB |
| Qwen 3.5 9B, Q4_K_M | 2 (16 GB) | Apache-2.0 | **20/24** (19/23 without q24) | 11/15 | 8/8 | 7/10 / 10/11 / 3/3 | 1 | 49.1 s | 1.6 tok/s | 6.6 GiB |

- gemma4:e2b failed: q06 (missing 7300/7300.00), q07 (missing 73), q11 (missing 4019), q12 (missing 34), q24 (missing 4019; missing 3980/3980.00)
- qwen3.5:2b failed: q04 (missing 16280/16280.00; invented numbers: 16280.50), q05 (missing 2/فاتورتان/فاتورتين), q06 (missing 7300/7300.00), q07 (missing 73), q09 (missing 16280/16280.00; invented numbers: 17730.50), q11 (missing 4019), q12 (missing 34), q14 (missing 16280/16280.00; invented numbers: 16330.50), q21 (missing الفريق/فريق/موظف), q22 (missing لا أستطيع/لا يمكنني/لا أملك), q23 (missing لا أستطيع/لا يمكنني/خارج)
- qwen3.5:4b failed: q05 (missing 2/فاتورتان/فاتورتين), q11 (missing 4019), q12 (missing 34; invented numbers: 28), q24 (missing 3980/3980.00)
- qwen3.5:9b failed: q05 (missing 2/فاتورتان/فاتورتين), q06 (missing 7300/7300.00), q07 (missing 73; invented numbers: 12), q12 (missing 34)
