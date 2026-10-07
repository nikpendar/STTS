"""Convert a Whisper encoder to a Core ML model for the Apple Neural Engine.

Usage: python convert_encoder_coreml.py <whisper.cpp dir> <model name> <out .mlpackage> [--int8]

Uses the ANE-optimized encoder from whisper.cpp's models/convert-whisper-to-coreml.py,
but loads only what the encoder needs so large models fit in a CI runner's memory.
--int8 stores weights as 8-bit, roughly halving the size of the FP16 model.
"""
import gc
import importlib.util
import os
import sys

import coremltools as ct
import torch
import whisper
from whisper.model import ModelDimensions

wcpp_dir, name, out_path = sys.argv[1:4]
int8 = "--int8" in sys.argv[4:]

spec = importlib.util.spec_from_file_location(
    "wcpp_convert", os.path.join(wcpp_dir, "models", "convert-whisper-to-coreml.py"))
conv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(conv)

checkpoint_path = whisper._download(
    whisper._MODELS[name], os.path.expanduser("~/.cache/whisper"), False)
checkpoint = torch.load(checkpoint_path, map_location="cpu")
dims = ModelDimensions(**checkpoint["dims"])
print(dims, flush=True)

model = conv.WhisperANE(dims).eval()
model.load_state_dict(checkpoint["model_state_dict"])
del checkpoint
encoder = model.encoder.float().eval()
del model
gc.collect()

example = torch.randn(1, dims.n_mels, 3000)
with torch.no_grad():
    traced = torch.jit.trace(encoder, example)
del encoder
gc.collect()

mlmodel = ct.convert(
    traced,
    convert_to="mlprogram",
    inputs=[ct.TensorType(name="logmel_data", shape=example.shape)],
    outputs=[ct.TensorType(name="output")],
    compute_units=ct.ComputeUnit.ALL,
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.iOS17,
    skip_model_load=True,
)
del traced
gc.collect()

if int8:
    import coremltools.optimize.coreml as cto
    config = cto.OptimizationConfig(
        global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
    mlmodel = cto.linear_quantize_weights(mlmodel, config)

mlmodel.save(out_path)
print("saved", out_path, flush=True)
