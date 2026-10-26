#!/usr/bin/env python3
"""Make the OCR sample set: 6 SYNTHETIC Arabic finance documents, each as an
image-only PDF (no text layer, so only OCR can read it) and as a PNG, plus
truth.json with the text in logical (reading) order and the named fields.

Everything in them is invented: companies, numbers, VAT and invoice IDs.

  docs/d01  clean letter (Naskh)                 d02  statement with a table (Sans)
  docs/d03  d01's exact text, "scanned"           d04  receipt, Arabic-Indic digits, Hijri date
  docs/d05  bilingual tax invoice (AR + EN)       d06  "phone photo": grey, tilted, JPEG
d01 and d03 hold the same text, so their gap is the cost of scan damage alone.

Re-run (writes into ./docs; the committed files are this script's output):
  docker run --rm -v "$PWD:/w" -w /w <PYBASE pinned image> sh -c \
    'apt-get update -qq && apt-get install -y -qq libraqm0 fonts-noto-core >/dev/null \
     && pip install -q pillow==12.0.0 fonttools==4.60.1 && python make_docs.py'
(run.sh ocr-docs does exactly this.)

Each text cell is drawn on its own, in one font and one direction: Arabic cells
right-to-left in an Arabic font, Latin/number-only cells left-to-right in a Latin
font.  So no line depends on the renderer's bidi handling of mixed runs, and the
pixels show the logical order that truth.json holds.  Every character is checked
against the font's cmap first: a missing glyph renders as an empty box, and OCR
would then be blamed for it.
"""
import hashlib
import json
import os
import random
import sys

NOTO = "/usr/share/fonts/truetype/noto/"
FONTS = {"naskh": "NotoNaskhArabic-Regular.ttf", "sans": "NotoSansArabic-Regular.ttf",
         "kufi": "NotoKufiArabic-Regular.ttf", "latin": "NotoSans-Regular.ttf"}


def is_arabic(s):
    return any("؀" <= c <= "ۿ" for c in s)


LETTER = [
    "شركة النخيل للمقاولات",
    "إشعار تذكير بالسداد",
    {"r": "رقم الفاتورة:", "l": "5318"},
    {"r": "تاريخ الفاتورة:", "l": "3/9/2026"},
    "تاريخ الاستحقاق: 3 أكتوبر 2026",
    {"r": "المبلغ المستحق بالريال:", "l": "48,750.00"},
    "نأمل التكرم بالسداد خلال سبعة أيام من تاريخ هذا الإشعار.",
    "للاستفسار يرجى التواصل مع قسم الحسابات.",
]
LETTER_FIELDS = [
    {"name": "invoice_no", "value": "5318", "accept": ["5318"]},
    {"name": "invoice_date", "value": "3/9/2026", "accept": ["3/9/2026", "3 9 2026"]},
    {"name": "due_date", "value": "3 أكتوبر 2026", "accept": ["3 أكتوبر 2026"]},
    {"name": "amount", "value": "48750.00", "accept": ["48750.00", "48750"]},
]

DOCS = {
    "d01": {"title": "clean letter", "font": "naskh", "size": 44, "lines": LETTER, "fields": LETTER_FIELDS,
            "damage": {}},
    "d02": {"title": "statement with a table", "font": "sans", "size": 38, "fields": [
        {"name": "row1_invoice", "value": "4011", "accept": ["4011"]},
        {"name": "row1_amount", "value": "12300.00", "accept": ["12300.00", "12300"]},
        {"name": "row2_invoice", "value": "4012", "accept": ["4012"]},
        {"name": "row2_amount", "value": "7450.50", "accept": ["7450.50"]},
        {"name": "row3_invoice", "value": "4019", "accept": ["4019"]},
        {"name": "row3_amount", "value": "3980.00", "accept": ["3980.00", "3980"]},
        {"name": "row3_date", "value": "2026-08-29", "accept": ["2026-08-29", "2026 08 29"]},
        {"name": "total", "value": "16280.00", "accept": ["16280.00", "16280"]}],
        "lines": [
            "كشف حساب العميل: مؤسسة الريان التجارية",
            {"cells": ["رقم الفاتورة", "التاريخ", "المبلغ", "الحالة"]},
            {"cells": ["4011", "2026-07-14", "12,300.00", "مستحقة"]},
            {"cells": ["4012", "2026-08-02", "7,450.50", "مسددة"]},
            {"cells": ["4019", "2026-08-29", "3,980.00", "متأخرة"]},
            {"r": "إجمالي الرصيد المستحق بالريال:", "l": "16,280.00"},
        ], "damage": {}},
    "d03": {"title": "d01 text, scanned", "font": "naskh", "size": 44, "lines": LETTER, "fields": LETTER_FIELDS,
            "damage": {"scale": 0.75, "rotate": 1.5, "blur": 1.0, "noise": 14000, "jpeg": 50}},
    "d04": {"title": "receipt, Arabic-Indic digits, Hijri date", "font": "naskh", "size": 44, "fields": [
        {"name": "receipt_no", "value": "8820", "accept": ["8820"]},
        {"name": "amount", "value": "22400", "accept": ["22400"]},
        {"name": "hijri_date", "value": "15 ربيع الآخر 1448", "accept": ["15 ربيع الآخر 1448"]},
        {"name": "invoice_no", "value": "6073", "accept": ["6073"]}],
        "lines": [
            "سند قبض",
            "رقم السند: ٨٨٢٠",
            "استلمنا من: شركة الأفق للتقنية",
            "مبلغ وقدره: ٢٢٤٠٠ ريال سعودي",
            "التاريخ: ١٥ ربيع الآخر ١٤٤٨ هـ",
            "وذلك عن: دفعة من الفاتورة رقم ٦٠٧٣",
        ], "damage": {"blur": 0.5, "noise": 5000}},
    "d05": {"title": "bilingual tax invoice", "font": "sans", "size": 38, "fields": [
        {"name": "invoice_id", "value": "INV-2026-0417", "accept": ["INV-2026-0417"]},
        {"name": "vat_no", "value": "399999999900003", "accept": ["399999999900003"]},
        {"name": "subtotal", "value": "10000.00", "accept": ["10000.00", "10000"]},
        {"name": "vat", "value": "1500.00", "accept": ["1500.00", "1500"]},
        {"name": "total", "value": "11500.00", "accept": ["11500.00", "11500"]}],
        "lines": [
            {"r": "فاتورة ضريبية", "l": "Tax Invoice"},
            {"r": "رقم الفاتورة:", "l": "INV-2026-0417"},
            "اسم العميل: شركة الواحة للتجارة",
            {"r": "الرقم الضريبي للعميل:", "l": "399999999900003"},
            {"r": "الإجمالي قبل الضريبة:", "l": "10,000.00"},
            {"r": "ضريبة القيمة المضافة 15 بالمئة:", "l": "1,500.00"},
            {"r": "الإجمالي المستحق:", "l": "11,500.00 SAR"},
        ], "damage": {}},
    "d06": {"title": "phone photo", "font": "kufi", "size": 40, "fields": [
        {"name": "invoice_no", "value": "9156", "accept": ["9156"]},
        {"name": "amount", "value": "2640.00", "accept": ["2640.00", "2640"]},
        {"name": "date", "value": "20 أغسطس 2026", "accept": ["20 أغسطس 2026"]}],
        "lines": [
            "عميلنا العزيز",
            "نود تذكيركم بأن الفاتورة رقم 9156",
            {"r": "بمبلغ بالريال", "l": "2,640.00"},
            "قد تجاوزت تاريخ استحقاقها في 20 أغسطس 2026",
            "شاكرين لكم حسن تعاونكم",
            "قسم الحسابات المدينة في شركة المدار",
        ], "damage": {"scale": 0.7, "rotate": 2.5, "blur": 0.8, "noise": 9000, "jpeg": 35,
                      "paper": 200, "ink": 70}},
}


def truth_line(line):
    if isinstance(line, str):
        return line
    if "cells" in line:
        return " ".join(line["cells"])        # first cell is the rightmost: logical RTL order
    return f"{line['r']} {line['l']}"


def main():
    if "--truth" in sys.argv:
        print(json.dumps(build_truth(), ensure_ascii=False, indent=1))
        return
    from fontTools.ttLib import TTFont
    from PIL import Image, ImageDraw, ImageFilter, ImageFont, features
    if not features.check("raqm"):
        sys.exit("Pillow has no raqm: Arabic would be drawn unshaped. Install libraqm.")
    cmaps = {k: set(TTFont(NOTO + f).getBestCmap()) for k, f in FONTS.items()}
    os.makedirs("docs", exist_ok=True)
    W, M = 1654, 110
    for did, doc in DOCS.items():
        fa = ImageFont.truetype(NOTO + FONTS[doc["font"]], doc["size"])
        fl = ImageFont.truetype(NOTO + FONTS["latin"], doc["size"] - 4)
        lh = int(doc["size"] * 2.6)
        img = Image.new("L", (W, 120 + lh * len(doc["lines"]) + 60), 255)
        d = ImageDraw.Draw(img)

        def cell(text, x_right=None, x_left=None, y=0):
            ar = is_arabic(text)
            key = doc["font"] if ar else "latin"
            missing = {c for c in text if c != " " and ord(c) not in cmaps[key]}
            if missing:
                sys.exit(f"{did}: font {FONTS[key]} has no glyph for {sorted(missing)} in {text!r}")
            font = fa if ar else fl
            kw = {"direction": "rtl", "language": "ar"} if ar else {"direction": "ltr"}
            w = d.textlength(text, font=font, **kw)
            x = x_right - w if x_right is not None else x_left
            d.text((x, y), text, font=font, fill=20, **kw)

        y = 90
        for line in doc["lines"]:
            if isinstance(line, str):
                cell(line, x_right=W - M, y=y)
            elif "cells" in line:
                n = len(line["cells"])
                colw = (W - 2 * M) / n
                for i, c in enumerate(line["cells"]):      # i = 0 is the rightmost column
                    cell(c, x_right=W - M - i * colw, y=y)
            else:
                cell(line["r"], x_right=W - M, y=y)
                cell(line["l"], x_left=M, y=y)
            y += lh
        dmg = doc["damage"]
        if dmg.get("scale"):
            img = img.resize((int(img.width * dmg["scale"]), int(img.height * dmg["scale"])), Image.LANCZOS)
        if dmg.get("rotate"):
            img = img.rotate(dmg["rotate"], resample=Image.BICUBIC, fillcolor=255, expand=True)
        if dmg.get("blur"):
            img = img.filter(ImageFilter.GaussianBlur(dmg["blur"]))
        if dmg.get("paper") or dmg.get("ink"):           # low contrast: grey paper, grey ink
            lo, hi = dmg.get("ink", 0), dmg.get("paper", 255)
            img = img.point(lambda v: int(lo + (hi - lo) * v / 255))
        random.seed(int(did[1:]) * 1000 + 418)
        px = img.load()
        for _ in range(dmg.get("noise", 0)):
            x, yy = random.randrange(img.width), random.randrange(img.height)
            px[x, yy] = random.choice((120, 170, 210, 235))
        img = img.convert("RGB")
        if dmg.get("jpeg"):
            img.save(f"docs/{did}.jpg", "JPEG", quality=dmg["jpeg"])
            img = Image.open(f"docs/{did}.jpg").convert("RGB")
            os.remove(f"docs/{did}.jpg")
        img.save(f"docs/{did}.png", "PNG", optimize=True)
        img.save(f"docs/{did}.pdf", "PDF", resolution=200.0 * dmg.get("scale", 1))
        print(f"wrote docs/{did}.png/.pdf {img.size} ({doc['title']})")
    t = build_truth()
    t["fonts"] = {f: hashlib.sha256(open(NOTO + f, "rb").read()).hexdigest() for f in FONTS.values()}
    with open("docs/truth.json", "w", encoding="utf-8") as fh:
        json.dump(t, fh, ensure_ascii=False, indent=1)
    print("wrote docs/truth.json")


def build_truth():
    return {"docs": {did: {"title": d["title"], "lines": [truth_line(x) for x in d["lines"]],
                           "fields": d["fields"]} for did, d in DOCS.items()}}


if __name__ == "__main__":
    main()
