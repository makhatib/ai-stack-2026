# Demo 5 -- Arabic voice: speak Arabic, get an Arabic answer.  Runs INSIDE
# open-webui after demos/lib/owui_common.py.  argv[1] = JSON {"model": ...};
# the question clip is on /tmp/demo5-ar-question.wav (run.sh copies it in and
# checks its sha256 against demos/fixtures/audio/audio.json first).
#
# The same three calls Open WebUI's microphone, chat and read-aloud buttons make:
#   1. STT   the spoken Arabic question -> text            (stt-arabic, Whisper turbo Arabic)
#   2. chat  that text -> an Arabic answer                 (LiteLLM -> local model)
#   3. TTS   the answer -> speech                          (tts-arabic, Chatterbox, MIT)
#   4. STT   that speech -> text again, to prove the spoken answer is the answer
# Pass criteria, fixed before the run: the question is understood (2 of the 3
# key words, Arabic script), the answer is Arabic and names Riyadh, the spoken
# answer is real audio and is heard back as Riyadh.
import io
import subprocess
import wave

args = json.loads(sys.argv[1])
MODEL = args["model"]
KEYWORDS = ["عاصمة", "المملكة", "السعودية"]
ANSWER = ["الرياض", "رياض"]

H, me = signin()
check("signed in as the owner through the trusted header", me.get("role") == "admin", me.get("email"))
cfg = req("/api/v1/audio/config", headers=H)
stt, tts = cfg.get("stt", {}), cfg.get("tts", {})
check("Open WebUI's STT is stt-arabic and its TTS is tts-arabic (profile voice-arabic)",
      "stt-arabic" in stt.get("OPENAI_API_BASE_URL", "") and "tts-arabic" in tts.get("OPENAI_API_BASE_URL", ""),
      f"stt={stt.get('OPENAI_API_BASE_URL')} tts={tts.get('OPENAI_API_BASE_URL')}")


def transcribe(wav_bytes, name):
    b = uuid.uuid4().hex
    body = (f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\n"
            f"Content-Type: audio/wav\r\n\r\n").encode() + wav_bytes + f"\r\n--{b}--\r\n".encode()
    t0 = time.monotonic()
    d = req("/api/v1/audio/transcriptions", body, {**H, "Content-Type": f"multipart/form-data; boundary={b}"})
    return (d or {}).get("text", ""), time.monotonic() - t0


def seconds(wav_bytes):
    with wave.open(io.BytesIO(wav_bytes)) as w:
        return w.getnframes() / w.getframerate()


# 1 -- the spoken question
q_wav = open("/tmp/demo5-ar-question.wav", "rb").read()
q_text, dt = transcribe(q_wav, "question.wav")
TIMES["stt_question_s"] = round(dt, 1)
note(f"heard ({seconds(q_wav):.1f} s of audio, {dt:.1f} s): {q_text!r}")
hits = has_any(q_text, KEYWORDS)
check(f"1. the spoken question is understood ({len(hits)}/{len(KEYWORDS)} key words, need 2)",
      len(hits) >= 2 and arabic_ratio(q_text) >= 0.8, f"Arabic letters {arabic_ratio(q_text):.0%}")

# 2 -- the answer, in Arabic, short enough to be read aloud
SYSTEM = "أنت مساعد صوتي. أجب بالعربية الفصحى بجملة واحدة قصيرة، بدون رموز أو تنسيق."
d, dt = chat(H, MODEL, [{"role": "system", "content": SYSTEM}, {"role": "user", "content": q_text}])
TIMES["answer_s"] = round(dt, 1)
answer = strip_think(answer_text(d))
note(f"answer ({dt:.1f} s): {answer!r}")
check("2. the answer is in Arabic", arabic_ratio(answer) >= 0.8, f"Arabic letters {arabic_ratio(answer):.0%}")
check("2. the answer is right (names Riyadh)", bool(has_any(answer, ANSWER)))

# 3 -- read it aloud (Open WebUI returns MP3; its own ffmpeg decodes it)
t0 = time.monotonic()
st, ctype, mp3 = req("/api/v1/audio/speech", {"input": answer, "voice": tts.get("VOICE") or "default",
                                               "model": tts.get("MODEL") or "chatterbox-ar"}, H, raw=True)
TIMES["tts_answer_s"] = round(time.monotonic() - t0, 1)
open("/tmp/demo5-answer.mp3", "wb").write(mp3)
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", "/tmp/demo5-answer.mp3", "-ac", "1", "-ar", "16000",
                "/tmp/demo5-answer.wav"], check=True)
a_wav = open("/tmp/demo5-answer.wav", "rb").read()
a_sec = seconds(a_wav)
TIMES["answer_audio_s"] = round(a_sec, 1)
check("3. the answer is spoken (audio comes back)", ctype.startswith("audio/") and a_sec >= 1.0,
      f"{ctype}, {a_sec:.1f} s of audio in {TIMES['tts_answer_s']} s (x{TIMES['tts_answer_s'] / max(a_sec, 0.1):.0f} real time)")

# 4 -- hear the spoken answer back
back, dt = transcribe(a_wav, "answer.wav")
TIMES["stt_answer_s"] = round(dt, 1)
note(f"spoken answer heard back as: {back!r}")
check("4. the spoken answer is heard back as Riyadh", bool(has_any(back, ANSWER)))
finish("05-arabic-voice")
