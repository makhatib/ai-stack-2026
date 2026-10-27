"""Speak stt/sentences.jsonl with the stack's own Arabic TTS (Chatterbox
Multilingual, MIT, built-in voice) and write stt/audio/<id>.wav (16 kHz mono).

Runs INSIDE the voice-arabic TTS image, offline (see run.sh stt-audio).
One fixed seed per sentence, so a re-run gives the same audio on the same
image.  The committed WAVs are the sample set; re-running is only needed to
check that they came from this script.

The audio is synthetic speech.  It is NOT a substitute for human speech: an
error in the transcript may be the TTS saying a word wrong, not the STT
hearing it wrong.  That is why run_stt.py also scores a human-speech control
set (FLEURS, see fleurs.lock).
"""
import json
import sys
import time
import wave
import zlib

import torch
import torchaudio
from chatterbox.mtl_tts import ChatterboxMultilingualTTS

here = sys.argv[1] if len(sys.argv) > 1 else "/eval/stt"
torch.set_num_threads(4)
model = ChatterboxMultilingualTTS.from_local("/models/chatterbox", device="cpu")
rows = [json.loads(line) for line in open(f"{here}/sentences.jsonl", encoding="utf-8") if line.strip()]
only = set(sys.argv[2:])
for r in rows:
    if only and r["id"] not in only:
        continue
    torch.manual_seed(zlib.crc32(r["id"].encode()))
    t0 = time.monotonic()
    with torch.inference_mode():
        wav = model.generate(r["text"], language_id="ar")
    wav = torchaudio.functional.resample(wav, model.sr, 16000)
    pcm = (wav.squeeze(0).clamp(-1, 1) * 32767).to(torch.int16).numpy().tobytes()
    with wave.open(f"{here}/audio/{r['id']}.wav", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(pcm)
    print(f"{r['id']} audio={len(pcm) / 32000:.1f}s wall={time.monotonic() - t0:.0f}s", flush=True)
