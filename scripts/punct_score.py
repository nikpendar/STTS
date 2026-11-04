#!/usr/bin/env python3
"""Scores automatic punctuation on the speech model's text against the references' marks
(punct-speech.yml). Words of each output are aligned with the reference's (difflib, spelling
normalized); on aligned words, the mark after each counts as none, comma, full stop or question.
Prints a markdown table: F1 for commas, full stops, question marks, sentence ends (full stop or
question mark), and how often the paragraph's last mark is right.

Usage: punct_score.py <eval.jsonl> <label>:<refs.tsv> [...]
"""
import difflib
import json
import re
import sys
from collections import defaultdict

MARKS = {"،": 1, ",": 1, "؛": 1, ";": 1, ":": 1, ".": 2, "!": 2, "؟": 3, "?": 3}
NAMES = ["none", "comma", "stop", "question"]


def tokens(text):
    out = []
    for w in text.split():
        mark = 0
        while w and w[-1] in MARKS:
            mark = max(mark, MARKS[w[-1]]) if mark != 3 else 3
            w = w[:-1]
        w = w.strip("«»\"'()")
        if not w:
            if out and mark:
                out[-1] = (out[-1][0], mark)
            continue
        out.append((norm(w), mark))
    return out


def norm(w):
    w = w.replace("ي", "ی").replace("ك", "ک").replace("‌", "").replace("ـ", "")
    return re.sub(r"[ً-ْ]", "", w)


rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
for spec in sys.argv[2:]:
    label, refs_path = spec.split(":", 1)
    refs = {}
    for l in open(refs_path, encoding="utf-8"):
        if "\t" in l:
            f, s = l.rstrip("\n").split("\t", 1)
            refs[f.rsplit(".", 1)[0]] = s
    stats = defaultdict(lambda: defaultdict(int))
    for r in rows:
        clip = r["clip"].rsplit(".", 1)[0]
        if clip not in refs:
            continue
        hyp, ref = tokens(r["text"]), tokens(refs[clip])
        st = stats[r["variant"]]
        if hyp and ref:
            st["end_total"] += 1
            st["end_right"] += int(hyp[-1][1] == ref[-1][1])
            st["end_question"] += int(hyp[-1][1] == 3)
        sm = difflib.SequenceMatcher(None, [w for w, _ in hyp], [w for w, _ in ref], autojunk=False)
        for a, b, size in sm.get_matching_blocks():
            for k in range(size):
                h, g = hyp[a + k][1], ref[b + k][1]
                for c in (1, 2, 3):
                    st[f"tp{c}"] += int(h == c and g == c)
                    st[f"fp{c}"] += int(h == c and g != c)
                    st[f"fn{c}"] += int(h != c and g == c)
                hb, gb = h >= 2, g >= 2
                st["tpb"] += int(hb and gb)
                st["fpb"] += int(hb and not gb)
                st["fnb"] += int(gb and not hb)

    def f1(st, k):
        tp, fp, fn = st[f"tp{k}"], st[f"fp{k}"], st[f"fn{k}"]
        p = tp / (tp + fp) if tp + fp else 0
        rc = tp / (tp + fn) if tp + fn else 0
        return f"{200 * p * rc / (p + rc) if p + rc else 0:.1f} ({100 * p:.0f}/{100 * rc:.0f})"

    print(f"\n### {label}\n")
    print("| variant | comma F1 (P/R) | stop F1 | question F1 | sentence end F1 | last mark right | ends in ؟ |")
    print("|---|---|---|---|---|---|---|")
    for name, st in stats.items():
        n = max(1, st["end_total"])
        print(f"| {name} | {f1(st, 1)} | {f1(st, 2)} | {f1(st, 3)} | {f1(st, 'b')} | "
              f"{100 * st['end_right'] / n:.0f}% | {100 * st['end_question'] / n:.0f}% |")
