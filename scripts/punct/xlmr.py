"""Ready-made reference: 1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase (47 languages, Apache-2.0)
via the punctuators package, zero-shot on the same test sets. Also scores a trivial baseline that only ends each
sentence with a period. usage: xlmr.py DATA RESULT.json
"""
import glob, json, os, resource, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import f1_line, label_text, score

data, result = sys.argv[1:3]


def split_zwnj(words, labels):
    out = []
    for w, l in zip(words, labels):
        parts = [x for x in w.replace("\u200c", " ").split() if x]
        out += [(x, 0) for x in parts[:-1]] + [(parts[-1], l)]
    return out


res = {"name": "xlmr-47lang"}
for test in ("test_wiki", "test_fleurs"):
    rows = [json.loads(l) for l in open(f"{data}/{test}.jsonl", encoding="utf-8")]
    print(f1_line(f"period-at-end {test}", score((r["labels"], [0] * (len(r["words"]) - 1) + [2]) for r in rows)))

from punctuators.models import PunctCapSegModelONNX
model = PunctCapSegModelONNX.from_pretrained("1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase")
files = [f for f in glob.glob(os.path.expanduser("~/.cache/huggingface/hub/models--1-800-BAD-CODE--xlm*/blobs/*"))]
res["download_mb"] = round(sum(os.path.getsize(f) for f in files) / 1e6, 1)
for test in ("test_wiki", "test_fleurs"):
    rows = [json.loads(l) for l in open(f"{data}/{test}.jsonl", encoding="utf-8")][:1000]
    start = time.perf_counter()
    outs = [model.infer([" ".join(r["words"])], apply_sbd=True)[0] for r in rows]
    res[f"ms_per_sentence_{test}"] = round(1000 * (time.perf_counter() - start) / len(rows), 1)
    pairs, skipped = [], 0
    for r, o in zip(rows, outs):
        # The model writes ZWNJ as a space, so both sides are compared with ZWNJ parts as separate words.
        gold = split_zwnj(r["words"], r["labels"])
        pred = split_zwnj(*label_text(" ".join(o)))
        if [w for w, _ in gold] != [w for w, _ in pred]:
            skipped += 1; continue
        pairs.append(([l for _, l in gold], [l for _, l in pred]))
    s = score(pairs); s["skipped"] = skipped
    res[test] = s
    print(f1_line(f"xlmr {test}", s), "skipped", skipped)
    if test == "test_fleurs":
        for o in outs[:5]:
            print("  pred:", " ".join(o))
res["peak_rss_mb"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024, 1)
print(json.dumps({k: v for k, v in res.items() if not k.startswith("test_")}))
json.dump(res, open(result, "w"), ensure_ascii=False, indent=1)
