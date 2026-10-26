#!/usr/bin/env python3
"""Exports the base Koochik checkpoint in several Core ML formats, for the compression benchmark
(.github/workflows/compress-eval.yml).

    export_variants.py <base.nemo> <out dir> <variant>...

A variant is <format>-<weights>: nn-fp16, nn-int8, mlp-fp16, mlp-int8, mlp-pal6 ... (see
export_coreml.export). Writes <out dir>/Koochik-<variant>.mlmodel or .mlpackage.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_coreml import export  # noqa: E402

import nemo.collections.asr as nemo_asr  # noqa: E402

base, out, variants = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:]
for variant in variants:
    fmt, weights = variant.split("-", 1)
    fmt = {"nn": "neuralnetwork", "mlp": "mlprogram"}[fmt]
    # export() changes the model's attention setup, so each variant starts from the checkpoint.
    model = nemo_asr.models.ASRModel.restore_from(str(base), map_location="cpu")
    path = out / f"Koochik-{variant}.{'mlpackage' if fmt == 'mlprogram' else 'mlmodel'}"
    shapes = export(model, path, fmt=fmt, weights=weights)
    print(variant, json.dumps(shapes), flush=True)
