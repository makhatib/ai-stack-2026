"""Shared scoring for the Arabic tests (NOM-418, DoD 2.8).  Standard library only.

normalize()      one Arabic normalisation used by every test, so numbers compare
edits()          word/char Levenshtein distance (corpus WER/CER = sum edits / sum ref len)
score_fields()   named fields scored as match | wrong | absent, never a bare boolean:
                 a stable wrong value and a missing value have different causes.
numbers_in()     every number in a text, for counting invented ("fabricated") numbers.
"""
import re
import unicodedata

_DIGITS = str.maketrans("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹", "01234567890123456789")
_DIACRITICS = re.compile("[ؐ-ًؚ-ٰٟۖ-ۭـ]")  # harakat, tatweel
_LETTERS = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ى": "ي", "ة": "ه"})
_THOUSANDS = re.compile(r"(?<=\d)[,٬](?=\d{3}(?!\d))")
_BIDI = re.compile("[‎‏‪-‮⁦-⁩؜﻿]")


def normalize(s: str) -> str:
    """NFKC, Western digits, no thousands separators, no diacritics/tatweel,
    alef/ya/ta-marbuta folded, punctuation -> space, lower case, single spaces.
    Decimal points between digits are kept (12500.50 stays one token)."""
    s = unicodedata.normalize("NFKC", s or "")
    s = _BIDI.sub("", s).translate(_DIGITS)
    s = s.replace("٫", ".")
    for _ in range(3):
        s = _THOUSANDS.sub("", s)
    s = _DIACRITICS.sub("", s).translate(_LETTERS)
    out = []
    for i, ch in enumerate(s):
        cat = unicodedata.category(ch)
        if ch == "." and 0 < i < len(s) - 1 and s[i - 1].isdigit() and s[i + 1].isdigit():
            out.append(ch)
        elif cat[0] in "PSZC":
            out.append(" ")
        else:
            out.append(ch)
    return " ".join("".join(out).lower().split())


def edits(ref, hyp) -> int:
    """Levenshtein distance between two sequences (lists of words or strings)."""
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1]


def wer_parts(ref: str, hyp: str):
    r, h = normalize(ref).split(), normalize(hyp).split()
    return edits(r, h), len(r)


def cer_parts(ref: str, hyp: str):
    r, h = normalize(ref), normalize(hyp)
    return edits(r, h), len(r)


_NUM = re.compile(r"(?<![\d.])\d+(?:\.\d+)?(?![\d.])")


def numbers_in(s: str):
    """Numbers in a text after normalize(), as strings ("12500", "15", "1448")."""
    return _NUM.findall(normalize(s))


def _has(hyp_n: str, form: str) -> bool:
    f = normalize(form)
    if not f:
        return False
    if f.isdigit() or _NUM.fullmatch(f):
        return f in _NUM.findall(hyp_n)
    return re.search(r"(?:^| )" + re.escape(f) + r"(?: |$)", hyp_n) is not None


MONTHS = ["يناير", "فبراير", "مارس", "ابريل", "مايو", "يونيو", "يوليو", "اغسطس", "سبتمبر",
          "اكتوبر", "نوفمبر", "ديسمبر", "محرم", "صفر", "ربيع الاول", "ربيع الاخر", "ربيع الثاني",
          "جمادي الاولي", "جمادي الاخره", "جمادي الثانيه", "رجب", "شعبان", "رمضان", "شوال",
          "ذو القعده", "ذو الحجه"]


def score_fields(fields, hyp: str):
    """fields: [{"name", "value", "accept": [forms]}].  Returns one row per field:
    {"name", "expected", "got", "verdict": match|wrong|absent}.
    match  = an accepted form (digits or words) is in the text;
    wrong  = no accepted form, but the slot holds another value (a number not
             claimed by another field, or another month name);
    absent = neither."""
    hyp_n = normalize(hyp)
    rows = []
    claimed = {normalize(f["value"]) for f in fields}
    for f in fields:
        got = next((a for a in f["accept"] if _has(hyp_n, a)), None)
        if got is not None:
            rows.append({"name": f["name"], "expected": f["value"], "got": got, "verdict": "match"})
            continue
        if normalize(f["value"]).isdigit():
            other = [n for n in _NUM.findall(hyp_n) if n not in claimed]
            if other:
                rows.append({"name": f["name"], "expected": f["value"], "got": " ".join(other), "verdict": "wrong"})
                continue
        elif f["name"] == "month":
            other = [m for m in MONTHS if _has(hyp_n, m) and m != normalize(f["value"])]
            if other:
                rows.append({"name": f["name"], "expected": f["value"], "got": other[0], "verdict": "wrong"})
                continue
        rows.append({"name": f["name"], "expected": f["value"], "got": None, "verdict": "absent"})
    return rows


def _selftest():
    assert normalize("الفاتورةُ رقم ٢٠٤١، بقيمة 12,500.50 ريالاً") == "الفاتوره رقم 2041 بقيمه 12500.50 ريالا"
    assert normalize("إلى أحمد") == "الي احمد"
    assert wer_parts("ذهب الولد الى المدرسة", "ذهب الولد للمدرسة") == (2, 4)
    assert cer_parts("abc", "abd") == (1, 3)
    f = [{"name": "invoice_no", "value": "2041", "accept": ["2041", "ألفين وواحد وأربعين"]},
         {"name": "day", "value": "15", "accept": ["15", "الخامس عشر"]},
         {"name": "month", "value": "نوفمبر", "accept": ["نوفمبر"]}]
    v = [r["verdict"] for r in score_fields(f, "الفاتورة رقم ٢٠٤١ مستحقة في الخامس عشر من نوفمبر")]
    assert v == ["match", "match", "match"], v
    v = score_fields(f, "الفاتورة رقم 2014 مستحقة في 15 من أكتوبر")
    assert [r["verdict"] for r in v] == ["wrong", "match", "wrong"], v
    assert v[0]["got"] == "2014" and v[2]["got"] == "اكتوبر"
    v = [r["verdict"] for r in score_fields(f, "الفاتورة مستحقة قريبا")]
    assert v == ["absent", "absent", "absent"], v
    # "15" must not match inside "2015" or "150"
    assert [r["verdict"] for r in score_fields(f[1:2], "سنة 2015 و150")] == ["wrong"]
    assert numbers_in("المبلغ ١٢٬٥٠٠ ريال في 15/11/2026") == ["12500", "15", "11", "2026"]
    print("arnorm selftest ok")


if __name__ == "__main__":
    _selftest()
