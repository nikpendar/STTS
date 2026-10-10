"""Builds the keyboard's next-word list (PersianSTTKeyboard/fa_bigrams.bin) from Persian Wikipedia.

For every word of fa_words.txt it keeps the words that most often follow it in Wikipedia
articles, with how likely each one is to come next, plus the words sentences most often start
with. Words are referred to by their line in fa_words.txt (0-based); one more index, after the
last line, is the word «و», which the word list leaves out because it has one letter.

Text: the 20231101.fa config of https://huggingface.co/datasets/wikimedia/wikipedia (CC BY-SA
4.0). Articles shorter than MIN_CHARS are skipped: most of them are bot-made stubs about
villages, all written from one template, which would otherwise decide what follows «در».
Pairs never cross punctuation, digits, Latin text or line breaks, and a word missing from the
list breaks the chain too.

File format, little-endian:

    "FABG"                      magic
    u32 N                       words: lines of fa_words.txt + 1 (و)
    u16 S, S x (u16 word, u8 q) sentence starters, best first
    N x (u8 C, C x (u16 word, u8 q))   followers of each word, best first

q is -8 * log2 of the probability (255 at most): P(next | word) = 2 ** (-q / 8), where the
count of the word is all its occurrences, so the followers of a word that often ends a
sentence add up to well under 1.

    pip install pyarrow numpy huggingface_hub
    python3 scripts/make_bigrams.py PersianSTTKeyboard/fa_words.txt <parquet files...> PersianSTTKeyboard/fa_bigrams.bin
"""

import math
import re
import struct
import sys
from array import array
from multiprocessing import Pool

import numpy as np
import pyarrow.parquet as pq

ZWNJ = "‌"
LETTERS = "آابپتثجچحخدذرزژسشصضطظعغفقکگلمنوهیئءأؤة"
TOKEN = re.compile(f"[{LETTERS}{ZWNJ}]+|[^\\s{LETTERS}{ZWNJ}]+")
SENTENCE_END = re.compile("[.!?؟؛:…]")
# Arabic letters as Persian, diacritics, tatweel and direction marks removed.
TABLE = str.maketrans(
    {"ي": "ی", "ى": "ی", "ك": "ک", "ۀ": "ه‌ی", "ـ": None,
     **{chr(c): None for c in range(0x064B, 0x0653)}, "ٰ": None,
     "‎": None, "‏": None, "﻿": None,
     **{chr(c): None for c in range(0x202A, 0x202F)}}
)

MIN_CHARS = 1500
MIN_PAIR = 4
MAX_FOLLOWERS = 20
STARTERS = 40
LETTER_SET = set(LETTERS + ZWNJ)

vocab: dict[str, int] = {}


def key(word: str) -> str:
    return word.replace(ZWNJ, "")


def load_vocab(path: str) -> list[str]:
    words = [line.split("\t")[0] for line in open(path, encoding="utf-8") if line.strip()]
    words.append("و")
    return words


def init(words: list[str]) -> None:
    global vocab
    vocab = {key(w): i for i, w in enumerate(words)}


def count_file(path: str):
    """Pair codes (left << 15 | right) with counts, word counts and starter counts of one file."""
    n = len(vocab)
    pairs = array("I")
    unigrams = [0] * n
    starters = [0] * n
    articles = kept = 0
    table = pq.read_table(path, columns=["text"])
    for batch in table.to_batches(2000):
        for text in batch.column(0).to_pylist():
            articles += 1
            if text is None or len(text) < MIN_CHARS:
                continue
            kept += 1
            text = text.translate(TABLE)
            for line in text.split("\n"):
                previous = -1
                start = True
                for match in TOKEN.finditer(line):
                    token = match.group()
                    if token[0] in LETTER_SET:
                        index = vocab.get(key(token), -1)
                        if index >= 0:
                            unigrams[index] += 1
                            if start:
                                starters[index] += 1
                            if previous >= 0:
                                pairs.append(previous << 15 | index)
                        previous = index
                        start = False
                    else:
                        previous = -1
                        start = SENTENCE_END.search(token) is not None
    codes, counts = np.unique(np.frombuffer(pairs, dtype=np.uint32), return_counts=True)
    print(f"{path}: {kept}/{articles} articles, {len(pairs)} pairs", flush=True)
    return codes, counts.astype(np.int64), np.array(unigrams, dtype=np.int64), np.array(starters, dtype=np.int64)


def quantize(p: float) -> int:
    return min(255, max(0, round(-8 * math.log2(p))))


def main(words_path: str, parquet: list[str], out: str) -> None:
    words = load_vocab(words_path)
    n = len(words)
    assert n < 1 << 15
    with Pool(initializer=init, initargs=(words,)) as pool:
        results = pool.map(count_file, parquet)
    codes = np.concatenate([r[0] for r in results])
    counts = np.concatenate([r[1] for r in results])
    unigrams = sum(r[2] for r in results)
    starters = sum(r[3] for r in results)
    order = np.argsort(codes, kind="stable")
    codes, counts = codes[order], counts[order]
    unique, first = np.unique(codes, return_index=True)
    totals = np.add.reduceat(counts, first)
    print(f"{int(unigrams.sum())} words, {len(unique)} distinct pairs")

    keep = totals >= MIN_PAIR
    unique, totals = unique[keep], totals[keep]
    left = (unique >> 15).astype(np.int64)
    right = (unique & 0x7FFF).astype(np.int64)
    # Best first within each left word.
    order = np.lexsort((-totals, left))
    left, right, totals = left[order], right[order], totals[order]

    followers: list[list[tuple[int, int]]] = [[] for _ in range(n)]
    for a, b, c in zip(left.tolist(), right.tolist(), totals.tolist()):
        if len(followers[a]) < MAX_FOLLOWERS:
            followers[a].append((b, quantize(c / unigrams[a])))

    sentences = int(starters.sum())
    best_starters = [int(i) for i in np.argsort(-starters)[:STARTERS] if starters[i] > 0]

    blob = bytearray(b"FABG")
    blob += struct.pack("<I", n)
    blob += struct.pack("<H", len(best_starters))
    for i in best_starters:
        blob += struct.pack("<HB", i, quantize(starters[i] / sentences))
    for entries in followers:
        blob += struct.pack("<B", len(entries))
        for b, q in entries:
            blob += struct.pack("<HB", b, q)
    with open(out, "wb") as f:
        f.write(blob)
    stored = sum(len(f) for f in followers)
    print(f"{stored} pairs for {sum(1 for f in followers if f)} words, {len(blob)} bytes written to {out}")

    print("starters:", " ".join(words[i] for i in best_starters[:15]))
    for word in ["از", "به", "می", "خیلی", "سلام", "من", "ما", "چه", "حال", "روز", "دوست", "بسیار",
                 "و", "تشکر", "امیدوارم", "کتاب", "جمهوری", "ایالات"]:
        i = vocab_index(words, word)
        if i is None:
            continue
        shown = ", ".join(f"{words[b]} {2 ** (-q / 8):.3f}" for b, q in followers[i][:8])
        print(f"{word} → {shown}")


def vocab_index(words: list[str], word: str):
    for i, w in enumerate(words):
        if key(w) == key(word):
            return i
    return None


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2:-1], sys.argv[-1])
