# scripts/owui-sync.py -- make Open WebUI use the profile settings compose gives it.
#
# WHY (NOM-416, measured).  Open WebUI copies its settings from the environment
# into its own database on FIRST start, and from then on reads the database.
# `aistack pin` re-derives the voice, parser and embedding settings from
# COMPOSE_PROFILES into .env (NOM-415), and compose passes them in -- but Open
# WebUI ignored them: after `voice-arabic` was switched on, the container env
# named tts-arabic/stt-arabic while Open WebUI still had no TTS or STT (read
# aloud answered 404), and after `docs-arabic` was switched off it still sent
# documents to docling-arabic, which was no longer running.
#
# WHAT.  Only the keys the profiles own, nothing an owner set by hand:
#   audio      -- STT/TTS engine, URL, model, voice (and their placeholder keys)
#   retrieval  -- content extraction engine, Docling URL and Docling params
#   embedding  -- engine, model and URL (bge-m3 through LiteLLM)
# Run INSIDE open-webui, which has the env; called by `aistack up`:
#   docker compose exec -T -e OWUI_SYNC_EMAIL=<admin> open-webui python3 - < scripts/owui-sync.py
# Signs in with the trusted header Authelia sets, as Open WebUI's first admin.
# Standard library only.  Prints what it changed; never prints a key.
import json
import os
import sys
import urllib.request

BASE = "http://127.0.0.1:8080"
E = os.environ


def call(path, body=None, token=None, headers=None):
    h = {"Content-Type": "application/json", **(headers or {})}
    if token:
        h["Authorization"] = "Bearer " + token
    r = urllib.request.Request(BASE + path, json.dumps(body).encode() if body is not None else None, h)
    with urllib.request.urlopen(r, timeout=60) as f:
        return json.loads(f.read() or b"null")


email = E.get("OWUI_SYNC_EMAIL", "")
if not email:
    # Not "first start already used the env": that is true only if the
    # profiles have not changed since Open WebUI first started (NOM-430).
    print("owui-sync: no Open WebUI admin yet (nobody has logged in), so nothing was synced. "
          "If you changed profiles since the first start, log in once, then run 'bin/aistack up' again.")
    sys.exit(0)
tok = call("/api/v1/auths/signin", {"email": "", "password": ""},
           headers={E.get("WEBUI_AUTH_TRUSTED_EMAIL_HEADER", "Remote-Email"): email})["token"]
changed = []

# --- audio -----------------------------------------------------------------
cur = call("/api/v1/audio/config", token=tok)
want = {
    "tts": {"ENGINE": E.get("AUDIO_TTS_ENGINE", ""), "OPENAI_API_BASE_URL": E.get("AUDIO_TTS_OPENAI_API_BASE_URL", ""),
            "OPENAI_API_KEY": E.get("AUDIO_TTS_OPENAI_API_KEY", ""), "MODEL": E.get("AUDIO_TTS_MODEL", ""),
            "VOICE": E.get("AUDIO_TTS_VOICE", "")},
    "stt": {"ENGINE": E.get("AUDIO_STT_ENGINE", ""), "OPENAI_API_BASE_URL": E.get("AUDIO_STT_OPENAI_API_BASE_URL", ""),
            "OPENAI_API_KEY": E.get("AUDIO_STT_OPENAI_API_KEY", ""), "MODEL": E.get("AUDIO_STT_MODEL", "")},
}
if not E.get("AUDIO_TTS_ENGINE"):          # profile off: the key goes back to "none" too
    want["tts"]["OPENAI_API_KEY"] = ""
if not E.get("AUDIO_STT_ENGINE"):
    want["stt"]["OPENAI_API_KEY"] = ""
diff = [f"{s}.{k}" for s in want for k, v in want[s].items() if (cur.get(s) or {}).get(k, "") != v]
if diff:
    form = {}
    for s in ("tts", "stt"):
        form[s] = {**(cur.get(s) or {}), **want[s]}
        for k in ("API_KEY", "WHISPER_MODEL", "DEEPGRAM_API_KEY", "AZURE_API_KEY", "AZURE_REGION", "AZURE_LOCALES",
                  "AZURE_BASE_URL", "AZURE_MAX_SPEAKERS", "SPLIT_ON", "AZURE_SPEECH_REGION",
                  "AZURE_SPEECH_BASE_URL", "AZURE_SPEECH_OUTPUT_FORMAT", "MISTRAL_API_KEY", "MISTRAL_API_BASE_URL"):
            form[s].setdefault(k, "")
    call("/api/v1/audio/config/update", form, tok)
    changed += [d for d in diff if "KEY" not in d]

# --- document parser --------------------------------------------------------
# DOCLING_PARAMS too (NOM-430, measured): it carries `ocr_lang: ["ara", "eng"]`.
# Without it, docs-arabic switched on after Open WebUI's first start sent scans
# to docling-arabic with no OCR language and read 0 of 12 Arabic words; with it,
# 12 of 12.  Parsed the way Open WebUI parses the env: not JSON means {}.
try:
    params = json.loads(E.get("DOCLING_PARAMS") or "{}")
except ValueError:
    params = {}
cur = call("/api/v1/retrieval/config", token=tok)
want = {"CONTENT_EXTRACTION_ENGINE": E.get("CONTENT_EXTRACTION_ENGINE", ""), "DOCLING_SERVER_URL": E.get("DOCLING_SERVER_URL", ""),
        "DOCLING_PARAMS": params if isinstance(params, dict) else {}}
diff = [k for k, v in want.items() if (cur.get(k) or type(v)()) != v]
if diff:
    call("/api/v1/retrieval/config/update", want, tok)
    changed += diff

# --- embeddings --------------------------------------------------------------
if E.get("RAG_EMBEDDING_ENGINE"):
    cur = call("/api/v1/retrieval/embedding", token=tok)
    url, key = E.get("RAG_OPENAI_API_BASE_URL", ""), E.get("RAG_OPENAI_API_KEY", "")
    oc = cur.get("openai_config") or {}
    if (cur.get("RAG_EMBEDDING_ENGINE") != E["RAG_EMBEDDING_ENGINE"] or cur.get("RAG_EMBEDDING_MODEL") != E.get("RAG_EMBEDDING_MODEL")
            or oc.get("url") != url or oc.get("key") != key):
        call("/api/v1/retrieval/embedding/update", {"RAG_EMBEDDING_ENGINE": E["RAG_EMBEDDING_ENGINE"],
             "RAG_EMBEDDING_MODEL": E.get("RAG_EMBEDDING_MODEL", ""), "openai_config": {"url": url, "key": key},
             "RAG_EMBEDDING_BATCH_SIZE": int(cur.get("RAG_EMBEDDING_BATCH_SIZE") or 8)}, tok)
        changed.append("embedding (documents uploaded before this keep their old vectors: re-upload them)")

print("owui-sync: " + ("updated " + ", ".join(changed) if changed else "Open WebUI already matches the profiles"))
