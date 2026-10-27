"""Core ML version of a trained tagger.

convert OUT: OUT/traced.pt -> OUT/Punct-fp16.mlpackage and OUT/Punct-int8.mlpackage (iOS 17 ML programs,
         int8 = linear weight quantization). Runs on Linux.
run NAME MLPACKAGE TOKENIZER_DIR DATA UNITS: scores and times it with Core ML (macOS only).
"""
import json, os, resource, subprocess, sys, time
import numpy as np
import coremltools as ct

sys.path.insert(0, os.path.dirname(__file__))
from common import f1_line, score


def du(path):
    return sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(path) for f in fs)


if sys.argv[1] == "convert":
    import torch
    out = sys.argv[2]
    traced = torch.jit.load(f"{out}/traced.pt")
    shape = (1, ct.RangeDim(lower_bound=2, upper_bound=256, default=32))
    m = ct.convert(traced, inputs=[ct.TensorType(name="input_ids", shape=shape, dtype=np.int32),
                                   ct.TensorType(name="attention_mask", shape=shape, dtype=np.int32)],
                   outputs=[ct.TensorType(name="logits")], minimum_deployment_target=ct.target.iOS17,
                   compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
    m.save(f"{out}/Punct-fp16.mlpackage")
    import coremltools.optimize.coreml as cto
    q = cto.linear_quantize_weights(m, cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric")))
    q.save(f"{out}/Punct-int8.mlpackage")
    for v in ("fp16", "int8"):
        print(f"coreml {v} {du(f'{out}/Punct-{v}.mlpackage')}")
    sys.exit()

_, _, name, pkg, tokdir, data, units = sys.argv
from transformers import AutoTokenizer
tok = AutoTokenizer.from_pretrained(tokdir, use_fast=True)
cu = {"cpu": ct.ComputeUnit.CPU_ONLY, "all": ct.ComputeUnit.ALL}[units]
t0 = time.perf_counter()
model = ct.models.MLModel(pkg, compute_units=cu)
load_s = time.perf_counter() - t0


def tag(words):
    enc = tok(words, is_split_into_words=True, truncation=True, max_length=256)
    ids = np.array([enc["input_ids"]], dtype=np.int32)
    logits = model.predict({"input_ids": ids, "attention_mask": np.ones_like(ids)})["logits"][0]
    pred = [0] * len(words)
    for i, w in enumerate(enc.word_ids()):
        if w is not None:
            pred[w] = int(logits[i].argmax())
    return pred


rows = [json.loads(l) for l in open(f"{data}/test_fleurs.jsonl", encoding="utf-8")]
for r in rows[:10]:
    tag(r["words"])
start = time.perf_counter()
preds = [tag(r["words"]) for r in rows]
ms = 1000 * (time.perf_counter() - start) / len(rows)
s = score((r["labels"], p) for r, p in zip(rows, preds))
print(f1_line(f"{name} coreml {units}", s))
print(json.dumps({"name": name, "units": units, "size_mb": round(du(pkg) / 1e6, 1), "load_s": round(load_s, 2),
                  "ms_per_sentence": round(ms, 1), "peak_rss_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6, 1)}))
