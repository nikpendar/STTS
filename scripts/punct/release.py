"""Files for the app's automatic punctuation, from the tagger the punctuation research trained
(ALBERT-fa, 6 layers, scripts/punct/train.py) and its Core ML ML program with 8-bit weights.

usage: release.py HF_DIR MLPACKAGE DATA OUT
OUT/punct-vocab.tsv   the SentencePiece pieces (piece TAB score, in id order) the Swift tokenizer reads
OUT/punct-info.json   the tokenizer's normalizer, pre-tokenizer and special ids
OUT/punct-tests.jsonl FLEURS sentences with the Hugging Face token ids, each word's last piece and the
                      Core ML model's labels, for the Swift check (Tests/Punct)
"""
import json, os, sys
import numpy as np
import coremltools as ct
from transformers import AutoTokenizer

hf, pkg, data, out = sys.argv[1:5]
os.makedirs(out, exist_ok=True)
tok = AutoTokenizer.from_pretrained(hf, use_fast=True)
spec = json.load(open(f"{hf}/tokenizer.json", encoding="utf-8"))
model = spec["model"]
assert model["type"] == "Unigram", model["type"]
with open(f"{out}/punct-vocab.tsv", "w", encoding="utf-8") as f:
    for piece, score in model["vocab"]:
        assert "\t" not in piece and "\n" not in piece
        f.write(f"{piece}\t{score}\n")
info = {"normalizer": spec.get("normalizer"), "pre_tokenizer": spec.get("pre_tokenizer"),
        "unk_id": model.get("unk_id"), "byte_fallback": model.get("byte_fallback"),
        "cls": tok.cls_token_id, "sep": tok.sep_token_id, "pad": tok.pad_token_id, "unk": tok.unk_token_id,
        "vocab": len(model["vocab"]), "do_lower_case": getattr(tok, "do_lower_case", None)}
json.dump(info, open(f"{out}/punct-info.json", "w"), ensure_ascii=False, indent=1)
print(json.dumps(info, ensure_ascii=False, indent=1)[:4000])

ml = ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.CPU_ONLY)
rows = [json.loads(l) for l in open(f"{data}/test_fleurs.jsonl", encoding="utf-8")][:150]
# Words with letters the speech model never writes, to check the normalizer too.
rows.append({"words": "آیا مؤسسه‌ی إسلامی ۱۲۳ کتاب‌ها را ﻻزم دارد Hello WORLD".split(), "labels": []})
with open(f"{out}/punct-tests.jsonl", "w", encoding="utf-8") as f:
    for r in rows:
        enc = tok(r["words"], is_split_into_words=True, truncation=True, max_length=128)
        ids = enc["input_ids"]
        last = {}
        for i, w in enumerate(enc.word_ids()):
            if w is not None:
                last[w] = i
        x = np.array([ids], dtype=np.int32)
        logits = ml.predict({"input_ids": x, "attention_mask": np.ones_like(x)})["logits"][0]
        labels = [int(logits[last[w]].argmax()) if w in last else 0 for w in range(len(r["words"]))]
        f.write(json.dumps({"words": r["words"], "ids": ids, "last": [last.get(w, -1) for w in range(len(r["words"]))],
                            "labels": labels, "gold": r["labels"]}, ensure_ascii=False) + "\n")
print("tests", len(rows))
