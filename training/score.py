#!/usr/bin/env python3
"""Word error rate (%) of <clips dir>/<wav>.txt against refs.tsv ("<wav>\t<reference>" lines).
Prints the number only: the training data is private and the workflow's log is public.

    score.py <refs.tsv> <clips dir>
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from text import distance, normalize  # noqa: E402

refs, clips = sys.argv[1], Path(sys.argv[2])
errors = words = 0
for line in open(refs, encoding="utf-8"):
    name, ref = line.rstrip("\n").split("\t", 1)
    hyp_path = clips / f"{name}.txt"
    hyp = hyp_path.read_text(encoding="utf-8") if hyp_path.exists() else ""
    r = normalize(ref).split()
    errors += distance(r, normalize(hyp).split())
    words += len(r)
print(f"{100 * errors / max(words, 1):.2f}")
