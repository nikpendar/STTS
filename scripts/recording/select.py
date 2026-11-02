"""A recording script for a new voice: 1500 short sentences from HomoRich-G2P-Persian (CC0) chosen
greedily to cover Persian sound pairs, with some questions.

usage: select.py OUT [COUNT]
Sentences have 4-14 words, Persian letters and ، . ؟ only (no digits, Latin or quotes). Each pick
maximises the sound pairs (in GE2PE phoneme letters, word boundaries included) not yet covered, per
word, so the script stays short to read. Writes OUT/script.txt (numbered) and OUT/script.csv (id|text).
"""
import heapq, os, re, sys
from collections import Counter

import pyarrow.parquet as pq
from huggingface_hub import hf_hub_download

out = sys.argv[1]
count = int(sys.argv[2]) if len(sys.argv) > 2 else 1500
os.makedirs(out, exist_ok=True)
path = hf_hub_download("MahtaFetrat/HomoRich-G2P-Persian", "data/train-01.parquet", repo_type="dataset")
t = pq.read_table(path, columns=["Grapheme", "Mapped Phoneme"])
OK = re.compile(r"^[ء-غف-يپچژکگیآ‌ ،.؟]+$")
seen, cands = set(), []
for g, p in zip(t.column("Grapheme").to_pylist(), t.column("Mapped Phoneme").to_pylist()):
    if not g or not p:
        continue
    g = " ".join(g.replace("ي", "ی").replace("ك", "ک").split())
    n = len(g.split())
    if not 4 <= n <= 14 or not OK.match(g) or g in seen:
        continue
    seen.add(g)
    s = "#" + p.replace(" ", "#") + "#"
    pairs = {s[i:i + 2] for i in range(len(s) - 1)}
    cands.append((g, n, pairs))
print(len(cands), "candidate sentences", flush=True)

covered, picked = Counter(), []


def gain(c):
    # Pairs heard fewer than 3 times count as new, so rare sounds come back a few times.
    return sum(1 for x in c[2] if covered[x] < 3) / c[1]


# Lazy greedy: a sentence's gain only falls as more is covered, so a stale heap entry is an upper bound.
heaps = {q: [(-gain(c), i) for i, c in enumerate(cands) if c[0].endswith("؟") == q] for q in (False, True)}
for h in heaps.values():
    heapq.heapify(h)
taken = set()
while len(picked) < count:
    h = heaps[len(picked) % 10 == 9 and bool(heaps[True])]
    if not h:
        break
    _, i = heapq.heappop(h)
    if i in taken:
        continue
    g = gain(cands[i])
    if h and g < -h[0][0]:
        heapq.heappush(h, (-g, i))
        continue
    taken.add(i)
    picked.append(cands[i])
    for x in cands[i][2]:
        covered[x] += 1
    if len(picked) % 100 == 0:
        print(len(picked), "picked,", len(covered), "pairs covered", flush=True)

allpairs = set().union(*(c[2] for c in cands))
print(f"{len(picked)} sentences, {sum(c[1] for c in picked)} words, pairs {len(covered)} of {len(allpairs)}", flush=True)
with open(f"{out}/script.txt", "w", encoding="utf-8") as f, open(f"{out}/script.csv", "w", encoding="utf-8") as c:
    for i, (g, _, _) in enumerate(picked, 1):
        f.write(f"{i}. {g}\n")
        c.write(f"{i:04d}|{g}\n")
