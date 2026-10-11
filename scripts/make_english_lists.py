"""Builds the keyboard's English word list and next-word list (PersianSTTKeyboard/en_words.txt and
PersianSTTKeyboard/en_bigrams.bin), the English counterparts of make_wordlist.py and
make_bigrams.py.

Words: the most frequent English words of wordfreq (https://github.com/rspeer/wordfreq, data
CC BY-SA 4.0), letters with inner apostrophes (don't, I'm), one per line with the Zipf frequency:

    word<TAB>zipf

wordfreq lowercases everything, so names are capitalized from English Wikipedia: a word written
mid-sentence with a capital at least ten times as often as without (London, Monday, English), and
used in Wikipedia at least a twentieth as often as wordfreq's frequency expects. The second test
keeps words lowercase that Wikipedia has mostly in titles (yeah, gonna, World in World War);
I and its contractions are always capitalized.

Next words: the words that most often follow each listed word in English Wikipedia (the
20231101.en config of https://huggingface.co/datasets/wikimedia/wikipedia, CC BY-SA 4.0), in the
format make_bigrams.py documents; here N is exactly the number of lines. Only the first
MAX_ARTICLES long articles of each file are read, which is plenty for common pairs.

    pip install wordfreq pyarrow numpy
    python3 scripts/make_english_lists.py <parquet files...> PersianSTTKeyboard/en_words.txt PersianSTTKeyboard/en_bigrams.bin
"""

import math
import re
import struct
import sys
from array import array
from multiprocessing import Pool

import numpy as np
import pyarrow.parquet as pq
from wordfreq import top_n_list, zipf_frequency

WORDS = 30_000
WORD = re.compile(r"^[a-z]+(?:'[a-z]+)?$")
TOKEN = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*|[^\sA-Za-z]+")
SENTENCE_END = re.compile("[.!?:…]")
MIN_CHARS = 1500
MAX_ARTICLES = 120_000
MIN_PAIR = 4
MAX_FOLLOWERS = 16
STARTERS = 40

vocab: dict[str, int] = {}


def load_words() -> list[tuple[str, float]]:
    words: list[tuple[str, float]] = []
    for word in top_n_list("en", 200_000):
        word = word.replace("’", "'")
        if not WORD.match(word) or (len(word) == 1 and word not in ("a", "i")):
            continue
        words.append((word, zipf_frequency(word, "en")))
        if len(words) == WORDS:
            break
    return words


def init(keys: list[str]) -> None:
    global vocab
    vocab = {k: i for i, k in enumerate(keys)}


def count_file(path: str):
    """Pair codes with counts, word counts, starter counts and mid-sentence capitalized and
    lowercase counts of one file."""
    n = len(vocab)
    pairs = array("I")
    unigrams = [0] * n
    starters = [0] * n
    capital = [0] * n
    lower = [0] * n
    articles = kept = 0
    table = pq.read_table(path, columns=["text"])
    for batch in table.to_batches(2000):
        for text in batch.column(0).to_pylist():
            articles += 1
            if text is None or len(text) < MIN_CHARS:
                continue
            kept += 1
            text = text.replace("’", "'")
            for line in text.split("\n"):
                previous = -1
                start = True
                prose = len(line) >= 40 and line.rstrip().endswith((".", "?", "!"))
                for match in TOKEN.finditer(line):
                    token = match.group()
                    if token[0].isalpha():
                        index = vocab.get(token.lower(), -1)
                        if index >= 0:
                            unigrams[index] += 1
                            if start:
                                if prose:
                                    starters[index] += 1
                            elif token[0].isupper():
                                if len(token) == 1 or not token.isupper():
                                    capital[index] += 1
                            else:
                                lower[index] += 1
                            if previous >= 0:
                                pairs.append(previous << 15 | index)
                        previous = index
                        start = False
                    else:
                        previous = -1
                        start = SENTENCE_END.search(token) is not None
            if kept >= MAX_ARTICLES:
                break
        if kept >= MAX_ARTICLES:
            break
    codes, counts = np.unique(np.frombuffer(pairs, dtype=np.uint32), return_counts=True)
    print(f"{path}: {kept}/{articles} articles, {len(pairs)} pairs", flush=True)
    return (codes, counts.astype(np.int64), np.array(unigrams, dtype=np.int64),
            np.array(starters, dtype=np.int64), np.array(capital, dtype=np.int64), np.array(lower, dtype=np.int64))


def quantize(p: float) -> int:
    return min(255, max(0, round(-8 * math.log2(p))))


def cased(word: str, zipf: float, capital: int, lower: int, total: int) -> str:
    if word == "i" or word.startswith("i'"):
        return "I" + word[1:]
    used = (capital + lower) / max(total, 1)
    if capital >= 20 and capital >= 10 * lower and used >= 0.05 * 10 ** (zipf - 9):
        return word[0].upper() + word[1:]
    return word


def main(parquet: list[str], words_out: str, bigrams_out: str) -> None:
    words = load_words()
    keys = [w for w, _ in words]
    n = len(keys)
    assert n < 1 << 15
    with Pool(initializer=init, initargs=(keys,)) as pool:
        results = pool.map(count_file, parquet)
    codes = np.concatenate([r[0] for r in results])
    counts = np.concatenate([r[1] for r in results])
    unigrams, starters, capital, lower = (sum(r[i] for r in results) for i in range(2, 6))
    order = np.argsort(codes, kind="stable")
    codes, counts = codes[order], counts[order]
    unique, first = np.unique(codes, return_index=True)
    totals = np.add.reduceat(counts, first)
    print(f"{int(unigrams.sum())} words, {len(unique)} distinct pairs")

    total = int(unigrams.sum())
    spelled = [cased(word, zipf, int(capital[i]), int(lower[i]), total) for i, (word, zipf) in enumerate(words)]
    with open(words_out, "w", encoding="utf-8") as f:
        for i, (_, zipf) in enumerate(words):
            f.write(f"{spelled[i]}\t{zipf:.2f}\n")

    keep = totals >= MIN_PAIR
    unique, totals = unique[keep], totals[keep]
    left = (unique >> 15).astype(np.int64)
    right = (unique & 0x7FFF).astype(np.int64)
    order = np.lexsort((-totals, left))
    left, right, totals = left[order], right[order], totals[order]
    followers: list[list[tuple[int, int]]] = [[] for _ in range(n)]
    for a, b, c in zip(left.tolist(), right.tolist(), totals.tolist()):
        if len(followers[a]) < MAX_FOLLOWERS and unigrams[a] > 0:
            followers[a].append((b, quantize(c / unigrams[a])))

    sentences = int(starters.sum())
    best_starters = [int(i) for i in np.argsort(-starters, kind="stable")[:STARTERS] if starters[i] > 0]
    blob = bytearray(b"FABG")
    blob += struct.pack("<I", n)
    blob += struct.pack("<H", len(best_starters))
    for i in best_starters:
        blob += struct.pack("<HB", i, quantize(starters[i] / sentences))
    for entries in followers:
        blob += struct.pack("<B", len(entries))
        for b, q in entries:
            blob += struct.pack("<HB", b, q)
    with open(bigrams_out, "wb") as f:
        f.write(blob)
    print(f"{n} words to {words_out}; {sum(len(f) for f in followers)} pairs, {len(blob)} bytes to {bigrams_out}")

    print("capitalized:", " ".join(w for w, k in zip(spelled, keys) if w != k)[:1500])
    print("starters:", " ".join(keys[i] for i in best_starters[:15]))
    for word in ["the", "i", "thank", "how", "see", "good", "united", "new", "would", "don't"]:
        if word in vocab_index(keys):
            i = vocab_index(keys)[word]
            print(f"{word} → " + ", ".join(f"{keys[b]} {2 ** (-q / 8):.3f}" for b, q in followers[i][:8]))


_index: dict[str, int] = {}


def vocab_index(keys: list[str]) -> dict[str, int]:
    if not _index:
        _index.update({k: i for i, k in enumerate(keys)})
    return _index


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    main(sys.argv[1:-2], sys.argv[-2], sys.argv[-1])
