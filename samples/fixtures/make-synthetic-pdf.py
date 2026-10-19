#!/usr/bin/env python3
"""Write samples/fixtures/synthetic.pdf — the one document W2 parses.

A GENERATOR RATHER THAN A COMMITTED BLOB, for two reasons.  A binary fixture in
git has no reviewable diff, so "the PDF changed" is a line nobody can read; and
a PDF is the single most attacker-shaped file format this stack accepts, so the
one we ship should be a file whose every byte is accounted for in source rather
than one someone downloaded once.

No dependencies.  reportlab is not installed in this stack and adding a Python
PDF library to build a four-line fixture would be a dependency with a CVE feed
attached.  The output is a hand-built PDF 1.4 with one page, one Helvetica text
object and a correct xref table — which is also a fair test of Docling, since a
minimal PDF exercises the parser's own layout inference rather than handing it
a tagged document that already knows its own reading order.

Deterministic: no creation date, no producer string, no object ordering that
depends on dict iteration.  Byte-identical on every run, so a fixture that
changes means the generator changed.
"""

import os
import sys

# The sentinel is what `aistack samples run W2` asserts Docling recovered.  It
# is deliberately unlike anything in the corpus or in a model's vocabulary: a
# substring match on it cannot be satisfied by a model paraphrasing, only by
# the bytes having made it through the parse.
SENTINEL = "AISTACK-SYNTHETIC-PDF-SENTINEL-7F3A"

LINES = [
    "Synthetic document for the W2 demo",
    "",
    SENTINEL,
    "",
    "This page exists so that Chat with your PDF has a PDF to chat with.",
    "It is synthetic: no customer wrote it and no real document was copied",
    "to make it. Docling parses these bytes, LiteLLM embeds the result, and",
    "the embedding lands in w2_chunks next to the local corpus.",
    "",
    "Retrieval over this page should find this page. That is the whole claim",
    "the demo makes, and it is the only one the harness checks.",
]


def escape(text):
    """PDF string escaping: backslash, then the parens it would otherwise end."""
    return text.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")


def build():
    # Text object: 12pt Helvetica, 16pt leading, starting near the top of a
    # US Letter page so nothing lands outside the MediaBox and gets dropped.
    content = ["BT", "/F1 12 Tf", "16 TL", "72 708 Td"]
    for line in LINES:
        content.append("(%s) Tj" % escape(line))
        content.append("T*")
    content.append("ET")
    stream = "\n".join(content).encode("ascii")

    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
        b"/Encoding /WinAnsiEncoding >>",
    ]

    out = bytearray(b"%PDF-1.4\n")
    # A binary comment line.  Without it a conforming reader may treat the file
    # as text and a transport may helpfully convert its line endings.
    out += b"%\xe2\xe3\xcf\xd3\n"

    offsets = []
    for i, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"

    xref_at = len(out)
    out += b"xref\n0 %d\n" % (len(objects) + 1)
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\n" % (len(objects) + 1)
    out += b"startxref\n%d\n%%%%EOF\n" % xref_at
    return bytes(out)


def main():
    dest = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "synthetic.pdf")
    data = build()
    with open(dest, "wb") as fh:
        fh.write(data)
    print("wrote %s (%d bytes, sentinel %s)" % (dest, len(data), SENTINEL))


if __name__ == "__main__":
    main()
