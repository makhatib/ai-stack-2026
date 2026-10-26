#!/usr/bin/env python3
"""Write an OpenSSH ed25519 key pair from `openssl` output (NOM-415).

    ssh-keypair.py <private-out> <public-out> <comment>

Why not ssh-keygen: it is not one of the installer's host tools (install.sh step
1), and adding a host dependency for one optional profile is the wrong trade.
openssl and python3 already are.  openssl makes the key; this file only
re-encodes it, stdlib only:

  * the private key in OpenSSH's own format ("openssh-key-v1", unencrypted —
    it is a file secret with a 0640 mode, like every other one here);
  * the public key as one `ssh-ed25519 AAAA… comment` line.

Nothing is printed.  An existing private key is never replaced (the caller
checks), so a re-run cannot lock the gateway out of its own sandbox.
"""
import base64
import os
import struct
import subprocess
import sys


def sstr(b):
    return struct.pack(">I", len(b)) + b


def main():
    priv_out, pub_out, comment = sys.argv[1], sys.argv[2], sys.argv[3].encode()
    der = subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-outform", "DER"],
                         check=True, capture_output=True).stdout
    pub_der = subprocess.run(["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
                             input=der, check=True, capture_output=True).stdout
    # PKCS#8 for ed25519 ends with OCTET STRING(OCTET STRING(seed32)); SPKI ends with the 32-byte key.
    seed, pub = der[-32:], pub_der[-32:]
    if len(der) != 48 or len(pub_der) != 44:
        sys.exit("unexpected openssl ed25519 encoding; refusing to guess")
    ktype = b"ssh-ed25519"
    pub_blob = sstr(ktype) + sstr(pub)
    check = os.urandom(4)
    body = check + check + sstr(ktype) + sstr(pub) + sstr(seed + pub) + sstr(comment)
    body += bytes(range(1, 1 + (-len(body) % 8)))
    blob = (b"openssh-key-v1\0" + sstr(b"none") + sstr(b"none") + sstr(b"")
            + struct.pack(">I", 1) + sstr(pub_blob) + sstr(body))
    b64 = base64.b64encode(blob).decode()
    pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
    pem += "\n".join(b64[i:i + 70] for i in range(0, len(b64), 70))
    pem += "\n-----END OPENSSH PRIVATE KEY-----\n"
    old = os.umask(0o077)
    try:
        with open(priv_out, "w") as fh:
            fh.write(pem)
        with open(pub_out, "w") as fh:
            fh.write("ssh-ed25519 " + base64.b64encode(pub_blob).decode() + " " + comment.decode() + "\n")
    finally:
        os.umask(old)


if __name__ == "__main__":
    main()
