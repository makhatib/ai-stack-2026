#!/usr/bin/env python3
# AI Stack 2026 — everything that touches config/authelia/users.yml.
#
# `scripts/user.sh` is the human surface: it prompts, restarts Authelia and
# reads the database.  This file is the part that hashes a password and edits
# the file, and it is separate for two reasons that are both about the password.
#
# WHY A PTY, AND WHY THE PASSWORD NEVER REACHES argv (NOM-402).
#
# The obvious shape is `printf %s "$pw" | docker run -i … authelia crypto hash
# generate argon2`.  MEASURED against the pinned 4.39.28 image three ways —
# with a trailing newline, without one, and with the confirmation prompt left
# on — and all three fail identically:
#
#   Error: failed to read the password from the terminal: you must either use
#   an interactive terminal or use the --password flag
#
# So that CLI takes a password from exactly two places: a terminal, or
# `--password <value>` on argv.  argv is not an option.  On the operator's own
# machine `ps` shows every local user the password of the one account that can
# open anything, and it is the docker client's argv that would carry it.
#
# That leaves a terminal, which means a pty.  `-i` alone is NOT enough: docker
# hands the container a pipe whatever our own stdin is, so the container still
# sees no terminal.  `-t` is the flag that makes the container's fd 0 a tty.
# With `-i -t` and the slave side of an openpty() as that stdin, docker is
# satisfied and Authelia's prompt reads from a real terminal.  The password
# travels prompt -> pipe -> pty and is in no argv, no file and no environment
# variable at any point.
#
# WHY THE FILE IS READ AND WRITTEN THROUGH A CONTAINER.
#
# config/authelia/users.yml is root:root 0600 inside a directory the operator
# owns — scripts/gen-secrets.sh puts it that way on purpose, because Authelia
# runs as uid 0 with every capability dropped and so does not bypass file
# permissions.  The operator can therefore replace the file but can neither
# read nor write it.  Rather than make `aistack user` a sudo command, the
# PINNED Authelia image — which is busybox-based and already has cat, mv,
# chown and chmod — does both halves as container root.  Anyone who can run
# `aistack up` already has the docker socket, so this grants nothing new; it
# only avoids a password prompt for sudo in the middle of a password prompt
# for Authelia.
#
# THE WRITE IS AN ATOMIC RENAME INSIDE THE MOUNT.  A truncate-in-place would
# leave a window in which users.yml is half a file, and the one file that
# decides whether anybody can log in is the wrong file to leave torn.  The temp
# name is created inside the same directory, given the same owner and mode, and
# renamed over the target.
#
# NO PYTHON LIBRARY IS REQUIRED HERE, AND THAT IS A CONSTRAINT RATHER THAN A
# PREFERENCE.  docs/install.md lists the host tools this stack needs and says in
# so many words that a plain `python3` is enough; install.sh checks that list and
# deliberately does not check for PyYAML (NOM-307, whose lesson was that the one
# path depending on a missing library DEGRADED QUIETLY).  `aistack user reset` is
# the FIRST command an operator runs after installing, on a machine built from
# that list, so `import yaml` here would turn owner bootstrap phase 2 back into a
# documented path that does not work on a documented machine — which is the
# defect this file exists to fix.  The two things we need out of YAML are
# therefore done below, each narrow enough to be exact and each refusing rather
# than guessing:
#
#   * users.yml is parsed as the STRICT block mapping this file also emits.
#     Anything outside that subset — a tab, a flow mapping, an anchor, a block
#     scalar, an unexpected indentation — is refused BY NAME and before anything
#     is written, so the failure is "this file is not the shape I understand"
#     and never a silently mangled account.
#   * configuration.yml is NOT parsed.  One nested path is read out of it by
#     indentation, because that is all that is needed, and a general parser for a
#     155-line hand-commented config would be a far bigger thing to be wrong
#     about than the six integers it yields.
#
# THE HASH PARAMETERS ARE DERIVED FROM THE SHIPPED CONFIG, NOT RETYPED.  An
# argon2 digest carries its own m/t/p, so a hash made with other parameters
# would still VERIFY — which is exactly why a retyped copy here could drift for
# a whole release without anything going red.  We read
# authentication_backend.file.password.argon2 out of
# config/authelia/configuration.yml, pass those values, and then assert the
# digest came back carrying them.

import argparse
import os
import pty
import re
import select
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUTH_DIR = os.environ.get("AISTACK_AUTHELIA_DIR",
                          os.path.join(ROOT, "config", "authelia"))
CONFIG = os.path.join(AUTH_DIR, "configuration.yml")
USERS = os.path.join(AUTH_DIR, "users.yml")

# How long to wait for a digest.  argon2id at m=65536 t=3 is ~0.1s; the rest is
# docker creating and tearing down a container.  Generous, and bounded.
HASH_TIMEOUT = 90

# The key order we emit.  Deterministic so that a diff of two generated files
# is a diff of their content, and `password` sits next to the name it belongs
# to rather than wherever a dict happened to put it.
KEY_ORDER = ["displayname", "password", "email", "groups", "disabled"]


def die(msg):
    sys.stderr.write("aistack user: %s\n" % msg)
    raise SystemExit(1)


# --- the small strict YAML this file reads and writes ------------------------
#
# Supported, because it is what users.yml is: a block mapping of block mappings,
# whose values are plain / single-quoted / double-quoted scalars, integers,
# true, false, null, a block sequence of those, or an empty flow sequence.
# Everything else is refused, including every YAML feature that could make two
# readers disagree about what the file says.


class Malformed(Exception):
    """users.yml is not in the subset this command understands."""


def _tokens(text):
    """(lineno, indent, content) for the lines that carry data."""
    toks = []
    for n, raw in enumerate(text.splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        stripped = raw.lstrip(" ")
        indent = len(raw) - len(stripped)
        # A TAB IN THE INDENTATION IS REFUSED RATHER THAN INTERPRETED.  YAML
        # forbids it, editors insert it, and guessing a width here would be
        # this command inventing a meaning for a file it is about to rewrite.
        if "\t" in raw[:indent] or stripped.startswith("\t"):
            raise Malformed("line %d indents with a tab" % n)
        toks.append((n, indent, stripped.rstrip()))
    return toks


def _uncomment(s, lineno):
    """`s` without a trailing comment.  Quotes are respected, not stripped."""
    if s[:1] in ("'", '"'):
        quote, i = s[0], 1
        while i < len(s):
            if quote == '"' and s[i] == "\\":
                i += 2
                continue
            if s[i] == quote:
                if quote == "'" and s[i + 1:i + 2] == "'":
                    i += 2
                    continue
                rest = s[i + 1:].strip()
                if rest and not rest.startswith("#"):
                    raise Malformed(
                        "line %d has %r after a quoted value" % (lineno, rest))
                return s[:i + 1]
            i += 1
        raise Malformed("line %d has an unterminated %s quote" % (lineno, quote))
    cut = s.find(" #")
    return (s[:cut] if cut >= 0 else s).rstrip()


def _scalar(s, lineno):
    if s in ("", "~", "null"):
        return None
    if s == "true":
        return True
    if s == "false":
        return False
    if s.startswith('"'):
        if len(s) < 2 or not s.endswith('"'):
            raise Malformed("line %d has an unterminated double quote" % lineno)
        body, out, i = s[1:-1], [], 0
        while i < len(body):
            if body[i] == "\\":
                nxt = body[i + 1:i + 2]
                if nxt not in ('"', "\\"):
                    # \n, \t, \u… are real YAML and this does not implement
                    # them; a password hash, a display name and an address need
                    # none of them, and a wrong guess would corrupt one.
                    raise Malformed(
                        "line %d uses the escape \\%s, which this command does "
                        "not implement" % (lineno, nxt or "<end>"))
                out.append(nxt)
                i += 2
                continue
            out.append(body[i])
            i += 1
        return "".join(out)
    if s.startswith("'"):
        if len(s) < 2 or not s.endswith("'"):
            raise Malformed("line %d has an unterminated single quote" % lineno)
        return s[1:-1].replace("''", "'")
    if s.startswith("["):
        if not s.endswith("]"):
            raise Malformed("line %d has an unterminated flow sequence" % lineno)
        inner = s[1:-1].strip()
        if not inner:
            return []
        return [_scalar(part.strip(), lineno) for part in inner.split(",")]
    if s[0] in "&*!|>{%@`":
        raise Malformed(
            "line %d starts a YAML feature this command does not implement (%s)"
            % (lineno, s[0]))
    if re.match(r"^-?[0-9]+$", s):
        return int(s)
    return s


def _sequence(toks, i, indent):
    items = []
    while i < len(toks):
        lineno, ind, content = toks[i]
        if ind < indent:
            break
        if ind > indent:
            raise Malformed("line %d is indented deeper than its sequence"
                            % lineno)
        if not content.startswith("- "):
            break
        items.append(_scalar(_uncomment(content[2:].strip(), lineno), lineno))
        i += 1
    return items, i


def _mapping(toks, i, indent):
    out = {}
    while i < len(toks):
        lineno, ind, content = toks[i]
        if ind < indent:
            break
        if ind > indent:
            raise Malformed("line %d is indented deeper than the mapping it is "
                            "in" % lineno)
        if content.startswith("- "):
            raise Malformed("line %d is a sequence item where a key was "
                            "expected" % lineno)
        key, sep, rest = content.partition(":")
        if not sep:
            raise Malformed("line %d is not `key: value`" % lineno)
        key = key.strip()
        if not key or key.startswith(("'", '"')):
            raise Malformed("line %d does not have a plain key" % lineno)
        if key in out:
            # A DUPLICATE KEY IS REFUSED, NOT RESOLVED.  YAML says the last one
            # wins; a reader that silently applied that rule to users.yml would
            # drop an account the operator can see in the file.
            raise Malformed("line %d repeats the key %r" % (lineno, key))
        rest = _uncomment(rest.strip(), lineno)
        if rest:
            out[key] = _scalar(rest, lineno)
            i += 1
            continue
        if i + 1 < len(toks) and toks[i + 1][1] > ind:
            child = toks[i + 1][1]
            if toks[i + 1][2].startswith("- "):
                out[key], i = _sequence(toks, i + 1, child)
            else:
                out[key], i = _mapping(toks, i + 1, child)
        else:
            out[key] = None
            i += 1
    return out, i


def parse_strict(text):
    """The document, or Malformed."""
    toks = _tokens(text)
    if not toks:
        raise Malformed("the file has no content")
    if toks[0][1] != 0:
        raise Malformed("line %d is indented, so the file has no top level"
                        % toks[0][0])
    doc, i = _mapping(toks, 0, 0)
    if i != len(toks):
        raise Malformed("line %d is outside the top-level mapping"
                        % toks[i][0])
    return doc


def config_scalars(path):
    """The scalar children of a nested path in configuration.yml.

    Found by indentation, not by parsing the file: see the header.  Refuses if
    a step of the path is missing, or occurs twice at its level and is
    therefore ambiguous.
    """
    try:
        with open(CONFIG, encoding="utf-8") as fh:
            toks = _tokens(fh.read())
    except OSError as exc:
        die("could not read %s: %s" % (CONFIG, exc))
    except Malformed as exc:
        die("%s: %s" % (CONFIG, exc))
    lo, hi, indent = 0, len(toks), 0
    for step in path:
        hits = [i for i in range(lo, hi)
                if toks[i][1] == indent
                and toks[i][2].partition(":")[0].strip() == step]
        if len(hits) != 1:
            die("%s has %d `%s:` keys where exactly one was expected (path %s); "
                "refusing to guess which one configures the running stack"
                % (CONFIG, len(hits), step, ".".join(path)))
        i = hits[0]
        j = i + 1
        while j < hi and toks[j][1] > indent:
            j += 1
        if j == i + 1:
            die("%s has `%s:` with nothing under it (path %s)"
                % (CONFIG, step, ".".join(path)))
        lo, hi, indent = i + 1, j, toks[i + 1][1]
    out = {}
    for i in range(lo, hi):
        lineno, ind, content = toks[i]
        if ind != indent:
            continue
        key, sep, rest = content.partition(":")
        if not sep:
            continue
        rest = _uncomment(rest.strip(), lineno)
        if rest:
            try:
                out[key.strip()] = _scalar(rest, lineno)
            except Malformed as exc:
                die("%s: %s" % (CONFIG, exc))
    return out


def pinned_image():
    """The Authelia image:tag@digest, read from versions.env."""
    pins = {}
    try:
        with open(os.path.join(ROOT, "versions.env"), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                pins[k.strip()] = v.strip()
    except OSError as exc:
        die("could not read versions.env: %s" % exc)
    for key in ("AUTHELIA_IMAGE", "AUTHELIA_TAG", "AUTHELIA_DIGEST"):
        if not pins.get(key):
            die("versions.env does not define %s" % key)
    return "%s:%s@%s" % (pins["AUTHELIA_IMAGE"], pins["AUTHELIA_TAG"],
                         pins["AUTHELIA_DIGEST"])


# --- the file, through the pinned image -------------------------------------

def read_users_file():
    """users.yml's bytes, read as container root.  '' when it does not exist."""
    if not os.path.exists(USERS):
        return None
    proc = subprocess.run(
        ["docker", "run", "--rm", "--network", "none",
         "-v", "%s:/c:ro" % AUTH_DIR, "--entrypoint", "cat", pinned_image(),
         "/c/users.yml"],
        capture_output=True, stdin=subprocess.DEVNULL)
    if proc.returncode != 0:
        die("could not read %s (it is root-owned, so this goes through the "
            "pinned Authelia image): %s"
            % (USERS, proc.stderr.decode("utf-8", "replace").strip()))
    return proc.stdout.decode("utf-8")


def write_users_file(text):
    """Replace users.yml atomically, keeping root:root 0600."""
    # The temp name is inside the mounted directory so that `mv` is a rename
    # within one filesystem and therefore atomic.  `set -e` inside the shell
    # chain means a failed chown or chmod leaves the TEMP file behind and the
    # real users.yml untouched, which is the safe half of the two.
    script = (
        "set -e; umask 077; "
        "cat > /c/.users.yml.new; "
        "chown 0:0 /c/.users.yml.new; "
        "chmod 0600 /c/.users.yml.new; "
        "mv -f /c/.users.yml.new /c/users.yml"
    )
    proc = subprocess.run(
        ["docker", "run", "--rm", "-i", "--network", "none",
         "-v", "%s:/c" % AUTH_DIR, "--entrypoint", "sh", pinned_image(),
         "-c", script],
        input=text.encode("utf-8"), capture_output=True)
    if proc.returncode != 0:
        die("could not write %s: %s"
            % (USERS, proc.stderr.decode("utf-8", "replace").strip()))


def split_header(text):
    """Everything before the top-level `users:` key, and the parsed mapping.

    The header is the file's own documentation of the bootstrap and is kept
    byte-for-byte; only the mapping below it is regenerated.  Per-user inline
    comments are not preserved, and that is deliberate — the one the installer
    writes says the hash was written by the installer, which stops being true
    the moment `aistack user reset` runs.
    """
    lines = text.splitlines(True)
    idx = None
    for i, line in enumerate(lines):
        if re.match(r"^users:\s*$", line):
            idx = i
            break
    if idx is None:
        die("%s has no top-level `users:` key; refusing to rewrite a file "
            "whose shape is not the one this command understands" % USERS)
    try:
        doc = parse_strict(text)
    except Malformed as exc:
        die("%s is not in the shape this command understands (%s); fix it "
            "before changing a user, and nothing was written" % (USERS, exc))
    if not isinstance(doc, dict) or not isinstance(doc.get("users"), dict):
        die("%s does not contain a `users:` mapping" % USERS)
    return "".join(lines[:idx + 1]), doc["users"]


def scalar(val):
    """One YAML scalar.

    EVERY STRING IS DOUBLE-QUOTED, including ones that would not need it.  An
    argon2id digest is `$`-dense and a display name is whatever a person typed,
    so the alternative is a per-value decision about whether this one needs
    quoting — and that decision is where a writer gets it wrong once and leaves
    a users.yml Authelia will not load.  Double quotes with `\\` and `"`
    escaped are safe for every character a digest, a display name or an address
    can contain, and the reader above accepts exactly those two escapes.
    """
    if isinstance(val, bool):
        return "true" if val else "false"
    if val is None:
        return "null"
    if isinstance(val, int):
        return str(val)
    return '"%s"' % str(val).replace("\\", "\\\\").replace('"', '\\"')


def emit(header, users):
    """Render the file back.  Deterministic, and valid YAML by construction."""
    out = [header]
    for name in sorted(users):
        fields = users[name] or {}
        out.append("  %s:\n" % name)
        keys = [k for k in KEY_ORDER if k in fields]
        keys += sorted(k for k in fields if k not in KEY_ORDER)
        for key in keys:
            val = fields[key]
            if isinstance(val, list):
                if not val:
                    out.append("    %s: []\n" % key)
                else:
                    out.append("    %s:\n" % key)
                    for item in val:
                        out.append("      - %s\n" % scalar(item))
            else:
                out.append("    %s: %s\n" % (key, scalar(val)))
    text = "".join(out)
    # PROVE THE RESULT READS BACK BEFORE IT IS WRITTEN.  Authelia reads this
    # file at startup and refuses to start without it, so a file we cannot read
    # ourselves must never reach the disk.  This is a round trip through the
    # reader above, which catches the failure that is actually plausible here —
    # a display name, address or digest whose quoting came out wrong — and the
    # restart `aistack user` performs afterwards is what proves AUTHELIA agrees:
    # it reports unhealthy if it cannot load the file.
    try:
        back = parse_strict(text)
    except Malformed as exc:
        die("the rewritten users.yml does not read back (%s); nothing was "
            "written" % exc)
    if not isinstance(back, dict) or back.get("users") != users:
        die("the rewritten users.yml does not round-trip to the same users; "
            "nothing was written")
    return text


# --- hashing ----------------------------------------------------------------

def argon2_params():
    pwd = config_scalars(["authentication_backend", "file", "password"])
    params = config_scalars(["authentication_backend", "file", "password",
                             "argon2"])
    algorithm = pwd.get("algorithm")
    if not params or algorithm is None:
        die("%s has no authentication_backend.file.password.argon2 block, so "
            "the parameters to hash with are UNKNOWN; refusing to guess"
            % CONFIG)
    if algorithm != "argon2":
        die("configuration.yml selects password algorithm %r, not argon2; this "
            "command only knows how to drive argon2" % algorithm)
    need = ("variant", "iterations", "memory", "parallelism", "key_length",
            "salt_length")
    missing = [k for k in need if params.get(k) is None]
    if missing:
        die("configuration.yml's argon2 block is missing %s. Refusing to fall "
            "back to the CLI's own defaults: that would hash with parameters "
            "the running config does not state." % ", ".join(missing))
    return params


def read_password(stream):
    data = stream.read()
    # ONE trailing newline is stripped and nothing else is touched.  A password
    # may legitimately begin or end with a space and this is not the place that
    # decides it may not.
    if data.endswith(b"\r\n"):
        data = data[:-2]
    elif data.endswith(b"\n"):
        data = data[:-1]
    if not data:
        die("no password arrived on stdin")
    if b"\n" in data or b"\r" in data:
        die("the password contains a newline, which cannot be typed into "
            "Authelia's prompt; choose one without")
    return data


def hash_password(password):
    params = argon2_params()
    image = pinned_image()
    mfd, sfd = pty.openpty()
    argv = [
        "docker", "run", "--rm", "-i", "-t",
        # No network: hashing is pure computation, and a container with no
        # route cannot send the password anywhere either.
        "--network", "none",
        image,
        "authelia", "crypto", "hash", "generate", "argon2", "--no-confirm",
        "-v", str(params["variant"]),
        "-i", str(params["iterations"]),
        "-m", str(params["memory"]),
        "-p", str(params["parallelism"]),
        "-k", str(params["key_length"]),
        "-s", str(params["salt_length"]),
    ]
    try:
        proc = subprocess.Popen(argv, stdin=sfd, stdout=sfd, stderr=sfd,
                                close_fds=True)
    except OSError as exc:
        os.close(mfd)
        os.close(sfd)
        die("could not run docker: %s" % exc)
    os.close(sfd)

    # WAIT FOR THE PROMPT; DO NOT GUESS AT IT.  A fixed sleep is a race with
    # container start-up: write too early and the terminal swallows the
    # password before Authelia has asked for it, and the run then hangs on a
    # prompt that will never be answered.
    #
    # MATCH ON A FLATTENED BUFFER.  The prompt does not arrive as a line: the
    # pty echoes it ONE CHARACTER PER LINE, so the raw bytes are
    # b"E\r\nn\r\nt\r\ne\r\nr\r\n \r\nP\r\na\r\ns\r\ns..." and a search for
    # b"assword" over them never matches.  Measured 2026-10-24; a first version
    # of this loop used a fixed sleep instead and so looked like it worked.
    buf = b""
    sent = False
    deadline = time.time() + HASH_TIMEOUT
    while time.time() < deadline:
        ready, _, _ = select.select([mfd], [], [], 1.0)
        if ready:
            try:
                chunk = os.read(mfd, 4096)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            flat = buf.replace(b"\r", b"").replace(b"\n", b"")
            if not sent and b"assword" in flat:
                os.write(mfd, password + b"\n")
                sent = True
            if b"Digest:" in flat:
                break
        elif proc.poll() is not None:
            break
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    os.close(mfd)

    # The pty echoes the prompt a character at a time, so flatten before
    # matching.  The password itself is never in here — Authelia puts the
    # terminal into no-echo to read it — but the buffer is dropped rather than
    # left for a traceback to print.
    text = buf.replace(b"\r", b"").replace(b"\n", b"").decode("utf-8", "replace")
    del buf
    if not sent:
        die("the pinned Authelia image never asked for a password "
            "(exit %s): %s" % (proc.returncode, text[-300:]))
    m = re.search(r"Digest:\s*(\$argon2id\$\S+)", text)
    if not m:
        die("no digest in the hashing output (exit %s): %s"
            % (proc.returncode, text[-300:]))
    digest = m.group(1)

    # ASSERT THE DIGEST MATCHES THE RUNNING CONFIG.  See the header: a digest
    # made with other parameters would still verify, so this is the only thing
    # that would notice the flags above drifting away from configuration.yml.
    want = "m=%s,t=%s,p=%s" % (params["memory"], params["iterations"],
                               params["parallelism"])
    if want not in digest:
        die("the digest does not carry the parameters configuration.yml "
            "states (%s); refusing to write it" % want)
    return digest


# --- subcommands ------------------------------------------------------------

def require_users_file():
    text = read_users_file()
    if text is None:
        die("%s does not exist yet. The installer creates it (owner bootstrap, "
            "phase 1); run ./install.sh first." % USERS)
    return text


def cmd_names(_args):
    header, users = split_header(require_users_file())
    del header
    for name in sorted(users):
        f = users[name] or {}
        groups = f.get("groups") or []
        if not isinstance(groups, list):
            groups = [groups]
        print("%s\t%s\t%s\t%s" % (
            name, f.get("displayname") or "", f.get("email") or "",
            ",".join(str(g) for g in groups)))


def cmd_set_password(args):
    header, users = split_header(require_users_file())
    if args.username not in users:
        die("there is no user %r. `aistack user list` shows who exists."
            % args.username)
    if not isinstance(users[args.username], dict):
        die("user %r has no fields in %s; fix the file before resetting them"
            % (args.username, USERS))
    digest = hash_password(read_password(sys.stdin.buffer))
    users[args.username]["password"] = digest
    write_users_file(emit(header, users))


def cmd_add(args):
    header, users = split_header(require_users_file())
    if args.username in users:
        die("user %r already exists. Use `aistack user reset %s` to change "
            "their password." % (args.username, args.username))
    if not re.match(r"^[a-z0-9][a-z0-9._-]{0,30}$", args.username):
        die("%r is not a usable username: use 1-31 characters from a-z, 0-9, "
            "dot, underscore and hyphen, starting with a letter or digit"
            % args.username)
    groups = [g.strip() for g in (args.groups or "").split(",") if g.strip()]
    digest = hash_password(read_password(sys.stdin.buffer))
    users[args.username] = {
        "displayname": args.display_name or args.username,
        "password": digest,
        "email": args.email or ("%s@localhost" % args.username),
        "groups": groups,
    }
    write_users_file(emit(header, users))


def cmd_remove(args):
    header, users = split_header(require_users_file())
    if args.username not in users:
        die("there is no user %r" % args.username)
    if len(users) == 1:
        die("%r is the only account in %s. Removing it would leave the stack "
            "with nobody who can log in and no supported way to create one "
            "without re-running the installer. Add the replacement first."
            % (args.username, USERS))
    del users[args.username]
    write_users_file(emit(header, users))


def main():
    ap = argparse.ArgumentParser(
        prog="authelia-users.py",
        description="Read and edit config/authelia/users.yml. Driven by "
                    "scripts/user.sh; not an operator-facing command.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("names", help="tab-separated name/displayname/email/groups")
    p.set_defaults(func=cmd_names)

    p = sub.add_parser("read", help="print users.yml")
    p.set_defaults(func=lambda a: sys.stdout.write(require_users_file()))

    p = sub.add_parser("set-password", help="password on stdin")
    p.add_argument("username")
    p.set_defaults(func=cmd_set_password)

    p = sub.add_parser("add", help="password on stdin")
    p.add_argument("username")
    p.add_argument("--display-name", default=None)
    p.add_argument("--email", default=None)
    p.add_argument("--groups", default=None,
                   help="comma-separated; empty by default, because a new "
                        "account should not inherit the owner's groups")
    p.set_defaults(func=cmd_add)

    p = sub.add_parser("remove")
    p.add_argument("username")
    p.set_defaults(func=cmd_remove)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
