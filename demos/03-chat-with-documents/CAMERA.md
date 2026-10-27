# Demo 3 — Chat with my documents in Open WebUI

**What the viewer sees:** you upload three company documents (two English, one
Arabic), then ask questions in English and Arabic. The answers come from the
documents and show which file they came from. Asked something the documents
do not say, it says so.

**What is really happening:** Open WebUI → Docling (reads the file) → bge-m3
embeddings through LiteLLM (Arabic-capable) → pgvector → the local model writes
the answer from the passages it was given.

**Sample files:** `demos/fixtures/docs/` — all invented: *Falcon Ridge Logistics*
travel policy and Q3 note (English), *Al Waha Trading* leave policy (Arabic).

## Before you record

1. Copy the three files to the computer you record on.
2. Rehearse: `demos/run.sh 3` must say `PASS`.
3. Pick the chat model in Open WebUI: `local-chat-large` (16 GB box) or `local-chat` (8 GB box).

## On camera

| Step | You do | You say | You should see |
|---|---|---|---|
| 1 | Open WebUI → **Workspace → Knowledge → +**. Name: *Company documents*. Drag in the three files. | "My files stay on my server." | Three files listed, each processed in seconds. |
| 2 | New chat. Type `#` and pick *Company documents*. Ask: **`How much is the daily meal allowance inside the Kingdom?`** | | **185 SAR**, with a citation to `en-travel-policy.md`. |
| 3 | Ask in Arabic: **`كم يوماً من الإجازة السنوية يحصل عليه الموظف في شركة الواحة؟`** | "Arabic works the same way." | **ثلاثين يوماً** (30), citing `ar-leave-policy.md`. |
| 4 | Ask in Arabic about an English file: **`متى افتُتح مستودع الدمام الجديد؟`** | "I can ask in Arabic about an English document." | **12 أغسطس 2026**, citing the Q3 note. |
| 5 | Ask: **`What is the CEO's monthly salary?`** | "And when the answer is not there…" | It says the documents do not contain it. No number. |
| 6 | Click a citation. | "I can always check the source." | The passage it used. |

## If it goes wrong

- **The answer gives 15 days for step 3:** that is the sick-leave line; the model picked the wrong passage. Re-ask with "annual leave".
- **Very slow answers:** you are on CPU. Use `local-chat` on 8 GB. The measured times are in the `demos` doc.
- **Step 4 misses:** documents uploaded before the bge-m3 change keep their old vectors. Delete and re-upload them.

## Automatic check

`demos/run.sh 3`: builds a fresh knowledge base from the three files and asks
four fixed questions. Each answer is scored **match / wrong / absent** against
the document's value; the retrieved passage and the citation are checked
separately; the salary question must contain **no number**. Step 4's
cross-language question is reported, not required.
