# Demo 6 — Arabic scanned document → text → question answered

**What the viewer sees:** you upload a *scanned* Arabic invoice reminder — a
picture, no text in it. The stack reads it and answers questions about it in
Arabic.

**What is really happening:** Open WebUI → `docling-arabic` (Docling + Tesseract's
Arabic model, both commercial-safe) turns the image into text → the local model
answers from that text. Profile `docs-arabic` must be on.

**Sample file:** `samples/fixtures/arabic-scan.pdf` — an invented company
(شركة الواحة للتجارة), invoice 2041, 12,500 SAR, due 15 November 2026. Image
only, slightly tilted and noisy like a real scan.

## Before you record

1. Install with the `docs-arabic` profile.
2. Copy `arabic-scan.pdf` to the computer you record on.
3. Rehearse: `demos/run.sh 6` must say `PASS`.

## On camera

| Step | You do | You say | You should see |
|---|---|---|---|
| 1 | Open the PDF and try to select text. | "This is only a picture of a page." | Nothing selects. |
| 2 | New chat in Open WebUI. Attach the PDF (paperclip). | "My server reads Arabic scans." | Processed in about 10 s. |
| 3 | Ask: **`ما رقم الفاتورة في هذا المستند؟`** | | **2041**. |
| 4 | Ask: **`ما المبلغ المستحق؟`** | | **12,500 ريال**. |
| 5 | (optional) Ask: **`ما تاريخ الاستحقاق؟`** | Be honest: | It may say the date is missing. **Known limit:** on right-to-left "label: value" lines Docling writes the date *before* its label, so the model can lose the pairing. Say so on camera, or skip this question. |

## If it goes wrong

- **Empty or Latin gibberish text:** the `docs-arabic` profile is off; the stock Docling has no Arabic model. Settings → Documents must show `docling-arabic`. `bin/aistack up` sets this.
- **Wrong number:** the model paired a value with the wrong label (step 5's limit). Ask for the invoice number, which is reliable.

## Automatic check

`demos/run.sh 6` has two stages, scored separately. **Text:** all 12 expected
words and 4 numbers must be in the OCR output. **Answer:** three Arabic questions
scored per field as match / wrong / absent; the invoice number is required, the
amount and the due date are reported (the known RTL limit).
