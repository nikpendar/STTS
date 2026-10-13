"""Exports a Shenava Koochik NeMo model as the app's streaming Core ML model: one cache-aware
encoder step plus the CTC head, an iOS14-target NeuralNetwork with fp16 weights, the same
interface as the published Koochik.mlmodel (ShenavaStream in the app):

    processed_signal [1,80,17] + cache_last_channel [17,1,70,512] + cache_last_time [17,1,512,8]
        -> logits [1,1,1025] + the next caches

Adapted from export_koochik10_streaming_coreml.py by Reza2kn (Apache-2.0), published with
Reza2kn/Shenava-Koochik-1.0-CoreML-iOS15-fp16. Changes: it takes the model in memory, writes
the fp16 weights through the spec so it runs on Linux, and checks the result with a prediction
only on macOS (the training workflow checks the Core ML model on macOS with the app's own code).
"""
from __future__ import annotations

import sys
import types
from pathlib import Path

import numpy as np
import torch


def patch_coremltools_cast() -> None:
    """coremltools turns a traced one-element tensor constant into a number with int(array),
    which NumPy 2.3 and later refuse for arrays that are not 0-dimensional; .item() gives the
    same number for any one-element array."""
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch import ops

    original = ops._cast
    if getattr(original, "patched_for_item", False):
        return

    def _cast(context, node, dtype, dtype_name):
        x = ops._get_inputs(context, node, expected=1)[0]
        if (x.can_be_folded_to_const() and not isinstance(x.val, dtype)
                and np.ndim(x.val) > 0 and np.size(x.val) == 1):
            context.add(mb.const(val=dtype(np.asarray(x.val).item()), name=node.name), node.name)
        else:
            original(context, node, dtype, dtype_name)

    _cast.patched_for_item = True
    ops._cast = _cast


def install_static_full_cache_masks(encoder, att_context: list[int]) -> None:
    """Constant attention masks for the steady-state streaming step (a full feature chunk and a
    full left cache): NeMo's mask builder uses dynamic shape operations that the Core ML
    NeuralNetwork converter cannot take."""

    def _static_create_masks(self, att_context_size, padding_length, max_audio_length, offset, device):
        total = int(max_audio_length)
        rows = torch.arange(total, device=device).view(total, 1)
        cols = torch.arange(total, device=device).view(1, total)
        left, right = int(att_context[0]), int(att_context[1])
        if self.att_context_style == "chunked_limited":
            chunk_size = right + 1
            row_chunk = torch.div(rows, chunk_size, rounding_mode="trunc")
            col_chunk = torch.div(cols, chunk_size, rounding_mode="trunc")
            diff_chunks = row_chunk - col_chunk
            left_chunks = left // chunk_size if left >= 0 else 10000
            allowed = torch.logical_and(diff_chunks <= left_chunks, diff_chunks >= 0)
        else:
            allowed = torch.ones((total, total), dtype=torch.bool, device=device)
            if left >= 0:
                allowed = torch.logical_and(allowed, cols >= rows - left)
            if right >= 0:
                allowed = torch.logical_and(allowed, cols <= rows + right)
        att_mask = torch.logical_not(allowed).unsqueeze(0)
        pad_mask = torch.zeros((1, total), dtype=torch.bool, device=device)
        return pad_mask, att_mask

    encoder._create_masks = types.MethodType(_static_create_masks, encoder)


class StreamingCTCStep(torch.nn.Module):
    def __init__(self, model, feature_frames: int, constant_cache_len: int):
        super().__init__()
        self.encoder = model.encoder
        self.ctc_decoder = getattr(model, "ctc_decoder", None) or model.decoder
        self.feature_frames = int(feature_frames)
        self.constant_cache_len = int(constant_cache_len)

    def forward(self, processed_signal, cache_last_channel, cache_last_time):
        processed_signal_length = processed_signal.new_full((1,), self.feature_frames, dtype=torch.int64)
        cache_last_channel_len = processed_signal.new_full((1,), self.constant_cache_len, dtype=torch.int64)
        encoded, _encoded_len, next_channel, next_time, _next_len = self.encoder.cache_aware_stream_step(
            processed_signal=processed_signal,
            processed_signal_length=processed_signal_length,
            cache_last_channel=cache_last_channel,
            cache_last_time=cache_last_time,
            cache_last_channel_len=cache_last_channel_len,
            keep_all_outputs=False,
        )
        logits = self.ctc_decoder(encoder_output=encoded)
        return logits, next_channel, next_time


def export(model, out_path: Path, att_context=(70, 0)) -> dict:
    """Writes the fp16 Core ML step model to `out_path`; returns its shapes. Changes the
    model's attention setup, so export last."""
    import coremltools as ct

    patch_coremltools_cast()
    att_context = [int(x) for x in att_context]
    model = model.cpu().eval()
    model.encoder.change_attention_model(self_attention_model=None, att_context_size=att_context,
                                         update_config=False, device=torch.device("cpu"))
    model.encoder.setup_streaming_params(att_context_size=att_context)
    install_static_full_cache_masks(model.encoder, att_context)

    cfg = model.encoder.streaming_cfg
    def first(value):
        return int(value[1] if isinstance(value, list) else value)
    feature_frames = first(cfg.pre_encode_cache_size) + first(cfg.chunk_size)
    constant_cache_len = int(cfg.last_channel_cache_size)

    step = StreamingCTCStep(model, feature_frames, constant_cache_len).eval()
    cache_channel, cache_time, _ = model.encoder.get_initial_cache_state(1, torch.float32, torch.device("cpu"))
    x = torch.randn(1, 80, feature_frames, dtype=torch.float32)
    with torch.no_grad():
        logits, next_channel, next_time = step(x, cache_channel, cache_time)
        traced = torch.jit.trace(step, (x, cache_channel, cache_time), strict=False, check_trace=False).eval()
    mlmodel = ct.convert(
        traced,
        source="pytorch",
        convert_to="neuralnetwork",
        minimum_deployment_target=ct.target.iOS14,
        inputs=[
            ct.TensorType(name="processed_signal", shape=x.shape, dtype=np.float32),
            ct.TensorType(name="cache_last_channel", shape=cache_channel.shape, dtype=np.float32),
            ct.TensorType(name="cache_last_time", shape=cache_time.shape, dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="logits"),
            ct.TensorType(name="cache_last_channel_next"),
            ct.TensorType(name="cache_last_time_next"),
        ],
    )
    spec = ct.utils.convert_neural_network_spec_weights_to_fp16(mlmodel.get_spec())
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    ct.utils.save_spec(spec, str(out_path))
    shapes = {
        "feature_frames": feature_frames,
        "processed_signal": list(x.shape),
        "cache_last_channel": list(cache_channel.shape),
        "cache_last_time": list(cache_time.shape),
        "logits": list(logits.shape),
        "bytes": out_path.stat().st_size,
    }
    if sys.platform == "darwin":
        prediction = ct.models.MLModel(str(out_path)).predict({
            "processed_signal": x.numpy(),
            "cache_last_channel": cache_channel.numpy(),
            "cache_last_time": cache_time.numpy(),
        })
        torch_arg = logits.numpy().reshape(-1, logits.shape[-1]).argmax(-1)
        coreml_arg = np.asarray(prediction["logits"]).reshape(-1, logits.shape[-1]).argmax(-1)
        shapes["argmax_agreement"] = float((torch_arg == coreml_arg).mean())
    return shapes
