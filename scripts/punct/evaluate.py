"""Scores an ONNX punctuation tagger and measures its speed and memory on CPU.

usage: evaluate.py NAME MODEL.onnx TOKENIZER_DIR DATA RESULT.json
Quality: F1 on test_wiki and test_fleurs. Speed: ms per sentence, one sentence at a time (as after a dictation),
1 thread and all threads. Memory: peak RSS of a fresh process that loads the model and tags 200 sentences,
minus the same process without the model.
"""
import json, os, resource, subprocess, sys, time
import numpy as np


def peak_mb():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024


def session(path, threads):
    import onnxruntime as ort
    o = ort.SessionOptions(); o.intra_op_num_threads = threads
    return ort.InferenceSession(path, o, providers=["CPUExecutionProvider"])


def tagger(path, tokdir, threads):
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(tokdir, use_fast=True)
    sess = session(path, threads)

    def tag(words):
        enc = tok(words, is_split_into_words=True, truncation=True, max_length=256)
        ids = np.array([enc["input_ids"]], dtype=np.int64)
        logits = sess.run(None, {"input_ids": ids, "attention_mask": np.ones_like(ids)})[0][0]
        last = {w: i for i, w in enumerate(enc.word_ids()) if w is not None}
        pred = [0] * len(words)
        for w, i in last.items():
            pred[w] = int(logits[i].argmax())
        return pred
    return tag


def load(path):
    return [json.loads(l) for l in open(path, encoding="utf-8")]


if __name__ == "__main__" and sys.argv[1] == "--rss":
    _, _, path, tokdir, data, use = sys.argv
    rows = load(f"{data}/test_fleurs.jsonl")[:200]
    from transformers import AutoTokenizer  # noqa: F401  (counted in the baseline too)
    import onnxruntime  # noqa: F401
    if use == "1":
        tag = tagger(path, tokdir, 1)
        for r in rows:
            tag(r["words"])
    print(peak_mb())
    sys.exit()

sys.path.insert(0, os.path.dirname(__file__))
from common import f1_line, render, score

name, path, tokdir, data, result = sys.argv[1:6]
res = {"name": name, "onnx_mb": round(os.path.getsize(path) / 1e6, 1)}
tag = tagger(path, tokdir, os.cpu_count())
for test in ("test_wiki", "test_fleurs"):
    rows = load(f"{data}/{test}.jsonl")
    preds = [tag(r["words"]) for r in rows]
    s = score((r["labels"], p) for r, p in zip(rows, preds))
    res[test] = s
    print(f1_line(f"{name} {test}", s), flush=True)
    if test == "test_fleurs":
        for r, p in list(zip(rows, preds))[:8]:
            print("  gold:", render(r["words"], r["labels"])); print("  pred:", render(r["words"], p))
rows = load(f"{data}/test_fleurs.jsonl")[:200]
for threads in (1, os.cpu_count()):
    t = tagger(path, tokdir, threads)
    for r in rows[:10]:
        t(r["words"])
    start = time.perf_counter()
    for r in rows:
        t(r["words"])
    res[f"ms_per_sentence_{threads}t"] = round(1000 * (time.perf_counter() - start) / len(rows), 1)
res["mean_words"] = round(sum(len(r["words"]) for r in rows) / len(rows), 1)
rss = [float(subprocess.check_output([sys.executable, __file__, "--rss", path, tokdir, data, u]).split()[-1]) for u in ("0", "1")]
res["rss_model_mb"] = round(rss[1] - rss[0], 1)
res["rss_total_mb"] = round(rss[1], 1)
print(json.dumps({k: v for k, v in res.items() if not k.startswith("test_")}), flush=True)
json.dump(res, open(result, "w"), ensure_ascii=False, indent=1)
