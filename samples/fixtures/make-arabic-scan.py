#!/usr/bin/env python3
"""Make samples/fixtures/arabic-scan.pdf: a SYNTHETIC Arabic invoice reminder,
rendered to an image and saved as an image-only PDF, so it has no text layer
and only OCR can read it (NOM-415, profile docs-arabic; demo 6).

Everything in it is invented: the company, the invoice number, the amounts.

How it was made (re-run to regenerate; the committed PDF is the output):
  docker run --rm -v "$PWD/samples/fixtures:/w" -w /w \
    python:3.12.15-slim-trixie@sha256:a0f57064cbdcd6285fa45f51237ab0b35ea8ebaed06a1f5973e89e19dfb86704 sh -c \
    'apt-get update -qq && apt-get install -y -qq libraqm0 fonts-noto-core >/dev/null \
     && pip install -q pillow==12.0.0 && python make-arabic-scan.py'
The base is the repo's PYBASE pin.  The font is Noto Naskh Arabic (SIL OFL
1.1).  It has no em dash and no brackets, so the text uses a colon: a missing glyph renders
as an empty box, and OCR would then be blamed for it.  Pillow must report raqm, or the
Arabic letters would be drawn unjoined and left-to-right, which is a damaged
image, not a test of OCR.

EXPECTED is what tests/profiles.sh and scripts/profile-smoke.sh look for in
the OCR output: words that must appear, and the amounts and dates as digits.
"""
import json
import random
import sys

EXPECTED = {
    "words": ["فاتورة", "شركة", "الواحة", "للتجارة", "المبلغ", "المستحق", "ريال",
              "تاريخ", "الاستحقاق", "السداد", "تذكير", "نوفمبر"],
    "numbers": ["2041", "12,500", "15", "2026"],
}

LINES = [
    "تذكير بالسداد: بيانات تجريبية",
    "شركة الواحة للتجارة",
    "فاتورة رقم 2041",
    "تاريخ الاستحقاق: 15 نوفمبر 2026",
    "المبلغ المستحق: 12,500 ريال",
    "نرجو السداد قبل نهاية الشهر، وشكراً لتعاونكم.",
]


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--expected":
        print(json.dumps(EXPECTED, ensure_ascii=False))
        return
    from PIL import Image, ImageDraw, ImageFilter, ImageFont, features
    if not features.check("raqm"):
        sys.exit("Pillow has no raqm: Arabic would be drawn unshaped. Install libraqm.")
    font = ImageFont.truetype("/usr/share/fonts/truetype/noto/NotoNaskhArabic-Regular.ttf", 44)
    img = Image.new("L", (1654, 1100), 255)          # A5-ish landscape at ~200 dpi
    d = ImageDraw.Draw(img)
    y = 90
    for line in LINES:
        w = d.textlength(line, font=font, direction="rtl", language="ar")
        d.text((1654 - 110 - w, y), line, font=font, fill=20, direction="rtl", language="ar")
        y += 140
    # Make it look scanned: a small tilt, a little blur and paper noise.
    random.seed(415)
    img = img.rotate(0.8, resample=Image.BICUBIC, fillcolor=255, expand=False)
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    px = img.load()
    for _ in range(9000):
        x, yy = random.randrange(img.width), random.randrange(img.height)
        px[x, yy] = random.choice((150, 200, 230))
    img.convert("RGB").save("arabic-scan.pdf", "PDF", resolution=200.0)
    print("wrote arabic-scan.pdf", img.size)


if __name__ == "__main__":
    main()
