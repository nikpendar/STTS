#!/usr/bin/env python3
"""Persian word and character error rates for whisper.cpp transcripts.

Usage: wer.py <refs.tsv> <hyp_dir> <label> <seconds> <model_bytes> <audio_seconds> <out.json>
refs.tsv has "<wav name>\t<reference>" lines; each hypothesis is <hyp_dir>/<wav name>.txt.
"""
import json
import re
import sys
import unicodedata

DIGITS = str.maketrans("۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩", "01234567890123456789")


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("ي", "ی").replace("ى", "ی").replace("ك", "ک").replace("ة", "ه")
    text = text.replace("أ", "ا").replace("إ", "ا").replace("ٱ", "ا")
    text = re.sub("[ً-ٰٟـ]", "", text)  # diacritics and tatweel
    text = text.replace("‌", " ").replace("‏", "").replace("‎", "")
    text = text.translate(DIGITS)
    text = re.sub(r"[^\w\s]", " ", text)
    return " ".join(text.lower().split())


def distance(a, b) -> int:
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def main():
    refs_path, hyp_dir, label, seconds, size, audio, out = sys.argv[1:]
    words = word_errors = chars = char_errors = 0
    samples = []
    for line in open(refs_path, encoding="utf-8"):
        name, ref = line.rstrip("\n").split("\t", 1)
        try:
            hyp = open(f"{hyp_dir}/{name}.txt", encoding="utf-8").read()
        except FileNotFoundError:
            hyp = ""
        r, h = normalize(ref), normalize(hyp)
        we = distance(r.split(), h.split())
        ce = distance(r.replace(" ", ""), h.replace(" ", ""))
        words += len(r.split())
        word_errors += we
        chars += len(r.replace(" ", ""))
        char_errors += ce
        if len(samples) < 5:
            samples.append({"ref": ref, "hyp": hyp.strip()})
    result = {
        "model": label,
        "wer": round(100 * word_errors / max(words, 1), 1),
        "cer": round(100 * char_errors / max(chars, 1), 1),
        "size_mb": round(int(size) / 1e6),
        "rtf": round(float(seconds) / max(float(audio), 1), 3),
        "samples": samples,
    }
    json.dump(result, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps({k: v for k, v in result.items() if k != "samples"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
