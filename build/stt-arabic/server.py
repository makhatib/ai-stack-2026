"""aistack-stt-arabic — Arabic speech-to-text, OpenAI-compatible (NOM-415).

  POST /v1/audio/transcriptions   multipart: file, [model], [language], [response_format]
  GET  /health

Model: Omar10lfc/whisper-large-v3-turbo-arabic (CTranslate2 INT8), baked into
the image at a pinned revision.  CPU only.  The language defaults to Arabic;
a caller may pass another ISO code, and Whisper still decodes it.

It receives audio bytes from Open WebUI only (pairwise bridge), has no egress,
writes nothing but a temp file, and never logs the transcript.
"""
import logging
import os
import tempfile
import time

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse
from faster_whisper import WhisperModel

MODEL_DIR = os.environ.get("STT_MODEL_DIR", "/models/whisper-ar")
THREADS = int(os.environ.get("STT_THREADS", "4"))
DEFAULT_LANG = os.environ.get("STT_LANGUAGE", "ar")
MAX_BYTES = int(os.environ.get("STT_MAX_BYTES", str(25 * 1024 * 1024)))

log = logging.getLogger("stt")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

model = WhisperModel(MODEL_DIR, device="cpu", compute_type="int8", cpu_threads=THREADS,
                     local_files_only=True)
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/v1/audio/transcriptions")
async def transcribe(file: UploadFile = File(...), model_name: str = Form("whisper-ar", alias="model"),
                     language: str = Form(""), response_format: str = Form("json")):
    data = await file.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise HTTPException(413, "audio too large")
    if not data:
        raise HTTPException(400, "empty audio")
    lang = (language or DEFAULT_LANG).strip().lower()[:8] or None
    t0 = time.monotonic()
    with tempfile.NamedTemporaryFile(dir="/tmp", suffix=".audio") as tmp:
        tmp.write(data)
        tmp.flush()
        try:
            segments, info = model.transcribe(tmp.name, language=lang, beam_size=1,
                                              vad_filter=True, condition_on_previous_text=False)
            text = " ".join(s.text.strip() for s in segments).strip()
        except Exception as e:  # undecodable audio is the caller's error, not ours
            raise HTTPException(400, f"could not decode audio: {type(e).__name__}")
    # Durations only: the transcript is user content and is never logged.
    log.info("transcribed audio=%.1fs wall=%.1fs lang=%s", info.duration, time.monotonic() - t0, lang)
    if response_format == "text":
        return PlainTextResponse(text)
    return JSONResponse({"text": text})
