#!/usr/bin/env python3
"""Compresses the weights of the Shenava Core ML model (a NeuralNetwork .mlmodel with fp16 weights).

Usage: compress_model.py <in.mlmodel> <out.mlmodel> <mode>
mode: fp16 (unchanged), linear8 (8-bit linear quantization), or palette<N> (N-bit lookup table from
k-means, N = 1..8). Layers coremltools does not quantize keep fp16 weights. Runs on Linux too: it
works on the model's protobuf and never loads the model.
"""
import sys

import numpy as np
import coremltools as ct
from coremltools.models.neural_network import quantization_utils as q
from google.protobuf.message import Message

src, dst, mode = sys.argv[1:]

_kmeans = q._get_kmeans_lookup_table_and_weight


def kmeans_lut(nbits, weight, *args, **kwargs):
    # Optimal 1-D k-means (kmeans1d) instead of scikit-learn, and a flat table: coremltools 9 returns
    # it as (n, 1), which the protobuf field rejects.
    lut, quantized = _kmeans(nbits, weight, True, *args[1:], **kwargs)
    return lut.reshape(-1), quantized


q._get_kmeans_lookup_table_and_weight = kmeans_lut
spec = ct.utils.load_spec(src)


def weight_params(msg):
    """Every WeightParams inside a protobuf message."""
    if msg.DESCRIPTOR.name == "WeightParams":
        yield msg
        return
    for field, value in msg.ListFields():
        if field.type != field.TYPE_MESSAGE:
            continue
        for item in ([value] if isinstance(value, Message) else value):
            if isinstance(item, Message):
                yield from weight_params(item)


def stats(spec):
    fp16 = fp32 = quantized = 0
    for wp in weight_params(spec):
        fp16 += len(wp.float16Value) // 2
        fp32 += len(wp.floatValue)
        quantized += len(wp.rawValue) and wp.quantization.numberOfBits and len(wp.rawValue) * 8 // wp.quantization.numberOfBits
    return f"weights fp16 {fp16:,} fp32 {fp32:,} quantized {quantized:,}"


print("before:", stats(spec))
if mode != "fp16":
    # coremltools quantizes only float32 weights, so fp16 ones are widened first.
    for wp in weight_params(spec):
        if len(wp.float16Value):
            wp.floatValue.extend(np.frombuffer(wp.float16Value, dtype=np.float16).astype(np.float32))
            wp.ClearField("float16Value")
    if mode == "linear8":
        spec = q._quantize_spec_weights(spec, 8, ct.models._QUANTIZATION_MODE_LINEAR_QUANTIZATION)
    elif mode.startswith("palette"):
        spec = q._quantize_spec_weights(spec, int(mode[7:]), ct.models._QUANTIZATION_MODE_LOOKUP_TABLE_KMEANS)
    else:
        raise SystemExit(f"unknown mode {mode}")
    # Whatever was not quantized (biases, norms, layers coremltools skips) goes back to fp16.
    for wp in weight_params(spec):
        if len(wp.floatValue):
            wp.float16Value = np.array(wp.floatValue, dtype=np.float32).astype(np.float16).tobytes()
            wp.ClearField("floatValue")
print("after: ", stats(spec))
ct.utils.save_spec(spec, dst)
