"""Builds the keyboard's Persian word list (PersianSTTKeyboard/fa_words.txt).

Words come from wordfreq (https://github.com/rspeer/wordfreq, data CC BY-SA 4.0), most frequent
first, one per line with its frequency in Zipf units (log10 of uses per billion words):

    word<TAB>zipf

Kept: words of Persian letters, with Arabic yeh and kaf normalized to the Persian ones and
diacritics removed. Words written with and without ZWNJ (می‌شود, میشود) are merged under the
ZWNJ form, which is the standard spelling; the keyboard matches typed text ignoring ZWNJ.

    pip install wordfreq
    python3 scripts/make_wordlist.py PersianSTTKeyboard/fa_words.txt
"""

import re
import sys

from wordfreq import top_n_list, zipf_frequency

ZWNJ = "‌"
LETTERS = "آابپتثجچحخدذرزژسشصضطظعغفقکگلمنوهیئءأؤة"
WORD = re.compile(f"^[{LETTERS}{ZWNJ}]+$")
DIACRITICS = re.compile("[ً-ٰٟـ]")


def normalize(word: str) -> str:
    word = word.replace("ي", "ی").replace("ى", "ی").replace("ك", "ک").replace("ۀ", "ه‌ی")
    word = DIACRITICS.sub("", word)
    return word.strip(ZWNJ)


def main(out: str) -> None:
    best: dict[str, tuple[str, float]] = {}
    order: list[str] = []
    for raw in top_n_list("fa", 1_000_000):
        word = normalize(raw)
        if not WORD.match(word) or ZWNJ * 2 in word:
            continue
        # Single letters other than و are mostly noise; و is typed alone anyway.
        if len(word.replace(ZWNJ, "")) < 2:
            continue
        zipf = zipf_frequency(raw, "fa")
        if zipf < 1.5:
            continue
        key = word.replace(ZWNJ, "")
        if key not in best:
            best[key] = (word, zipf)
            order.append(key)
        else:
            spelled, total = best[key]
            # Frequencies add up; the ZWNJ spelling wins.
            combined = 10 ** total + 10 ** zipf
            from math import log10

            best[key] = (word if ZWNJ in word and ZWNJ not in spelled else spelled, log10(combined))
    entries = sorted(best.values(), key=lambda e: -e[1])
    with open(out, "w", encoding="utf-8") as f:
        for word, zipf in entries:
            f.write(f"{word}\t{zipf:.2f}\n")
    print(f"{len(entries)} words written to {out}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "fa_words.txt")
