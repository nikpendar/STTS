#!/usr/bin/env python3
"""Exports the CTC branch of a NeMo (hybrid) FastConformer model to ONNX for sherpa-onnx,
with the metadata sherpa-onnx reads, plus tokens.txt and an int8 copy.

Usage: export_nemo_ctc.py <model.nemo> <out dir>
"""
import os
import sys

import nemo.collections.asr as nemo_asr
import onnx
from onnxruntime.quantization import QuantType, quantize_dynamic

src, out = sys.argv[1:]
os.makedirs(out, exist_ok=True)
model = nemo_asr.models.ASRModel.restore_from(src, map_location="cpu")
model.eval()
if hasattr(model, "cur_decoder"):
    model.change_decoding_strategy(decoder_type="ctc")
    model.set_export_config({"decoder_type": "ctc"})

vocab = list(model.tokenizer.vocab) if hasattr(model.tokenizer, "vocab") else [
    model.tokenizer.ids_to_tokens([i])[0] for i in range(model.tokenizer.vocab_size)]
with open(os.path.join(out, "tokens.txt"), "w", encoding="utf-8") as f:
    for i, token in enumerate(vocab):
        f.write(f"{token} {i}\n")
    f.write(f"<blk> {len(vocab)}\n")

path = os.path.join(out, "model.onnx")
model.export(path)
proto = onnx.load(path)
meta = {
    "vocab_size": str(len(vocab) + 1),
    "normalize_type": "per_feature",
    "subsampling_factor": str(model.cfg.encoder.get("subsampling_factor", 8)),
    "model_type": "EncDecCTCModelBPE",
    "version": "1",
    "model_author": "NeMo",
}
for key, value in meta.items():
    entry = proto.metadata_props.add()
    entry.key, entry.value = key, value
onnx.save(proto, path)
quantize_dynamic(path, os.path.join(out, "model.int8.onnx"), weight_type=QuantType.QUInt8)
print("features:", model.cfg.preprocessor.get("features"), "vocab:", len(vocab), meta)
for name in os.listdir(out):
    print(name, os.path.getsize(os.path.join(out, name)))
