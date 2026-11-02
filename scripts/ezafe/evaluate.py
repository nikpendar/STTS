"""Ezafe F1 on the held-out HomoRich sentences: the trained tagger (ONNX) against Homo-GE2PE, which
the app uses now (its own Ezafe marks, greedy, release tts-fa-mana).

usage: evaluate.py DATA MODEL_DIR VOICE_DIR
"""
import json, sys, time

import numpy as np
import onnxruntime as ort
from transformers import AutoTokenizer

data, mdir, vdir = sys.argv[1:4]
test = [json.loads(l) for l in open(f"{data}/test.jsonl", encoding="utf-8")]
tok = AutoTokenizer.from_pretrained(f"{mdir}/hf")
enc = ort.InferenceSession(f"{vdir}/g2p-encoder.onnx")
dec = ort.InferenceSession(f"{vdir}/g2p-decoder.onnx")


def tagger(session):
    def run(words):
        e = tok(words, is_split_into_words=True, truncation=True, max_length=128)
        last = {w: i for i, w in enumerate(e.word_ids()) if w is not None}
        ids = np.array([e["input_ids"]], dtype=np.int64)
        logits = session.run(None, {"input_ids": ids, "attention_mask": np.ones_like(ids)})[0][0]
        return [int(logits[last[i]].argmax()) if i in last else 0 for i in range(len(words))]
    return run


def ge2pe(words):
    b = [x + 3 for x in " ".join(words).replace("ی", "ي").encode()]
    h = enc.run(None, {"input_ids": np.array([b], dtype=np.int64)})[0]
    o = [0]
    while len(o) < 4 * len(b) + 16:
        n = int(dec.run(None, {"decoder_input_ids": np.array([o], dtype=np.int64), "encoder_hidden_states": h})[0][0].argmax())
        if n == 1:
            break
        o.append(n)
    ph = bytes(i - 3 for i in o[1:] if 3 <= i < 259).decode("utf-8", "replace").split()
    return [int(x.endswith("1")) for x in ph] if len(ph) == len(words) else None


def f1(pairs):
    tp = fp = fn = 0
    for gold, pred in pairs:
        for g, p in zip(gold, pred):
            tp += g and p; fp += p and not g; fn += g and not p
    pr = tp / max(tp + fp, 1); rc = tp / max(tp + fn, 1)
    return f"F1 {200 * pr * rc / max(pr + rc, 1e-9):.1f} (P {100 * pr:.1f} R {100 * rc:.1f})"


N = int(sys.argv[4]) if len(sys.argv) > 4 else 1000
rows = test[:N]
base, skipped, t = [], 0, time.time()
for r in rows:
    pred = ge2pe(r["words"])
    if pred is None:
        skipped += 1
        pred = [0] * len(r["words"])
    base.append((r["labels"], pred))
print(f"Homo-GE2PE (app now): {f1(base)} on {len(rows)} sentences, {skipped} misaligned counted as no Ezafe, {time.time() - t:.0f} s", flush=True)
for name in ("model.onnx", "model.int8.onnx"):
    run = tagger(ort.InferenceSession(f"{mdir}/{name}"))
    t = time.time()
    pairs = [(r["labels"], run(r["words"])) for r in rows]
    print(f"tagger {name}: {f1(pairs)}, {1000 * (time.time() - t) / len(rows):.1f} ms per sentence", flush=True)
run = tagger(ort.InferenceSession(f"{mdir}/model.int8.onnx"))
for s in ["خود برنامه بدون خطا کامپایل شد", "خدا کرم کرد", "کرم ضد آفتاب را روی میز گذاشتم", "کتاب بزرگ من روی میز است",
          "صدای فارسی آفلاین داخل برنامه کار می‌کند", "سرعت روی پردازنده مک خوب است"]:
    w = s.split()
    print(" ".join(x + ("ِ" if l else "") for x, l in zip(w, run(w))), "| GE2PE:",
          " ".join(x + ("ِ" if l else "") for x, l in zip(w, ge2pe(w) or [0] * len(w))))
