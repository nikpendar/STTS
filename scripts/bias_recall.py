#!/usr/bin/env python3
"""Share of the target words' occurrences in the references that the hypotheses have.

Usage: bias_recall.py <targets.txt> <refs.tsv:hyp dir> ...
"""
import sys

sys.path.insert(0, sys.path[0])
from wer import normalize  # noqa: E402

targets = set(open(sys.argv[1], encoding="utf-8").read().split())
said = found = 0
for item in sys.argv[2:]:
    refs, hyps = item.split(":")
    for line in open(refs, encoding="utf-8"):
        name, ref = line.rstrip("\n").split("\t", 1)
        try:
            hyp = normalize(open(f"{hyps}/{name}.txt", encoding="utf-8").read()).split()
        except FileNotFoundError:
            hyp = []
        for w in normalize(ref).split():
            if w in targets:
                said += 1
                found += w in hyp
print(f"{100 * found / max(said, 1):.1f} {found}/{said}")
