"""The Ezafe tagger (scripts/ezafe/train.py, release tts-fa-ezafe) as the app's Core ML model.

usage: coreml.py HF_DIR DATA PUNCT_DIR OUT
OUT/Ezafe.mlpackage    iOS 17 ML program, 8-bit weights (as the punctuation tagger)
OUT/ezafe-tests.jsonl  test sentences with Hugging Face's token ids and the Core ML model's labels,
                       for the Swift check (Tests/Ezafe)
Fails when the tokenizer is not the punctuation tagger's (PUNCT_DIR/punct-vocab.tsv and
punct-info.json), whose pieces the app reuses.
"""
import json, os, sys
import numpy as np
import torch
import coremltools as ct
import coremltools.optimize.coreml as cto
from transformers import AutoModelForTokenClassification, AutoTokenizer

hf, data, punct, out = sys.argv[1:5]
os.makedirs(out, exist_ok=True)
tok = AutoTokenizer.from_pretrained(hf, use_fast=True)

# The same pieces, scores and ZWNJ id as the punctuation tagger's.
spec = json.load(open(f"{hf}/tokenizer.json", encoding="utf-8"))
mine = "".join(f"{p}\t{s}\n" for p, s in spec["model"]["vocab"])
theirs = open(f"{punct}/punct-vocab.tsv", encoding="utf-8").read()
info = json.load(open(f"{punct}/punct-info.json", encoding="utf-8"))
same = mine == theirs and tok.convert_tokens_to_ids("[ZWNJ]") == info["zwnj"] and tok.cls_token_id == info["cls"] \
    and tok.sep_token_id == info["sep"]
print(f"tokenizer same as the punctuation tagger's: {same}", flush=True)
if not same:
    sys.exit("::error::the Ezafe tokenizer differs from punct-vocab.tsv; the app would need its own")

model = AutoModelForTokenClassification.from_pretrained(hf).eval()


class Logits(torch.nn.Module):
    def __init__(self, m):
        super().__init__(); self.m = m

    def forward(self, input_ids, attention_mask):
        return self.m(input_ids=input_ids, attention_mask=attention_mask).logits


sample = tok("این یک جمله آزمایشی است که برای ساختن مدل نوشته شده".split(), is_split_into_words=True, return_tensors="pt")
with torch.no_grad():
    traced = torch.jit.trace(Logits(model).eval(), (sample["input_ids"].int(), sample["attention_mask"].int()))
shape = (1, ct.RangeDim(lower_bound=2, upper_bound=256, default=32))
ml = ct.convert(traced, inputs=[ct.TensorType(name="input_ids", shape=shape, dtype=np.int32),
                                ct.TensorType(name="attention_mask", shape=shape, dtype=np.int32)],
                outputs=[ct.TensorType(name="logits")], minimum_deployment_target=ct.target.iOS17,
                compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
ml = cto.linear_quantize_weights(ml, cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric")))
ml.save(f"{out}/Ezafe.mlpackage")
ml = ct.models.MLModel(f"{out}/Ezafe.mlpackage", compute_units=ct.ComputeUnit.CPU_ONLY)

rows = [json.loads(l) for l in open(f"{data}/test.jsonl", encoding="utf-8")][:1000]
rows.append({"words": "آیا مؤسسه‌ی إسلامی کتاب‌ها را ﻻزم دارد خانۀ".split(), "labels": []})
tp = fp = fn = agree = total = 0
with open(f"{out}/ezafe-tests.jsonl", "w", encoding="utf-8") as f:
    for r in rows:
        words = [w.replace("ي", "ی").replace("ك", "ک") for w in r["words"]][:24]
        enc = tok(words, is_split_into_words=True, truncation=True, max_length=256)
        last = {}
        for i, w in enumerate(enc.word_ids()):
            if w is not None:
                last[w] = i
        x = np.array([enc["input_ids"]], dtype=np.int32)
        logits = ml.predict({"input_ids": x, "attention_mask": np.ones_like(x)})["logits"][0]
        labels = [int(logits[last[w]].argmax()) if w in last else 0 for w in range(len(words))]
        gold = r["labels"][:len(words)]
        for p, g in zip(labels, gold):
            tp += p and g; fp += p and not g; fn += g and not p
        f.write(json.dumps({"words": words, "ids": enc["input_ids"], "labels": labels, "gold": gold}, ensure_ascii=False) + "\n")
pr, rc = tp / max(tp + fp, 1), tp / max(tp + fn, 1)
print(f"::notice title=Core ML Ezafe::{len(rows)} sentences: F1 {200 * pr * rc / max(pr + rc, 1e-9):.1f} (P {100 * pr:.1f}, R {100 * rc:.1f})")
size = sum(os.path.getsize(os.path.join(d, n)) for d, _, ns in os.walk(f"{out}/Ezafe.mlpackage") for n in ns)
print(f"::notice title=size::Ezafe.mlpackage {size / 1e6:.1f} MB")
