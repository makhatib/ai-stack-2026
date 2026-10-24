#!/usr/bin/env python3
# tests/owner-bootstrap.py — the parts of tests/owner-bootstrap.sh that bash
# cannot do: drive an interactive prompt through a pty, hold a session cookie
# across requests, and compute a TOTP code.
#
# It prints `key=value` lines and nothing else, so the shell half asserts on
# values rather than on grepped prose.  Every subcommand exits 0 when it got
# an answer -- including an answer the test is expecting to be a refusal -- and
# non-zero only when it could not ask.  That split is the same one tests/run.sh
# makes between a failure and a refusal, for the same reason.
#
# THE SYNTHETIC PASSWORD LIVES IN A FILE, NOT IN argv.  It is synthetic and the
# fixture is thrown away, so this is about not shipping an example worth
# copying: the command under test refuses a password from argv or a pipe on
# purpose, and a test that then put one on argv would be arguing with it.

import base64
import fcntl
import hmac
import hashlib
import http.cookies
import json
import os
import pty
import select
import shlex
import struct
import subprocess
import sys
import termios
import time
import urllib.error
import urllib.request

FIX = os.environ.get("FIXTURE", "")
PW_FILE = os.path.join(FIX, "synthetic-password")
COOKIE_FILE = os.path.join(FIX, "session-cookie")
SECRET_FILE = os.path.join(FIX, "totp-secret")


def out(**kw):
    """Print `key=value` lines the shell half can `eval` safely.

    EVERY VALUE IS SHELL-QUOTED, and that is not decoration.  Authelia answers
    some paths with a plain-text body rather than JSON, so a reported value can
    contain a space -- and an unquoted `detail=403 Forbidden` makes the shell's
    `eval` try to run `Forbidden`, which turned a measured refusal into
    "command not found" and an unmeasured section (MEASURED, NOM-402).
    """
    for k, v in kw.items():
        print("%s=%s" % (k, shlex.quote(str(v))))


def refuse(msg):
    sys.stderr.write("owner-bootstrap.py: %s\n" % msg)
    raise SystemExit(2)


def password():
    with open(PW_FILE, encoding="utf-8") as fh:
        return fh.read().rstrip("\n")


# --- pty ---------------------------------------------------------------------

def cmd_drive(argv):
    """drive <timeout> -- cmd... :: expect send [expect send ...]"""
    timeout = float(argv[0])
    argv = argv[1:]
    if argv[0] != "--":
        refuse("drive: expected -- before the command")
    argv = argv[1:]
    if "::" not in argv:
        refuse("drive: expected :: before the prompt list")
    i = argv.index("::")
    cmd, pairs = argv[:i], argv[i + 1:]
    pairs = [password() if p == "@PASSWORD@" else p for p in pairs]

    mfd, sfd = pty.openpty()

    def child():
        # THE CHILD MUST OWN THE pty, not merely be handed it.  Without
        # setsid + TIOCSCTTY, `[ -t 0 ]` still passes but /dev/tty is somebody
        # else's terminal -- which is a real failure mode of this exact prompt
        # and not one worth re-deriving from a hang (NOM-402).
        os.setsid()
        fcntl.ioctl(sfd, termios.TIOCSCTTY, 0)

    proc = subprocess.Popen(cmd, stdin=sfd, stdout=sfd, stderr=sfd,
                            preexec_fn=child, close_fds=True)
    os.close(sfd)
    seen = b""
    buf = b""
    idx = 0
    deadline = time.time() + timeout
    while time.time() < deadline:
        if idx < len(pairs) and pairs[idx].encode() in buf:
            os.write(mfd, pairs[idx + 1].encode() + b"\n")
            buf = b""
            idx += 2
            continue
        ready, _, _ = select.select([mfd], [], [], 1.0)
        if ready:
            try:
                chunk = os.read(mfd, 65536)
            except OSError:
                break
            if not chunk:
                break
            seen += chunk
            buf += chunk
        elif proc.poll() is not None:
            break
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    os.close(mfd)
    transcript = seen.decode("utf-8", "replace")
    tpath = os.path.join(FIX, "transcript-%d.txt" % int(time.time() * 1000))
    with open(tpath, "w", encoding="utf-8") as fh:
        fh.write(transcript)
    # THE TRANSCRIPT IS AN OUTPUT, because one of the properties under test is
    # that the password is NOT in it.
    out(exit=proc.returncode, prompts="%d/%d" % (idx // 2, len(pairs) // 2),
        transcript=tpath)


# --- http --------------------------------------------------------------------

def req(url, host, method="GET", body=None, cookie=None, extra=None):
    """One request.  Returns (status, headers, body-bytes).

    X-Forwarded-Proto: https IS the point of this helper.  Authelia's session
    cookie is Secure, and the fixture publishes plain HTTP on loopback, so
    without this header the cookie is rejected as insecure and every assertion
    below would measure nothing.
    """
    data = None
    headers = {
        "X-Forwarded-Proto": "https",
        "X-Forwarded-Host": host,
        "Accept": "application/json",
    }
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if cookie:
        headers["Cookie"] = cookie
    if extra:
        headers.update(extra)
    rq = urllib.request.Request(url, data=data, headers=headers, method=method)

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None

    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(rq, timeout=30) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.headers, exc.read()
    except urllib.error.URLError as exc:
        refuse("could not reach %s: %s" % (url, exc))


def jdoc(body):
    """Parse a JSON body, or report it as data rather than as a traceback.

    Authelia does not answer JSON on every path -- a rejected elevation request
    returns a plain `Forbidden` body -- and a test that dies with a
    JSONDecodeError on one of those has turned a measurement into a crash.
    The body is reported verbatim (truncated, newlines flattened); out() quotes
    it, so it stays readable rather than being mangled to survive an eval.
    """
    try:
        return json.loads(body or b"{}")
    except ValueError:
        return {"status": "?", "raw": (body or b"")[:120].decode(
            "utf-8", "replace").replace("\n", " ").strip()}


def session_cookie(headers):
    for raw in headers.get_all("Set-Cookie") or []:
        jar = http.cookies.SimpleCookie()
        jar.load(raw)
        for name, morsel in jar.items():
            if name == "aistack_session":
                return "%s=%s" % (name, morsel.value)
    return None


def remember(headers, cookie):
    """Keep the stored session cookie current.  Returns (cookie, "yes"/"no").

    AUTHELIA REGENERATES THE SESSION ID AT EACH SECURITY STEP, and a client
    that keeps sending the pre-step value is anonymous from then on.  MEASURED
    (NOM-402): `POST /api/user/session/elevation` answers `{"status":"OK"}`
    and sets a NEW aistack_session cookie; the very next request carrying the
    old one is refused by Authelia's 1FA middleware with a plain-text
    `403 Forbidden` and NO log line -- which reads exactly like the one-time
    code being rejected, and is not.  The same regeneration after the second
    factor is handled in cmd_probe_twofactor for the same reason.
    """
    fresh = session_cookie(headers)
    if fresh and fresh != cookie:
        with open(COOKIE_FILE, "w", encoding="utf-8") as fh:
            fh.write(fresh)
        return fresh, "yes"
    return cookie, "no"


def forward_auth(base, host, cookie=None, accept="text/html"):
    """The verdict Caddy gets for one request.

    THE `Accept` HEADER CHANGES THE DENIAL, and both forms are real: Caddy's
    forward_auth passes the original request's headers through, so a person's
    browser (text/html) is redirected to the portal with 302 while an XHR or
    an API client (application/json) is refused with 401.  Measured both ways
    (NOM-402).  Neither reaches protected content, and asserting only one of
    them would leave the other free to become a 200.
    """
    status, _, _ = req(
        base + "/api/authz/forward-auth", host, cookie=cookie,
        extra={"X-Forwarded-Method": "GET", "X-Forwarded-Uri": "/",
               "Accept": accept})
    return status


def cmd_probe_anon(argv):
    base, host = argv[0], argv[1]
    out(fa=forward_auth(base, host),
        fa_api=forward_auth(base, host, accept="application/json"))


def cmd_probe_password(argv):
    base, host, user = argv[0], argv[1], argv[2]
    status, headers, body = req(
        base + "/api/firstfactor", host, method="POST",
        body={"username": user, "password": password(),
              "keepMeLoggedIn": False, "targetURL": "https://%s/" % host})
    doc = jdoc(body)
    cookie = session_cookie(headers)
    if cookie:
        with open(COOKIE_FILE, "w", encoding="utf-8") as fh:
            fh.write(cookie)
    out(http=status, first=doc.get("status", "?"),
        cookie="yes" if cookie else "no",
        fa=forward_auth(base, host, cookie) if cookie else "none",
        fa_api=forward_auth(base, host, cookie, "application/json")
        if cookie else "none")


def cmd_elevate_start(argv):
    base, host = argv[0], argv[1]
    cookie = open(COOKIE_FILE, encoding="utf-8").read().strip()
    status, headers, body = req(base + "/api/user/session/elevation", host,
                                method="POST", cookie=cookie)
    doc = jdoc(body)
    _, rotated = remember(headers, cookie)
    out(http=status, elevation=doc.get("status", "?"), rotated=rotated,
        detail=doc.get("raw", doc.get("message", "")))


def cmd_enrol(argv):
    """enrol <base> <host> <otc>: elevate with the code, register TOTP, confirm."""
    base, host, otc = argv[0], argv[1], argv[2]
    cookie = open(COOKIE_FILE, encoding="utf-8").read().strip()
    status, headers, body = req(base + "/api/user/session/elevation", host,
                                method="PUT", cookie=cookie, body={"otc": otc})
    doc = jdoc(body)
    cookie, _ = remember(headers, cookie)
    if doc.get("status") != "OK":
        out(http=status, elevated=doc.get("status", "?"), registered="no",
            detail=doc.get("raw", doc.get("message", "?")))
        return
    # The body is REQUIRED.  Without it Authelia answers "Unable to set up
    # one-time password" and logs "error parsing the request body", which reads
    # like a server fault rather than a missing field (measured, NOM-402).
    status, headers, body = req(
        base + "/api/secondfactor/totp/register", host,
        method="PUT", cookie=cookie,
        body={"algorithm": "SHA1", "length": 6, "period": 30})
    doc = jdoc(body)
    cookie, _ = remember(headers, cookie)
    secret = (doc.get("data") or {}).get("base32_secret")
    if not secret:
        out(http=status, elevated="OK", registered="no",
            detail=doc.get("message", "?"))
        return
    with open(SECRET_FILE, "w", encoding="utf-8") as fh:
        fh.write(secret)
    status, headers, body = req(base + "/api/secondfactor/totp/register", host,
                                method="POST", cookie=cookie,
                                body={"token": totp(secret)})
    doc = jdoc(body)
    remember(headers, cookie)
    out(http=status, elevated="OK", registered=doc.get("status", "?"),
        detail=doc.get("raw", doc.get("message", "")))


def totp(secret):
    pad = "=" * ((8 - len(secret) % 8) % 8)
    key = base64.b32decode(secret + pad)
    counter = int(time.time()) // 30
    mac = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    off = mac[-1] & 0x0F
    return "%06d" % ((struct.unpack(">I", mac[off:off + 4])[0] & 0x7FFFFFFF)
                     % 1000000)


def cmd_probe_twofactor(argv):
    """Fresh login, then the second factor, then forward-auth."""
    base, host, user = argv[0], argv[1], argv[2]
    secret = open(SECRET_FILE, encoding="utf-8").read().strip()
    # WAIT FOR A NEW PERIOD.  Authelia refuses a TOTP value it has already
    # seen, so reusing the code that confirmed the registration fails with
    # "Authentication failed, please retry later" -- which looks exactly like a
    # wrong secret (measured, NOM-402).
    first = totp(secret)
    waited = 0
    while totp(secret) == first and waited < 35:
        time.sleep(2)
        waited += 2

    _, headers, _ = req(
        base + "/api/firstfactor", host, method="POST",
        body={"username": user, "password": password(),
              "keepMeLoggedIn": False, "targetURL": "https://%s/" % host})
    c1 = session_cookie(headers)
    if not c1:
        refuse("the first factor returned no session cookie")
    status, headers, body = req(
        base + "/api/secondfactor/totp", host, method="POST", cookie=c1,
        body={"token": totp(secret), "targetURL": "https://%s/" % host})
    doc = jdoc(body)
    # THE COOKIE IS ROTATED BY THE SECOND FACTOR.  Keeping c1 here leaves the
    # test holding a session that is still one-factor, and it then measures a
    # denial it would have got anyway (measured, NOM-402).
    c2 = session_cookie(headers) or c1
    rotated = "yes" if (session_cookie(headers) and
                        session_cookie(headers) != c1) else "no"
    _, _, sbody = req(base + "/api/state", host, cookie=c2)
    sdoc = jdoc(sbody)
    out(http=status, second=doc.get("status", "?"), rotated=rotated,
        level=(sdoc.get("data") or {}).get("authentication_level", "?"),
        fa=forward_auth(base, host, c2),
        fa_api=forward_auth(base, host, c2, "application/json"))


COMMANDS = {
    "drive": cmd_drive,
    "probe-anon": cmd_probe_anon,
    "probe-password": cmd_probe_password,
    "elevate-start": cmd_elevate_start,
    "enrol": cmd_enrol,
    "probe-twofactor": cmd_probe_twofactor,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        refuse("usage: owner-bootstrap.py {%s} ..." % "|".join(COMMANDS))
    if not FIX or not os.path.isdir(FIX):
        refuse("FIXTURE must name the fixture directory")
    COMMANDS[sys.argv[1]](sys.argv[2:])
