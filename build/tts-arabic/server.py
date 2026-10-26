"""aistack-tts-arabic — Arabic text-to-speech, OpenAI-compatible (NOM-415).

  POST /v1/audio/speech   JSON: input, [model], [voice], [language]  -> audio/wav
  GET  /health

Model: Chatterbox Multilingual (Resemble AI, MIT), baked into the image at a
pinned Hugging Face revision.  CPU only.  ONE voice: the built-in default
speaker that ships with the model (conds.pt, same MIT licence).  There is no
voice-cloning endpoint and a request for any other voice is refused: cloning a
person's voice needs that person's consent, and nothing here could check it.

It receives text from Open WebUI only (pairwise bridge), has no egress, writes
nothing to disk, and never logs the text it speaks.
"""
import io
import logging
import os
import time
import wave

import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

from chatterbox.mtl_tts import SUPPORTED_LANGUAGES, ChatterboxMultilingualTTS

MODEL_DIR = os.environ.get("TTS_MODEL_DIR", "/models/chatterbox")
THREADS = int(os.environ.get("TTS_THREADS", "4"))
DEFAULT_LANG = os.environ.get("TTS_LANGUAGE", "ar")
MAX_CHARS = int(os.environ.get("TTS_MAX_CHARS", "600"))
VOICES = {"default"}

log = logging.getLogger("tts")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

torch.set_num_threads(THREADS)
model = ChatterboxMultilingualTTS.from_local(MODEL_DIR, device="cpu")
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


class Speech(BaseModel):
    input: str
    model: str = "chatterbox-ar"
    voice: str = "default"
    language: str = ""
    response_format: str = "wav"
    speed: float = 1.0


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/v1/audio/speech")
def speech(req: Speech):
    text = req.input.strip()
    if not text:
        raise HTTPException(400, "empty input")
    if len(text) > MAX_CHARS:
        raise HTTPException(413, f"input longer than {MAX_CHARS} characters")
    # Open WebUI sends its configured voice name; anything but the built-in
    # speaker would be a cloning request in disguise.
    voice = (req.voice or "default").strip().lower()
    if voice not in VOICES and voice not in ("alloy",):  # alloy = Open WebUI's built-in default name
        raise HTTPException(400, "only the built-in 'default' voice is available")
    lang = (req.language or DEFAULT_LANG).strip().lower()
    if lang not in SUPPORTED_LANGUAGES:
        raise HTTPException(400, f"unsupported language {lang!r}")
    t0 = time.monotonic()
    with torch.inference_mode():
        wav = model.generate(text, language_id=lang)
    pcm = (wav.squeeze(0).clamp(-1, 1) * 32767).to(torch.int16).numpy().tobytes()
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(model.sr)
        w.writeframes(pcm)
    seconds = len(pcm) / 2 / model.sr
    # Lengths and timings only: the text is user content and is never logged.
    log.info("spoke chars=%d audio=%.1fs wall=%.1fs lang=%s", len(text), seconds, time.monotonic() - t0, lang)
    return Response(buf.getvalue(), media_type="audio/wav")
