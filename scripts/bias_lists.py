#!/usr/bin/env python3
"""Word lists for the contextual-biasing benchmark (bias-eval.yml).

Usage: bias_lists.py <out dir> <extra text file> <refs.tsv:hyp dir> ...
targets.txt: reference words the plain model misses (in no hypothesis of the clip they belong
to), rare (at most 2 times in all references) and 4+ letters, as a user's dictionary holds the
names the model writes wrong. distractors.txt: as many rare words from other sentences that no
clip says. Both lists together are the realistic dictionary; distractors alone check that words
the user does not say do no harm.
"""
import collections
import random
import sys

sys.path.insert(0, sys.path[0])
from wer import normalize  # noqa: E402

out, extra, *sets = sys.argv[1:]
counts = collections.Counter()
missed = collections.Counter()
for item in sets:
    refs, hyps = item.split(":")
    for line in open(refs, encoding="utf-8"):
        name, ref = line.rstrip("\n").split("\t", 1)
        try:
            hyp = set(normalize(open(f"{hyps}/{name}.txt", encoding="utf-8").read()).split())
        except FileNotFoundError:
            hyp = set()
        words = normalize(ref).split()
        counts.update(words)
        missed.update(w for w in set(words) if w not in hyp)
targets = sorted(w for w in missed if counts[w] <= 2 and len(w) >= 4 and not w.isdigit())
random.seed(7)
targets = sorted(random.sample(targets, min(40, len(targets))))
other = collections.Counter(normalize(open(extra, encoding="utf-8").read()).split())
pool = sorted(w for w, n in other.items() if n == 1 and len(w) >= 4 and w not in counts and not w.isdigit())
distractors = sorted(random.sample(pool, min(len(targets), len(pool))))
open(f"{out}/targets.txt", "w", encoding="utf-8").write("\n".join(targets) + "\n")
open(f"{out}/distractors.txt", "w", encoding="utf-8").write("\n".join(distractors) + "\n")
open(f"{out}/dictionary.txt", "w", encoding="utf-8").write("\n".join(targets + distractors) + "\n")
print(f"targets {len(targets)}, distractors {len(distractors)}")
