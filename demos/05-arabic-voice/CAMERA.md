# Demo 5 — Arabic voice: speak Arabic, get an Arabic answer

**What the viewer sees:** you press the microphone in Open WebUI and ask a
question in Arabic. The question appears as Arabic text, the answer comes back
in Arabic, and the stack reads it aloud.

**What is really happening:** browser microphone → Open WebUI → `stt-arabic`
(Whisper large-v3-turbo Arabic fine-tune, Apache-2.0) → the local model →
`tts-arabic` (Chatterbox Multilingual, MIT, one built-in voice, no cloning).
All on your server. Profile `voice-arabic` must be on.

## Before you record

1. Install with the `voice-arabic` profile (or switch it on and `bin/aistack up`).
2. Open WebUI → **Settings → Audio**: STT engine *OpenAI* → `stt-arabic`, TTS → `tts-arabic`. `bin/aistack up` sets this for you.
3. Rehearse: `demos/run.sh 5` must say `PASS`. It uses a synthetic clip made by the same TTS (`demos/fixtures/audio/ar-question.wav`).
4. **Set expectations:** on CPU, reading aloud takes about **10–12 seconds per second of speech**. A one-line answer takes about 40 s on 4 vCPU. Cut the wait in the edit, or record on a GPU machine.

## On camera

| Step | You do | You say | You should see |
|---|---|---|---|
| 1 | New chat. Press the **microphone**. Say: **«ما هي عاصمة المملكة العربية السعودية؟ أجب بجملة واحدة.»** | | Your question as Arabic text in the box (about 10–15 s on CPU). |
| 2 | Send. | "The answer is generated on my server." | **«…الرياض»** in Arabic. |
| 3 | Press **read aloud** on the answer. | "And it speaks Arabic, with a voice I am allowed to use commercially." | The answer is spoken. |

## If it goes wrong

- **The microphone does nothing:** browsers allow the microphone only over HTTPS. In VPS mode that is automatic; in home mode accept the certificate first.
- **The transcript has a wrong letter or two:** that is the current CPU STT model. The `demos` doc and NOM-415 have the measured error rate. Speak slowly and clearly.
- **Read-aloud spins for a minute:** that is CPU TTS. It finishes.

## Automatic check

`demos/run.sh 5`: transcribes the committed Arabic clip (its sha256 is checked
first), asks the model, reads the answer aloud, and transcribes that audio
again. Passes only if the question is understood (2 of 3 key words), the answer
is Arabic and names Riyadh, real audio comes back, and that audio is heard back
as Riyadh.
