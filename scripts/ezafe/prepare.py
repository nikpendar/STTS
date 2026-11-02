"""HomoRich-G2P-Persian (MahtaFetrat, CC0) as Ezafe training data: (words, labels) per sentence.

usage: prepare.py OUT [MAX_TRAIN]
Words are what the app's phonemizer sees (PersianPhonemizer.clean: Persian letters and ZWNJ, no
diacritics); a word's label is 1 when its "Mapped Phoneme" ends in 1 (GE2PE's Ezafe mark). Sentences
whose word count differs from the phoneme count are left out. Writes OUT/train.jsonl, OUT/test.jsonl.
"""
import json, os, random, sys

import pyarrow.parquet as pq
from huggingface_hub import hf_hub_download

out = sys.argv[1]
max_train = int(sys.argv[2]) if len(sys.argv) > 2 else 400_000
os.makedirs(out, exist_ok=True)


def clean(s):
    o = ""
    for ch in s:
        v = ord(ch)
        if 0x0621 <= v <= 0x063A or 0x0641 <= v <= 0x064A or v in (0x067E, 0x0686, 0x0698, 0x06A9, 0x06AF, 0x06CC, 0x06C0, 0x0622, 0x200C):
            o += ch
        elif o and o[-1] != " " and not (0x064B <= v <= 0x0652) and v != 0x0640:
            o += " "
    return o.replace("ي", "ی").replace("ك", "ک").strip()


path = hf_hub_download("MahtaFetrat/HomoRich-G2P-Persian", "data/train-01.parquet", repo_type="dataset")
table = pq.read_table(path)
print(table.schema, flush=True)
g = table.column("Grapheme").to_pylist()
p = table.column("Mapped Phoneme").to_pylist()
rows, skipped = [], 0
for text, ph in zip(g, p):
    if not text or not ph:
        skipped += 1
        continue
    words, pw = clean(text).split(), ph.split()
    if not words or len(words) != len(pw):
        skipped += 1
        continue
    rows.append({"text": text, "words": words, "labels": [int(x.endswith("1")) for x in pw]})
print(f"{len(rows)} aligned, {skipped} skipped", flush=True)
random.seed(0)
random.shuffle(rows)
test, train = rows[:3000], rows[3000:3000 + max_train]
for name, part in (("train", train), ("test", test)):
    with open(f"{out}/{name}.jsonl", "w", encoding="utf-8") as f:
        for r in part:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
ez = sum(sum(r["labels"]) for r in train)
n = sum(len(r["labels"]) for r in train)
print(f"train {len(train)} sentences, {n} words, {ez / n:.1%} with Ezafe; test {len(test)}", flush=True)
for r in test[:5]:
    print(" ".join(w + ("ِ" if l else "") for w, l in zip(r["words"], r["labels"])))
