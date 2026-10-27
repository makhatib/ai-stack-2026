# demos/lib/owui_common.py -- shared helpers for the checks that go through
# Open WebUI.  NOT imported: run.sh concatenates this file in front of a
# check and pipes the result into `python3 -` INSIDE the open-webui
# container, so the check uses Open WebUI's own API -- the same calls its
# chat box, file upload, microphone and read-aloud buttons make -- and needs
# no published port.  Standard library only.
#
# Sign-in is the trusted header Authelia sets in front of Open WebUI
# (WEBUI_AUTH_TRUSTED_EMAIL_HEADER).  The email is the owner's Authelia
# account (DEMO_OWUI_EMAIL, default owner@localhost), so the check sees what
# the owner sees on camera.
import json
import os
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.request
import uuid

BASE = "http://127.0.0.1:8080"
EMAIL = os.environ.get("DEMO_OWUI_EMAIL", "owner@localhost")
RESULTS = []          # (name, ok, detail)
TIMES = {}


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok), detail))
    print(f"  [{'ok  ' if ok else 'FAIL'}] {name}{(' -- ' + detail) if detail else ''}", flush=True)
    return ok


def note(text):
    print(f"         {text}", flush=True)


def req(path, data=None, headers=None, method=None, timeout=1800, raw=False):
    if isinstance(data, (dict, list)):
        data = json.dumps(data).encode()
        headers = {**(headers or {}), "Content-Type": "application/json"}
    r = urllib.request.Request(BASE + path, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as f:
            body = f.read()
            if raw:
                return f.status, f.headers.get("content-type", ""), body
            return json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        # Say what the API said: a bare "HTTP Error 400" hides the reason.
        e.msg = f"{e.msg}: {method or ('POST' if data else 'GET')} {path} -> {e.read()[:300]!r}"
        raise


def signin():
    me = req("/api/v1/auths/signin", {"email": "", "password": ""},
             {"Remote-Email": EMAIL, "Remote-Name": "Owner"})
    return {"Authorization": "Bearer " + me["token"]}, me


def upload(H, name, data, ctype):
    b = uuid.uuid4().hex
    body = (f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\n"
            f"Content-Type: {ctype}\r\n\r\n").encode() + data + f"\r\n--{b}--\r\n".encode()
    return req("/api/v1/files/?process=true&process_in_background=false", body,
               {**H, "Content-Type": f"multipart/form-data; boundary={b}"})


def chat(H, model, messages, files=None, timeout=1800):
    body = {"model": model, "messages": messages, "stream": False}
    if files:
        body["files"] = files
    t0 = time.monotonic()
    d = req("/api/chat/completions", body, H, timeout=timeout)
    return d, time.monotonic() - t0


def answer_text(d):
    try:
        return (d["choices"][0]["message"].get("content") or "").strip()
    except Exception:
        return ""


def strip_think(text):
    """Qwen 3.5 may emit a <think>...</think> block; score only the answer."""
    return re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()


AR_DIGITS = str.maketrans("٠١٢٣٤٥٦٧٨٩", "0123456789")


def norm_ar(s):
    """Arabic normalisation for scoring: NFKC, no harakat/tatweel, one alef,
    ta marbuta as ha, alef maqsura as ya, Arabic-Indic digits as ASCII."""
    s = unicodedata.normalize("NFKC", s)
    s = re.sub("[ً-ْـ]", "", s)
    s = re.sub("[أإآ]", "ا", s)
    s = s.replace("ة", "ه").replace("ى", "ي")
    return s.translate(AR_DIGITS)


def arabic_ratio(s):
    letters = [c for c in s if c.isalpha()]
    if not letters:
        return 0.0
    return sum(1 for c in letters if "؀" <= c <= "ۿ") / len(letters)


def has_any(text, options):
    """The options found in text.  A number must stand alone: "30" is not in
    "300" or "2030" (a substring test would have passed a wrong value)."""
    t = norm_ar(text).lower()
    found = []
    for o in options:
        n = norm_ar(o).lower()
        if re.fullmatch(r"[\d.,]+", n):
            if re.search(r"(?<![\d.,])" + re.escape(n) + r"(?![\d]|[.,]\d)", t):
                found.append(o)
        elif n in t:
            found.append(o)
    return found


def finish(label):
    ok = all(r[1] for r in RESULTS)
    print(json.dumps({"demo": label, "status": "PASS" if ok else "FAIL", "checks": len(RESULTS),
                      "failed": [r[0] for r in RESULTS if not r[1]], "times_s": TIMES}, ensure_ascii=False))
    sys.exit(0 if ok else 1)
