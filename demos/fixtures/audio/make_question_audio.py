# demos/fixtures/audio/make_question_audio.py -- how ar-question.wav was made.
# Runs INSIDE open-webui after demos/lib/owui_common.py, with the voice-arabic
# profile on:  cat demos/lib/owui_common.py demos/fixtures/audio/make_question_audio.py \
#   | docker compose exec -T open-webui python3 - > demos/fixtures/audio/ar-question.wav.b64
#
# The voice is the stack's own TTS: Chatterbox Multilingual (Resemble AI, MIT),
# the one built-in voice, no cloning (build/tts-arabic/models.lock pins the
# weights by commit and sha256).  Its audio carries Resemble's watermark, which
# marks it as synthetic.  No human voice is recorded anywhere in these demos.
# The output is decoded by Open WebUI's ffmpeg to 16 kHz mono WAV, the format
# a phone or browser microphone typically delivers to STT.
#
# TTS is not bit-for-bit repeatable, so the committed WAV is the fixture and its
# sha256 is in audio.json; re-running this makes a new, similar clip.
import base64
import subprocess

TEXT = "مرحباً، ما هي عاصمة المملكة العربية السعودية؟ أجب بجملة واحدة."
H, me = signin()
st, ctype, mp3 = req("/api/v1/audio/speech", {"input": TEXT, "voice": "default", "model": "chatterbox-ar"}, H, raw=True)
open("/tmp/q.mp3", "wb").write(mp3)
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", "/tmp/q.mp3", "-ac", "1", "-ar", "16000", "/tmp/q.wav"], check=True)
sys.stdout.write(base64.b64encode(open("/tmp/q.wav", "rb").read()).decode())
